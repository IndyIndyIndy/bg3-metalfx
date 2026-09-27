// Everything that observes the mod instead of doing its work.

static double now_ns(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom;
}

// Stall detector (hang_watch) runs on the config-poll thread, so it keeps ticking if the render thread
// deadlocks. MARK records where the render thread last was, with one relaxed store plus one increment at
// the coarse hooks and never per bind, which tells "stuck inside a hook" from "GPU queue backed up".
static const char* volatile g_where = "startup";
static volatile uint64_t g_whereSeq = 0;
#define MARK(x)                                                                                                        \
    do {                                                                                                               \
        g_where = (x);                                                                                                 \
        __atomic_fetch_add(&g_whereSeq, 1u, __ATOMIC_RELAXED);                                                         \
    } while (0)

static void hang_watch(void) {
    static int lastFrame = -1, stalledPolls = 0, reported = 0;
    if (!g_scaler || g_mode != 0 || !g_logging) {
        lastFrame = -1;
        stalledPolls = 0;
        reported = 0;
        return;
    }

    int f = g_bframe;
    if (f != lastFrame) {
        lastFrame = f;
        stalledPolls = 0;
        reported = 0;
        return;
    }

    // Same frame as 0.5 s ago. Loading screens stall for a while too, so report only after 3 s, and then
    // repeat slowly so the log shows how long it lasted.
    if (++stalledPolls < 6) return;
    if (reported && (stalledPolls % 20) != 0) return;
    reported = 1;

    static uint64_t lastSeq = 0;
    uint64_t seq = __atomic_load_n(&g_whereSeq, __ATOMIC_RELAXED);
    uint64_t adv = seq - lastSeq;
    lastSeq = seq;

    log_line_always("HANG WATCH: no present for %.1fs, frame=%d comps=%d chain=%u/%u rebuilding=%d "
                    "harvestBusy=%d  last hook='%s', %llu hook entries since the previous poll => %s",
                    stalledPolls * 0.5, f, g_compCount, g_compChain, g_chainId, g_gradRebuilding ? 1 : 0,
                    g_pendingGradOut ? 1 : 0, g_where ? g_where : "?", adv,
                    adv == 0 ? "STUCK inside that hook (or the thread is blocked below it)"
                             : "thread is RUNNING, it is encoding but not presenting, i.e. the stall is "
                               "downstream (GPU queue / driver), not in our code");
}

// composite watchdog
// presents advance at a normal rate but every frame carries the same stale image because our composite stopped.
static void composite_watch(void) {
    static int lastComp = -1;
    static uint32_t lastPresent = 0, lastChain = 0;
    static int stalled = 0, reported = 0;
    if (g_mode != 0 || !g_scaler) {
        lastComp = -1;
        lastPresent = 0;
        stalled = 0;
        reported = 0;
        return;
    }

    int c = g_compCount;
    uint32_t p = g_presentCount, ch = g_chainId;
    bool presentsMoving = (p != lastPresent), compsMoving = (c != lastComp), chainMoving = (ch != lastChain);
    lastPresent = p;
    lastComp = c;
    lastChain = ch;
    if (lastComp < 0 || !presentsMoving || compsMoving) {
        stalled = 0;
        reported = 0;
        return;
    }

    // Presenting, but not compositing. Loading screens can do this for a while (no world to upscale), so
    // report only after 3 s, the same threshold hang_watch uses, and then repeat slowly so the log shows
    // how long it lasted.
    if (++stalled < 6) return;

    // Escape hatch for encode_path = event: a GPU wait has no timeout, so if the game CB carrying the
    // signal was never committed both queues wait forever. Signal both events from the CPU (one stale
    // composite) and force the path back to separate for the rest of the run. Only fires while a wait is
    // genuinely outstanding.
    if (effective_encode_path() == ENC_EVENT && g_evQueue && g_evPendingChain != g_compChain &&
        g_evToGame.signaledValue < g_evPendingSeq) {
        uint64_t seq = g_evPendingSeq;
        g_evFailed = true;   // first, so no new event encode is issued meanwhile
        g_evToUs.signaledValue = seq;
        g_evToGame.signaledValue = seq;
        g_evBreaks++;
        log_line_always("EVENT WATCH: broke a stalled wait after %.1f s (seq %llu, toGame was %llu), "
                        "the game CB carrying the signal was never committed. encode_path falls back to "
                        "separate for the rest of this run; the next frame is one stale composite.",
                        stalled * 0.5, (unsigned long long)seq, (unsigned long long)g_evToGame.signaledValue);
    }

    // Menus and loading screens present without rendering a world (the chain stands still): nothing to
    // composite there, so no alarm. The alarm is world frames rendered and not composited.
    if (!chainMoving) return;
    if (reported && (stalled % 20) != 0) return;
    reported = 1;

    log_line_always("COMPOSITE WATCH: presents are advancing but composites have stood still for "
                    "%.1f s, presents=%u comps=%d snaps=%d chain=%u (composited %u) rebuilding=%d "
                    "measuredCells=%d fsrOut=%p out=%p => the app is ALIVE and presenting, and every "
                    "frame carries the same image. hang_watch cannot see this: there is no stall. "
                    "Look at why upscale_native bailed out, not at the GPU queue.",
                    stalled * 0.5, p, g_compCount, g_snapCount, g_chainId, g_compChain, g_gradRebuilding ? 1 : 0,
                    g_gradMeasured, (void*)g_fsrOut, (void*)g_out);
}

// Window delta of a growing counter: returns cur - prev and remembers cur for the next window
static inline uint64_t win(uint64_t& prev, uint64_t cur) {
    uint64_t d = cur - prev;
    prev = cur;
    return d;
}

static inline double winf(double& prev, double cur) {
    double d = cur - prev;
    prev = cur;
    return d;
}

// The one line, written even with logging = false, that says whether MetalFX, the grading and the
// interpolation are doing their work. Written on the first window with world frames, and after that only
// when the verdict changes.
static void run_status(uint32_t presents) {   // presents: g_presentCount, counted by the present hooks
    static uint32_t pChain = 0;
    static int pComp = 0, pGraded = 0;
    static uint64_t pFi = 0;
    static char last[128] = "";
    if (!g_scaler) {   // no world frame recognised yet: after a minute of presents that is the fingerprint-lost case
        static bool said = false;
        if (!said && g_mode == 0 && presents >= 3000 && g_chainId == 0) {
            said = true;
            log_line_always(
                "STATUS: MetalFX INACTIVE, no world frame recognised in %u presents (TAA pass not seen: TAA off, or BG3 changed its shaders); BG3's own upscaler renders",
                presents);
        }
        return;
    }

    uint32_t dChain = g_chainId - pChain;
    int dComp = g_compCount - pComp, dGraded = g_gradedCount - pGraded;
    uint64_t dFi = g_fiEncoded - pFi;
    pChain = g_chainId;
    pComp = g_compCount;
    pGraded = g_gradedCount;
    pFi = g_fiEncoded;
    if (dChain < 60) return;   // menu or loading screen: no world frames to judge

    const char* mfx = dComp * 10 >= (int)dChain * 9 ? "active" : (dComp ? "PARTIAL" : "INACTIVE (BG3's FSR renders)");
    const char* grad = !g_gradingApply
                           ? "off (config)"
                           : (dGraded * 10 >= dComp * 9 ? "active" : (dGraded ? "partial" : "not learned yet"));
    const char* fi = !g_fi ? "off" : (dFi ? "active" : "INACTIVE");

    char cur[128];
    snprintf(cur, sizeof cur, "MetalFX %s, grading %s, frame interpolation %s", mfx, grad, fi);
    if (!strcmp(cur, last)) return;
    strlcpy(last, cur, sizeof last);

    log_line_always("STATUS: %s   [window: chains=%u composites=%d graded=%d interpolated=%llu]", cur, dChain, dComp,
                    dGraded, (unsigned long long)dFi);
}

static void mfx_report_stats(void) {
    static uint64_t pChain = 0, pComp = 0, pEnc = 0;
    double lat = g_encLatN ? (g_encLatSum / g_encLatN) : 0.0;
    log_line("MFX STATS [last %llu chains]: composites=%llu encodes=%llu | encode->scheduled avg=%.2f ms (a collapse "
             "to ~0.2 ms means the GPU dropped our submissions) | inflight peak %d   [total: chains=%u]",
             (unsigned long long)win(pChain, g_chainId), (unsigned long long)win(pComp, (uint64_t)g_compCount),
             (unsigned long long)win(pEnc, (uint64_t)g_encodeCount), lat, g_inflightWinPeak, g_chainId);

    // Event path: encodes must equal waits (every chain encoded on queue B got its composite ordered
    // behind it), skipped waits should be ~0, and breaks MUST be 0, one break means the CPU-side fallback
    // fired and the rest of the run is on the separate path, whatever the config says.
    if (g_evEncodes || g_evWaits || g_evWaitsSkipped || g_evBreaks || effective_encode_path() == ENC_EVENT) {
        static uint64_t pE = 0, pW = 0, pS = 0, pB = 0;
        log_line("EVENT PATH [last window]: encodes=%llu waits=%llu waits-skipped=%llu CPU-breaks=%llu  "
                 "toUs=%llu toGame=%llu pendingSeq=%llu%s   [total: encodes=%d breaks=%d]",
                 (unsigned long long)win(pE, (uint64_t)g_evEncodes), (unsigned long long)win(pW, (uint64_t)g_evWaits),
                 (unsigned long long)win(pS, (uint64_t)g_evWaitsSkipped),
                 (unsigned long long)win(pB, (uint64_t)g_evBreaks),
                 (unsigned long long)(g_evToUs ? g_evToUs.signaledValue : 0),
                 (unsigned long long)(g_evToGame ? g_evToGame.signaledValue : 0), (unsigned long long)g_evPendingSeq,
                 g_evFailed ? "   ** FALLEN BACK TO separate **" : "", g_evEncodes, g_evBreaks);
    }

    if (g_vtMipBias != 0.0f || g_vtMipAuto) {
        // The rescale counter grows continuously: BG3 rewrites these entries all the time (the table is a
        // RING buffer) and each rewrite earns exactly one rescale from BG3's fresh value, which the
        // wrote[]/haveWrote[] guard makes sound. Growth is expected, and the per-window rate says how often
        // we write into a buffer the engine is actively churning.
        log_line("VT MIP BIAS: %+.2f%s | in-place rescales: %d total, %d in this window over %d "
                 "signature-held entries",
                 (g_vtMipAuto && g_inW && g_outW) ? log2f((float)g_inW / (float)g_outW) : g_vtMipBias,
                 g_vtMipAuto ? " (auto)" : "", g_vtPatched, g_vtPatched - g_vtPatchedPrev, g_vtHeld);
        g_vtPatchedPrev = g_vtPatched;
    }

    if (g_mipBias != 0.0f)
        log_line("MIP BIAS: lodBias %+.2f applied to %d samplers, %d skipped by the filter "
                 "(mip-filtered AND anisotropic = material). applied == 0 means the filter is wrong, "
                 "not the API.",
                 g_mipBias, g_mipBiasApplied, g_mipBiasSkipped);

    g_inflightWinPeak = 0;
    g_encLatSum = 0.0;
    g_encLatN = 0;
}

// Rate limit for the three 'SLOW: ... commandBuffer alloc' lines (first 5, then every 100th).
static bool slow_alloc_reportable(void) {
    static int n = 0;
    n++;
    return n <= 5 || n % 100 == 0;
}

// CGEventSourceKeyState reads the live key state wihtout an event tap, so it needs no accessibility
// permission and cannot swallow the game's input. Polled on the config thread, so hold the combo briefly.
// 0x3B = Control, 0x38 = Shift, 0x08 = C   (Carbon virtual key codes)
static void poll_capture_hotkey(void) {
    static bool wasDown = false;
    if (!g_gpuCapture) {
        wasDown = false;
        return;
    }

    bool down = CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, 0x3B) &&
                CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, 0x38) &&
                CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, 0x08);
    if (down && !wasDown) {   // edge, so holding it does not queue a dozen captures
        g_captureRequested = true;
        log_line("GPU capture: hotkey pressed, capturing the next %d frames", g_captureFrames);
    }
    wasDown = down;
}

// GPU frame capture over gpu_capture_frames presents, saved as a .gputrace for Xcode. Armed by gpu_capture,
// triggered by a hotkey (poll_capture_hotkey).
static int g_captureHeld = 0;
static void maybe_gpu_capture(void) {
    static int state = 0;   // 0 idle, 1 capturing, 2 done
    if (!g_device) return;
    if (state == 2 && !g_captureRequested) return;   // done; a new press re-arms
    if (state == 2) state = 0;

    if (state == 0 && g_gpuCapture && g_captureRequested) {
        g_captureRequested = false;
        @autoreleasepool {
            MTLCaptureManager* cm = [MTLCaptureManager sharedCaptureManager];
            if (![cm supportsDestination:MTLCaptureDestinationGPUTraceDocument]) {
                log_line("GPU capture: GPUTraceDocument unsupported (MTL_CAPTURE_ENABLED not honored?)");
                state = 2;
                return;
            }

            const char* home = getenv("HOME");
            static int nth = 0;
            nth++;
            NSString* path =
                (nth == 1)
                    ? [NSString stringWithFormat:@"%s/Desktop/BG3_capture.gputrace", home ? home : "/tmp"]
                    : [NSString stringWithFormat:@"%s/Desktop/BG3_capture-%d.gputrace", home ? home : "/tmp", nth];
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

            MTLCaptureDescriptor* d = [[MTLCaptureDescriptor alloc] init];
            d.captureObject = g_device;
            d.destination = MTLCaptureDestinationGPUTraceDocument;
            d.outputURL = [NSURL fileURLWithPath:path];

            NSError* err = nil;
            if ([cm startCaptureWithDescriptor:d error:&err]) {
                state = 1;
                log_line("GPU capture STARTED -> %s", path.UTF8String);
            } else {
                log_line("GPU capture start FAILED: %s", err ? err.localizedDescription.UTF8String : "?");
                state = 2;
            }
            [d release];
        }
    } else if (state == 1) {
        // Temporal artefacts are differences BETWEEN frames, so the capture stays open for several
        // presents and Xcode can step through them. Logged per present, so how far the capture reached
        // is a fact in the log, whereas Xcode's metadata frame count is not a reliable check.
        int held = ++g_captureHeld;
        log_line("GPU capture: present %d of %d inside the capture", held, g_captureFrames);
        if (held < g_captureFrames) return;
        g_captureHeld = 0;

        @autoreleasepool {
            [[MTLCaptureManager sharedCaptureManager] stopCapture];
            state = 2;
            log_line("GPU capture SAVED after %d presents, open the .gputrace on the Desktop in Xcode", held);
        }
    }
}
