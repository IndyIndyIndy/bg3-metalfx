// MetalFX works through a scaler object that is built once for a fixed input and output size, so this
// file waits until the game's three inputs are known and then builds it. It also keeps the device, the
// two resolutions and the textures the upscale reads and writes, because everything else needs them.

// MTLFXTemporalScaler build
static id<MTLDevice> g_device = nil;
static id<MTLTexture> g_color = nil, g_depth = nil, g_mv = nil;

// MetalFX consumes the pre-TAA jittered scene colour (what PPTAA_PS reads). the resolved post-TAA colour
// has no sub-pixel detail left to reconstruct. We track the two most-recent render-res RG11B10
// single-attachment passes and, when PPTAA_PS binds, freeze the previous one into g_color.
static id<MTLTexture> g_rrCur = nil, g_rrPrev = nil;   // transient, same-frame only (no retain)
static id<MTLFXTemporalScaler> g_scaler = nil;         // MetalFX temporal scaler
static NSUInteger g_inW = 0, g_inH = 0, g_outW = 0, g_outH = 0;

// Dimensions the live scaler + persistent copies were built for, and a mismatch means the resolution
// changed and everything dimension-bound has to be rebuilt (see maybe_handle_resize).
static NSUInteger g_builtInW = 0, g_builtInH = 0, g_builtOutW = 0, g_builtOutH = 0;
static NSUInteger g_candInW = 0, g_candInH = 0, g_candOutW = 0,
                  g_candOutH = 0;   // last sizes seen (any view); see capture_mfx_inputs
static int g_buildTries = 0;

// True whenever the mod is NOT the active upscaler (mode = fsr / none): passthrough must be a clean
// baseline, so everything optional checks this and forwards. The swizzles stay installed.
static inline bool mod_idle(void);
static bool mfx_active(void);
static void dl_start(CAMetalLayer* layer);   // display-link presenter, defined with the presenter core
static void mfx_check_copy_usage(void);

// config: mfx_input. 0 = pre-TAA, 1 = post-TAA. Post-TAA colour is already resolved and carries no jitter,
// so encode_metalfx_on feeds a zero offset in that mode.
// TODO: maybe add a metalfx spatial scaler as a third mode, since post_taa already hands it the only input it needs.
static volatile int g_mfxInputMode = 0;

static void cache_tex(id<MTLTexture>* slot, id<MTLTexture> t) {   // MRC: keep a ref while cached
    if (*slot == t) return;

    [t retain];
    [*slot release];
    *slot = t;
}

static void try_build_scaler(void) {
    if (mod_idle() || g_scaler || !g_device || !g_color || !g_depth || !g_mv || g_inW == 0 || g_outW == 0) return;
    if (g_buildTries++ > 30) return;
    if (![MTLFXTemporalScalerDescriptor supportsDevice:g_device]) {
        log_line("MetalFX: device unsupported");
        return;
    }

    MTLFXTemporalScalerDescriptor* d = [MTLFXTemporalScalerDescriptor new];
    d.colorTextureFormat = g_color.pixelFormat;
    d.depthTextureFormat = g_depth.pixelFormat;
    d.motionTextureFormat = g_mv.pixelFormat;
    d.outputTextureFormat =
        MTLPixelFormatRG11B10Float;   // HDR output; our LUT apply tonemaps it into the RGB10A2 scene
    d.inputWidth = g_inW;
    d.inputHeight = g_inH;
    d.outputWidth = g_outW;
    d.outputHeight = g_outH;

    // The auto-exposure heuristic is left off: our input is linear HDR from before BG3's tonemap, and a
    // wandering exposure scale reaches the temporal accumulator as a differently-lit frame every time.
    id<MTLFXTemporalScaler> scaler = [d newTemporalScalerWithDevice:g_device];
    if (scaler) {
        g_scaler = scaler;   // owned (+1)
        // Remember what it was built for, and maybe_handle_resize() compares against these
        g_builtInW = g_inW;
        g_builtInH = g_inH;
        g_builtOutW = g_outW;
        g_builtOutH = g_outH;

        log_line("MetalFX scaler BUILT OK: in %lux%lu -> out %lux%lu  color=%s depth=%s mv=%s out=%s",
                 (unsigned long)g_inW, (unsigned long)g_inH, (unsigned long)g_outW, (unsigned long)g_outH,
                 pfName(g_color.pixelFormat) ?: "?", pfName(g_depth.pixelFormat) ?: "?",
                 pfName(g_mv.pixelFormat) ?: "?", pfName(d.outputTextureFormat) ?: "?");

        // Apple's guidance: Halton(2,3) with about 8 x ratio^2 phases (32 at 2x). Logged for reference.
        float ratio = (float)g_outW / (float)g_inW;
        log_line("MetalFX scale %.2fx/axis (%.0f%% render scale). Device supports %.2f-%.2fx; Apple advises "
                 "not exceeding 2x. Jitter phases wanted at this ratio: ~%d (Halton 2,3).",
                 ratio, 100.0f / ratio, [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:g_device],
                 [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:g_device],
                 (int)(8.0f * ratio * ratio + 0.5f));

        mfx_check_copy_usage();   // copies made before this build may lack a flag the scaler requests
    } else if (g_buildTries <= 3) {
        log_line("MetalFX scaler build FAILED (nil): color=%s depth=%s mv=%s in %lux%lu out %lux%lu (try %d)",
                 pfName(g_color.pixelFormat) ?: "?", pfName(g_depth.pixelFormat) ?: "?",
                 pfName(g_mv.pixelFormat) ?: "?", (unsigned long)g_inW, (unsigned long)g_inH, (unsigned long)g_outW,
                 (unsigned long)g_outH, g_buildTries);
    }

    [d release];
}

// composite targets: MetalFX output and the post-FSR scene texture
static id<MTLTexture> g_out = nil, g_scene = nil;   // g_out = MetalFX HDR output; g_scene = post-FSR RGB10A2 scene

// The pre-TAA colour is a transient pool texture. On the separate path our CB runs before the game CB, so
// we blit it into a persistent copy on the game CB right after TAA reads it, and MetalFX reads the copy (one
// frame stale, sharp). Depth and motion have the same volatility.
static id<MTLTexture> g_colorCopy = nil;                   // persistent private copy of the pre-TAA color
static id<MTLTexture> g_depthCopy = nil, g_mvCopy = nil;   // ditto for depth + motion vectors (same volatility)
static id<MTLTexture> g_fsrOut = nil;   // BG3's FSR-EASU compute output (target-res HDR) = ord52's input
static bool g_fsrOutLogged = false;
static id<MTLTexture> g_snapSrc = nil;         // transient: the pre-TAA texture to snapshot this frame
static volatile bool g_needSnapshot = false;   // set when PPTAA_PS is bound; consumed at next encoder
static int g_snapCount = 0, g_compCount = 0;   // DIAG: snapshots / composites executed (lockstep check)
static int g_gradedCount = 0;                  // composites that went through the harvested LUT
