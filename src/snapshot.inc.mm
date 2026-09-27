// What the mod takes out of the game's frame. The first half is the small texture helpers everything
// uses, and the second copies the images MetalFX and the interpolator need, each at the one moment in the
// frame where it is finished and not yet overwritten.

static __thread bool g_inOwnAlloc = false;   // true while WE allocate on this thread (so the creation probe skips our textures)
static std::atomic<void*> g_fsrOutPending{nullptr};   // FSR-out candidate seen by the creation hook (any thread), adopted by the render thread
// TODO: copies the whole texture, not the active viewport, which is why a window below the display's
// size stands MetalFX down. Needs the scaler's content rect too, not just a smaller copy.
static id<MTLTexture> make_copy_like(id<MTLTexture> src, MTLTextureUsage usage) {
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                                  width:src.width
                                                                                 height:src.height
                                                                              mipmapped:NO];
    td.usage = usage;
    td.storageMode = MTLStorageModePrivate;

    g_inOwnAlloc = true;
    id<MTLTexture> t = [g_device newTextureWithDescriptor:td];   // +1 owned
    g_inOwnAlloc = false;
    return t;
}

static void retire_obj(id* slot);   // defined with the resize handling, in resize_lifetime
// The texture usage MetalFX REQUESTS for one of its inputs (0 colour, 1 depth, 2 motion, 3 output), OR-ed
// with what our own passes need: ask the framework, do not guess. While no scaler exists
// yet the request is unknown and `ours` stands alone, and mfx_check_copy_usage() settles that afterwards.
static MTLTextureUsage mfx_usage(int which, MTLTextureUsage ours) {
    if (!g_scaler) return ours;

    switch (which) {
        case 0: return ours | g_scaler.colorTextureUsage;
        case 1: return ours | g_scaler.depthTextureUsage;
        case 2: return ours | g_scaler.motionTextureUsage;
        default: return ours | g_scaler.outputTextureUsage;
    }
}

static bool same_dims(id<MTLTexture> a, id<MTLTexture> b) {
    return a && b && a.width == b.width && a.height == b.height && a.pixelFormat == b.pixelFormat;
}

// A frame-interpolator input copy is reusable when it matches its source and carries every usage bit the
// interpolator requests (the bits are known only once the interpolator exists).
static bool fi_copy_ok(id<MTLTexture> copy, id<MTLTexture> src, MTLTextureUsage need) {
    return same_dims(copy, src) && (copy.usage & need) == need;
}

// Name our own objects so a GPU capture shows "BG3MFX ..." instead of "MTLTexture 301" for debugging
static inline void mfx_label(id obj, const char* name) {
    // Labels exist for Xcode's GPU capture and for reading the log next to a trace. Nothing reads
    // them while playing, and each one is an NSString allocation on an object we create EVERY frame
    // (the snapshot blit, the composite encoder, our own CB). Gate them on the two situations that
    // can actually look at them.
    if (!g_logging && !g_gpuCapture) return;
    if (obj && [obj respondsToSelector:@selector(setLabel:)]) [obj setLabel:[NSString stringWithUTF8String:name]];
}

// Copy MetalFX's three inputs (pre-TAA colour, depth, motion) into our persistent textures, plus the FI
// ring and the bloom reference. Returns true when it encoded a snapshot for this chain (the event path
// then encodes MetalFX right behind it), false when there was nothing to snapshot.
static bool snapshot_pre_taa(id gameCB) {
    MARK("snapshot_pre_taa");
    if (!g_needSnapshot) return false;
    g_needSnapshot = false;
    id<MTLTexture> csrc = g_snapSrc;
    if (g_mode != 0 || !csrc || !g_device) return false;

    // Snapshot all three temporal inputs here, the one valid point: the frame just wrote them and TAA is
    // about to read them, so reading them live from our async CB would race the pool allocator. Usage is
    // what MetalFX requests plus ShaderRead for our probes.
    if (!g_colorCopy) {
        g_colorCopy = make_copy_like(csrc, mfx_usage(0, MTLTextureUsageShaderRead));
        mfx_label(g_colorCopy, "BG3MFX in: colour (pre-TAA, render res)");
    }
    if (g_depth && !g_depthCopy) {
        g_depthCopy = make_copy_like(g_depth, mfx_usage(1, MTLTextureUsageShaderRead));
        mfx_label(g_depthCopy, "BG3MFX in: depth");
    }
    if (g_mv && !g_mvCopy) {
        g_mvCopy = make_copy_like(g_mv, mfx_usage(2, MTLTextureUsageShaderRead));
        mfx_label(g_mvCopy, "BG3MFX in: motion vectors");
    }

    if (!same_dims(csrc, g_colorCopy)) return false;

    // Delay the jitter by one frame in lockstep with the colour content (see g_jxLive/g_jxPending).
    // Without this step MetalFX would be told the frame carries no jitter while BG3 keeps jittering.
    g_jxLive = g_jxPending;
    g_jyLive = g_jyPending;
    g_jxPending = g_jx;
    g_jyPending = g_jy;

    bool wantDepth = same_dims(g_depth, g_depthCopy);
    bool wantMotion = same_dims(g_mv, g_mvCopy);

    // The pre-bloom reference for the bloom extract rides in the same encoder. It is a copy, not a
    // reference: BG3 ping-pongs the post-TAA attachments, so a live pointer can be overwritten by ord49's
    // combine. This boundary (first after TAA, before the bloom ladder) is where TAA's output is untouched.
    bool wantTaa = g_gradingHarvest && g_gradingBloom && g_gradingApply && g_taaFresh && !g_taaCopied &&
                   g_taaAtt;   // its only reader is the bloom extract
    if (wantTaa && !same_dims(g_taaCopy, g_taaAtt)) {
        retire_obj((id*)&g_taaCopy);   // BG3's unretained CB may still read the old one
        g_taaCopy = make_copy_like(g_taaAtt, MTLTextureUsageShaderRead);
        if (!same_dims(g_taaCopy, g_taaAtt)) wantTaa = false;
    }

    // Frame interpolation: its own two-slot copies of depth and motion, plus the jitter and projection of
    // this frame, filed under this chain. Same encoder, two more copies (~13 MB).
    int fiSlot = -1;
    if (g_fi && g_depth && g_mv) {
        fiSlot = (int)(g_chainId % (uint32_t)FI_RING);
        if (!fi_copy_ok(g_fiDepth[fiSlot], g_depth, g_fiNeedDepth)) {
            retire_obj((id*)&g_fiDepth[fiSlot]);
            g_fiDepth[fiSlot] = make_copy_like(g_depth, g_fiNeedDepth);
        }
        if (!fi_copy_ok(g_fiMv[fiSlot], g_mv, g_fiNeedMotion)) {
            retire_obj((id*)&g_fiMv[fiSlot]);
            g_fiMv[fiSlot] = make_copy_like(g_mv, g_fiNeedMotion);
        }
        if (!g_fiDepth[fiSlot] || !g_fiMv[fiSlot]) fiSlot = -1;
        else {
            g_fiJx[fiSlot] = g_jx;
            g_fiJy[fiSlot] = g_jy;
            memcpy(g_fiProj[fiSlot], g_lastProj, sizeof(g_lastProj));
            std::atomic_thread_fence(std::memory_order_release);
            g_fiChain[fiSlot].store(g_chainId, std::memory_order_release);
        }   // publish LAST
    }

    id<MTLBlitCommandEncoder> b = [gameCB blitCommandEncoder];
    mfx_label(b, "BG3MFX snapshot: colour+depth+motion (+TAA-out, +FI depth/motion) -> our copies");
    [b copyFromTexture:csrc toTexture:g_colorCopy];
    if (wantDepth) [b copyFromTexture:g_depth toTexture:g_depthCopy];
    if (wantMotion) [b copyFromTexture:g_mv toTexture:g_mvCopy];
    if (fiSlot >= 0) {
        [b copyFromTexture:g_depth toTexture:g_fiDepth[fiSlot]];
        [b copyFromTexture:g_mv toTexture:g_fiMv[fiSlot]];
    }
    if (wantTaa) {
        [b copyFromTexture:g_taaAtt toTexture:g_taaCopy];
        g_taaCopied = true;
        static bool once = false;
        if (!once) {
            once = true;
            log_line("GRAD pre-bloom SNAPSHOT: copying the TAA output (%p) in the snapshot encoder. The live "
                     "attachment is overwritten by ord49's combine on ping-pong frames.",
                     (void*)g_taaAtt);
        }
    }

    [b endEncoding];
    g_snapCount++;
    return true;
}

// fi_ui: snapshot the HUD-free world and the UI layer IN THIS FRAME, at the encoder boundary right before
// CombineUI (see the globals). `uiSrc` is the colour attachment of the encoder created just before, the
// Noesis output CombineUI is about to sample. Both copies go into ONE blit encoder on BG3's CB, the chain
// is published at encode time (release) and the GPU completion of this CB is the same completion that
// passes the frame to the presenter.
static int vs_ring_index(id t);                           // defined with the ring, in the presenter
static bool vs_slot_owner_gen(int slot, uint32_t* gen);   // generation of the proxy currently rendering into `slot`
static void snapshot_world_ui_inframe(id gameCB, id<MTLTexture> uiSrc, id<MTLTexture> ringTex) {
    id<MTLTexture> w = g_scene;
    int slot = vs_ring_index(ringTex);
    uint32_t gen = 0;
    if (slot < 0 || !vs_slot_owner_gen(slot, &gen) || !w || !g_outW || w.width != g_outW || w.height != g_outH) {
        g_wuSnapNoSrc++;
        return;
    }

    if (!uiSrc || uiSrc.width != w.width || uiSrc.height != w.height || uiSrc.pixelFormat == w.pixelFormat) {
        // No plausible UI source before this CombineUI (a UI-less frame, or the previous encoder was not
        // the Noesis pass). Publish nothing: composeOK stays false for this chain -> vtex fallback.
        g_wuSnapNoSrc++;
        return;
    }

    if (!fi_copy_ok(g_wSnap[slot], w, g_fiNeedColor)) {
        retire_obj((id*)&g_wSnap[slot]);
        g_wSnap[slot] = make_copy_like(w, g_fiNeedColor);
        mfx_label(g_wSnap[slot], "BG3MFX HUD-free world snapshot");
    }
    if (!same_dims(g_uiSnap[slot], uiSrc)) {
        retire_obj((id*)&g_uiSnap[slot]);
        g_uiSnap[slot] = make_copy_like(uiSrc, MTLTextureUsageShaderRead);
        mfx_label(g_uiSnap[slot], "BG3MFX UI layer snapshot");
    }

    if (!g_wSnap[slot] || !g_uiSnap[slot]) {
        g_wuSnapNoSrc++;
        return;
    }

    g_wFmt = w.pixelFormat;
    id<MTLBlitCommandEncoder> b = [gameCB blitCommandEncoder];
    mfx_label(b, "BG3MFX fi_ui snapshot: world + UI layer (in-frame, before CombineUI)");
    [b copyFromTexture:w toTexture:g_wSnap[slot]];
    [b copyFromTexture:uiSrc toTexture:g_uiSnap[slot]];
    [b endEncoding];

    g_uiSnapSrc[slot] = (void*)uiSrc;
    std::atomic_thread_fence(std::memory_order_release);
    g_wSnapGen[slot].store(gen, std::memory_order_release);
    g_uiSnapGen[slot].store(gen, std::memory_order_release);
    g_uiSnapped++;   // an error on this command buffer is reported by vs_present's completion handler
}
