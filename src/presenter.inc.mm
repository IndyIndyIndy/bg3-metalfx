// Frame interpolation cannot be added from inside the game's own presentation, so the mod takes the
// presentation away from it. The game renders into our textures behind a stand-in drawable, and a
// display link then shows an interpolated and a real image in turn. The limiter that keeps the game in
// step with those ticks is at the end of the file.

// fi_ui identity check on CombineUI's texture binds: its "Tex" (fragment texture 1) must be the texture
// snapshot_world_ui_inframe blitted for this frame. On a mismatch the slot is invalidated and the presenter
// shows vtex instead of composing the wrong UI. Nothing here autoreleases.
static IMP o_setFragTexN = nullptr;
static void s_setFragTexN(id self, SEL _cmd, const id<MTLTexture>* texs, NSRange r) {
    if (g_fiUi && texs && r.location <= 1 && r.location + r.length > 1 &&
        objc_getAssociatedObject(self, &kFinalCompKey)) {
        id<MTLTexture> t = texs[1 - r.location];
        int slot = vs_ring_index(objc_getAssociatedObject(self, &kEncColor0Key));
        uint32_t gen = 0;
        if (t && slot >= 0 && vs_slot_owner_gen(slot, &gen) &&
            g_uiSnapGen[slot].load(std::memory_order_relaxed) == gen) {
            if (g_uiSnapSrc[slot] == (void*)t) g_uiSrcMatch++;
            else {
                g_uiSrcMismatch++;
                g_uiSnapGen[slot].store(0xFFFFFFFFu, std::memory_order_release);
                if (g_uiSrcMismatch <= 5 || g_uiSrcMismatch % 500 == 0)
                    log_line("FI UI SOURCE MISMATCH #%llu: CombineUI Tex=%p %s %lux%lu, we blitted %p (chain %u) -> "
                             "slot invalidated",
                             (unsigned long long)g_uiSrcMismatch, (void*)t, pfName(t.pixelFormat) ?: "?",
                             (unsigned long)t.width, (unsigned long)t.height, g_uiSnapSrc[slot], g_chainId);
            }
        }
    }
    ((void (*)(id, SEL, const id<MTLTexture>*, NSRange))o_setFragTexN)(self, _cmd, texs, r);
}

// the drawable proxy
// BG3 never touches a real drawable while the virtual swapchain is on: nextDrawable hands it this object,
// whose `texture` is one of OUR ring textures (vtex), and its presentDrawable: is intercepted (vs_intercept).
// BG3 calls exactly two things on a drawable: `texture`, and presentDrawable.
// Owning the presentation this way is what makes frame interpolation possible: a guest in BG3's present loop cannot insert an image.
@interface BG3MFXDrawableProxy : NSObject <CAMetalDrawable>
@property (nonatomic, retain) id<MTLTexture> vtex;    // OUR ring texture BG3 renders this frame into
@property (nonatomic, assign) CAMetalLayer* vlayer;   // the layer the proxy stands in for
@property (nonatomic, assign) int vslot;         // ring slot of vtex (also the slot of this frame's world/UI snapshots)
@property (nonatomic, assign) uint32_t vchain;   // g_chainId when BG3 presented it
@property (nonatomic, assign) uint32_t vgen;     // hand-out generation (tags this frame's world/UI snapshots)
@property (nonatomic, assign)
    void* vsceneSrc;   // g_scene (the tonemapped-world pool texture) at CombineUI: scene-cut signal
@end

static void vs_free_slot(BG3MFXDrawableProxy* p);
@implementation BG3MFXDrawableProxy
- (void)dealloc {
    vs_free_slot(self);
    [_vtex release];
    [super dealloc];
}   // a proxy BG3 drops without presenting still returns its slot
- (id<MTLTexture>)texture {
    return _vtex;
}

- (CAMetalLayer*)layer {
    return _vlayer;
}

- (void)present {
}

- (void)presentAtTime:(CFTimeInterval)t {
    (void)t;
}

- (void)presentAfterMinimumDuration:(CFTimeInterval)d {
    (void)d;
}

- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block {
    (void)block;
}

- (CFTimeInterval)presentedTime {
    return 0.0;
}

- (NSUInteger)drawableID {
    return 0;
}
@end

// the virtual swapchain
// BG3 renders every frame into one of OUR ring textures and its presentDrawable: is swallowed. What replaces
// the present is a completion handler on BG3's command buffer (the one hook the present boundary allows),
// which hands the finished frame (the proxy) to the presenter through a small FIFO. Only the presenter
// takes real drawables. Images reach a drawable through a fullscreen-triangle render pass (vs_emit), never
// a blit: the drawables are framebufferOnly and a render target is the one thing such a texture may be.
static id<MTLTexture> g_vsTex[VS_RING];

// The proxy that owns slot i, from hand-out until the presenter has shown its frame, with nil meaning
// free. Not retained, because BG3 holds the proxy, and it is written by the render thread and by the
// completion handlers that free a slot.
static BG3MFXDrawableProxy* volatile g_vsSlotProxy[VS_RING];
static uint32_t g_vsGen = 0;   // hand-out generation counter
static std::atomic<uint32_t> g_vsRingGen{0};   // bumped by the render thread on a ring rebuild; the presenter thread reacts (fi_release_objects)
static uint32_t g_vsRingGenSeen = 0;   // presenter thread only
static int g_vsSyncOriginal = -1;      // BG3's displaySyncEnabled before we changed it (-1 = untouched)

// Free a proxy's ring slot, but only if the proxy still owns it: after a ring rebuild or a ring-conflict
// reuse another proxy may be rendering into the same slot, and the old completion handler must not
// free it under that one.
static void vs_free_slot(BG3MFXDrawableProxy* p) {
    int s = p.vslot;
    if (s >= 0 && s < VS_RING && g_vsSlotProxy[s] == p) g_vsSlotProxy[s] = nil;
}

static int g_vsNext = 0;
static NSUInteger g_vsW = 0, g_vsH = 0;
static MTLPixelFormat g_vsFmt = MTLPixelFormatInvalid;
static bool vs_is_ring_tex(id t) {
    if (!t) return false;
    for (int i = 0; i < VS_RING; i++)
        if (g_vsTex[i] == t) return true;
    return false;
}

static int vs_ring_index(id t) {
    if (!t) return -1;
    for (int i = 0; i < VS_RING; i++)
        if (g_vsTex[i] == t) return i;
    return -1;
}

static bool vs_slot_owner_gen(int slot, uint32_t* gen) {
    BG3MFXDrawableProxy* p = (slot >= 0 && slot < VS_RING) ? g_vsSlotProxy[slot] : nil;
    if (!p) return false;
    *gen = p.vgen;
    return true;
}

static id<MTLCommandQueue> g_vsQueue = nil;
static id<MTLRenderPipelineState> g_vsCopyPSO = nil;      // one texture through, into the drawable
static id<MTLRenderPipelineState> g_vsComposePSO = nil;   // fi_ui: UI layer (tex1) over the world (tex0)

// The presenter's two fullscreen-triangle pipelines, from one library. The compose replicates BG3's CombineUI:
// premultiplied UI over the world (`ui.rgb + base * (1 - ui.a)`, from the disassembly), no display gamma (its
// _Combine.SDRGamma is 1.0). Both presented images of a frame run through the same pipeline, so interpolated
// and real frames share one colour space. Known deviation: BG3 dims the frame during load fades by a constant
// this shader does not know. Built for the drawable format on first use, retired with the ring.
static bool vs_build_pipelines(MTLPixelFormat fmt) {
    if (g_vsCopyPSO && g_vsComposePSO) return true;
    if (!g_device) return false;

    @autoreleasepool {
        NSString* src = @"#include <metal_stdlib>\n using namespace metal;\n"
                         "struct V { float4 pos [[position]]; float2 uv; };\n"
                         "constexpr sampler smp(coord::normalized, filter::nearest);\n"
                         "vertex V vs_v(uint vid [[vertex_id]]) {\n"
                         "  float2 p = float2((vid << 1) & 2, vid & 2);\n"   // fullscreen triangle
                         "  V o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o; }\n"
                         "fragment float4 vs_copy_f(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
                         "  return t.sample(smp, in.uv); }\n"
                         "fragment float4 vs_compose_f(V in [[stage_in]], texture2d<float> world [[texture(0)]],\n"
                         "                             texture2d<float> ui [[texture(1)]]) {\n"
                         "  float3 w = world.sample(smp, in.uv).rgb; float4 u = ui.sample(smp, in.uv);\n"
                         "  return float4(saturate(u.rgb + w * (1.0 - u.a)), 1.0); }\n";
        NSError* err = nil;
        id<MTLLibrary> lib = [g_device newLibraryWithSource:src options:nil error:&err];
        if (!lib) {
            log_line_always("VIRTUAL SWAPCHAIN: presenter shaders FAILED: %s",
                            err ? err.localizedDescription.UTF8String : "?");
            return false;
        }

        id<MTLFunction> vfn = [lib newFunctionWithName:@"vs_v"];
        id<MTLFunction> copyFn = [lib newFunctionWithName:@"vs_copy_f"];
        id<MTLFunction> composeFn = [lib newFunctionWithName:@"vs_compose_f"];
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = vfn;
        d.colorAttachments[0].pixelFormat = fmt;
        d.fragmentFunction = copyFn;
        if (!g_vsCopyPSO) g_vsCopyPSO = [g_device newRenderPipelineStateWithDescriptor:d error:&err];
        d.fragmentFunction = composeFn;
        if (!g_vsComposePSO) g_vsComposePSO = [g_device newRenderPipelineStateWithDescriptor:d error:&err];

        [d release];
        [vfn release];
        [copyFn release];
        [composeFn release];
        [lib release];

        if (!g_vsCopyPSO || !g_vsComposePSO)
            log_line_always("VIRTUAL SWAPCHAIN: presenter pipeline FAILED: %s",
                            err ? err.localizedDescription.UTF8String : "?");
        return g_vsCopyPSO && g_vsComposePSO;
    }
}

// One reusable descriptor for every fullscreen pass the presenter encodes (presenter thread only)
static MTLRenderPassDescriptor* vs_pass_into(id<MTLTexture> dst) {
    static MTLRenderPassDescriptor* rp = nil;
    if (!rp) {
        rp = [MTLRenderPassDescriptor new];
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    }

    rp.colorAttachments[0].texture = dst;
    return rp;
}

// TODO: the sums and counters below are written from Metal's completion handlers and read by vs_report
// on the render thread, with no atomics, so a concurrent update can be lost. Diagnostics only, it shifts
// a mean in the log and nothing else, but the numbers are approximate rather than exact.
static uint64_t g_vsHanded = 0, g_vsSwallowed = 0, g_vsPresented = 0, g_vsDropErr = 0, g_vsRingConflict = 0,
                g_vsNoHook = 0, g_vsHandlers = 0;
static double g_vsLatSum = 0, g_vsLatMax = 0, g_vsCopySum = 0, g_vsCopyMax = 0;
static double g_vsLastPresentNs = 0, g_vsIntervalSum = 0;
static uint64_t g_vsIntervalN = 0;

// Hand-off FIFO between BG3's completion handler and the display-link presenter. The handler only enqueues
// and returns, because nextDrawable waits ~8 ms for a refresh slot with VSync on and blocking there would
// hold Metal's completion queue and every handler behind it, BG3's included.
//
// VS_FIFO = 3 gives two waiting frames and has to stay that shallow, because a deep queue fills and stays
// full whenever the presenter is slower than BG3, so every frame waits the whole queue length.
// One waiting frame is too few, because a tick pair consumes exactly one
// frame and a frame completing just after a take-state tick waits two ticks, so the next one would be
// dropped although the average rate matches. Worst case that costs one base frame of latency, usually none.
//
// Backlog drain: BG3 (capped) and the presenter (display link) run at exactly the same rate, so whatever
// occupancy a hiccup or a loading screen leaves behind would stay forever and cost every frame behind it
// one extra tick pair, which is why the presenter
// reports a backlog whenever a take leaves another frame waiting and the frame cap stretches BG3's period
// by one percent while it holds, draining one frame every three seconds without a drop or a reset.
#define VS_FIFO 3
static BG3MFXDrawableProxy* g_vsFifo[VS_FIFO];
static double g_vsFifoT[VS_FIFO];
static int g_vsFifoHead = 0, g_vsFifoTail = 0;
static pthread_mutex_t g_vsMtx = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_vsFifoFull = 0;
static std::atomic<bool> g_vsBacklog{false};   // a take left another frame waiting (read by frame_cap_wait)
static uint64_t g_capStretched = 0;            // frames the cap stretched to drain a backlog
static void vs_enqueue(BG3MFXDrawableProxy* p, double tHandler) {
    pthread_mutex_lock(&g_vsMtx);
    int next = (g_vsFifoTail + 1) % VS_FIFO;

    if (next == g_vsFifoHead) {
        // Over capacity: drop the OLDEST queued frame, not the newest. Dropping the newest lets the queue's
        // latency grow, whereas dropping the oldest keeps what is shown close to what BG3 just rendered, and the
        // count still says how far over capacity we are.
        BG3MFXDrawableProxy* old = g_vsFifo[g_vsFifoHead];
        g_vsFifoHead = (g_vsFifoHead + 1) % VS_FIFO;
        g_vsFifoFull++;
        vs_free_slot(old);
        [old release];
    }

    g_vsFifo[g_vsFifoTail] = p;
    g_vsFifoT[g_vsFifoTail] = tHandler;
    g_vsFifoTail = next;

    pthread_mutex_unlock(&g_vsMtx);
}

// The interpolator, owned and used by the display-link presenter only
static id<MTLFXFrameInterpolator> g_fiObj = nil;
static id<MTLTexture> g_fiOut = nil;   // interpolated frame (target res); copied into the dup drawable

// prevColorTexture is a DEDICATED presenter-owned copy, not a ring slot. After each interpolated encode we
// blit the current world colour into g_fiColorCopy[parity], and the next frame reads the other half as
// prevColor. This decouples prevColor's lifetime from the drawable ring: the ring slot of the presented
// proxy is freed normally, and FIFO-drop / ring-conflict paths cannot overwrite a texture the interpolator
// is still reading. Cost: one target-res blit (~0.1-0.2 ms). On macOS 27 the framework keeps the previous
// colour itself (requiresPrevColorTexture = NO) and the copies are not made.
static id<MTLTexture> g_fiColorCopy[2] = {nil, nil};
static int g_fiParity = 0;
static bool g_fiInternalPrev = false;   // macOS 27: no prevColor copy, the interpolator manages it
static uint32_t g_fiPrevChain = 0;
static bool g_fiHavePrev = false;
static void* g_fiPrevSceneSrc = nullptr;
static uint64_t g_fiResetsScene = 0;   // scene-cut resets (subset of g_fiResets)
static double g_fiPrevHandlerNs = 0.0;
static uint64_t g_fiSkipped = 0, g_fiResets = 0, g_fiBuildFailed = 0;
static double g_fiEncSum = 0, g_fiEncMax = 0;

// Presenter-owned objects (interpolator, its textures, the copy/compose pipelines, the probe target) are
// created and released on the presenter thread only. The render thread never touches them, but announces a
// ring rebuild through g_vsRingGen and the presenter releases and rebuilds at the start of its next frame.
static void fi_release_objects(void) {
    retire_obj((id*)&g_fiObj);
    retire_obj((id*)&g_fiOut);
    retire_obj((id*)&g_fiColorCopy[0]);
    retire_obj((id*)&g_fiColorCopy[1]);
    retire_obj((id*)&g_vsCopyPSO);
    retire_obj((id*)&g_vsComposePSO);

    g_fiHavePrev = false;
}

static inline void vs_presenter_sync(void) {
    uint32_t gen = g_vsRingGen.load(std::memory_order_acquire);
    if (gen != g_vsRingGenSeen) {
        g_vsRingGenSeen = gen;
        fi_release_objects();
    }
}

static uint64_t g_fiRebuilds = 0;   // interpolator rebuilt because its inputs changed size or format
static bool fi_ready(id<MTLTexture> depth, id<MTLTexture> mv) {
    if (g_fiObj) return true;
    if (g_fiBuildFailed || !g_device || !depth || !mv) return false;

    MTLFXFrameInterpolatorDescriptor* d = [MTLFXFrameInterpolatorDescriptor new];
    // fi_ui interpolates the HUD-free world (RGB10A2) and outputs a presentable BGRA8, whereas without it the
    // whole drawable (BGRA8) is both input and output. The build is one-shot, so the format is fixed to
    // the mode active at first interp.
    d.colorTextureFormat = g_fiUi ? g_wFmt : g_vsFmt;
    d.outputTextureFormat = g_fiUi ? g_wFmt : g_vsFmt;   // fi_ui: interp WORLD only; UI composited afterwards
    d.depthTextureFormat = depth.pixelFormat;
    d.motionTextureFormat = mv.pixelFormat;
    d.inputWidth = depth.width;
    d.inputHeight = depth.height;   // motion/depth resolution (render res)
    d.outputWidth = g_vsW;
    d.outputHeight = g_vsH;

    // uiTexture is not used: fi_ui composes the UI itself (vs_emit), so the interpolator sees the HUD-free world only.
    if (@available(macOS 27.0, *)) {
        d.requiresPrevColorTexture = NO;   // the framework keeps the previous colour, no copy per frame
        g_fiInternalPrev = true;
    }

    g_fiObj = [d newFrameInterpolatorWithDevice:g_device];   // +1, kept
    [d release];

    if (!g_fiObj) {
        g_fiBuildFailed++;
        log_line_always(
            "FRAME INTERP: newFrameInterpolatorWithDevice returned nil (color=%s depth=%s mv=%s %lux%lu -> %lux%lu)",
            pfName(g_vsFmt) ?: "?", pfName(depth.pixelFormat) ?: "?", pfName(mv.pixelFormat) ?: "?",
            (unsigned long)depth.width, (unsigned long)depth.height, (unsigned long)g_vsW, (unsigned long)g_vsH);
        return false;
    }

    mfx_label(g_fiObj, "BG3MFX frame interpolator");

    // Publish the requested input usage, since copies made before this point are re-created by the snapshot code.
    g_fiNeedColor = MTLTextureUsageShaderRead | g_fiObj.colorTextureUsage;
    g_fiNeedDepth = MTLTextureUsageShaderRead | g_fiObj.depthTextureUsage;
    g_fiNeedMotion = MTLTextureUsageShaderRead | g_fiObj.motionTextureUsage;

    // The output and the two prevColor copies share the colour format (world RGB10A2 with fi_ui, the drawable's
    // BGRA8 otherwise), and the copies are also blit destinations.
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(g_fiUi ? g_wFmt : g_vsFmt)
                                                                                  width:g_vsW
                                                                                 height:g_vsH
                                                                              mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    g_inOwnAlloc = true;
    td.usage = MTLTextureUsageShaderRead | g_fiObj.outputTextureUsage;
    g_fiOut = [g_device newTextureWithDescriptor:td];
    if (!g_fiInternalPrev) {
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | g_fiObj.colorTextureUsage;
        g_fiColorCopy[0] = [g_device newTextureWithDescriptor:td];
        g_fiColorCopy[1] = [g_device newTextureWithDescriptor:td];
    }

    g_inOwnAlloc = false;
    if (!g_fiOut || (!g_fiInternalPrev && (!g_fiColorCopy[0] || !g_fiColorCopy[1]))) {
        g_fiBuildFailed++;
        fi_release_objects();
        log_line_always("FRAME INTERP: texture allocation failed");
        return false;
    }

    mfx_label(g_fiOut, "BG3MFX interpolated frame");
    mfx_label(g_fiColorCopy[0], "BG3MFX prevColor copy");
    mfx_label(g_fiColorCopy[1], "BG3MFX prevColor copy");

    log_line_always(
        "FRAME INTERP: interpolator built %lux%lu -> %lux%lu, prevColor %s; requested usage colour=0x%lx prev/colour depth=0x%lx motion=0x%lx "
        "output=0x%lx ui=0x%lx | our virtual textures carry 0x%lx, depth/motion copies 0x%lx",
        (unsigned long)depth.width, (unsigned long)depth.height, (unsigned long)g_vsW, (unsigned long)g_vsH,
        g_fiInternalPrev ? "kept by the framework (macOS 27)" : "our ping-pong copy",
        (unsigned long)g_fiObj.colorTextureUsage, (unsigned long)g_fiObj.depthTextureUsage,
        (unsigned long)g_fiObj.motionTextureUsage, (unsigned long)g_fiObj.outputTextureUsage,
        (unsigned long)g_fiObj.uiTextureUsage, (unsigned long)(g_vsTex[0] ? g_vsTex[0].usage : 0),
        (unsigned long)depth.usage);

    return true;
}

static uint64_t g_pathCompose = 0, g_pathVtex = 0;   // which source the presented images came from
static uint64_t g_vsNoReconRun = 0;   // consecutive presents with no usable reconstruction (menu/transition)
static int g_vsSyncSet = -1;          // -1 untouched, else the displaySyncEnabled we set

// Hand BG3 a proxy with our texture, or nil to say "use the real path" (caller then calls the original).
static id vs_hand_out(CAMetalLayer* layer) {
    if (!g_device || !o_nextDrawable) {
        g_vsNoHook++;
        return nil;
    }

    CGSize sz = layer.drawableSize;
    NSUInteger w = (NSUInteger)sz.width, h = (NSUInteger)sz.height;
    MTLPixelFormat fmt = layer.pixelFormat;
    if (!w || !h) return nil;

    if (w != g_vsW || h != g_vsH || fmt != g_vsFmt) {   // first use or a resize: rebuild the ring
        for (int i = 0; i < VS_RING; i++) {
            retire_obj((id*)&g_vsTex[i]);
            g_vsSlotProxy[i] = nil;
        }

        g_vsW = w;
        g_vsH = h;
        g_vsFmt = fmt;

        for (int i = 0; i < VS_RING; i++) {
            MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                                                          width:w
                                                                                         height:h
                                                                                      mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
                       g_fiNeedColor;   // without fi_ui the ring is the interpolator's colour input
            td.storageMode = MTLStorageModePrivate;
            g_inOwnAlloc = true;
            g_vsTex[i] = [g_device newTextureWithDescriptor:td];
            g_inOwnAlloc = false;
            if (!g_vsTex[i]) {
                log_line_always("VIRTUAL SWAPCHAIN: texture alloc failed");
                return nil;
            }
            mfx_label(g_vsTex[i], "BG3MFX virtual drawable");
        }

        // A private texture has undefined contents until somehting writes it. A real drawable from the pool
        // arrives cleared, and BG3's first frames (logo, loading) may rely on that and not cover every pixel, and
        // whatever the memory held would then be presented (a one-frame pink flash at start). Clear once.
        if (!g_vsQueue) {
            g_vsQueue = [g_device newCommandQueue];
            mfx_label(g_vsQueue, "BG3MFX queue C (virtual swapchain presenter)");
        }

        if (g_vsQueue) {
            id<MTLCommandBuffer> cb = [g_vsQueue commandBuffer];
            objc_setAssociatedObject(cb, &kOurOffThreadCBKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (int i = 0; i < VS_RING; i++) {
                MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = g_vsTex[i];
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            }
            [cb commit];
            [cb waitUntilCompleted];   // queue C has no ordering against BG3's queue; the clear must land before BG3's first frame
        }

        // Everything the presenter built for the old size or format goes with the ring, and the presenter
        // thread releases and rebuilds it (vs_presenter_sync), this thread only announces the change.
        g_vsRingGen.fetch_add(1, std::memory_order_release);
        log_line_always("VIRTUAL SWAPCHAIN: ring of %d x %lux%lu %s allocated; BG3 renders into these from now on "
                        "and we present the real drawables ourselves",
                        VS_RING, (unsigned long)w, (unsigned long)h, pfName(fmt) ?: "?");
    }

    int slot = -1;
    for (int k = 0; k < VS_RING; k++) {
        int c = (g_vsNext + k) % VS_RING;
        if (!g_vsSlotProxy[c]) {
            slot = c;
            break;
        }
    }

    if (slot < 0) {
        g_vsRingConflict++;
        slot = g_vsNext;
    }
    g_vsNext = (slot + 1) % VS_RING;

    BG3MFXDrawableProxy* p = [[BG3MFXDrawableProxy alloc] init];
    p.vtex = g_vsTex[slot];
    p.vlayer = layer;
    p.vslot = slot;
    p.vgen = ++g_vsGen;
    g_vsSlotProxy[slot] = p;
    g_vsHanded++;

    return [p autorelease];
}

// BG3's present of a virtual proxy: swallow it, and when BG3's command buffer has completed, present the
// content ourselves. Nothing is encoded on BG3's CB.
static void vs_present(id cb, BG3MFXDrawableProxy* p) {
    g_vsSwallowed++;

    // We own the presentation: VSync on while we present two images per frame (the display link ticks
    // with the refresh), BG3's original setting otherwise. Set on the render thread, once per state
    // change, and logged.
    {
        int want = g_fi ? 1 : 0;
        if (g_vsSyncSet != want) {
            if (g_vsSyncOriginal < 0) g_vsSyncOriginal = p.vlayer.displaySyncEnabled ? 1 : 0;
            p.vlayer.displaySyncEnabled = want ? YES : NO;
            g_vsSyncSet = want;
            // Two drawables per frame (dup + real) need the full pool of 3, so ask for it explicitly so
            // nextDrawable does not block long.
            if (g_fi && p.vlayer.maximumDrawableCount < 3) p.vlayer.maximumDrawableCount = 3;
            log_line_always(
                "VIRTUAL SWAPCHAIN: displaySyncEnabled -> %d maxDrawable=%lu (frame_interp=%d, BG3's original %d)",
                p.vlayer.displaySyncEnabled ? 1 : 0, (unsigned long)p.vlayer.maximumDrawableCount, g_fi ? 1 : 0,
                g_vsSyncOriginal);
        }
    }

    if (!g_vsQueue) {
        g_vsQueue = [g_device newCommandQueue];
        mfx_label(g_vsQueue, "BG3MFX queue C (virtual swapchain presenter)");
    }

    if (!g_vsQueue || !vs_build_pipelines(g_vsFmt)) {
        vs_free_slot(p);
        g_vsDropErr++;
        return;
    }

    static bool once = false;
    if (!once) {
        once = true;
        log_line_always("VIRTUAL SWAPCHAIN: first swallowed present: BG3's presentDrawable: is now ours, the "
                        "display link presents");
    }

    dl_start(p.vlayer);
    [p retain];   // handed from handler to presenter thread
    double tHook = now_ns();

    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        double tHandler = now_ns();
        double lat = (tHandler - tHook) / 1e6;
        g_vsLatSum += lat;
        if (lat > g_vsLatMax) g_vsLatMax = lat;
        g_vsHandlers++;

        if (done.error) {
            g_vsDropErr++;
            vs_free_slot(p);
            if (g_vsDropErr <= 5 || g_vsDropErr % 100 == 0)
                log_line_always("VIRTUAL SWAPCHAIN: BG3's command buffer completed with ERROR #%llu (chain %u): %s",
                                (unsigned long long)g_vsDropErr, p.vchain, done.error.localizedDescription.UTF8String);
            [p release];
            return;
        }

        vs_enqueue(p, tHandler);   // nothing else here: this is Metal's completion queue
    }];
}

// presenter core
// Interpolate between the previously processed frame and `p`, encoded on `ours`. Returns g_fiOut when a
// SHOWABLE interpolation was encoded (valid history), nil when this frame is to be doubled (inputs missing,
// or the history was just reset and the first output is primed but not shown). Owns all the bookkeeping:
// skip reasons, resets & the prevColor ping-pong.
static inline uint32_t fi_motion_lag(void) {
    int mode = g_fiMotionKey;
    if (mode == 1) return 0u;                                   // "current": the frame's own chain
    if (mode == 0) return 1u;                                   // "previous": one chain back
    return effective_encode_path() == ENC_SEPARATE ? 1u : 0u;   // "auto": separate path lags the world by one frame
}

static id<MTLTexture> fi_encode_interp(BG3MFXDrawableProxy* p, id<MTLCommandBuffer> ours, double tHandler) {
    if (!g_fi) return nil;

    // Which chain's depth/motion/jitter/projection slot belongs to the WORLD image in colorTexture. On
    // encode_path = separate, MetalFX upscales the PREVIOUS frame's snapshot (our CB is committed before
    // BG3's frame CB, the one-frame latency of that path), so the world BG3 tonemaps in frame F, and hence
    // g_scene / vtex / our world snapshot of frame F, is world F-1: its motion, depth and jitter live in
    // slot vchain-1.
    // On the event path the world is F and the slot is vchain. fi_motion_key = auto derives
    // this from the path, while current and previous force it. fi_ui only swaps the COLOUR inputs (drawable ->
    // HUD-free world). Measured on the separate path: vchain gives strong double contours on a fast pan,
    // vchain-1 does not.
    uint32_t chWant = p.vchain - fi_motion_lag();
    int k = (int)(chWant % (uint32_t)FI_RING);
    uint32_t chK = g_fiChain[k].load(std::memory_order_acquire);   // ACQUIRE: pairs the publish in snapshot_pre_taa
    id<MTLTexture> colTex = p.vtex;
    bool worldOK = true;
    if (g_fiUi) {   // this frame's world snapshot (by ring slot + generation); prev comes from the ping-pong below
        int wk = p.vslot;
        worldOK = g_wSnapGen[wk].load(std::memory_order_acquire) == p.vgen && g_wSnap[wk];
        if (worldOK) colTex = g_wSnap[wk];
    }

    // The interpolator is built for one input size and colour format, and a render-scale change in BG3's menu
    // or a fi_ui switch invalidates it (the API requires matching dimensions), so it is rebuilt here.
    if (g_fiObj && g_fiDepth[k] &&
        (g_fiObj.inputWidth != g_fiDepth[k].width || g_fiObj.inputHeight != g_fiDepth[k].height ||
         g_fiObj.colorTextureFormat != (g_fiUi ? g_wFmt : g_vsFmt))) {
        g_fiRebuilds++;
        g_fiBuildFailed = 0;
        fi_release_objects();
        log_line("FRAME INTERP: inputs changed to %lux%lu, interpolator rebuilt (#%llu)",
                 (unsigned long)g_fiDepth[k].width, (unsigned long)g_fiDepth[k].height,
                 (unsigned long long)g_fiRebuilds);
    }

    // g_fiOut must match the COLOUR input (world = RGB10A2 for fi_ui, p.vtex = BGRA8 otherwise).
    bool inputsOK = chK == chWant && g_fiDepth[k] && g_fiMv[k] && fi_ready(g_fiDepth[k], g_fiMv[k]) &&
                    same_dims(g_fiOut, colTex) && worldOK;
    if (!inputsOK) {
        // name the failing condition (first one in evaluation order)
        if (chK != chWant) {
            g_fiSkipChain++;
            static uint64_t n = 0;
            n++;
            if (n <= 24 || n % 200 == 0)
                log_line("FI SKIP chain-miss #%llu: vchain=%u want=%u slot=%d has=%u | g_chainId now=%u "
                         "fifo-depth~%d worldOK=%d",
                         (unsigned long long)n, p.vchain, chWant, k, chK, g_chainId,
                         (g_vsFifoTail - g_vsFifoHead + VS_FIFO) % VS_FIFO, worldOK ? 1 : 0);
        } else if (!g_fiDepth[k] || !g_fiMv[k]) g_fiSkipNoTex++;
        else if (!g_fiObj) g_fiSkipReady++;
        else if (!worldOK) g_fiSkipWorld++;
        else g_fiSkipDims++;
        g_fiSkipped++;
        return nil;
    }

    const float* pr = g_fiProj[k];
    float p00 = pr[0], p11 = pr[5], nearZ = pr[14];   // column-major: col0.x, col1.y, col3.z

    // Reset ONLY on a genuine discontinuity: d==0 (BG3 re-presented the same world frame, ~25 % of presents)
    // and d==1 (normal) both interpolate, while d>1 skipped a frame whose motion we never saw (wrong to warp through),
    // d<0 is out-of-order/wrap. A reset on d==0 would flicker black on a quarter of all presents.
    int64_t dChain = (int64_t)p.vchain - (int64_t)g_fiPrevChain;

    // Scene cut (Apple: "set shouldResetHistory ... when there is a scene cut"): BG3 allocates a new
    // tonemapped-world target at every level/menu transition
    // The chain often continues across such a cut (dChain 0/1), so it needs its own signal.
    bool sceneCut = g_fiHavePrev && p.vsceneSrc && g_fiPrevSceneSrc && p.vsceneSrc != g_fiPrevSceneSrc;
    if (sceneCut) g_fiResetsScene++;
    bool reset = !g_fiHavePrev || g_fiEncoded == 0 || dChain > 1 || dChain < 0 || sceneCut;

    // Last frame's copy (garbage on the very first, discarded via reset), and nil when the framework keeps it.
    id<MTLTexture> prevTex = g_fiInternalPrev ? nil : g_fiColorCopy[1 - g_fiParity];
    double dt = g_fiPrevHandlerNs > 0 ? (tHandler - g_fiPrevHandlerNs) / 1e9 : 1.0 / 60.0;
    if (dt < 1.0 / 240.0 || dt > 0.1) dt = 1.0 / 60.0;

    g_fiObj.colorTexture = colTex;
    g_fiObj.prevColorTexture = prevTex;   // ping-pong: the true previously-processed frame (world when fi_ui)
    g_fiObj.depthTexture = g_fiDepth[k];
    g_fiObj.motionTexture = g_fiMv[k];
    g_fiObj.motionVectorScaleX = g_mvScaleX;
    g_fiObj.motionVectorScaleY = g_mvScaleY;   // same convention as the scaler
    g_fiObj.jitterOffsetX = g_fiJx[k];
    g_fiObj.jitterOffsetY = -g_fiJy[k];
    g_fiObj.depthReversed = kDepthReversed;
    g_fiObj.deltaTime = (float)dt;
    g_fiObj.nearPlane = nearZ > 0.0f ? nearZ : 0.1f;
    g_fiObj.farPlane = 1.0e5f;   // BG3: reversed-Z, infinite far plane
    g_fiObj.fieldOfView = p11 > 0.0f ? (float)(2.0 * atan(1.0 / p11) * 180.0 / M_PI) : 60.0f;
    g_fiObj.aspectRatio = (p00 > 0.0f && p11 > 0.0f) ? p11 / p00 : (float)g_vsW / (float)g_vsH;
    g_fiObj.shouldResetHistory = reset ? YES : NO;

    // fi_ui: the interpolator produces the WORLD only (g_fiOut, world space), while the UI is composed on top of
    // BOTH presented frames (vs_emit), so interp and real share one colour space. Without fi_ui the whole
    // drawable is interpolated and g_fiOut is a presentable BGRA8 frame.
    g_fiObj.outputTexture = g_fiOut;

    double te = now_ns();
    [g_fiObj encodeToCommandBuffer:ours];
    double enc = (now_ns() - te) / 1e6;
    g_fiEncSum += enc;
    if (enc > g_fiEncMax) g_fiEncMax = enc;
    g_fiEncoded++;

    if (!g_fiInternalPrev) {   // this frame becomes the next frame's prevColor (ping-pong = true FIFO predecessor)
        id<MTLBlitCommandEncoder> pb = [ours blitCommandEncoder];
        [pb copyFromTexture:colTex toTexture:g_fiColorCopy[g_fiParity]];
        [pb endEncoding];
        g_fiParity ^= 1;
    }

    g_fiPrevChain = p.vchain;
    g_fiHavePrev = true;
    g_fiPrevSceneSrc = p.vsceneSrc;
    g_fiPrevHandlerNs = tHandler;

    // An interpolation built on freshly reset history is unreliable.
    // Prime the history with this encode but DON'T show it, and double the real frame for this pair.
    if (reset) {
        g_fiResets++;
        return nil;
    }

    return g_fiOut;
}

// What the REAL image of frame `p` is made of: the in-frame world + UI snapshots (compose path), or BG3's own
// vtex. The composed image equals vtex (measured over the whole frame), and vtex needs no snapshots, so it is
// the fallback.
struct VsSources {
    id<MTLTexture> world, ui;
    bool composeOK;
};
static VsSources vs_resolve_sources(BG3MFXDrawableProxy* p) {
    VsSources s = {nil, nil, false};
    int wk = p.vslot;
    s.world = (g_wSnapGen[wk].load(std::memory_order_acquire) == p.vgen) ? g_wSnap[wk] : nil;
    s.ui = (g_uiSnapGen[wk].load(std::memory_order_acquire) == p.vgen) ? g_uiSnap[wk] : nil;
    s.composeOK = g_fiUi && g_vsComposePSO && s.world && s.ui && same_dims(s.world, g_fiOut);

    return s;
}

// Statistics for a newly taken frame: which source its images come from, and how long the compose has been
// unavailable (menus and transitions have no world snapshot).
static void vs_count_path(const VsSources& s) {
    if (s.composeOK) g_pathCompose++;
    else g_pathVtex++;

    if (!g_fiUi) return;
    if (s.composeOK) g_vsNoReconRun = 0;
    else if (++g_vsNoReconRun == 1 || g_vsNoReconRun % 120 == 0)
        log_line("FI UI: no current reconstruction (world=%p ui=%p) -> presenting BG3's real drawable (run of %llu). "
                 "Transition/menu?",
                 (void*)s.world, (void*)s.ui, (unsigned long long)g_vsNoReconRun);
}

static inline id<MTLTexture> vs_real_source(const VsSources& s, BG3MFXDrawableProxy* p) {
    return s.composeOK ? s.world : p.vtex;
}

// The DUP image: the interpolation when it is showable (world space when fi_ui -> composed with the UI,
// drawable space otherwise -> copied), else the real image's source (frame doubling).
static inline id<MTLTexture> vs_dup_source(id<MTLTexture> interp, const VsSources& s, BG3MFXDrawableProxy* p) {
    // With fi_ui the interpolation is a HUD-free world and only presentable through the compose, so if the
    // compose is unavailable (UI snapshot invalidated, PSO failed) the frame is doubled instead.
    if (interp && g_fiUi && !s.composeOK) interp = nil;
    return interp ? interp : vs_real_source(s, p);
}

// Write one presented image into `dst` on `cb` (our off-thread CB): the UI layer composed over `src` (the
// world or the interpolated world), or a plain copy of `src`. One fullscreen triangle either way.
static void vs_emit(id<MTLCommandBuffer> cb, id<MTLTexture> dst, id<MTLTexture> src, bool compose, id<MTLTexture> ui) {
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:vs_pass_into(dst)];
    [enc setRenderPipelineState:compose ? g_vsComposePSO : g_vsCopyPSO];
    [enc setFragmentTexture:src atIndex:0];
    if (compose) [enc setFragmentTexture:ui atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
}

// Bookkeeping when a frame's FIRST image has completed on the GPU: presenter latency + interval statistics.
static void vs_note_presented(double tHandler) {
    double tDone = now_ns();
    double copy = (tDone - tHandler) / 1e6;
    g_vsCopySum += copy;
    if (copy > g_vsCopyMax) g_vsCopyMax = copy;

    if (g_vsLastPresentNs > 0) {
        g_vsIntervalSum += (tDone - g_vsLastPresentNs) / 1e6;
        g_vsIntervalN++;
    }

    g_vsLastPresentNs = tDone;
    g_vsPresented++;
}


// the presenter: CAMetalDisplayLink, driven by the display's refresh tick
// The display drives the presenter: the link calls needsUpdate: once per refresh tick (2 x frame_cap, else
// 60 Hz) and hands us exactly ONE drawable, no nextDrawable, no pool wait, no afterMinimumDuration.
//
// A BG3 frame that has completed waits in the FIFO (VS_FIFO = 3, two waiting slots) until a tick in the take state
// (g_dlPhase == 0) dequeues it: that tick shows the interpolated image (between the previous frame and this
// one), the next tick shows the real image, then the machine is back in the take state.
// If no new frame has arrived by then, the real image is repeated (the base is slower than the tick pair), no drop, no reset.
// A drop happens only when BG3 completes frames faster than the tick pairs consume them and the FIFO overflows
// (vs_enqueue drops the oldest, and the interpolator resets across the gap).
@interface BG3MFXDisplayLinkDelegate : NSObject <CAMetalDisplayLinkDelegate>
@end
static CAMetalDisplayLink* g_dl = nil;
static BG3MFXDisplayLinkDelegate* g_dlDelegate = nil;
static uint64_t g_dlThreadId = 0;   // the link's run-loop thread (nextDrawable from there is the link's own)
static bool g_dlStarted = false;
static BG3MFXDrawableProxy* g_dlCur = nil;  // the frame whose real image is current (retained; the ring slot stays busy)
static int g_dlPhase = 0;   // 0 = may take a new frame (shows its dup), 1 = show the real image of g_dlCur next
static uint64_t g_dlTicks = 0, g_dlDup = 0, g_dlReal = 0, g_dlRepeat = 0, g_dlIdle = 0, g_dlLate = 0,
                g_dlNoDrawable = 0, g_dlNextDrawableCalls = 0;
static uint64_t g_vsForeignNextDrawable = 0;   // nextDrawable calls from threads other than BG3's render thread and the link (real drawable handed out)
static double g_dlLateSum = 0.0;
static double g_dlGpuSum = 0.0;
static uint64_t g_dlGpuN = 0;           // GPU time of the tick command buffers (GPUEndTime - GPUStartTime)
static double g_dlFirstTickNs = 0.0;    // wall clock of the first tick (tick rate check)
static float g_dlHz = 0.0f;             // the rate last programmed into the link
static CAMetalLayer* g_dlLayer = nil;   // the layer the link drives (not retained; BG3 owns it)
static std::atomic<bool> g_dlActive{false};   // a CAMetalDisplayLink is attached to g_dlLayer (set before it exists, cleared before it goes)
static std::atomic<int> g_dlWantLink{0};   // 1 = the link thread creates a new link on its next pass
static std::atomic<NSUInteger> g_vsMaxDrawableDeferred{0};   // maximumDrawableCount BG3 asked for while the link was attached
static uint64_t g_vsMaxDrawableSwallowed = 0;
static void dl_create_link(CAMetalLayer* layer);

// The virtual swapchain was switched off while the link runs: release the current frame and everything
// waiting in the FIFO (their ring slots with them), reset the phase machine and give BG3 back its VSync
// setting. Nothing is presented on the layer any more, and BG3's own presents are the picture now.
static void dl_stand_down(void) {
    if (g_dlCur) {
        BG3MFXDrawableProxy* old = g_dlCur;
        g_dlCur = nil;
        id<MTLCommandBuffer> fence =
            g_vsQueue ? [g_vsQueue commandBuffer] : nil;   // completes after every earlier tick on queue C
        if (fence) {
            [fence addCompletedHandler:^(id<MTLCommandBuffer>) {
                vs_free_slot(old);
                [old release];
            }];
            [fence commit];
        } else {
            vs_free_slot(old);
            [old release];
        }
    }

    g_dlPhase = 0;
    pthread_mutex_lock(&g_vsMtx);
    while (g_vsFifoHead != g_vsFifoTail) {
        BG3MFXDrawableProxy* p = g_vsFifo[g_vsFifoHead];
        g_vsFifoHead = (g_vsFifoHead + 1) % VS_FIFO;
        vs_free_slot(p);
        [p release];
    }
    g_vsBacklog.store(false, std::memory_order_relaxed);
    pthread_mutex_unlock(&g_vsMtx);

    if (g_vsSyncSet >= 0 && g_vsSyncOriginal >= 0 && g_dlLayer) {
        g_dlLayer.displaySyncEnabled = g_vsSyncOriginal ? YES : NO;
        g_vsSyncSet = -1;
        log_line_always(
            "DISPLAYLINK: virtual swapchain off, presenter stood down, displaySyncEnabled -> %d (BG3's original)",
            g_vsSyncOriginal);
    }

    // Detach the link: while one is attached, CoreAnimation rejects setMaximumDrawableCount: on the layer,
    // and BG3 sets it on every window-mode change. dl_start creates a new link when the swapchain returns.
    if (g_dl) {
        g_dlActive.store(false, std::memory_order_release);
        [g_dl invalidate];
        [g_dl release];
        g_dl = nil;
        NSUInteger want = g_vsMaxDrawableDeferred.exchange(0);
        if (want && g_dlLayer) g_dlLayer.maximumDrawableCount = want;   // the value BG3 asked for meanwhile
        log_line_always("DISPLAYLINK: link detached from BG3's layer%s",
                        want ? ", deferred maximumDrawableCount applied" : "");
    }
}

@implementation BG3MFXDisplayLinkDelegate
- (void)metalDisplayLink:(CAMetalDisplayLink*)link needsUpdate:(CAMetalDisplayLinkUpdate*)u {
    g_dlTicks++;
    if (g_dlFirstTickNs == 0.0) g_dlFirstTickNs = now_ns();
    {   // the tick rate follows frame_cap live (2 x cap, else 60)
        float hz = (float)(g_frameCap > 0 ? g_frameCap * 2 : 60);
        if (hz != g_dlHz) {
            g_dlHz = hz;
            // TODO: untested on ProMotion, min = max pins the panel instead of riding its variable rate.
            link.preferredFrameRateRange = CAFrameRateRangeMake(hz, hz, hz);
        }
    }

    double late = CACurrentMediaTime() - u.targetTimestamp;
    if (late > 0.0) {
        g_dlLate++;
        g_dlLateSum += late;
    }

    id<CAMetalDrawable> d = u.drawable;
    if (!d || !d.texture) {
        g_dlNoDrawable++;
        return;
    }

    if (!g_vsc || g_mode != 0) {   // switched off live: BG3 presents itself again, this presenter stands down
        dl_stand_down();
        return;
    }

    vs_presenter_sync();
    if (!g_vsQueue || !vs_build_pipelines(g_vsFmt)) return;
    BG3MFXDrawableProxy* p = nil;
    double tH = 0.0;

    if (g_dlPhase == 0) {   // take the next completed frame, if any
        pthread_mutex_lock(&g_vsMtx);
        if (g_vsFifoHead != g_vsFifoTail) {
            p = g_vsFifo[g_vsFifoHead];
            tH = g_vsFifoT[g_vsFifoHead];
            g_vsFifoHead = (g_vsFifoHead + 1) % VS_FIFO;
        }
        g_vsBacklog.store(g_vsFifoHead != g_vsFifoTail, std::memory_order_relaxed);   // another frame still waits
        pthread_mutex_unlock(&g_vsMtx);
    }

    if (!p && !g_dlCur) {
        g_dlIdle++;
        return;
    }   // nothing to show yet (before the first frame); the drawable is not presented

    id<MTLCommandBuffer> cb = [g_vsQueue commandBuffer];
    if (!cb) {
        g_vsDropErr++;
        if (p) {
            vs_free_slot(p);
            [p release];
        }
        return;
    }

    objc_setAssociatedObject(cb, &kOurOffThreadCBKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (p) {
        id<MTLTexture> interp = fi_encode_interp(p, cb, tH);
        VsSources s = vs_resolve_sources(p);
        vs_count_path(s);
        id<MTLTexture> dupSrc = vs_dup_source(interp, s, p);
        vs_emit(cb, d.texture, dupSrc, s.composeOK, s.ui);
        if (s.composeOK) g_uiFed++;

        BG3MFXDrawableProxy* old = g_dlCur;
        g_dlCur = p;
        g_dlPhase = 1;
        g_dlDup++;
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            vs_note_presented(tH);
            if (old) {
                vs_free_slot(old);
                [old release];
            }   // nothing reads the old frame after this CB
        }];
    } else {
        // Real image of the current frame (g_dlPhase == 1), or a repeat of it (take state, nothing new yet)
        VsSources s = vs_resolve_sources(g_dlCur);
        vs_emit(cb, d.texture, vs_real_source(s, g_dlCur), s.composeOK, s.ui);
        if (g_dlPhase == 1) {
            g_dlPhase = 0;
            g_dlReal++;
        } else g_dlRepeat++;
    }

    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        double g = c.GPUEndTime - c.GPUStartTime;
        if (g > 0 && g < 1.0) {
            g_dlGpuSum += g;
            g_dlGpuN++;
        }
        if (c.error) {
            static int n = 0;
            if (++n <= 5 || n % 100 == 0)
                log_line_always("DISPLAYLINK: tick command buffer ERROR #%d: %s", n, c.error.localizedDescription.UTF8String);
        }
    }];

    [cb presentDrawable:d];
    [cb commit];
}
@end

static void* dl_thread(void* arg) {
    pthread_setname_np("BG3MFX display-link presenter");
    pthread_threadid_np(NULL, &g_dlThreadId);
    CAMetalLayer* layer = (CAMetalLayer*)arg;
    g_dlLayer = layer;
    g_dlDelegate = [BG3MFXDisplayLinkDelegate new];

    for (;;) @autoreleasepool {
            if (!g_dl) {   // no link attached: wait for a request (the swapchain came back on) without spinning
                if (g_dlWantLink.exchange(0)) dl_create_link(layer);
                else {
                    usleep(20000);
                    continue;
                }
            }
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
    return nullptr;
}

// Runs on the link thread. g_dlActive goes up before the link exists so a concurrent setMaximumDrawableCount from BG3 is deferred rather than thrown at.
static void dl_create_link(CAMetalLayer* layer) {
    g_dlActive.store(true, std::memory_order_release);
    g_dl = [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
    g_dlHz = (float)(g_frameCap > 0 ? g_frameCap * 2 : 60);
    g_dl.preferredFrameRateRange = CAFrameRateRangeMake(g_dlHz, g_dlHz, g_dlHz);
    g_dl.delegate = g_dlDelegate;
    [g_dl addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    g_dlPhase = 0;

    log_line_always(
        "DISPLAYLINK: presenter started on BG3's layer, preferred %.0f Hz (2 x frame_cap), frame latency %.1f", g_dlHz,
        g_dl.preferredFrameLatency);
}

static void dl_start(CAMetalLayer* layer) {
    if (!layer) return;
    if (g_dlStarted) {
        if (!g_dl && !g_dlActive.load(std::memory_order_acquire)) g_dlWantLink.store(1);
        return;
    }   // re-attach after a stand-down

    g_dlStarted = true;
    g_dlWantLink.store(1);

    pthread_t th;
    pthread_create(&th, nullptr, dl_thread, (void*)layer);
    pthread_detach(th);
}

// The presenter's report, every 600 presents (window deltas). Diagnostics behind `logging`, while STATUS carries
// the always-on verdict.
static void vs_report(void) {
    if (g_vsc && !o_nextDrawable) {
        static bool once = false;
        if (!once) {
            once = true;
            log_line_always("VIRTUAL SWAPCHAIN: key is on but nextDrawable is NOT hooked, nothing is virtualised.");
        }
    }

    if (!g_logging) return;

    if (g_frameCap > 0 || g_capWaits) {
        static uint64_t pW = 0, pL = 0, pSt = 0;
        static double pWs = 0, pOs = 0;
        uint64_t dW = win(pW, g_capWaits), dL = win(pL, g_capLate), dSt = win(pSt, g_capStretched);
        double dWs = winf(pWs, g_capWaitSum), dOs = winf(pOs, g_capOverSum);

        log_line("FRAME CAP [last window]: cap=%d | waited on %llu frames, mean wait %.2f ms, wake overshoot mean %.3f "
                 "ms max %.3f | late (frame longer than the period, no wait) %llu | stretched %llu (backlog drain)  "
                 "[late > 0 means BG3 itself is slower than the cap there]",
                 g_frameCap, (unsigned long long)dW, dW ? dWs / 1e6 / (double)dW : 0.0,
                 dW ? dOs / 1e6 / (double)dW : 0.0, g_capOverMax / 1e6, (unsigned long long)dL,
                 (unsigned long long)dSt);
        g_capOverMax = 0.0;
    }

    if (!g_vsc && !g_vsHanded) return;   // the rest describes the virtual swapchain
    if (g_vsForeignNextDrawable)
        log_line("PROXY DRAWABLE: foreign nextDrawable calls so far %llu (real drawables handed out)",
                 (unsigned long long)g_vsForeignNextDrawable);

    {
        static uint64_t pH = 0, pS = 0, pP = 0, pE = 0, pC = 0, pHd = 0, pIn = 0, pFf = 0;
        static double pLat = 0, pCp = 0, pIv = 0;
        uint64_t dH = win(pH, g_vsHanded), dS = win(pS, g_vsSwallowed), dP = win(pP, g_vsPresented),
                 dE = win(pE, g_vsDropErr), dC = win(pC, g_vsRingConflict), dHd = win(pHd, g_vsHandlers),
                 dIn = win(pIn, g_vsIntervalN), dFf = win(pFf, g_vsFifoFull);
        double dLat = winf(pLat, g_vsLatSum), dCp = winf(pCp, g_vsCopySum), dIv = winf(pIv, g_vsIntervalSum);

        log_line("VIRTUAL SWAPCHAIN [last window]: handed=%llu swallowed=%llu presented=%llu handlers=%llu | dropped "
                 "err=%llu ring-conflicts=%llu no-hook=%llu | hook->completion mean %.2f ms max %.2f | "
                 "completion->presented mean %.2f ms max %.2f | our present interval mean %.2f ms (%.1f fps) | "
                 "fifo-full drops=%llu   [total presented=%llu]",
                 (unsigned long long)dH, (unsigned long long)dS, (unsigned long long)dP, (unsigned long long)dHd,
                 (unsigned long long)dE, (unsigned long long)dC, (unsigned long long)g_vsNoHook,
                 dHd ? dLat / (double)dHd : 0.0, g_vsLatMax, dP ? dCp / (double)dP : 0.0, g_vsCopyMax,
                 dIn ? dIv / (double)dIn : 0.0, dIn && dIv > 0 ? 1000.0 * (double)dIn / dIv : 0.0,
                 (unsigned long long)dFf, (unsigned long long)g_vsPresented);
    }

    if (!g_fi && !g_fiEncoded) return;

    {
        static uint64_t pFe = 0, pFs = 0, pFr = 0, pFsc = 0, pSc = 0, pSt = 0, pSr = 0, pSd = 0, pSw = 0;
        static double pFt = 0;
        uint64_t dE = win(pFe, g_fiEncoded);
        double dT = winf(pFt, g_fiEncSum);

        log_line("FRAME INTERP [last window]: interpolated=%llu skipped=%llu resets=%llu (scene cuts %llu) | encode "
                 "CPU mean %.3f ms max %.3f | frame_cap=%d",
                 (unsigned long long)dE, (unsigned long long)win(pFs, g_fiSkipped),
                 (unsigned long long)win(pFr, g_fiResets), (unsigned long long)win(pFsc, g_fiResetsScene),
                 dE ? dT / (double)dE : 0.0, g_fiEncMax, g_frameCap);

        // Skip causes: chain = depth/motion slot for the wanted chain (fi_motion_lag) not published or
        // overwritten, no-tex = slot has no copies, not-ready = interpolator not built, world = fi_ui world
        // snapshot for vchain missing, dims = g_fiOut vs colour input format/size mismatch.
        log_line("FI SKIP WHY [window]: chain=%llu no-tex=%llu not-ready=%llu world=%llu dims=%llu",
                 (unsigned long long)win(pSc, g_fiSkipChain), (unsigned long long)win(pSt, g_fiSkipNoTex),
                 (unsigned long long)win(pSr, g_fiSkipReady), (unsigned long long)win(pSw, g_fiSkipWorld),
                 (unsigned long long)win(pSd, g_fiSkipDims));
    }

    if (g_fiUi) {
        log_line("FI PATH [window]: compose=%llu vtex=%llu", (unsigned long long)g_pathCompose, (unsigned long long)g_pathVtex);
        g_pathCompose = g_pathVtex = 0;
    }

    if (g_dlStarted) {
        static uint64_t pT = 0, pD = 0, pR = 0, pRp = 0, pI = 0, pL = 0, pNd = 0, pGn = 0;
        static double pLs = 0, pG = 0;
        uint64_t dT = win(pT, g_dlTicks), dL = win(pL, g_dlLate), dGn = win(pGn, g_dlGpuN);
        double dLs = winf(pLs, g_dlLateSum), dG = winf(pG, g_dlGpuSum);
        double secs = g_dlFirstTickNs > 0 ? (now_ns() - g_dlFirstTickNs) / 1e9 : 0.0;

        log_line("DISPLAYLINK [window]: ticks=%llu dup=%llu real=%llu repeat=%llu idle=%llu | late ticks=%llu (mean "
                 "%.2f ms) no-drawable=%llu | tick CB GPU mean %.2f ms | tick rate since start %.1f Hz | link's own "
                 "nextDrawable calls=%llu  [repeat > 0: BG3 slower than the tick pair; fifo-full drops = frames that "
                 "arrived faster than it]",
                 (unsigned long long)dT, (unsigned long long)win(pD, g_dlDup), (unsigned long long)win(pR, g_dlReal),
                 (unsigned long long)win(pRp, g_dlRepeat), (unsigned long long)win(pI, g_dlIdle),
                 (unsigned long long)dL, dL ? dLs * 1000.0 / (double)dL : 0.0,
                 (unsigned long long)win(pNd, g_dlNoDrawable), dGn ? dG * 1000.0 / (double)dGn : 0.0,
                 secs > 0 ? (double)g_dlTicks / secs : 0.0, (unsigned long long)g_dlNextDrawableCalls);
    }

    if (g_fiUi || g_uiFed)
        log_line("FI UI [totals]: in-frame snapshots=%llu (no source=%llu) composed=%llu | UI source identity vs "
                 "CombineUI Tex: match=%llu MISMATCH=%llu (a mismatch invalidates that frame's compose -> vtex)",
                 (unsigned long long)g_uiSnapped, (unsigned long long)g_wuSnapNoSrc, (unsigned long long)g_uiFed,
                 (unsigned long long)g_uiSrcMatch, (unsigned long long)g_uiSrcMismatch);
}

// The nextDrawable hook. If the saved original were our own hook (a double swizzle), forwarding would
// recurse endlessly, and a nil drawable is a dropped frame, not a dead process, so that case returns nil.
static id s_nextDrawable(id self, SEL _cmd) {
    if (!o_nextDrawable || o_nextDrawable == (IMP)s_nextDrawable) {
        static bool once = false;
        if (!once) {
            once = true;
            log_line_always("PROXY DRAWABLE: nextDrawable hook has no original to forward to, returning nil");
        }
        return nil;
    }

    // Virtual swapchain: BG3 gets one of OUR textures and the real pool stays untouched. Live switch: with
    // the key off, the next request falls through to the real path again.
    if (g_vsc && g_mode == 0) {
        uint64_t tid = 0;
        pthread_threadid_np(NULL, &tid);
        if (g_dlThreadId && tid == g_dlThreadId)
            g_dlNextDrawableCalls++;   // CAMetalDisplayLink fetching for itself: real drawable
        else if (g_renderThreadId && tid != g_renderThreadId) {
            // Not BG3's render thread: AppKit, CoreAnimation or an overlay asking the layer directly. Such a
            // caller expects a real CAMetalDrawable and may use private selectors a proxy lacks (an unrecognised
            // selector there is an uncaught exception, which BG3 turns into an abort).
            g_vsForeignNextDrawable++;
            if (g_vsForeignNextDrawable <= 3) {
                char name[64] = "";
                pthread_getname_np(pthread_self(), name, sizeof name);
                log_line_always(
                    "PROXY DRAWABLE: nextDrawable from a foreign thread (%llu '%s', main=%d), handing out the real drawable (#%llu)",
                    (unsigned long long)tid, name, pthread_main_np() ? 1 : 0,
                    (unsigned long long)g_vsForeignNextDrawable);
            }
        } else {
            id v = vs_hand_out((CAMetalLayer*)self);
            if (v) return v;
        }
    }

    return ((id (*)(id, SEL))o_nextDrawable)(self, _cmd);
}

// BG3 sets maximumDrawableCount on its layer at every window-mode change, and with a CAMetalDisplayLink attached
// CoreAnimation throws on that setter, and BG3 does not catch it. While our link owns the layer the value is
// deferred (the link hands out one drawable per tick, the pool size is irrelevant) and applied when the link
// detaches. Our own request in vs_present passes through the same hook.
static IMP o_setMaxDrawables = nullptr;
static void s_setMaxDrawables(id self, SEL _cmd, NSUInteger n) {
    if (g_dlActive.load(std::memory_order_acquire) && (CAMetalLayer*)self == g_dlLayer) {
        g_vsMaxDrawableDeferred.store(n);
        if (++g_vsMaxDrawableSwallowed <= 3)
            log_line_always(
                "DISPLAYLINK: setMaximumDrawableCount:%lu on BG3's layer deferred (a display link is attached; %s)",
                (unsigned long)n, pthread_main_np() ? "main thread" : "other thread");
        return;
    }

    ((void (*)(id, SEL, NSUInteger))o_setMaxDrawables)(self, _cmd, n);
}

static void hook_layer(CAMetalLayer* layer) {
    if (!layer || o_nextDrawable) return;   // hooked once, for the whole process

    // The methods may be inherited (BG3's layer could be a subclass): swizzling one changes the class that
    // owns it, which is what we want, and swz refuses a class that brings its own implementation.
    Class c = object_getClass(layer);
    swz(&o_setMaxDrawables, c, @selector(setMaximumDrawableCount:), (IMP)s_setMaxDrawables);
    swz(&o_nextDrawable, c, @selector(nextDrawable), (IMP)s_nextDrawable);

    // The virtual swapchain stands or falls with this one hook, so the log says either way, even when
    // logging is off.
    if (o_nextDrawable)
        log_line_always("PROXY DRAWABLE: hooked nextDrawable on %s, original imp %p, ours %p", class_getName(c),
                        (void*)o_nextDrawable, (void*)s_nextDrawable);
    else
        log_line_always("PROXY DRAWABLE: could not hook nextDrawable on %s, the virtual swapchain stays off",
                        class_getName(c));
}

// The frame limiter (frame_cap), owned by us because we own the presentation.
// Runs on the render thread at the START of a frame (first render encoder after a present), so the previous frame is already
// committed and on the GPU while we wait. Frame doubling needs 2 x base under the refresh rate, and with the
// presenter pacing the two presents half an interval apart (D = 1/(2*cap)), the base must sit EXACTLY on
// the cap or the pairs drift against the refresh grid.
//
// TODO: nothing here reads the GPU's real pace, so a scene that cannot hold the cap just drops and the
// interpolator restarts its history.
static void frame_cap_wait(void) {
    int cap = g_frameCap;
    if (cap <= 0) {
        g_capNextNs = 0.0;
        return;
    }

    double period = 1e9 / (double)cap, now = now_ns();
    if (g_vsBacklog.load(std::memory_order_relaxed)) {
        period *= 1.01;
        g_capStretched++;
    }

    // Never wait more than one period, whatever the deadline chain says. BG3 pipelines frames across
    // threads, so a second waiter can enter while the first still waits, each waiter advances
    // the chain by a period, and without this clamp the chain runs two periods ahead and the base rate
    // halves.
    if (g_capNextNs > now + period) g_capNextNs = now + period;

    if (g_capNextNs > now) {
        double target = g_capNextNs, remain = target - now;
        g_capWaitSum += remain;
        g_capWaits++;

        static mach_timebase_info_data_t tb = {0, 0};
        if (tb.denom == 0) mach_timebase_info(&tb);
        if (remain > 0.8e6) {   // coarse part: kernel wait until 0.6 ms before the deadline
            uint64_t deadline = (uint64_t)((target - 0.6e6) * (double)tb.denom / (double)tb.numer);
            mach_wait_until(deadline);
        }
        while ((now = now_ns()) < target) { /* spin the last few hundred microseconds */
        }
        double over = now - target;
        g_capOverSum += over;
        if (over > g_capOverMax) g_capOverMax = over;
    } else if (g_capNextNs > 0.0) g_capLate++;   // the frame itself took longer than the period: no wait, re-anchor
    g_capNextNs = (g_capNextNs > now - period ? g_capNextNs : now) + period;
}
