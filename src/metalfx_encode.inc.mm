// Where the frame is handed to MetalFX, on one of the two encode_path settings: separate encodes onto
// its own command buffer on BG3's queue, event onto a second queue ordered by two shared events. Both
// go through the same readiness gate, the same exposure hint and the same encode core, and they differ only
// in WHEN that buffer runs, which is what decides whether the world on screen is a frame old.

// Everything MetalFX needs exists and matches the live render resolution. Asked by both encode paths
// BEFORE they touch a command buffer, since the event path in particular must not signal the game CB and
// then find it has nothing to encode.
static bool mfx_inputs_ready(void) {
    if (!g_scaler || !g_colorCopy || !g_depthCopy || !g_mvCopy || !g_device) return false;

    // The API wants each input at the descriptor's size and format
    if (g_colorCopy.width != g_inW || g_colorCopy.height != g_inH ||
        g_colorCopy.pixelFormat != g_scaler.colorTextureFormat)
        return false;
    if (g_depthCopy.width != g_inW || g_depthCopy.height != g_inH ||
        g_depthCopy.pixelFormat != g_scaler.depthTextureFormat)
        return false;
    if (g_mvCopy.width != g_inW || g_mvCopy.height != g_inH || g_mvCopy.pixelFormat != g_scaler.motionTextureFormat)
        return false;

    if (!g_out) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG11B10Float
                                                                                      width:g_outW
                                                                                     height:g_outH
                                                                                  mipmapped:NO];

        // ShaderRead for the composite, plus whatever MetalFX asks for its output (it writes through
        // compute, so ShaderWrite is in there). g_scaler exists at this point.
        td.usage = mfx_usage(3, MTLTextureUsageShaderRead);
        td.storageMode = MTLStorageModePrivate;
        g_inOwnAlloc = true;
        g_out = [g_device newTextureWithDescriptor:td];   // +1 owned (HDR)
        mfx_label(g_out, "BG3MFX out: MetalFX result (target res)");
        g_inOwnAlloc = false;
        if (!g_out) return false;
    }

    return true;
}

static void encode_metalfx_on(id<MTLCommandBuffer> encCB, float jx, float jy);
// Separate path: our CB is committed on BG3's queue before the game's frame CB, so the GPU runs it
// between frame N-1 and N and MetalFX reads the previous snapshot, and the jitter lags by one frame to match
// (g_jxLive). It is the default because Metal overlaps it with the next frame's early passes, hiding its
// GPU time. The event path is event_encode().
static bool encode_metalfx(id gameCB) {
    if (!mfx_inputs_ready()) return false;

    double t0 = now_ns();
    id<MTLCommandBuffer> encCB = [[gameCB commandQueue] commandBuffer];   // can block at 64 in flight
    double ms = (now_ns() - t0) / 1e6;
    if (ms > 50.0 && slow_alloc_reportable())
        log_line_always("SLOW: MetalFX commandBuffer alloc took %.0f ms (queue saturated?)", ms);
    if (!encCB) return false;

    mfx_label(encCB, "BG3MFX: MetalFX encode");
    encode_metalfx_on(encCB, g_jxLive, g_jyLive);
    [encCB commit];
    return true;
}

// Constant exposure for the scaler (config: mfx_exposure_value, 0 = none). MetalFX clamps its history in an
// exposure-dependent way, so un-normalised linear HDR without a hint shifts chromaticity across channels. A
// constant gives the right space without the per-frame wander that auto-exposure would feed the accumulator.
// Per the API, the red channel of texel (0,0) multiplies the input.
static void mfx_apply_exposure(void) {
    static id<MTLTexture> expTex = nil;
    static float wrote = -1.0f;
    float v = g_mfxExposureValue;
    if (v <= 0.0f) {
        if (g_expTexApplied) {
            [g_scaler setExposureTexture:nil];
            g_expTexApplied = false;
        }
        return;
    }

    if (!expTex) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float
                                                                                      width:1
                                                                                     height:1
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        g_inOwnAlloc = true;
        expTex = [g_device newTextureWithDescriptor:td];
        g_inOwnAlloc = false;
        if (!expTex) return;
    }

    if (wrote != v) {
        _Float16 h = (_Float16)v;
        [expTex replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&h bytesPerRow:2];
        wrote = v;
        log_line("MFX EXPOSURE TEXTURE: constant %.4f written to a 1x1 R16Float", v);
    }

    [g_scaler setExposureTexture:expTex];
    g_expTexApplied = true;
}

// The encode core, shared by both paths: set the scaler's per-frame properties, encode it onto
// `encCB`, attach the instruments and the in-flight accounting. jx/jy are the projection jitter in input
// pixels for the colour that g_colorCopy holds at the time encCB EXECUTES, which frame that is, is the
// caller's to decide, and that is the whole difference between the two paths. Does not commit.
static void encode_metalfx_on(id<MTLCommandBuffer> encCB, float jx, float jy) {
    if (g_mfxInputMode == 1) {
        jx = 0.0f;
        jy = 0.0f;
    }   // post-TAA: BG3 already resolved it

    g_jxFed = jx;
    g_jyFed = -jy;   // what the log must report

    // BG3 always jitters its camera, so an offset that stays exactly zero means we lost it on the way
    // here rather than that there is none, and silent zero-jitter looks exactly like "MetalFX just
    // reconstructs badly".
    {
        static int zeroRun = 0;
        static bool warned = false;
        if (jx == 0.0f && jy == 0.0f && g_mfxInputMode != 1) {
            if (++zeroRun == 120 && !warned) {
                warned = true;
                log_line_always("WARNING: jitter fed to MetalFX has been exactly (0,0) for 120 frames. BG3 always "
                                "jitters, so this is a bug on our side, the reconstruction is running blind.");
            }
        } else zeroRun = 0;
    }

    [g_scaler setColorTexture:g_colorCopy];
    [g_scaler setDepthTexture:g_depthCopy];
    [g_scaler setMotionTexture:g_mvCopy];
    [g_scaler setOutputTexture:g_out];
    mfx_apply_exposure();

    [g_scaler setJitterOffsetX:jx];
    // Framebuffer-Y flip: the jitter comes from the projection matrix (clip space, Y up), whereas MetalFX wants
    // it in the colour texture's pixel space (Y down), the same space its motion vectors live in. A
    // wrong sign shakes the whole image, with an amplitude that grows with the upscale ratio.
    [g_scaler setJitterOffsetY:-jy];

    // UNITS: BG3's velocity is already in render pixels, MetalFX's unit, so the scale is only the
    // direction flip (-1). From VelocityBufferCamera_PS (Core.metallib):
    //     cur  = position.xy + (curJit.x, -curJit.y)        // [[position]], pixels
    //     prev = fma(prevPos, (g_RTWidth, g_RTHeight), ...) // UV * RT size, pixels
    //     return cur - prev
    [g_scaler setMotionVectorScaleX:g_mvScaleX];
    [g_scaler setMotionVectorScaleY:g_mvScaleY];
    [g_scaler setDepthReversed:kDepthReversed];

    // Diagnostic: force a history reset on a fixed cadence so the convergence probe has "camera stopped"
    // events to bin. The picture softens on each reset, so it is a probe, not a setting.
    {
        int period = g_mfxResetPeriod;   // read once: the poll thread may write it between the test and the modulo
        if (period > 0 && (g_resetCtr++ % (uint64_t)period) == 0) g_reset = YES;
    }

    [g_scaler setReset:g_reset];
    g_reset = NO;
    [g_scaler setInputContentWidth:g_inW];
    [g_scaler setInputContentHeight:g_inH];
    [g_scaler encodeToCommandBuffer:encCB];

    if (!g_encLogged) {
        [encCB addCompletedHandler:^(id<MTLCommandBuffer> c) {
            log_line("MFX completion: error=%s", c.error ? c.error.localizedDescription.UTF8String : "none");
        }];
    }

    // In-flight accounting (an MFX STATS instrument). Release at SCHEDULED: the command buffer is encoded
    // and MetalFX is done reading the scaler's properties, whereas COMPLETED would be a whole frame later.
    g_encodeCount++;
    if (!g_logging) return;   // the in-flight count and encode->scheduled latency feed MFX STATS only

    int32_t nowIn = __atomic_add_fetch(&g_mfxInFlight, 1, __ATOMIC_RELAXED);
    if (nowIn > g_inflightWinPeak) g_inflightWinPeak = nowIn;
    double encNs = now_ns();
    [encCB addScheduledHandler:^(id<MTLCommandBuffer> c) {
        (void)c;
        __atomic_fetch_sub(&g_mfxInFlight, 1, __ATOMIC_RELAXED);
        // NOT MetalFX's encode time: encode -> scheduled measures how far ahead of the GPU the CPU
        // runs (a few ms). With normal pipelining the in-flight count is >= 1 almost always, so a
        // valve keyed on it would sit permanently at its trip point.
        g_encLatSum += (now_ns() - encNs) / 1e6;
        g_encLatN++;
    }];
}

// encode_path = event: second queue + shared events
// Removes the separate path's one-frame latency: our CB runs on a second queue ordered against the game
// frame by two events, so it reads this frame's snapshot and overlaps BG3's render-res post passes.
//
//   queue A (BG3):  ... TAA | snapshot blit | SIGNAL toUs=n | bloom ... ord51 | WAIT toGame>=n | composite | ord52 ...
//   queue B (ours):                          WAIT toUs>=n | MetalFX encode | SIGNAL toGame=n
//
// The ordering stays acyclic even when BG3 spreads a frame over several command buffers. The one failure
// mode: a GPU wait has no timeout, so if the game CB carrying the signal is never committed both queues
// wait forever. That is why these are shared events (CPU-signallable): composite_watch breaks the stall.
// TODO: never run together with frame_interp, and fi_motion_lag() takes the frame's own chain on this path.
static bool event_objects_ready(void) {
    if (g_evQueue && g_evToUs && g_evToGame) return true;
    if (!g_device) return false;

    id<MTLCommandQueue> q = [g_device newCommandQueue];   // +1, kept for the process lifetime
    id<MTLSharedEvent> a = [g_device newSharedEvent], b = [g_device newSharedEvent];
    if (!q || !a || !b) {
        [q release];
        [a release];
        [b release];
        g_evFailed = true;
        log_line_always("EVENT PATH: could not create the second queue / shared events, falling back to "
                        "encode_path = separate for this run");
        return false;
    }

    mfx_label(q, "BG3MFX queue B (MetalFX)");
    mfx_label(a, "BG3MFX event: snapshot written (A->B)");
    mfx_label(b, "BG3MFX event: MetalFX output written (B->A)");

    g_evToUs = a;
    g_evToGame = b;
    g_evQueue = q;   // last: composite_watch on the poll thread treats a non-nil queue as "armed"

    log_line("EVENT PATH active: MetalFX encodes on a second queue, ordered by two shared events. "
             "Same-frame jitter, no retained frame CB.");
    return true;
}

// Called at the encoder boundary right after snapshot_pre_taa has encoded this chain's snapshot blit on
// the game CB, the ONLY place the three inputs are guaranteed written before anything else touches the
// pool textures. No encoder is open on gameCB here, so the event signal is legal.
static void event_encode(id gameCB) {
    if (effective_encode_path() != ENC_EVENT || g_mode != 0 || g_bypassComposite)
        return;                                  // bypass: nothing would consume the encode
    if (g_evPendingChain == g_chainId) return;   // one encode per chain, like g_compChain
    if (!mfx_inputs_ready()) return;
    // No destination for this chain means no composite, so do not encode an image nobody will read, and
    // mfx_active() then leaves BG3's own FSR in charge of this chain (same rule as the separate path).
    if (!g_fsrOut || g_fsrOut.width != g_outW || g_fsrOut.height != g_outH) return;
    if (!event_objects_ready()) return;

    uint64_t seq = ++g_evSeq;
    [gameCB encodeSignalEvent:g_evToUs value:seq];

    double t0 = now_ns();
    id<MTLCommandBuffer> cb = [g_evQueue commandBuffer];
    double ms = (now_ns() - t0) / 1e6;
    if (ms > 50.0 && slow_alloc_reportable())
        log_line_always("SLOW: queue-B commandBuffer alloc took %.0f ms (queue saturated?)", ms);
    if (!cb) return;   // the signal above then has no waiter: harmless

    mfx_label(cb, "BG3MFX: MetalFX encode (queue B)");
    [cb encodeWaitForEvent:g_evToUs value:seq];

    // The jitter of the colour just snapshotted: g_jxPending was latched from g_jx inside
    // snapshot_pre_taa a moment ago. Same frame by construction, no delay bookkeeping on this path.
    encode_metalfx_on(cb, g_jxPending, g_jyPending);
    [cb encodeSignalEvent:g_evToGame value:seq];
    [cb commit];

    g_evPendingSeq = seq;
    g_evPendingChain = g_chainId;
    g_evEncodes++;
}
