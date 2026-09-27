// A new resolution makes every texture here the wrong size, so the scaler and its copies are retired and
// rebuilt lazily. Freeing is deferred, because BG3's frame command buffers do not retain our textures and
// releasing one while a submitted buffer still reads it would be a use-after-free, so a retired object
// sits in a small graveyard for a few presents first.

// resolution changes
// Triggered by the graphics menu, a fullscreen/windowed toggle, or moving to another display.
// MTLFXTemporalScaler is built for fixed input and output sizes and the snapshot copies are allocated
// once, so without a rebuild every dimension check fails: snapshot_pre_taa bails out, mfx_active() stops
// suppressing BG3's own FSR, and the game renders without us with nothing on screen to say so.

// Ask the framework for its texture-usage requirements instead of guessing them. The first snapshot
// precedes the first scaler build, because the build needs g_color and the TAA bind sets it a moment
// earlier, so those copies carry our guess alone. Once the scaler exists, any copy whose usage lacks a
// requested flag is retired and re-created with the request OR-ed in. The request is logged either way.
static void mfx_check_copy_usage(void) {
    if (!g_scaler) return;

    const MTLTextureUsage uC = g_scaler.colorTextureUsage, uD = g_scaler.depthTextureUsage,
                          uM = g_scaler.motionTextureUsage, uO = g_scaler.outputTextureUsage;
    log_line("MetalFX texture usage requested: colour=0x%lx depth=0x%lx motion=0x%lx output=0x%lx", (unsigned long)uC,
             (unsigned long)uD, (unsigned long)uM, (unsigned long)uO);

    struct {
        id<MTLTexture>* slot;
        MTLTextureUsage need;
        const char* name;
    } chk[] = {
        {&g_colorCopy, uC, "colour"},
        {&g_depthCopy, uD, "depth"},
        {&g_mvCopy, uM, "motion"},
        {&g_out, uO, "output"},
    };

    for (auto& c : chk) {
        id<MTLTexture> t = *c.slot;
        if (!t || (t.usage & c.need) == c.need) continue;
        log_line("MetalFX %s copy has usage 0x%lx but the scaler requests 0x%lx, re-creating it with the "
                 "requested flags",
                 c.name, (unsigned long)t.usage, (unsigned long)c.need);
        retire_obj((id*)c.slot);
    }
}

// A resize retires the ring, the presenter's objects, the scaler copies and the snapshot rings within a
// few presents (over 50 objects), and the capacity covers that with room. Retirements come from the render
// thread and the presenter thread, the drain runs on the render thread, so the array is locked.
#define GRAVE_CAP 96
static struct {
    id obj;
    uint32_t at;
} g_grave[GRAVE_CAP];
static int g_graveN = 0;
static pthread_mutex_t g_graveMtx = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_graveOverflow = 0;
static void retire_obj(id* slot) {
    id obj = *slot;
    if (!obj) return;
    *slot = nil;

    pthread_mutex_lock(&g_graveMtx);
    bool stored = g_graveN < GRAVE_CAP;
    if (stored) g_grave[g_graveN++] = {obj, g_presentCount};
    pthread_mutex_unlock(&g_graveMtx);

    if (!stored) {   // never expected; freeing now risks an in-flight read, so say it
        if (++g_graveOverflow == 1)
            log_line_always("GRAVEYARD FULL (%d entries): an object was released immediately", GRAVE_CAP);
        [obj release];
    }
}

static void drain_graveyard(void) {
    id freed[GRAVE_CAP];
    int n = 0;

    pthread_mutex_lock(&g_graveMtx);
    for (int i = 0; i < g_graveN;) {
        if (g_presentCount - g_grave[i].at >=
            8) {   // longer than anything in flight: BG3's 2-3 frames, the FIFO, the presenter's current frame
            freed[n++] = g_grave[i].obj;
            g_grave[i] = g_grave[--g_graveN];
        } else i++;
    }
    pthread_mutex_unlock(&g_graveMtx);

    for (int i = 0; i < n; i++) [freed[i] release];
}

static int g_dimChangeSeen = 0, g_resizes = 0;
static void teardown_for_resize(void) {
    retire_obj((id*)&g_scaler);
    retire_obj((id*)&g_colorCopy);
    retire_obj((id*)&g_depthCopy);
    retire_obj((id*)&g_mvCopy);
    retire_obj((id*)&g_out);
    retire_obj((id*)&g_gradInCand);
    retire_obj((id*)&g_bloomTex);
    retire_obj((id*)&g_taaCopy);

    // Cached per-frame references to now-dead pool textures
    cache_tex(&g_gradAtt, nil);
    cache_tex(&g_taaAtt, nil);
    g_taaCopied = false;
    for (int i = 0; i < g_gradPoolN; i++) [g_gradPool[i] release];
    g_gradPoolN = 0;
    g_gradInSrc = nullptr;
    g_pendingGradOut = false;
    g_taaFresh = false;
    g_bloomReady = false;
    g_needSnapshot = false;
    g_snapSrc = nil;

    // The new resolution allocates new attachments, so ord49's remembered one is stale. Clearing
    // `seen` as well puts the candidate blit back into its broad mode until ord49 is identified again.
    g_bloomOutTex = nullptr;
    g_bloomCombineChain = 0xFFFFFFFFu;
    g_bloomCombineSeen = false;
    g_gradCandChain = 0xFFFFFFFFu;
    g_evPendingChain = 0xFFFFFFFFu;   // event path: no composite waits for an encode whose inputs just died
    g_reset = true;                   // MetalFX history is meaningless across a resolution change
    g_buildTries = 0;                 // re-arm the build attempts (they give up after 30)

    g_encLogged = false;
    g_fsrOutLogged = false;
    g_gradLogged = false;
    g_gradApplyLogged = false;
    g_bloomLogged = false;

    // g_fsrOut is deliberately KEPT: the creation hook replaces it when BG3 allocates the new one,
    // and same_dims() guards every use until then. Dropping it here would break the native path if
    // this teardown ever fired without a real resize. The harvested LUT is a colour mapping and is
    // resolution-independent, so it stays valid too.
    g_resizes++;
}

// Called once per present, where the frame's observed dimensions have settled.
static void maybe_handle_resize(void) {
    if (!g_scaler || !g_inW || !g_outW) return;

    // The candidates are the sizes the LAST passes of this frame reported (capture_mfx_inputs). A secondary
    // view mid-frame does not reach here, whereas a real resolution change holds for two presents.
    if (g_candInW == g_builtInW && g_candInH == g_builtInH && g_candOutW == g_builtOutW && g_candOutH == g_builtOutH) {
        g_dimChangeSeen = 0;
        return;
    }

    // A candidate that flips between presents is a secondary view, not a resize: it must repeat itself.
    static NSUInteger lastIn = 0, lastInH = 0, lastOut = 0, lastOutH = 0;
    bool same = g_candInW == lastIn && g_candInH == lastInH && g_candOutW == lastOut && g_candOutH == lastOutH;
    lastIn = g_candInW;
    lastInH = g_candInH;
    lastOut = g_candOutW;
    lastOutH = g_candOutH;
    if (!same) {
        g_dimChangeSeen = 0;
        return;
    }

    if (++g_dimChangeSeen < 2) return;
    g_dimChangeSeen = 0;

    log_line("RESIZE #%d: %lux%lu -> %lux%lu (out %lux%lu -> %lux%lu): rebuilding scaler + copies", g_resizes + 1,
             (unsigned long)g_builtInW, (unsigned long)g_builtInH, (unsigned long)g_candInW, (unsigned long)g_candInH,
             (unsigned long)g_builtOutW, (unsigned long)g_builtOutH, (unsigned long)g_candOutW,
             (unsigned long)g_candOutH);

    g_inW = g_candInW;
    g_inH = g_candInH;
    g_outW = g_candOutW;
    g_outH = g_candOutH;
    teardown_for_resize();
}
