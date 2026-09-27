// The variables the whole mod shares: this file only declares them, plus the few helpers that belong
// next to a declaration. The code that reads and writes them lives in the files included after it.

// Grading harvest (colour fidelity: BG3's own grading, learned as a LUT)
// ord50 (PPColorGradingApplyLUTPS) grades the render-res scene in place on its colour attachment. Its LUT
// sits in an argument buffer we cannot read, but the attachment is visible, so snapshot it just before
// ord50 and read it just after, and each pixel is then an input/output pair of the whole ord50 function.
// We fit those into our own 3D LUT and apply it to our MetalFX HDR before writing g_fsrOut, where harvest
// and apply share the PQ coordinate, so it need not match ord50's internals.
static const int GRAD_N = 33;                  // LUT edge (33^3 cells, corners align for trilinear)
static const uint32_t GRAD_MIN_COUNT = 8;      // samples a cell needs to count as measured
static const int GRAD_STRIDE = 3;              // harvest every 3rd pixel (each axis)
static const int GRAD_REBUILD_FRAMES = 30;     // pair-frames between CPU LUT rebuilds
static const int GRAD_APPLY_MIN_CELLS = 200;   // measured cells before we apply the LUT
static const float GRAD_MAX_STD = 0.02f;       // per-cell spread above which a harvest is not trusted
                                               // (gameplay measures ~0.002, a mismatched context ~0.06)
static int g_gradRejects = 0;                  // harvests discarded by the consistency gate
static volatile bool g_gradingHarvest = true, g_gradingApply = true;   // config
static id<MTLTexture> g_gradAtt = nil;                                 // ord50's color attachment (the pooled 0x302580)
static id<MTLTexture> g_gradInCand = nil;   // persistent copy: attachment content just before ord50
static void* g_gradInSrc = nullptr;         // texture the candidate was blitted from (same-frame validity)

// ord49 (PPBloomUpsampleBlurAndCombine_PS) writes the texture ord50 grades in place, so the one candidate
// snapshot we need is taken at the boundary right after ord49 (rather than after every pool-attachment
// pass).
static void* g_bloomOutTex = nullptr;                         // ord49's color attachment = ord50's in-place input
static volatile uint32_t g_bloomCombineChain = 0xFFFFFFFFu;   // chain in which ord49 was last bound
static bool g_bloomCombineSeen = false;                       // false until ord49 is identified: then blit as before
static int g_gradCandBlits = 0;                               // candidate snapshots taken (verification, see the log)
static volatile uint32_t g_gradCandChain = 0xFFFFFFFFu;       // chain whose candidate is already in hand
static volatile bool g_pendingGradOut = false;                // ord50 bound -> run the harvest at the next boundary
static id<MTLComputePipelineState> g_gradHarvestPSO = nil, g_gradApplyPSO = nil;
static id<MTLBuffer> g_gradCells = nil;               // GRAD_N^3 x GradCell (shared; CPU rebuild reads it)
static id<MTLTexture> g_gradLutTex[2] = {nil, nil};   // double-buffered harvested LUT (RGBA16F 3D)
static std::atomic<int> g_gradLutActive{-1};   // -1 = none yet, else index into g_gradLutTex; release-stored after the texture is written
static volatile bool g_gradRebuilding = false;   // set by the harvest that closes a window, cleared by the rebuild
static int g_gradPairFrames = 0, g_gradRebuilds = 0;
static int g_gradMissed = 0;              // ord50 frames without a matching candidate (should stay ~0)
static int g_gradStateWait = 0;           // boundaries spent waiting for the rebuild (watchdog)
static volatile int g_gradMeasured = 0;   // measured cells at last rebuild (apply gate)
static bool g_gradLogged = false, g_gradApplyLogged = false, g_gradApplyBloomWas = false;
static uint16_t g_gradLutData[GRAD_N * GRAD_N * GRAD_N * 4];   // rebuild scratch (halfs)

// Bloom layer: our pre-TAA feed has no bloom, but BG3 composites bloom before the grading, so the LUT
// expects a bloomed input. The layer is recoverable additively as (post-ord49) - (post-TAA), and both are in
// hand at the harvest boundary. Extracted render-res and added, bilinearly upscaled, in gradapply.
static volatile bool g_gradingBloom = true;   // config
static id<MTLTexture> g_taaCopy = nil;        // snapshot of the pre-bloom scene (see grading_boundary)
static bool g_taaCopied = false;
static id<MTLTexture> g_taaAtt = nil;   // TAA's output attachment (the pooled 0x303980)

// BG3 ping-pongs the two post-TAA pool textures in some contexts, so a single "the ord50 attachment"
// pointer falls a frame behind and the candidate blit stalls. Track the small set of textures ever seen
// in either role and blit for any member, and the exact promotion check in s_setRPS keeps it correct.
static id<MTLTexture> g_gradPool[4];
static int g_gradPoolN = 0;   // render thread only
static bool grad_pool_contains(id<MTLTexture> t) {
    for (int i = 0; i < g_gradPoolN; i++)
        if (g_gradPool[i] == t) return true;
    return false;
}

static void grad_pool_add(id<MTLTexture> t) {
    if (!t || grad_pool_contains(t)) return;
    if (g_gradPoolN == 4) {   // LRU: drop the oldest (stale after an area change)
        [g_gradPool[0] release];
        memmove(&g_gradPool[0], &g_gradPool[1], sizeof(id) * 3);
        g_gradPoolN = 3;
    }
    [t retain];
    g_gradPool[g_gradPoolN++] = t;
}

static id<MTLTexture> g_bloomTex = nil;   // extracted additive bloom layer (render-res)
static id<MTLComputePipelineState> g_bloomPSO = nil;

// Freshness tracked by order, not by frame number (the composite can run twice per frame). The chain is
// TAA capture --(g_taaFresh)--> extract --(g_bloomReady)--> apply(s):
//   g_taaFresh   set at the TAA capture, cleared by the extract, so an extraction never reuses a partner.
//   g_bloomReady set by the extract, cleared at the next TAA capture (not by the apply), so every
//                composite of the same chain gets the layer but it never survives into a layerless chain.
static volatile bool g_taaFresh = false;     // a TAA output was captured since the last extract
static volatile bool g_bloomReady = false;   // the layer belongs to the current post-chain
static int g_bloomOffFrames = 0;             // DIAG: applies that ran without a bloom layer
static int g_bloomExtracted = 0;             // DIAG: successful layer extractions
static int g_taaSeen = 0;                    // DIAG: PPTAA_PS binds (distinguishes "no TAA pass"
                                             // from "TAA ran but we failed to capture its output")
static bool g_bloomLogged = false;

// Live config (polled from config.toml).
static volatile int g_mode = 0;   // 0 = metalfx (our path); else passthrough (game's FSR)
static inline bool mod_idle(void) { return g_mode != 0; }
static volatile bool g_skipFsrTonemap = true;   // skip ord51 (see s_drawPrim)
static int g_fsrTonemapSkipped = 0;
static volatile bool g_logPasses = false;   // per-frame render-pass logging (diagnostic, costs CPU)
static volatile float g_mvScaleX = -1.0f, g_mvScaleY = -1.0f;   // MetalFX motionVectorScaleX/Y (direct pixels; -1 = negated BG3 velocity)

// config: encode_path, read at launch. ENC_SEPARATE = our own CB (MetalFX reads the previous snapshot,
// 1 frame late), ENC_EVENT = second queue + MTLSharedEvents, same-frame. See config.h.
static volatile int g_encodePath = ENC_SEPARATE;

// The event path's CPU-side fallback has fired, after a GPU wait stalled and was broken from the CPU, so
// the path is forced back to "separate" for the rest of the run. Read through effective_encode_path().
static volatile bool g_evFailed = false;
static volatile bool g_fiUi = false;   // config: fi_ui, interpolate the HUD-free world and re-compose the UI layer on both presented images (vs_emit); off = interpolate the finished frame

// fi_ui snapshots: the HUD-free world (g_scene) and the screen-space UI layer, copied into our rings for
// the presenter to compose later. Both are taken in the frame they belong to, at the encoder boundary
// before CombineUI, on BG3's own command buffer, so the snapshot completes before it is read (no
// cross-queue ordering) and no pool-texture pointer outlives its frame (a blit from freed memory at a
// level transition would abort the command buffer). The UI source is the attachment of the encoder just
// before CombineUI, and s_setFragTexN verifies it against CombineUI's "Tex" and falls back to vtex on a
// mismatch. Snapshots are keyed by the drawable's ring slot plus hand-out generation, not by chain: BG3
// repeats a chain across many presents, which would overwrite a snapshot the presenter still holds.
#define VS_RING 8
static id<MTLTexture> g_uiSnap[VS_RING], g_wSnap[VS_RING];
static std::atomic<uint32_t> g_uiSnapGen[VS_RING], g_wSnapGen[VS_RING];             // publish barrier (hand-out generation), like g_fiChain
static void* g_uiSnapSrc[VS_RING];   // pointer of the texture blitted as UI for that slot (identity check only)
static MTLPixelFormat g_wFmt = MTLPixelFormatRGB10A2Unorm;   // format of the HUD-free world (the interpolator's colour)
static uint64_t g_uiSnapped = 0, g_uiFed = 0, g_uiSrcMatch = 0, g_uiSrcMismatch = 0, g_wuSnapNoSrc = 0;
static void* g_prevEncC0 = nullptr;   // colour attachment 0 of the last render encoder created (render thread)
static const char kEncColor0Key = 0;   // colour attachment 0 of a render encoder (grading detection, UI identity, early logging)
static const char kEncOrdKey = 0;   // pass ordinal of a render encoder, attached only while g_bframe < 4 (early PSHADER log)
static const char kFinalCompKey = 0;   // encoder writes our virtual drawable => it is CombineUI, the final composite
static bool vs_is_ring_tex(id t);      // defined with the ring, in the presenter
static volatile bool g_vsc = false;    // config: virtual_swapchain (BG3 renders into our ring; we present)
static volatile int g_frameCap = 0;    // config: frame_cap (our frame limiter, frame_cap_wait)

// Frame limiter state + statistics. g_capNextNs is the next frame's deadline on the mach clock (now_ns), and
// frame_cap_wait is defined with the presenter and reports in the FRAME CAP line.
static double g_capNextNs = 0.0;

// Armed at every present (present_prologue), and consumed with exchange(false) so exactly ONE render encoder
// waits per frame, whichever thread creates it (BG3 opens encoders from several threads at a frame start).
static std::atomic<bool> g_capArmed{false};
static uint64_t g_capWaits = 0, g_capLate = 0;
static double g_capWaitSum = 0.0, g_capOverSum = 0.0, g_capOverMax = 0.0;
static volatile bool g_fi = false;   // config: frame_interp (MTLFXFrameInterpolator in the presenter)
static volatile int g_fiMotionKey = 2;   // config: fi_motion_key (2 = auto from encode_path, 1 = current chain, 0 = previous chain); see fi_motion_lag()

// Frame-interpolation inputs: a ring filled at the snapshot (render thread) and read 2-3 frames later by
// the presenter (the GPU trails the encode). The ring must be deeper than that lag, and 8 covers it. Looked
// up by exact chain id.
#define FI_RING 8
static id<MTLTexture> g_fiDepth[FI_RING], g_fiMv[FI_RING];
static uint64_t g_renderThreadId = 0;   // BG3's render thread (the one that binds PPTAA_PS); only it receives proxy drawables

// Texture usage the frame interpolator requests for its inputs, ShaderRead until the interpolator exists
// (fi_ready fills them in). The snapshot code re-creates a copy whose usage lacks a requested bit.
static volatile MTLTextureUsage g_fiNeedColor = MTLTextureUsageShaderRead, g_fiNeedDepth = MTLTextureUsageShaderRead,
                                g_fiNeedMotion = MTLTextureUsageShaderRead;
static uint64_t g_fiEncoded = 0;   // interpolations encoded (counted by the presenter)
static float g_fiJx[FI_RING], g_fiJy[FI_RING], g_fiProj[FI_RING][16];

// g_fiChain is the cross-thread publish barrier: the render thread writes the slot's pointers, jitter and
// projection, then release-stores the chain id last, and the presenter acquire-loads it first and reads the
// rest only on a match. Without it ARM64 could hand the presenter torn floats.
static std::atomic<uint32_t> g_fiChain[FI_RING];

// why an interpolation was skipped, so "skipped" names a cause instead of lumping six
// conditions into one number. Five counters, not six: depth and motion share g_fiSkipNoTex.
static uint64_t g_fiSkipChain = 0, g_fiSkipNoTex = 0, g_fiSkipReady = 0, g_fiSkipDims = 0, g_fiSkipWorld = 0;
static float g_lastProj[16];
static IMP o_nextDrawable = nullptr;   // CAMetalLayer's nextDrawable before our hook (set once by hook_layer)

// Marks a command buffer of OURS that is encoded off the render thread (the virtual-swapchain presenter).
// Every encoder hook skips such a CB entirely: the render-thread state machines (snapshot, grading
// boundary, pass ordinals) must never be touched from a second thread.
static const char kOurOffThreadCBKey = 0;
static inline int effective_encode_path(void) {
    return (g_encodePath == ENC_EVENT && g_evFailed) ? ENC_SEPARATE : g_encodePath;
}

// State of the event path (encode_path = event). Documented at event_encode().
static id<MTLCommandQueue> g_evQueue = nil;
static id<MTLSharedEvent> g_evToUs = nil;                  // game CB -> our CB: "the snapshot is written"
static id<MTLSharedEvent> g_evToGame = nil;                // our CB -> game CB: "g_out is written"
static uint64_t g_evSeq = 0;                               // monotonic; one value per event-path encode
static volatile uint64_t g_evPendingSeq = 0;               // the value the current chain's composite must wait for
static volatile uint32_t g_evPendingChain = 0xFFFFFFFFu;   // chain that has an encode in flight on queue B
static int g_evEncodes = 0, g_evWaits = 0, g_evWaitsSkipped = 0, g_evBreaks = 0;   // MFX STATS, window deltas

// BG3 renders reversed-Z, and both MetalFX and the frame interpolator have to be told, or their
// disocclusion logic reads near and far the wrong way round. Not configurable, it is a property of
// BG3's renderer.
static const BOOL kDepthReversed = YES;

static volatile bool g_gpuCapture = false;         // one-shot GPU frame capture (open the .gputrace in Xcode)
static volatile int g_captureFrames = 5;           // how many presents the capture spans
static volatile bool g_captureRequested = false;   // set by the hotkey, consumed by the render thread

// The jitter ACTUALLY handed to the scaler this frame. The FRAME line reports these, not the raw
// values, so a mode that feeds exactly zero also reports zero.
static volatile float g_jxFed = 0.0f, g_jyFed = 0.0f;
static volatile bool g_bypassComposite = false;   // diagnostic: skip our composite (see what ord52 produces)
static volatile float g_sharpness = 0.0f;   // post-upscale sharpen amount in the LUT apply (config: sharpness, default 0.15; 0 = off)
static int g_bframe = 0, g_passIdx = 0;   // frame counter (advances per present once the scaler exists) + per-frame render-pass ordinal
static IMP o_present = nullptr, o_present2 = nullptr;
static volatile float g_jx = 0.0f, g_jy = 0.0f;   // current-frame jitter in pixels (proj m[2][0/1])

// On the separate path MetalFX is 1 frame stale (it reads the previous frame's snapshotted colour/depth/MV).
// The jitter must be delayed the same 1 frame so it matches that colour, else the reprojection is off by a sub-pixel
// every frame -> shimmer. g_jxLive = jitter of the frame currently in g_colorCopy, and g_jxPending = this
// frame's jitter (becomes Live at the next snapshot).
static volatile float g_jxLive = 0.0f, g_jyLive = 0.0f, g_jxPending = 0.0f, g_jyPending = 0.0f;
static bool g_reset = true, g_encLogged = false;   // g_encLogged latches the first MFX NATIVE log line
static volatile float g_mipBias = 0.0f;            // config: mip_bias (0 = off, sampler-level)
static volatile float g_vtMipBias = 0.0f;          // config: vt_mip_bias (Granite virtual textures)
static volatile bool g_vtMipAuto = true;           // config: vt_mip_bias_auto
static volatile float g_mfxExposureValue = 0.0f;   // config: mfx_exposure_value (0 = off)
static bool g_expTexApplied = false;               // an exposure texture is currently set on the scaler
static volatile float g_chGainR = 1.0f, g_chGainG = 1.0f, g_chGainB = 1.0f;   // chroma_gain_*
static volatile float g_chSat = 1.0f;                                         // config: chroma_saturation
static int g_vtPatched;   // entries the tileset patch actually wrote
static int g_vtPatchedPrev = 0;   // g_vtPatched at the last report: the per-WINDOW rate is the informative number, not the total
static int g_vtHeld = 0;                         // entries currently held by signature (reported next to the rate)
static int g_mipBiasApplied, g_mipBiasSkipped;   // how the material-sampler filter split
static volatile int g_mfxResetPeriod = 0;        // config: mfx_reset_period (0 = off)
static uint64_t g_resetCtr = 0;                  // counts encodes for mfx_reset_period
static uint32_t g_presentCount = 0;              // advances every present, unlike g_bframe

// "Already composited" is keyed to the world chain, not the present: the chain id advances once per
// PPTAA_PS bind, so each world render composites exactly once however often the game presents.
static volatile uint32_t g_chainId = 0, g_compChain = 0xFFFFFFFFu;

// The scaler is stateful: a second encodeToCommandBuffer: before the first has finished reading its
// properties mutates it in use and MetalFX asserts inside its ANE encode. One encode per chain, with the
// count released at SCHEDULED, keeps at most one outstanding. g_mfxInFlight is an MFX STATS instrument,
// not a gate.
static volatile int32_t g_mfxInFlight = 0;
static int g_encodeCount = 0;       // encodes actually issued
static int g_inflightWinPeak = 0;   // same, reset each reporting window
static double g_encLatSum = 0.0;    // encode -> scheduled, in ms: how wide the danger window really is
static int g_encLatN = 0;
