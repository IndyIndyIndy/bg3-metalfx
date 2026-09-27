// Applies the config variables from the parsed config file. apply_config copies them over and
// settles the few keys that depend on each other, and the thread behind it re-reads the file twice a
// second, taking the watchdogs and the capture hotkey along on the same tick.

static void apply_config(const Config& c) {
    g_mode = c.mode;
    g_logging = c.logging;
    g_logPasses = c.log_passes && c.logging;   // subordinate: no log, no pass logging
    g_mvScaleX = c.mv_scale_x;
    g_mvScaleY = c.mv_scale_y;
    g_sharpness = c.sharpness;
    g_gpuCapture = c.gpu_capture;

    // Decided at launch: the presenter layout (frame_interp implies the virtual swapchain and two images
    // per frame, virtual_swapchain stays as a separate key for tests, fi_ui fixes the interpolator's colour
    // format) and the encode path (a switch mid-chain would encode the scaler on both queues at once).
    // frame_cap and fi_motion_key stay live.
    static bool first = true;
    if (first) {
        first = false;
        g_encodePath = c.encode_path;
        g_vsc = c.virtual_swapchain || c.frame_interp;
        g_fiUi = c.fi_ui && c.frame_interp;
        g_fi = c.frame_interp;
    }

    g_frameCap = c.frame_cap;
    if (g_fiMotionKey != c.fi_motion_key)
        log_line_always("CONFIG: fi_motion_key -> %s", c.fi_motion_key == 2 ? "auto"
                                                       : c.fi_motion_key    ? "current"
                                                                            : "previous");
    g_fiMotionKey = c.fi_motion_key;

    g_captureFrames = c.gpu_capture_frames;
    g_mfxInputMode = c.mfx_input;
    g_bypassComposite = c.bypass_composite;

    g_gradingHarvest = c.grading_harvest;
    g_gradingApply = c.grading_apply;
    g_gradingBloom = c.grading_bloom;
    g_skipFsrTonemap = c.skip_fsr_tonemap;
    g_mfxResetPeriod = c.mfx_reset_period;

    g_mipBias = c.mip_bias;
    g_vtMipBias = c.vt_mip_bias;
    g_vtMipAuto = c.vt_mip_bias_auto;
    g_mfxExposureValue = c.mfx_exposure_value;
    g_chGainR = c.chroma_gain_r;
    g_chGainG = c.chroma_gain_g;
    g_chGainB = c.chroma_gain_b;
    g_chSat = c.chroma_saturation;
}

static void run_config_poll(void) {
    [NSThread detachNewThreadWithBlock:^{
        while (true) {
            if (config_file_changed()) {
                Config c = load_config();
                apply_config(c);
            }

            // A typo in config.toml behaves exactly like a default, with no hint. Name it, once per
            // distinct set, and unconditionally, because the person who mistyped a key is not running
            // with logging = true.
            {
                static char lastUnknown[512] = {0};
                if (g_cfgUnknown[0] && strcmp(g_cfgUnknown, lastUnknown) != 0) {
                    strlcpy(lastUnknown, g_cfgUnknown, sizeof(lastUnknown));
                    log_line_always("CONFIG: unrecognised or out-of-range key(s) in config.toml, IGNORED: %s  "
                                    "(a mistyped key is silently the default, check the spelling "
                                    "against the comments in the generated file)",
                                    g_cfgUnknown);
                } else if (!g_cfgUnknown[0]) lastUnknown[0] = 0;
            }

            hang_watch();
            composite_watch();
            poll_capture_hotkey();

            [NSThread sleepForTimeInterval:0.5];
        }
    }];
}
