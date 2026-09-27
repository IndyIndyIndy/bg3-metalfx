// Where every hook is installed, and where most of them run.
// hook_device starts it: the queues come from the device, the command buffers from the queues, the encoders from those,
// and each class is hooked the first time one is seen, because Metal's real classes only exist at runtime.

// PPTAA_PS bound: a new world chain starts. The pass right before TAA (g_rrPrev, the DeferredFog/SSS output)
// holds the jittered pre-TAA colour, and MetalFX gets THAT so it reconstructs real sub-pixel detail instead of
// upscaling an already resolved, soft frame.
// TAA's own output attachment is the pre-bloom scene the bloom extract needs.
static bool g_preTaaLogged = false;
static void taa_bound(id<MTLTexture> attC0) {
    // Only the WORLD's TAA pass, at render resoultion, starts a chain. BG3 runs a second TAA for the
    // portrait in the inventory and the ESC menu at its own size, and counting it would pair the interpolator
    // with the portrait's depth and motion and snapshot a stale world texture.
    if (attC0 && g_inW && (attC0.width != g_inW || attC0.height != g_inH)) {
        static uint64_t n = 0;
        if (++n == 1 || n % 5000 == 0)
            log_line("TAA pass at %lux%lu ignored (render res %lux%lu): a portrait, not the world (#%llu)",
                     (unsigned long)attC0.width, (unsigned long)attC0.height, (unsigned long)g_inW,
                     (unsigned long)g_inH, (unsigned long long)n);
        return;
    }

    g_taaSeen++;
    g_chainId++;   // re-arms exactly one composite (see g_compChain)
    if (!g_renderThreadId) pthread_threadid_np(NULL, &g_renderThreadId);

    // Pre-TAA (default) keeps the sub-pixel detail but also BG3's per-frame render noise (SSR, SSAO,
    // dither), whereas post-TAA is BG3's resolved image, softer but noise-free.
    id<MTLTexture> feed = (g_mfxInputMode == 1 && attC0) ? attC0 : g_rrPrev;
    if (feed) {
        cache_tex(&g_color, feed);   // format/size reference for building the scaler
        g_snapSrc = feed;            // snapshot this texture at the next encoder boundary
        g_needSnapshot = true;

        if (!g_preTaaLogged) {
            log_line("MetalFX input LOCKED: %s RG11B10 %lux%lu",
                     g_mfxInputMode == 1 ? "POST-TAA (TAA's resolved output)" : "PRE-TAA (input to PPTAA_PS)",
                     (unsigned long)feed.width, (unsigned long)feed.height);
            g_preTaaLogged = true;
        }

        // Diagnostic: g_rrPrev is inferred, not read from PPTAA_PS's bindings. BG3 ping-pongs two textures,
        // so a healthy sequence alternates between exactly two pointers, and a third or a broken rhythm means
        // we would feed MetalFX the wrong texture.
        static void* s_lastSrc = nullptr;
        static int s_srcLogs = 0;
        if (s_srcLogs < 24) {
            s_srcLogs++;
            log_line("SNAPSRC chain %u: colour=%p depth=%p mv=%p%s", g_chainId, (void*)feed, (void*)g_depth,
                     (void*)g_mv, (s_lastSrc && s_lastSrc == (void*)feed) ? "   <-- SAME AS LAST CHAIN" : "");
            s_lastSrc = (void*)feed;
        }
    }

    // Bloom layer: TAA's OUTPUT attachment is the pre-bloom scene that ord49 adds bloom to. Kept OUT of the
    // feed branch on purpose: a frame whose input happens to be nil still has a valid TAA output.
    if (attC0 && g_gradingHarvest) {   // same gate as the harvest itself
        if (!grad_pool_contains(attC0)) {
            grad_pool_add(attC0);
            log_line("GRAD TAA-out attachment: %p %lux%lu (pool now %d)", (void*)attC0, (unsigned long)attC0.width,
                     (unsigned long)attC0.height, g_gradPoolN);
        }

        cache_tex(&g_taaAtt, attC0);   // this frame's pre-bloom scene (ping-pong partner)
        g_taaFresh = true;
        g_taaCopied = false;
        g_bloomReady = false;   // a new post-chain begins; last chain's layer expires here
    }
}

// PPColorGradingApplyLUTPS (ord50) bound: THIS encoder grades its colour attachment in place. The candidate
// blitted at this encoder's own boundary (grading_boundary, just before creation) holds the INPUT, while the
// output is harvested at the next boundary.
static void grading_bound(id<MTLTexture> attC0) {
    if (!attC0 || !g_gradingHarvest) return;

    if (!grad_pool_contains(attC0)) {
        grad_pool_add(attC0);
        log_line("GRAD ord50 attachment: %p RG11B10 %lux%lu (pool now %d)", (void*)attC0, (unsigned long)attC0.width,
                 (unsigned long)attC0.height, g_gradPoolN);
    }

    cache_tex(&g_gradAtt, attC0);   // THIS frame's graded texture (BG3 ping-pongs two)
    if (g_gradInSrc == (void*)attC0) {
        g_pendingGradOut = true;
        g_gradInSrc = nullptr;
    } else g_gradMissed++;   // no matching candidate: this frame yields no pair
}

// The pipeline-bind hook: read the pass tag decided at PSO creation and dispatch on it. Untagged pipelines
// are the vast majority of binds and leave after one associated-pointer read.
static IMP o_setRPS = nullptr;
static void s_setRPS(id self, SEL _cmd, id<MTLRenderPipelineState> pso) {
    if (!mod_idle()) {
        // The tag is a raw associated pointer (RETAIN_NONATOMIC): nothing autoreleased on this path.
        NSNumber* tagN = pso ? objc_getAssociatedObject(pso, &kPsoTagKey) : nil;
        int tag = tagN ? tagN.intValue : PSO_OTHER;

        // The skip-draw state belongs to one pipeline binding: g_skipEnc names the encoder whose current
        // binding is skipped, and an untagged pipeline bound on it ends the skip. Tagged pipelines re-decide below.
        if (tag == PSO_OTHER && (void*)self == g_skipEnc) g_skipEnc = nullptr;

        // Everything below may create autoreleased objects (strings, log formatting), so the pool starts here.
        if (tag != PSO_OTHER || (g_scaler && g_bframe < 4)) @autoreleasepool {
                id<MTLTexture> attC0 = objc_getAssociatedObject(self, &kEncColor0Key);   // colour attachment 0

                if (g_scaler && g_bframe < 4) {
                    // Early-frame pass map: the colour attachment names each pass's output (FSR_Tonemap's
                    // output is the tonemap input, and the bloom chain is visible the same way).
                    NSString* fn = objc_getAssociatedObject(pso, &kRenderFragKey);
                    NSNumber* ord = objc_getAssociatedObject(self, &kEncOrdKey);
                    log_line("PSHADER F%d ord%d frag=%s  out=%p %s %lux%lu", g_bframe, ord ? ord.intValue : -1,
                             fn.UTF8String, (void*)attC0, attC0 ? (pfName(attC0.pixelFormat) ?: "?") : "-",
                             (unsigned long)(attC0 ? attC0.width : 0), (unsigned long)(attC0 ? attC0.height : 0));
                }

                if (tag == PSO_TAA) taa_bound(attC0);
                else if (tag == PSO_GRADING) grading_bound(attC0);
                else if (tag == PSO_BLOOM_COMBINE && attC0) {
                    // ord49 (bloom combine): remember which texture it wrote and in which chain, so the NEXT
                    // boundary can tell "this is ord50's input" apart from the other pool-attachment boundaries.
                    g_bloomOutTex = (void*)attC0;
                    g_bloomCombineChain = g_chainId;
                    g_bloomCombineSeen = true;
                }

                // FSR_* passes (ord51 FSR_Tonemap and any sibling) only feed FSR's EASU/RCAS compute, and that
                // dispatch is suppressed in metalfx mode, so their draws are swallowed. Decided per pipeline
                // binding: g_skipEnc names this encoder while its binding is skipped, and an untagged pipeline bound
                // later on it clears that (top of this function). The draw hooks compare the encoder pointer,
                // one compare per draw.
                bool skipDraw = tag == PSO_FSR_TONEMAP && g_skipFsrTonemap && mfx_active();
                if (skipDraw) g_skipEnc = (void*)self;
                else if (g_skipEnc == (void*)self) g_skipEnc = nullptr;
            }
    }

    ((void (*)(id, SEL, id))o_setRPS)(self, _cmd, pso);
}

static IMP o_drawPrim = nullptr;
static void s_drawPrim(id self, SEL _cmd, NSUInteger type, NSUInteger start, NSUInteger count) {
    if ((void*)self == g_skipEnc && !mod_idle()) {
        if (++g_fsrTonemapSkipped == 1)
            log_line("skip-draw: full-screen draw suppressed (the pass has no consumer left in metalfx mode)");
        return;   // swallow the draw; the pass itself stays empty
    }

    ((void (*)(id, SEL, NSUInteger, NSUInteger, NSUInteger))o_drawPrim)(self, _cmd, type, start, count);
}

static IMP o_drawIdx = nullptr;
static void s_drawIdx(id self, SEL _cmd, NSUInteger type, NSUInteger n, NSUInteger it, id buf, NSUInteger off) {
    if ((void*)self == g_skipEnc && !mod_idle()) {
        g_fsrTonemapSkipped++;
        return;
    }   // same pass, indexed draw

    ((void (*)(id, SEL, NSUInteger, NSUInteger, NSUInteger, id, NSUInteger))o_drawIdx)(self, _cmd, type, n, it, buf,
                                                                                       off);
}

// Fragment-buffer bind: apply the Granite virtual-texture mip bias to the bound buffer in place, then forward the bind unchanged.
static IMP o_setFragBuf = nullptr;
static void s_setFragBuf(id self, SEL _cmd, id<MTLBuffer> buf, NSUInteger offset, NSUInteger idx) {
    if (!mod_idle()) patch_vt_tileset(buf, offset, idx);   // nothing autoreleased on this path
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))o_setFragBuf)(self, _cmd, buf, offset, idx);
}

static void hook_render_encoder(Class c) {
    if (!c || !mark_class(c)) return;
    swz(&o_drawPrim, c, @selector(drawPrimitives:vertexStart:vertexCount:), (IMP)s_drawPrim);
    swz(&o_drawIdx, c, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:),
        (IMP)s_drawIdx);
    swz(&o_vbuf, c, @selector(setVertexBuffer:offset:atIndex:), (IMP)s_vbuf);
    swz(&o_setRPS, c, @selector(setRenderPipelineState:), (IMP)s_setRPS);
    swz(&o_setFragBuf, c, @selector(setFragmentBuffer:offset:atIndex:), (IMP)s_setFragBuf);
    swz(&o_setFragTexN, c, @selector(setFragmentTextures:withRange:), (IMP)s_setFragTexN);   // UI identity check

    log_line("hooked MTLRenderCommandEncoder class: %s", class_getName(c));
}

// cmdbuffer -> render encoder. Every render pass BG3 opens passes through here, so this is the per-pass
// boundary: frame-cap wait, pre-TAA snapshot + MetalFX encode, grading harvest, pass logging, native
// upscale into FSR's output, fi_ui copies, per-pass GPU timing. The new encoder is then tagged
// (colour attachment 0, ord, camera pass) for the encoder hooks.
static IMP o_renderEnc = nullptr;
static id s_renderEnc(id self, SEL _cmd, MTLRenderPassDescriptor* d) {
    // Our own off-thread command buffer (virtual-swapchain presenter): none of the render-thread state
    // below may run for it, and the encoder class is already hooked. Forward and leave.
    if (objc_getAssociatedObject(self, &kOurOffThreadCBKey)) return ((id (*)(id, SEL, id))o_renderEnc)(self, _cmd, d);

    // Frame start (first render encoder since our swallowed present, which arms this): the frame limiter
    // waits here, with the previous frame already committed. Outside the PERF scope: the wait is the cap,
    // not hook cost.
    if (!mod_idle() && g_capArmed.exchange(false)) frame_cap_wait();

    MARK("renderCommandEncoder");
    id<MTLTexture> c0 = d ? d.colorAttachments[0].texture : nil;

    if (!mod_idle()) @autoreleasepool {
            if (g_fsrOutPending.load(std::memory_order_relaxed)) {   // adopt BG3's new FSR-out target
                if (void* np = g_fsrOutPending.exchange(nullptr, std::memory_order_acq_rel)) {
                    cache_tex(&g_fsrOut, (id<MTLTexture>)np);
                    [(id)np release];
                }
            }

            // No encoder is open on the game CB at this point, so blit/render encoders are legal here.
            // Preserve the just-consumed pre-TAA colour (if flagged). On the event path the
            // MetalFX encode follows IMMEDIATELY, at this same boundary: the snapshot blit is the last
            // thing on the game CB, the event signal goes right behind it, and queue B may start as soon
            // as the GPU has executed that blit. Must precede grading_boundary, which opens encoders.
            if (snapshot_pre_taa(self)) event_encode(self);
            grading_boundary(self, d);   // harvest ord50's output / keep a "before ord50" candidate
            log_render_pass(d);          // caches inputs + the scene texture, builds the scaler

            // Just before BG3's tonemap pass (the first RGB10A2 target-res writer), write our MetalFX HDR
            // into FSR's output texture so BG3 tonemaps and grades it natively.
            if (d && is_scene_pass(d)) upscale_native(self);

            // fi_ui: the pass about to be created writes our virtual drawable => it is CombineUI. Everything it
            // reads (g_scene, the Noesis UI written by the encoder before this one) is complete at this
            // boundary, so copy both now, in this frame's command buffer.
            int cs = vs_ring_index(c0);
            if (cs >= 0) {
                if (BG3MFXDrawableProxy* owner = g_vsSlotProxy[cs]) owner.vsceneSrc = (void*)g_scene;
                if (g_fiUi) snapshot_world_ui_inframe(self, (id<MTLTexture>)g_prevEncC0, c0);
            }

            g_prevEncC0 = (void*)c0;   // pointer only; consumed within this frame
        }

    id e = ((id (*)(id, SEL, id))o_renderEnc)(self, _cmd, d);

    // The encoder class still has to be hooked even in passthrough, or switching mode live would find
    // an unhooked class. Everything else (the associated-object tagging) is ours and is skipped.
    if (e) hook_render_encoder(object_getClass(e));

    if (!mod_idle()) @autoreleasepool {
            if (e) {
                // color0 is read by the ord50 detection every frame (and the ord-probe logging early on)
                objc_setAssociatedObject(e, &kEncColor0Key, c0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (g_fiUi && vs_is_ring_tex(c0))
                    objc_setAssociatedObject(e, &kFinalCompKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (g_scaler && g_bframe < 4)
                    objc_setAssociatedObject(e, &kEncOrdKey, @(g_passIdx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (is_camera_pass(d))
                    objc_setAssociatedObject(e, &kCamPassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }

    return e;
}

// Compute encoder: the pipeline's "is FSR" tag (decided once at compile time by tag_pso) names the encoder
// that currently has an FSR kernel bound, the same way g_skipEnc does for render encoders. A pointer
// compare per dispatch, nothing stored on the encoder. Raw associated pointer only, nothing autoreleased.
static void* g_fsrEnc = nullptr;   // the compute encoder whose current binding is an FSR kernel
static IMP o_setCPS = nullptr;
static void s_setCPS(id self, SEL _cmd, id<MTLComputePipelineState> pso) {
    if (!mod_idle()) {
        if (pso && objc_getAssociatedObject(pso, &kPSOIsFsrKey)) g_fsrEnc = (void*)self;
        else if (g_fsrEnc == (void*)self) g_fsrEnc = nullptr;
    }

    ((void (*)(id, SEL, id))o_setCPS)(self, _cmd, pso);
}

// True while MetalFX replaces BG3's upscale for the current chain: only then are FSR's dispatch and
// the skip-draw passes suppressed, and otherwise (warmup, passthrough) FSR must run so the image is valid.
// FSR runs between ord51 and our composite, so `g_compChain != g_chainId` holds exactly for a chain we
// are still going to composite. In a context that never binds PPTAA_PS (no chain advance) BG3's own
// upscale is left alone instead of being suppressed with nothing put in its place.
static bool mfx_active(void) {
    return g_mode == 0 && g_scaler && g_colorCopy && g_depthCopy && g_mvCopy && g_scene && g_compChain != g_chainId &&
           // Event path: only a chain whose encode is already in flight on queue B gets its FSR
           // suppressed. event_encode() decides at the snapshot boundary, which precedes FSR's
           // dispatch, so this reads a settled value.
           (effective_encode_path() != ENC_EVENT || g_evPendingChain == g_chainId) && g_colorCopy.width == g_inW &&
           g_scene.width == g_outW && g_scene.height == g_outH &&
           // Without a destination texture we must not suppress BG3's FSR dispatch: a frame we
           // cannot composite is then rendered by BG3's own FSR (a worse frame beats a broken one).
           g_fsrOut && g_fsrOut.width == g_outW && g_fsrOut.height == g_outH;
}

static bool g_fsrSkipLogged = false;
static IMP o_dispatch = nullptr;
static void s_dispatch(id self, SEL _cmd, MTLSize tg, MTLSize tptg) {
    if ((void*)self == g_fsrEnc && !mod_idle() && mfx_active()) {
        if (!g_fsrSkipLogged) {
            g_fsrSkipLogged = true;
            log_line("FSR dispatch suppressed (metalfx mode), MetalFX replaces the upscale");
        }
        return;   // swallow FSR's upscale dispatch; MetalFX writes the scene instead
    }

    ((void (*)(id, SEL, MTLSize, MTLSize))o_dispatch)(self, _cmd, tg, tptg);
}

static void hook_compute_encoder(Class c) {
    if (!c || !mark_class(c)) return;
    swz(&o_setCPS, c, @selector(setComputePipelineState:), (IMP)s_setCPS);
    swz(&o_dispatch, c, @selector(dispatchThreadgroups:threadsPerThreadgroup:), (IMP)s_dispatch);
    log_line("hooked MTLComputeCommandEncoder class: %s", class_getName(c));
}

static IMP o_cce = nullptr, o_cceD = nullptr, o_cceT = nullptr;
static id s_cce(id self, SEL _cmd) {
    id e = ((id (*)(id, SEL))o_cce)(self, _cmd);
    if (e) hook_compute_encoder(object_getClass(e));
    return e;
}

static id s_cceD(id self, SEL _cmd, id desc) {
    id e = ((id (*)(id, SEL, id))o_cceD)(self, _cmd, desc);
    if (e) hook_compute_encoder(object_getClass(e));
    return e;
}

static id s_cceT(id self, SEL _cmd, NSUInteger dt) {
    id e = ((id (*)(id, SEL, NSUInteger))o_cceT)(self, _cmd, dt);
    if (e) hook_compute_encoder(object_getClass(e));
    return e;
}

static void hook_cmdbuffer(Class c) {
    if (!c || !mark_class(c)) return;
    swz(&o_renderEnc, c, @selector(renderCommandEncoderWithDescriptor:), (IMP)s_renderEnc);
    swz(&o_cce, c, @selector(computeCommandEncoder), (IMP)s_cce);
    swz(&o_cceD, c, @selector(computeCommandEncoderWithDescriptor:), (IMP)s_cceD);
    swz(&o_cceT, c, @selector(computeCommandEncoderWithDispatchType:), (IMP)s_cceT);
    swz(&o_present, c, @selector(presentDrawable:), (IMP)s_present);
    swz(&o_present2, c, @selector(presentDrawable:afterMinimumDuration:), (IMP)s_present2);
    swz(&o_present3, c, @selector(presentDrawable:atTime:), (IMP)s_present3);

    log_line("hooked MTLCommandBuffer class: %s", class_getName(c));
}

// queue -> command buffer
static IMP o_cmdBuf = nullptr, o_cmdBufU = nullptr, o_cmdBufD = nullptr;
static id s_cmdBuf(id self, SEL _cmd) {
    id cb = ((id (*)(id, SEL))o_cmdBuf)(self, _cmd);
    if (cb) hook_cmdbuffer(object_getClass(cb));
    return cb;
}

// commandBufferWithUnretainedReferences is BG3's frame command buffer. Forwarded unchanged, and the hook
// only makes sure the class is hooked.
static id s_cmdBufU(id self, SEL _cmd) {
    id cb = ((id (*)(id, SEL))o_cmdBufU)(self, _cmd);
    if (cb) hook_cmdbuffer(object_getClass(cb));
    return cb;
}

static id s_cmdBufD(id self, SEL _cmd, id desc) {
    id cb = ((id (*)(id, SEL, id))o_cmdBufD)(self, _cmd, desc);
    if (cb) hook_cmdbuffer(object_getClass(cb));
    return cb;
}

static void hook_queue(Class c) {
    if (!c || !mark_class(c)) return;
    swz(&o_cmdBuf, c, @selector(commandBuffer), (IMP)s_cmdBuf);
    swz(&o_cmdBufU, c, @selector(commandBufferWithUnretainedReferences), (IMP)s_cmdBufU);
    swz(&o_cmdBufD, c, @selector(commandBufferWithDescriptor:), (IMP)s_cmdBufD);

    log_line("hooked MTLCommandQueue class: %s", class_getName(c));
}

// device -> command queue creation
static IMP o_newQueue = nullptr, o_newQueueN = nullptr;
static id s_newQueue(id self, SEL _cmd) {
    id q = ((id (*)(id, SEL))o_newQueue)(self, _cmd);
    if (q) hook_queue(object_getClass(q));
    return q;
}

static id s_newQueueN(id self, SEL _cmd, NSUInteger n) {
    id q = ((id (*)(id, SEL, NSUInteger))o_newQueueN)(self, _cmd, n);
    if (q) hook_queue(object_getClass(q));
    return q;
}

// FSR's compute output (ord52's tonemap input) is a target-res RG11B10 write texture no binding hook
// sees, but its creation is visible, so the target-res writable RG11B10 texture is grabbed as g_fsrOut.
static void log_created_texture(id<MTLTexture> t, const char* via) {
    if (!t || g_inOwnAlloc || mod_idle()) return;
    if (t.pixelFormat != MTLPixelFormatRG11B10Float) return;

    bool write = (t.usage & MTLTextureUsageShaderWrite) != 0;

    // Target-res = larger than the render resolution and non-square (excludes square shadow maps),
    // relative to g_inW so it holds on any display and after a resolution change.
    bool targetRes = t.width != t.height && (g_inW ? t.width > g_inW : t.width >= 1280);

    // NOTE: only the NEWTEX line below is diagnostic. The grab underneath it is FUNCTIONAL, g_fsrOut is
    // what the whole native-tonemap path writes into, so it must stay outside the logging guard.
    if (g_logging) {
        NSString* sig = [NSString
            stringWithFormat:@"newtex:%s:%lux%lu:%d", via, (unsigned long)t.width, (unsigned long)t.height, write];
        if (log_first_time(sig))
            log_line("NEWTEX(%s) RG11B10 %lux%lu usage=0x%lx%s%s", via, (unsigned long)t.width, (unsigned long)t.height,
                     (unsigned long)t.usage, write ? " WRITE" : "",
                     (targetRes && write) ? "  <-- FSR-out candidate" : "");
    }

    if (targetRes && write) {
        // BG3 creates textures on its loading threads, while g_fsrOut is read by the render thread. Hand the
        // candidate over through an atomic and let the render thread adopt it (s_renderEnc).
        [t retain];
        void* prev = g_fsrOutPending.exchange((void*)t, std::memory_order_acq_rel);
        if (prev) [(id)prev release];
        mfx_label(t, "BG3MFX target: BG3's FSR-out (we write here, ord52 reads it)");

        if (!g_fsrOutLogged) {
            g_fsrOutLogged = true;
            log_line("FSR output candidate GRABBED (%s): RG11B10 %lux%lu", via, (unsigned long)t.width,
                     (unsigned long)t.height);
        }
    }
}

static IMP o_newTex = nullptr;
static id s_newTex(id self, SEL _cmd, MTLTextureDescriptor* d) {
    id t = ((id (*)(id, SEL, id))o_newTex)(self, _cmd, d);
    @autoreleasepool {
        log_created_texture(t, "device");
    }
    return t;
}

static IMP o_heapTex = nullptr;
static id s_heapTex(id self, SEL _cmd, MTLTextureDescriptor* d, NSUInteger off) {
    id t = ((id (*)(id, SEL, id, NSUInteger))o_heapTex)(self, _cmd, d, off);
    @autoreleasepool {
        log_created_texture(t, "heap");
    }
    return t;
}

static IMP o_heapTexAuto = nullptr;
static id s_heapTexAuto(id self, SEL _cmd, MTLTextureDescriptor* d) {
    id t = ((id (*)(id, SEL, id))o_heapTexAuto)(self, _cmd, d);
    @autoreleasepool {
        log_created_texture(t, "heap");
    }
    return t;
}

static void hook_heap(Class c) {
    if (!c || !mark_class(c)) return;
    swz(&o_heapTex, c, @selector(newTextureWithDescriptor:offset:), (IMP)s_heapTex);
    swz(&o_heapTexAuto, c, @selector(newTextureWithDescriptor:), (IMP)s_heapTexAuto);   // automatic placement
    log_line("hooked MTLHeap class: %s", class_getName(c));
}

static IMP o_newHeap = nullptr;
static id s_newHeap(id self, SEL _cmd, id d) {
    id h = ((id (*)(id, SEL, id))o_newHeap)(self, _cmd, d);
    @autoreleasepool {
        if (h) hook_heap(object_getClass(h));
    }
    return h;
}

// Defined further down with the mip-bias block, and used by the device hook below.
static IMP o_newSampler;
static id s_newSampler(id self, SEL _cmd, MTLSamplerDescriptor* d);

static void hook_device(id<MTLDevice> dev) {
    if (!dev) return;
    if (!g_device) g_device = dev;   // the first device is ours (scaler, allocations); a second one is not adopted
    Class c = object_getClass(dev);
    if (!mark_class(c)) return;

    @autoreleasepool {
        log_line("== BG3 MetalFX diagnostic, device hooked ==");
        log_line("device: %s (runtime class %s)", dev.name.UTF8String, class_getName(c));
        log_line("MetalFX Temporal supported: %s", [MTLFXTemporalScalerDescriptor supportsDevice:dev] ? "YES" : "NO");
    }

    swz(&o_newCompute, c, @selector(newComputePipelineStateWithFunction:error:), (IMP)s_newCompute);
    swz(&o_newComputeR, c, @selector(newComputePipelineStateWithFunction:options:reflection:error:),
        (IMP)s_newComputeR);
    swz(&o_newRender, c, @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)s_newRender);
    swz(&o_newRenderR, c, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), (IMP)s_newRenderR);
    swz(&o_newQueue, c, @selector(newCommandQueue), (IMP)s_newQueue);
    swz(&o_newQueueN, c, @selector(newCommandQueueWithMaxCommandBufferCount:), (IMP)s_newQueueN);
    swz(&o_newTex, c, @selector(newTextureWithDescriptor:), (IMP)s_newTex);
    swz(&o_newHeap, c, @selector(newHeapWithDescriptor:), (IMP)s_newHeap);
    swz(&o_newSampler, c, @selector(newSamplerStateWithDescriptor:), (IMP)s_newSampler);

    log_line("hooked MTLDevice class: %s", class_getName(c));
}

// mip bias on the material samplers
// BG3 picks mip levels for the render resolution, so at 2x the output shows half-resolution texture
// detail. The standard remedy is a sampler bias of log2(inW/outW) (-1.0 at 2x), and MTLSamplerDescriptor
// has lodBias since macOS 26. Applied only to mip-filtered anisotropic samplers (material samplers), because UI,
// LUT and shadow samplers have neither and biasing them would break them. This reaches the ordinary
// material samplers, and Granite virtual textures need vt_mip_bias instead.
static id s_newSampler(id self, SEL _cmd, MTLSamplerDescriptor* d) {
    if (!mod_idle() && d && g_mipBias != 0.0f) @autoreleasepool {
            bool mipped = d.mipFilter != MTLSamplerMipFilterNotMipmapped;
            bool aniso = d.maxAnisotropy > 1;

            if (mipped && aniso && [d respondsToSelector:@selector(setLodBias:)]) {
                // Copy first: the descriptor belongs to the caller and may be reused for other samplers.
                MTLSamplerDescriptor* c2 = [d copy];
                c2.lodBias = g_mipBias;
                g_mipBiasApplied++;
                if (g_mipBiasApplied == 1)
                    log_line("MIP BIAS: applying lodBias %+.2f to mip-filtered, anisotropic samplers "
                             "(aniso=%lu mip=%d). log2(inW/outW) at the current scale is %+.2f.",
                             g_mipBias, (unsigned long)d.maxAnisotropy, (int)d.mipFilter,
                             (g_inW && g_outW) ? log2((double)g_inW / (double)g_outW) : 0.0);

                id r = ((id (*)(id, SEL, id))o_newSampler)(self, _cmd, c2);
                [c2 release];
                return r;
            }

            g_mipBiasSkipped++;
            if (g_mipBiasSkipped == 1)
                log_line("MIP BIAS: first skipped sampler, mipFilter=%d maxAnisotropy=%lu (not a material "
                         "sampler by the filter; UI/LUT/shadow samplers must stay untouched)",
                         (int)d.mipFilter, (unsigned long)d.maxAnisotropy);
        }

    return ((id (*)(id, SEL, id))o_newSampler)(self, _cmd, d);
}
