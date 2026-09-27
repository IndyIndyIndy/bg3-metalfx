// The frame boundary.
// The game's present call is where the mod counts frames, writes its reports and drains the graveyard, and where a present
// of one of our own drawables is swallowed. The rest of the file recognises passes and pipelines by the shaders they bind,
// so the hot hooks only compare a tag.

static void present_prologue(void);

// Shared front of the three presentDrawable: hooks. Returns true when the present was swallowed (BG3 rendered
// into our virtual drawable and the presenter shows it). Our own off-thread command buffers pass straight
// through, and for the game's real drawables the layer class is hooked and the per-present bookkeeping runs.
static bool present_intercept(id cb, id<CAMetalDrawable> d) {
    if (objc_getAssociatedObject(cb, &kOurOffThreadCBKey)) return false;
    if (d && [d isKindOfClass:[BG3MFXDrawableProxy class]] && ((BG3MFXDrawableProxy*)d).vtex) {
        BG3MFXDrawableProxy* p = (BG3MFXDrawableProxy*)d;
        p.vchain = g_chainId;
        present_prologue();
        vs_present(cb, p);
        return true;
    }

    if (g_vsc) hook_layer(d.layer);   // the nextDrawable hook on BG3's layer class
    present_prologue();
    return false;
}

static void present_prologue(void) {
    MARK("present");
    g_presentCount++;

    // Passthrough: the drawable is the game's own, we have nothing to reset or measure. Only the
    // graveyard still drains, so textures retired before the mode switch are eventually freed.
    if (mod_idle()) {
        drain_graveyard();
        return;
    }

    // The frame limiter runs at the START of the next frame (frame_cap_wait from s_renderEnc, armed here), so
    // the finished frame is not held on the CPU before the GPU sees it. A frame presented without any render
    // encoder since the last present (loading screens) never reaches that call and is capped here instead,
    // so the presenter is not flooded.
    // Only with the virtual swapchain: its display link presents in step with the cap.
    if (g_capArmed.exchange(false)) frame_cap_wait();
    g_capArmed.store(g_frameCap > 0 && g_vsc);

    if (g_presentCount % 600 == 0) {
        run_status(g_presentCount);
        if (g_scaler) {
            mfx_report_stats();
            vs_report();
        }
    }

    drain_graveyard();
    maybe_handle_resize();
    maybe_gpu_capture();

    if (g_scaler && g_bframe < 14)
        log_line("FRAME %d: snaps=%d comps=%d jitter=(%.3f, %.3f) px  mvScale=(%.2f, %.2f)", g_bframe, g_snapCount,
                 g_compCount, g_jxFed, g_jyFed, g_mvScaleX, g_mvScaleY);

    if (g_scaler) g_bframe++;
    g_passIdx = 0;
    g_rrCur = nil;
    g_rrPrev = nil;
}

// The three presentDrawable: variants
static void s_present(id self, SEL _cmd, id<CAMetalDrawable> drawable) {
    if (present_intercept(self, drawable)) return;
    ((void (*)(id, SEL, id))o_present)(self, _cmd, drawable);
}

static void s_present2(id self, SEL _cmd, id<CAMetalDrawable> drawable, CFTimeInterval dur) {
    if (present_intercept(self, drawable)) return;
    ((void (*)(id, SEL, id, CFTimeInterval))o_present2)(self, _cmd, drawable, dur);
}

static IMP o_present3 = nullptr;
static void s_present3(id self, SEL _cmd, id<CAMetalDrawable> drawable, CFTimeInterval at) {
    if (present_intercept(self, drawable)) return;
    ((void (*)(id, SEL, id, CFTimeInterval))o_present3)(self, _cmd, drawable, at);
}

static void capture_mfx_inputs(MTLRenderPassDescriptor* d) {
    id<MTLTexture> c0 = d.colorAttachments[0].texture;
    id<MTLTexture> dep = d.depthAttachment.texture;
    int nColor = 0;
    MTLPixelFormat f0 = MTLPixelFormatInvalid;
    for (NSUInteger i = 0; i < 8 && nColor < 2; i++) {   // only "exactly one" matters below
        id<MTLTexture> t = d.colorAttachments[i].texture;
        if (t) {
            if (nColor == 0) f0 = t.pixelFormat;
            nColor++;
        }
    }

    // Early diagnostic: log every render-res RG11B10 colour pass in order, which locates the pre-TAA scene
    // colour. The bracket is relative to the live resolutions, above half the render width to skip the
    // bloom mips and below the target width to skip the upscaled ones, so it holds on any display.
    g_passIdx++;
    if (g_logging && g_scaler && g_bframe < 4 && c0 && c0.pixelFormat == MTLPixelFormatRG11B10Float &&
        c0.width > g_inW / 2 && c0.width < g_outW)
        log_line("RG11B10 F%d ord%d nColor=%d depth=%s %lux%lu '%s'", g_bframe, g_passIdx, nColor, dep ? "y" : "n",
                 (unsigned long)c0.width, (unsigned long)c0.height, c0.label ? c0.label.UTF8String : "-");

    // Which passes define the render and target resolution is a heuristic over formats and sizes, and BG3
    // renders secondary views (portraits, the character sheet: 1272x1254 next to 1512x982) through the same
    // pass types. Once the scaler exists, only passes at the BUILT sizes feed the live state, while other sizes
    // become candidates that maybe_handle_resize adopts at present time after a two-frame debounce.
    const bool locked = g_scaler != nil;
    if (nColor == 1 && f0 == MTLPixelFormatRG16Float && c0) {   // the motion-vector pass
        g_candInW = c0.width;
        g_candInH = c0.height;
        if (!locked || (c0.width == g_builtInW && c0.height == g_builtInH)) {
            cache_tex(&g_mv, c0);
            if (dep) cache_tex(&g_depth, dep);
            g_inW = c0.width;
            g_inH = c0.height;
        }
    }

    // Track the two most-recent render-res RG11B10 single-attachment scene-colour passes.
    // g_color itself is chosen in s_setRPS the moment PPTAA_PS is bound (= the pass right before TAA,
    // g_rrPrev). Require nColor==1 to skip g-buffer/multi-target passes.
    if (nColor == 1 && c0 && c0.pixelFormat == MTLPixelFormatRG11B10Float && g_inW && c0.width == g_inW) {
        g_rrPrev = g_rrCur;
        g_rrCur = c0;
    }

    // Target res = a NON-square color target larger than render-res, excludes square shadow maps
    // (8192x8192 etc.). The upscale ratio is modest (~1.5x), so cap at 3x for safety.
    if (c0 && g_inW && c0.width > g_inW && c0.width <= g_inW * 3 && c0.width != c0.height) {
        g_candOutW = c0.width;
        g_candOutH = c0.height;
        if (!locked || (c0.width == g_builtOutW && c0.height == g_builtOutH)) {
            g_outW = c0.width;
            g_outH = c0.height;
        }
    }

    // The post-FSR scene texture we overwrite: a target-res RGB10A2Unorm color target.
    if (c0 && g_outW && c0.pixelFormat == MTLPixelFormatRGB10A2Unorm && c0.width == g_outW && c0.height == g_outH) {
        // Every target-res RGB10A2 pass overwrites g_scene, so it holds the LAST one of the
        // frame, and the fi_ui world snapshot is copied form it just before CombineUI, which makes
        // whichever texture it points at the world the presenter shows.
        // Format and size are the only things matched, so log every pointer change (first 40, then every 200th) with pass
        // ordinal and  chain, and a menu-only pass winning the slot shows up in the log instead of having to be inferred from a wrong picture.
        if (g_logging && c0 != g_scene) {
            static uint64_t changes = 0;
            changes++;
            if (changes <= 40 || changes % 200 == 0)
                log_line("G_SCENE CHANGE #%llu: %p -> %p '%s' at ord%d chain=%u frame=%d (fi_ui world source)",
                         (unsigned long long)changes, (void*)g_scene, (void*)c0, c0.label ? c0.label.UTF8String : "-",
                         g_passIdx, g_chainId, g_bframe);
        }
        cache_tex(&g_scene, c0);
    }

    // DIAG: report every change of the observed dimensions, independent of the scaler. If BG3's
    // render-scale slider recreates its targets this fires, and if it stays silent while the slider
    // moves, the scale is applied some other way (viewport, see the VIEWPORT lines) or not at all.
    static NSUInteger lastIn = 0, lastInH = 0, lastOut = 0, lastOutH = 0;
    if (g_inW != lastIn || g_inH != lastInH || g_outW != lastOut || g_outH != lastOutH) {
        if (lastIn || lastOut)
            log_line("DIMS changed: render %lux%lu -> %lux%lu, target %lux%lu -> %lux%lu", (unsigned long)lastIn,
                     (unsigned long)lastInH, (unsigned long)g_inW, (unsigned long)g_inH, (unsigned long)lastOut,
                     (unsigned long)lastOutH, (unsigned long)g_outW, (unsigned long)g_outH);
        lastIn = g_inW;
        lastInH = g_inH;
        lastOut = g_outW;
        lastOutH = g_outH;
    }

    try_build_scaler();
}

// render-pass target enumeration (the decisive MV/Depth/Color probe)
static void log_render_pass(MTLRenderPassDescriptor* d) {
    if (!d || mod_idle()) return;
    capture_mfx_inputs(d);   // cache candidate MetalFX inputs + try to build the scaler

    // Pure diagnostics that would build strings for every render pass of every frame, so off by default.
    if (!g_logPasses) return;

    NSMutableString* sig = [NSMutableString string];
    NSMutableString* human = [NSMutableString string];
    int nColor = 0;
    MTLPixelFormat firstFmt = MTLPixelFormatInvalid;
    for (NSUInteger i = 0; i < 8; i++) {
        id<MTLTexture> t = d.colorAttachments[i].texture;
        if (!t) continue;
        if (nColor == 0) firstFmt = t.pixelFormat;
        nColor++;
        [sig appendFormat:@"C%lu=%lu:%lux%lu|", (unsigned long)i, (unsigned long)t.pixelFormat, (unsigned long)t.width,
                          (unsigned long)t.height];
        const char* pn = pfName(t.pixelFormat);
        [human appendFormat:@" C%lu=[%s %lux%lu%@]", (unsigned long)i,
                            pn ? pn : [NSString stringWithFormat:@"fmt%lu", (unsigned long)t.pixelFormat].UTF8String,
                            (unsigned long)t.width, (unsigned long)t.height,
                            t.label ? [NSString stringWithFormat:@" '%@'", t.label] : @""];
    }

    id<MTLTexture> dt = d.depthAttachment.texture;
    if (dt) {
        [sig appendFormat:@"D=%lu:%lux%lu", (unsigned long)dt.pixelFormat, (unsigned long)dt.width,
                          (unsigned long)dt.height];
        const char* pn = pfName(dt.pixelFormat);
        [human appendFormat:@" D=[%s %lux%lu]", pn ? pn : "?", (unsigned long)dt.width, (unsigned long)dt.height];
    }

    // A single RG16Float color target = the motion-vector pass (see the _VEL_ pipelines)
    if (nColor == 1 && firstFmt == MTLPixelFormatRG16Float) [human appendString:@"   <-- MOTION-VECTOR target"];
    if (sig.length == 0) return;
    if (log_first_time([@"rp:" stringByAppendingString:sig])) log_line("PASS%s", human.UTF8String);
}

// render pipeline (shader names + attachment formats)
// Behind log_passes: this runs on BG3's pipeline-compile threads and log_first_time() takes the global
// mutex, so leaving it on funnels the game's parallel shader compilation through one lock during a load.
static void log_render_pipe(MTLRenderPipelineDescriptor* d) {
    if (!d || mod_idle() || !g_logging || !g_logPasses) return;   // pure diagnostics: strings per pipeline

    NSString* vf = d.vertexFunction.name ?: @"-";
    NSString* ff = d.fragmentFunction.name ?: @"-";
    NSMutableString* fmts = [NSMutableString string];
    for (NSUInteger i = 0; i < 8; i++) {
        MTLPixelFormat f = d.colorAttachments[i].pixelFormat;
        if (f == MTLPixelFormatInvalid) continue;
        const char* pn = pfName(f);
        [fmts appendFormat:@"%lu:%s ", (unsigned long)i,
                           pn ? pn : [NSString stringWithFormat:@"fmt%lu", (unsigned long)f].UTF8String];
    }

    NSString* sig =
        [NSString stringWithFormat:@"rpipe:%@|%@|%@|d%lu", vf, ff, fmts, (unsigned long)d.depthAttachmentPixelFormat];
    if (log_first_time(sig))
        log_line("RPIPE v=%s f=%s color=[%s] depth=%s", vf.UTF8String, ff.UTF8String, fmts.UTF8String,
                 pfName(d.depthAttachmentPixelFormat) ?: "none");
}

// Associated-object keys for encoders and pipeline states
static const char kCamPassKey = 0;      // render encoder is a camera-view pass (probe its constants)
static const char kRenderFragKey = 0;   // fragment-function name attached to a render PSO (diagnostics only)
static void* g_skipEnc = nullptr;       // the encoder whose current pipeline binding is skipped (render thread)
static const char kPSOIsFsrKey = 0;     // set at compile time on FSR's own kernels (see below)
static void tag_pso(id pso, id<MTLFunction> fn) {
    if (!pso || !fn.name) return;

    // The shader dump is diagnostic and takes the global mutex on a compile thread, so it is gated.
    if (g_logging && g_logPasses && log_first_time([@"cs:" stringByAppendingString:fn.name]))
        log_line("COMPUTE shader: %s", fn.name.UTF8String);

    // Decide "is this an FSR kernel?" once at compile time, so s_dispatch reads a flag not a string.
    if ([fn.name hasPrefix:@"FSR"])
        objc_setAssociatedObject(pso, &kPSOIsFsrKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// swizzled methods
// MRC: the original `new...` returns +1, and capturing it in a local and returning it preserves ownership.
static IMP o_newCompute = nullptr;
static id s_newCompute(id self, SEL _cmd, id<MTLFunction> fn, NSError** err) {
    MARK("newPipelineState (shader compile)");
    id pso = ((id (*)(id, SEL, id, NSError**))o_newCompute)(self, _cmd, fn, err);
    @autoreleasepool {
        tag_pso(pso, fn);
    }
    return pso;
}

static IMP o_newComputeR = nullptr;
static id s_newComputeR(id self, SEL _cmd, id<MTLFunction> fn, MTLPipelineOption opt,
                        MTLAutoreleasedComputePipelineReflection* refl, NSError** err) {
    id pso = ((id (*)(id, SEL, id, MTLPipelineOption, MTLAutoreleasedComputePipelineReflection*,
                      NSError**))o_newComputeR)(self, _cmd, fn, opt, refl, err);
    @autoreleasepool {
        tag_pso(pso, fn);
    }
    return pso;
}

static IMP o_newRender = nullptr;

// Classify a render PSO once at creation into a small integer, so s_setRPS reads a tag per bind instead
// of comparing shader-function names thousands of times per frame.
enum { PSO_OTHER = 0, PSO_TAA = 1, PSO_GRADING = 2, PSO_FSR_TONEMAP = 3, PSO_BLOOM_COMBINE = 4, PSO_COMBINE_UI = 5 };
static const char kPsoTagKey = 0;
static void tag_render_pso(id ps, MTLRenderPipelineDescriptor* d) {
    if (!ps) return;
    NSString* n = d.fragmentFunction.name;
    if (!n) return;

    if (g_logging)   // the name is only ever read by diagnostics
        objc_setAssociatedObject(ps, &kRenderFragKey, n, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    int tag = PSO_OTHER;
    if ([n isEqualToString:@"PPTAA_PS"]) tag = PSO_TAA;
    else if ([n isEqualToString:@"PPColorGradingApplyLUTPS"]) tag = PSO_GRADING;
    else if ([n isEqualToString:@"PPBloomUpsampleBlurAndCombine_PS"]) tag = PSO_BLOOM_COMBINE;

    // Prefix, not equality: every FSR_* render pass feeds the suppressed upscale.
    else if ([n hasPrefix:@"FSR"]) tag = PSO_FSR_TONEMAP;
    else if ([n isEqualToString:@"CombineUI"]) tag = PSO_COMBINE_UI;   // the final composite (fi_ui)

    objc_setAssociatedObject(ps, &kPsoTagKey, @(tag), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id s_newRender(id self, SEL _cmd, MTLRenderPipelineDescriptor* d, NSError** err) {
    MARK("newPipelineState (shader compile)");
    @autoreleasepool {
        log_render_pipe(d);
    }

    id ps = ((id (*)(id, SEL, id, NSError**))o_newRender)(self, _cmd, d, err);
    @autoreleasepool {
        tag_render_pso(ps, d);
    }
    return ps;
}

static IMP o_newRenderR = nullptr;
static id s_newRenderR(id self, SEL _cmd, MTLRenderPipelineDescriptor* d, MTLPipelineOption opt,
                       MTLAutoreleasedRenderPipelineReflection* refl, NSError** err) {
    @autoreleasepool {
        log_render_pipe(d);
    }

    id ps = ((id (*)(id, SEL, id, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection*, NSError**))o_newRenderR)(self, _cmd, d, opt, refl, err);
    @autoreleasepool {
        tag_render_pso(ps, d);
    }
    return ps;
}
