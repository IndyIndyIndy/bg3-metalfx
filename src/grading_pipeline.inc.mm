// Two of the game's colour steps happen before our image enters its pipeline, so this file puts them
// back. It learns the grading from the game's own input and output pairs, recovers the bloom as the
// difference between two of its textures, and writes the result into the texture its tonemap reads.

// Grading harvest: kernels + state machine
// PQ transfer (ST.2084, BG3's exact constants) as the LUT coordinate: perceptually uniform, so the
// 33^3 grid spends its resolution where color errors are visible. 1.0 linear = 100 nits (x*0.01), an
// arbitrary anchor, and only harvest/apply consistency matters. Values > 100 clamp to the cube edge.
#define GRAD_PQ_MSL                                                                                                    \
    "static inline float3 pq_enc(float3 x) {\n"                                                                        \
    "  x = clamp(x * 0.01, 0.0, 1.0);\n"                                                                               \
    "  float3 y = pow(x, 0.1593017578125);\n"                                                                          \
    "  return pow((0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), 78.84375);\n"                                    \
    "}\n"                                                                                                              \
    "static inline float3 pq_dec(float3 t) {\n"                                                                        \
    "  t = clamp(t, 0.0, 1.0);\n"                                                                                      \
    "  float3 y = pow(t, 1.0 / 78.84375);\n"                                                                           \
    "  float3 x = pow(max(y - 0.8359375, 0.0) / max(18.8515625 - 18.6875 * y, 1e-6), 1.0 / 0.1593017578125);\n"        \
    "  return x * 100.0;\n"                                                                                            \
    "}\n"

static void build_grad_psos(void) {
    if ((g_gradHarvestPSO && g_gradApplyPSO && g_bloomPSO) || !g_device) return;
    @autoreleasepool {
        NSString* src =
            @"#include <metal_stdlib>\n"
             "using namespace metal;\n" GRAD_PQ_MSL
             // Layout must match struct GradCell (grading.h): 5 packed uint32.
             "struct GCell { atomic_uint sumR; atomic_uint sumG; atomic_uint sumB; atomic_uint sumSq; atomic_uint count; };\n"
             "struct HP { uint N; uint stride; uint cap; };\n"
             "kernel void gradharvest(texture2d<float, access::read> tin [[texture(0)]],\n"
             "                        texture2d<float, access::read> tout [[texture(1)]],\n"
             "                        device GCell* cells [[buffer(0)]],\n"
             "                        constant HP& P [[buffer(1)]],\n"
             "                        uint2 gid [[thread_position_in_grid]]) {\n"
             "  uint2 px = gid * P.stride + (P.stride / 2);\n"
             "  if (px.x >= tin.get_width() || px.y >= tin.get_height()) return;\n"
             "  float3 ci = tin.read(px).rgb, co = tout.read(px).rgb;\n"
             "  if (any(isnan(ci)) || any(isnan(co)) || any(ci > 65000.0) || any(co > 65000.0)) return;\n"
             "  float3 ti = pq_enc(ci), to = pq_enc(co);\n"
             "  uint3 cell = uint3(ti * float(P.N - 1) + 0.5);\n"
             "  device GCell& C = cells[(cell.z * P.N + cell.y) * P.N + cell.x];\n"
             // Reserve a count slot FIRST, so racing threads that overshoot the cap undo their increment
             // and never touch the sums -> the sums are hard-bounded at cap x 65535 < 2^32.
             "  if (atomic_fetch_add_explicit(&C.count, 1u, memory_order_relaxed) >= P.cap) {\n"
             "    atomic_fetch_sub_explicit(&C.count, 1u, memory_order_relaxed); return;\n"
             "  }\n"
             "  float l = (to.r + to.g + to.b) * (1.0 / 3.0);\n"
             "  atomic_fetch_add_explicit(&C.sumR, uint(to.r * 65535.0 + 0.5), memory_order_relaxed);\n"
             "  atomic_fetch_add_explicit(&C.sumG, uint(to.g * 65535.0 + 0.5), memory_order_relaxed);\n"
             "  atomic_fetch_add_explicit(&C.sumB, uint(to.b * 65535.0 + 0.5), memory_order_relaxed);\n"
             "  atomic_fetch_add_explicit(&C.sumSq, uint(l * l * 16384.0 + 0.5), memory_order_relaxed);\n"
             "}\n"
             // BG3's bloom as an isolated additive layer: bloomed scene minus pre-bloom scene
             "kernel void bloomextract(texture2d<float, access::read> post [[texture(0)]],\n"
             "                         texture2d<float, access::read> pre [[texture(1)]],\n"
             "                         texture2d<float, access::write> d [[texture(2)]],\n"
             "                         uint2 gid [[thread_position_in_grid]]) {\n"
             "  if (gid.x >= d.get_width() || gid.y >= d.get_height()) return;\n"
             "  float3 b = post.read(gid).rgb - pre.read(gid).rgb;\n"
             "  d.write(float4(max(b, 0.0), 1.0), gid);\n"
             "}\n"
             "struct AP { uint useBloom; float sharpness; float gainR; float gainG; float gainB; float sat; };\n"
             "kernel void gradapply(texture2d<float, access::read> s [[texture(0)]],\n"
             "                      texture3d<float, access::sample> lut [[texture(1)]],\n"
             "                      texture2d<float, access::write> d [[texture(2)]],\n"
             "                      texture2d<float, access::sample> bloom [[texture(3)]],\n"
             "                      constant AP& P [[buffer(0)]],\n"
             "                      uint2 gid [[thread_position_in_grid]]) {\n"
             "  if (gid.x >= d.get_width() || gid.y >= d.get_height()) return;\n"
             "  float3 c = s.read(gid).rgb;\n"
             // Optional unsharp mask (cross kernel) on the upscaled HDR, before bloom and grading. MetalFX
             // has no sharpening of its own, while BG3's FSR path ends in RCAS.
             "  if (P.sharpness > 0.0) {\n"
             "    uint2 sz = uint2(s.get_width(), s.get_height());\n"
             "    float3 l = s.read(uint2(gid.x > 0 ? gid.x - 1 : 0, gid.y)).rgb;\n"
             "    float3 r = s.read(uint2(min(gid.x + 1, sz.x - 1), gid.y)).rgb;\n"
             "    float3 u = s.read(uint2(gid.x, gid.y > 0 ? gid.y - 1 : 0)).rgb;\n"
             "    float3 dn = s.read(uint2(gid.x, min(gid.y + 1, sz.y - 1))).rgb;\n"
             "    c = max(c + P.sharpness * (4.0 * c - l - r - u - dn), 0.0);\n"
             "  }\n"
             "  constexpr sampler smp(coord::normalized, filter::linear, address::clamp_to_edge);\n"
             "  if (P.useBloom != 0) {\n"   // render-res layer, bilinearly upscaled onto our target-res HDR
             "    float2 uv = (float2(gid) + 0.5) / float2(d.get_width(), d.get_height());\n"
             "    c += bloom.sample(smp, uv).rgb;\n"
             "  }\n"
             "  float3 t = pq_enc(c);\n"
             "  float n = float(lut.get_width());\n"
             "  float3 crd = (t * (n - 1.0) + 0.5) / n;\n"   // sample at cell centers
             // Per-channel gain, applied last, off by default.
             "  float3 o = pq_dec(lut.sample(smp, crd).rgb) * float3(P.gainR, P.gainG, P.gainB);\n"
             // Saturation scales the distance from luma (grey stays grey), countering the local-variance
             // loss from MetalFX's neighbourhood clamping without shifting neutral surfaces.
             "  if (P.sat != 1.0) {\n"
             "    float y = dot(o, float3(0.2126, 0.7152, 0.0722));\n"
             "    o = max(y + (o - y) * P.sat, 0.0);\n"
             "  }\n"
             "  d.write(float4(max(o, 0.0), 1.0), gid);\n"
             "}\n";
        NSError* err = nil;
        id<MTLLibrary> lib = [g_device newLibraryWithSource:src options:nil error:&err];
        if (!lib) {
            log_line("grad lib FAILED: %s", err ? err.localizedDescription.UTF8String : "?");
            return;
        }

        struct {
            id<MTLComputePipelineState>* slot;
            NSString* name;
        } k[] = {{&g_gradHarvestPSO, @"gradharvest"}, {&g_gradApplyPSO, @"gradapply"}, {&g_bloomPSO, @"bloomextract"}};

        for (auto& e : k) {
            id<MTLFunction> fn = [lib newFunctionWithName:e.name];
            if (!*e.slot) *e.slot = [g_device newComputePipelineStateWithFunction:fn error:&err];
            [fn release];
        }

        [lib release];
        log_line("grad PSOs %s", (g_gradHarvestPSO && g_gradApplyPSO && g_bloomPSO) ? "built" : "FAILED");
    }
}

// Does THIS post-chain feed the harvest?
static inline bool grading_chain_harvests(void) {
    if (g_mode != 0 || !g_gradingHarvest) return false;

    // Once the LUT is published and consistant, the pairs stop telling us anything new every single
    // frame, and the mapping only changes on an area change (or a scene/grade change: game<->menu). Harvest
    // every 2nd chain: a grade change re-converges in ~2.5 s and the steady-state cost is negligible.
    // The bloom extract still runs every frame.
    if (g_gradRebuilds >= 3 && g_gradMeasured >= GRAD_APPLY_MIN_CELLS && (g_chainId & 1u) != 0u) return false;

    return true;
}

// The compute encoder shared by the bloom extract and the harvest, created on first use.
static id<MTLComputeCommandEncoder> grad_encoder(id gameCB, id<MTLComputeCommandEncoder>* ce) {
    if (!*ce) *ce = [gameCB computeCommandEncoder];
    return *ce;
}

// CPU rebuild of the LUT, on a background thread: averages the cells into a dense LUT (holes filled),
// uploads it to the INACTIVE half of the double buffer, flips, and decays the sums (area adaptation). Runs
// once the command buffer carrying the last harvest of the window has completed: the queue is serial, so
// every earlier harvest is complete too, and no new harvest is dispatched while g_gradRebuilding is set.
static void grading_rebuild_lut(void) {
    double t0 = now_ns();
    GradStats st = grading_rebuild((const GradCell*)g_gradCells.contents, GRAD_N, GRAD_MIN_COUNT, g_gradLutData);

    // Consistency GATE: in gameplay the per-cell spread is ~0.002, because ord50 is a pure color
    // function on the texture we snapshot. A context where it instead reads some other texture
    // yields wildly disagreeing pairs.
    // Averaging those produces a wrong transform, so don't publish it AND drop the polluted accumulation instead of
    // letting the decay wash it out over ~5 s. The last good LUT stays active meanwhile.
    bool trustworthy = st.measuredCells > 0 && st.meanStd <= GRAD_MAX_STD;
    if (!trustworthy && st.measuredCells > 0) {
        memset(g_gradCells.contents, 0, g_gradCells.length);
        if (++g_gradRejects <= 5 || g_gradRejects % 50 == 0)
            log_line("GRAD rebuild REJECTED (#%d): std mean=%.4f > %.3f, pairs disagree, discarding "
                     "this harvest and keeping the last good LUT",
                     g_gradRejects, st.meanStd, GRAD_MAX_STD);
    }

    if (trustworthy) {
        int slot = (g_gradLutActive.load(std::memory_order_relaxed) == 0) ? 1 : 0;
        if (!g_gradLutTex[slot]) {
            MTLTextureDescriptor* td = [MTLTextureDescriptor new];
            td.textureType = MTLTextureType3D;
            td.pixelFormat = MTLPixelFormatRGBA16Float;
            td.width = GRAD_N;
            td.height = GRAD_N;
            td.depth = GRAD_N;
            td.usage = MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModeShared;
            g_gradLutTex[slot] = [g_device newTextureWithDescriptor:td];
            [td release];
        }

        if (g_gradLutTex[slot]) {
            [g_gradLutTex[slot] replaceRegion:MTLRegionMake3D(0, 0, 0, GRAD_N, GRAD_N, GRAD_N)
                                  mipmapLevel:0
                                        slice:0
                                    withBytes:g_gradLutData
                                  bytesPerRow:GRAD_N * 8
                                bytesPerImage:GRAD_N * GRAD_N * 8];
            g_gradLutActive.store(slot, std::memory_order_release);
            g_gradMeasured = st.measuredCells;
        }
    }

    if (trustworthy) grading_decay((GradCell*)g_gradCells.contents, GRAD_N);   // rejected data is already cleared
    g_gradRebuilds++;

    // LUT fingerprint: luma of the LUT's output on the grey diagonal at 25/50/75 % input, per rebuild.
    // Two runs that show the same picture must show the same fingerprint.
    if (g_logging && st.measuredCells > 0) {
        float fp[3];
        int idx[3] = {GRAD_N / 4, GRAD_N / 2, (3 * GRAD_N) / 4};
        for (int i = 0; i < 3; i++) {
            int ci = idx[i];
            const uint16_t* h = &g_gradLutData[((ci * GRAD_N + ci) * GRAD_N + ci) * 4];
            fp[i] = 0.2126f * grading_half_to_float(h[0]) + 0.7152f * grading_half_to_float(h[1]) +
                    0.0722f * grading_half_to_float(h[2]);
        }
        log_line("GRAD FP #%d: [%.3f %.3f %.3f] %s cells=%d std=%.4f chain=%u", g_gradRebuilds, fp[0], fp[1], fp[2],
                 trustworthy ? "accepted" : "REJECTED", st.measuredCells, st.meanStd, g_chainId);
    }

    // Consistency stat: ~0 stddev means ord50 really maps the snapshotted attachment
    // pixel-for-pixel, whereas a big spread means it reads another texture (or grades spatially).
    if (g_gradRebuilds <= 10 || g_gradRebuilds % 20 == 0)
        log_line(
            "GRAD rebuild #%d: measured %d/%d cells, samples=%llu, missed=%d, bloomOff=%d, taaSeen=%d, bloomExt=%d, cand=%d, std mean=%.4f max=%.4f, cpu %.1f ms%s",
            g_gradRebuilds, st.measuredCells, st.totalCells, (unsigned long long)st.samples, g_gradMissed,
            g_bloomOffFrames, g_taaSeen, g_bloomExtracted, g_gradCandBlits, st.meanStd, st.maxStd,
            (now_ns() - t0) / 1e6,
            (st.measuredCells > 0 && st.meanStd > GRAD_MAX_STD) ? "  <-- INCONSISTENT (rejected)" : "");

    g_gradRebuilding = false;   // last: re-opens the harvest
}

// Attached to the game CB right after the harvest that closed a rebuild window (no encoder open). Metal's
// completion queue is shared with the presenter's hand-off handler, so the handler only forwards and the
// work runs on a background queue.
static void grading_rebuild_after(id gameCB) {
    [gameCB addCompletedHandler:^(id<MTLCommandBuffer>) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ grading_rebuild_lut(); });
    }];
}

// At the encoder boundary right after ord50: the live attachment now holds ord50's OUTPUT and
// g_gradInCand its INPUT -> accumulate the pairs into the cell grid on the game CB (serialized). Returns
// true when this harvest closed a rebuild window (the caller attaches the rebuild to the CB).
static bool grading_dispatch_harvest(id gameCB, id<MTLComputeCommandEncoder>* cep) {
    if (!g_gradAtt || !g_gradInCand || !same_dims(g_gradAtt, g_gradInCand)) return false;
    build_grad_psos();
    if (!g_gradHarvestPSO) return false;

    if (!g_gradCells) {
        g_gradCells = [g_device newBufferWithLength:sizeof(GradCell) * GRAD_N * GRAD_N * GRAD_N
                                            options:MTLResourceStorageModeShared];
        if (!g_gradCells) return false;
        memset(g_gradCells.contents, 0, g_gradCells.length);
    }

    if (!grading_chain_harvests()) return false;
    if (g_gradRebuilding) {   // the CPU reads the cells: no new atomics
        // Watchdog: if the command buffer never completes from a killed queue or a lost callback, the
        // harvest must not block forever, so resume accumulating after ~10 s worth of boundaries.
        if (++g_gradStateWait > 600) {
            g_gradStateWait = 0;
            g_gradRebuilding = false;
            log_line("GRAD rebuild watchdog: rebuild never ran, resuming harvest");
        }
        return false;
    }

    g_gradStateWait = 0;
    struct {
        uint32_t N, stride, cap;
    } P = {(uint32_t)GRAD_N, (uint32_t)GRAD_STRIDE, GRAD_CAP_COUNT};

    id<MTLComputeCommandEncoder> ce = grad_encoder(gameCB, cep);
    [ce setComputePipelineState:g_gradHarvestPSO];
    [ce setTexture:g_gradInCand atIndex:0];
    [ce setTexture:g_gradAtt atIndex:1];
    [ce setBuffer:g_gradCells offset:0 atIndex:0];
    [ce setBytes:&P length:sizeof(P) atIndex:1];
    NSUInteger gw = (g_gradInCand.width + GRAD_STRIDE - 1) / GRAD_STRIDE;
    NSUInteger gh = (g_gradInCand.height + GRAD_STRIDE - 1) / GRAD_STRIDE;
    [ce dispatchThreads:MTLSizeMake(gw, gh, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];

    if (!g_gradLogged) {
        g_gradLogged = true;
        log_line("GRAD harvest ACTIVE: ord50 pairs %lux%lu stride %d -> %d^3 LUT", (unsigned long)g_gradInCand.width,
                 (unsigned long)g_gradInCand.height, GRAD_STRIDE, GRAD_N);
    }

    if (++g_gradPairFrames % GRAD_REBUILD_FRAMES != 0) return false;
    g_gradRebuilding = true;   // this harvest closes the window; the rebuild runs when its CB has completed
    return true;
}

// Right after ord50: g_gradInCand is the bloomed scene and g_taaCopy the pre-bloom scene, so their
// difference is the additive bloom layer. Runs every frame and shares the harvest's compute encoder (an
// encoder switch costs more than the dispatch on a TBDR GPU).
static void grading_dispatch_bloom(id gameCB, id<MTLComputeCommandEncoder>* cep) {
    // g_taaAtt must have been captured since the last extraction. A stale one (a frame without
    // PPTAA_PS, or an area change) has matching dimensions but unrelated content, so the difference
    // would be garbage, not bloom. Skipping is the safe fallback: the apply then runs without a bloom
    // layer.
    if (!g_gradingBloom || !g_gradingApply || !g_taaCopy || !g_taaCopied || !g_taaFresh)
        return;   // the layer is only read by the LUT apply

    if (!g_gradInCand || !same_dims(g_taaCopy, g_gradInCand)) return;
    build_grad_psos();
    if (!g_bloomPSO) return;

    if (!g_bloomTex || !same_dims(g_bloomTex, g_gradInCand)) {
        retire_obj((id*)&g_bloomTex);
        g_bloomTex = make_copy_like(g_gradInCand, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
        if (!same_dims(g_bloomTex, g_gradInCand)) return;
    }

    id<MTLComputeCommandEncoder> ce = grad_encoder(gameCB, cep);
    [ce setComputePipelineState:g_bloomPSO];
    [ce setTexture:g_gradInCand atIndex:0];   // post-ord49 (scene + bloom)
    [ce setTexture:g_taaCopy atIndex:1];      // post-ord39 SNAPSHOT (scene without bloom)
    [ce setTexture:g_bloomTex atIndex:2];
    [ce dispatchThreads:MTLSizeMake(g_bloomTex.width, g_bloomTex.height, 1)
        threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];

    // Deliberately NOT ended here: the harvest dispatches into the same encoder right after us, and
    // grading_boundary closes it once. Ending it here would leave the harvest encoding into a dead encoder.
    g_taaFresh = false;    // consumed: this partner must not be reused for a later extraction
    g_bloomReady = true;   // hand the layer to the next apply
    g_bloomExtracted++;

    if (!g_bloomLogged) {
        g_bloomLogged = true;
        log_line("GRAD bloom layer ACTIVE: (post-ord49 %p) - (TAA-out %p) %lux%lu", (void*)g_gradInCand,
                 (void*)g_taaAtt, (unsigned long)g_bloomTex.width, (unsigned long)g_bloomTex.height);
    }
}

// Encoder-boundary hook (game CB, no encoder open): (1) if ord50 just ran, harvest its output now, and
// (2) keep a fresh "before" candidate of ord50's attachment. Which pass IS ord50 is only known at
// setRPS time (after encoder creation), so the blit runs at every boundary of that attachment
// (ord49 + ord50 once the pointer is locked, every render-res RG11B10 pass before that) and
// s_setRPS promotes the candidate blitted immediately before ord50's own encoder.
static void grading_boundary(id gameCB, MTLRenderPassDescriptor* d) {
    MARK("grading_boundary");
    if (g_mode != 0 || !g_gradingHarvest || !g_device || !d) return;

    // The pre-bloom (TAA-out) copy for the bloom extract is taken in snapshot_pre_taa, in the same
    // blit encoder as the three MetalFX inputs, same boundary, one encoder instead of two.
    if (g_pendingGradOut) {
        g_pendingGradOut = false;
        id<MTLComputeCommandEncoder> ce = nil;
        grading_dispatch_bloom(gameCB, &ce);
        bool closesWindow = grading_dispatch_harvest(gameCB, &ce);
        if (ce) [ce endEncoding];
        if (closesWindow) grading_rebuild_after(gameCB);
    }

    id<MTLTexture> c0 = d.colorAttachments[0].texture;
    if (!c0 || c0.pixelFormat != MTLPixelFormatRG11B10Float || !g_inW || c0.width != g_inW || c0.height != g_inH ||
        d.colorAttachments[1].texture)
        return;

    // Pool member (or nothing known yet) -> keep a candidate. Restricting this to the LAST seen ord50
    // attachment stalls the harvest whenever BG3 ping-pongs the two post-TAA textures.
    if (g_gradPoolN > 0 && !grad_pool_contains(c0)) return;

    // Take the candidate only at the first boundary that follows ord49 and targets ord49's attachment
    // (exactly ord50's input): the chain window, the texture identity and "not already taken this chain"
    // are all needed, none alone is unique. Until ord49 is identified the broad filter applies.
    if (g_bloomCombineSeen &&
        (g_bloomCombineChain != g_chainId || (void*)c0 != g_bloomOutTex || g_gradCandChain == g_chainId))
        return;

    if (!g_gradInCand || !same_dims(c0, g_gradInCand)) {
        retire_obj((id*)&g_gradInCand);
        g_gradInCand = make_copy_like(c0, MTLTextureUsageShaderRead);
        if (!same_dims(c0, g_gradInCand)) return;
    }

    id<MTLBlitCommandEncoder> b = [gameCB blitCommandEncoder];
    [b copyFromTexture:c0 toTexture:g_gradInCand];
    [b endEncoding];

    g_gradInSrc = (void*)c0;
    g_gradCandChain = g_chainId;
    g_gradCandBlits++;   // should track taaSeen 1:1, anything higher means we blit copies nobody reads
}

// Native tonemap injection: write MetalFX's HDR into FSR's compute-output texture (ord52's input) before
// ord52 runs, so BG3's own PPToneMap_LUT tonemaps and grades OUR image.
static void upscale_native(id gameCB) {
    MARK("upscale_native (MetalFX encode)");
    if (g_compChain == g_chainId || g_mode != 0) return;

    // Event path: an encode pending on queue B reads this chain's copies, and the next snapshot on the
    // game queue overwrites them. The wait that orders the game queue behind queue B is therefore
    // encoded first, before any return that skips the composite, exactly once per chain.
    static uint32_t waitedChain = 0xFFFFFFFFu;
    if (effective_encode_path() == ENC_EVENT && g_evPendingChain == g_chainId && waitedChain != g_chainId) {
        waitedChain = g_chainId;
        [gameCB encodeWaitForEvent:g_evToGame value:g_evPendingSeq];
        g_evWaits++;
    }

    if (g_bypassComposite || !g_fsrOut) return;
    // The destination check comes BEFORE the encode: a return after the encode would leave the chain
    // un-latched (g_compChain) and the next scene pass would encode MetalFX a second time.
    if (g_fsrOut.width != g_outW || g_fsrOut.height != g_outH) return;

    @try {
        if (effective_encode_path() == ENC_EVENT) {
            // The encode went to queue B at the snapshot boundary and the wait is in place (above). A chain
            // without a pending encode is left to BG3's FSR (mfx_active() made the same decision at its dispatch).
            if (g_evPendingChain != g_chainId) {
                g_evWaitsSkipped++;
                return;
            }
        } else if (!encode_metalfx(gameCB)) return;

        if (!g_out || !same_dims(g_out, g_fsrOut)) return;
        // With a harvested grading LUT ready, replicate ord50 on our target-res HDR (our pre-TAA feed never
        // went through BG3's render-res grading), and otherwise plain blit (ungraded).
        int lutSlot = g_gradLutActive.load(std::memory_order_acquire);
        bool useLUT = g_gradingApply && lutSlot >= 0 && g_gradMeasured >= GRAD_APPLY_MIN_CELLS && g_gradApplyPSO;

        if (useLUT) {
            // Same-frame bloom layer only (a stale one would trail moving highlights)
            bool useBloom = g_gradingBloom && g_bloomTex && g_bloomReady;
            if (!useBloom && g_gradingBloom) g_bloomOffFrames++;

            struct {
                uint32_t useBloom;
                float sharpness;
                float gainR, gainG, gainB, sat;
            } ap = {useBloom ? 1u : 0u, g_sharpness, g_chGainR, g_chGainG, g_chGainB, g_chSat};

            id<MTLComputeCommandEncoder> ce = [gameCB computeCommandEncoder];
            mfx_label(ce, "BG3MFX composite: grade+bloom -> FSR-out (tex2 = destination)");
            [ce setComputePipelineState:g_gradApplyPSO];
            [ce setTexture:g_out atIndex:0];
            [ce setTexture:g_gradLutTex[lutSlot] atIndex:1];
            [ce setTexture:g_fsrOut atIndex:2];
            [ce setTexture:(useBloom ? g_bloomTex : g_out) atIndex:3];   // dummy bind when off
            [ce setBytes:&ap length:sizeof(ap) atIndex:0];
            [ce dispatchThreads:MTLSizeMake(g_fsrOut.width, g_fsrOut.height, 1)
                threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [ce endEncoding];

            g_gradedCount++;
            if (!g_gradApplyLogged || useBloom != g_gradApplyBloomWas) {
                g_gradApplyLogged = true;
                g_gradApplyBloomWas = useBloom;
                log_line("GRAD apply ACTIVE: harvested %d^3 LUT (%d measured cells), bloom=%s -> g_fsrOut", GRAD_N,
                         g_gradMeasured, useBloom ? "ON" : "off");
            }
        } else {
            id<MTLBlitCommandEncoder> b = [gameCB blitCommandEncoder];
            mfx_label(b, "BG3MFX composite: plain copy -> FSR-out");
            [b copyFromTexture:g_out toTexture:g_fsrOut];   // g_fsrOut is linear HDR (FSR_RCAS already inverted)
            [b endEncoding];
        }

        g_compChain = g_chainId;
        g_compCount++;
        if (!g_encLogged) {
            g_encLogged = true;
            log_line("MFX NATIVE: MetalFX -> FSR-out %p -> BG3 tonemaps (in %lux%lu -> out %lux%lu)", (void*)g_fsrOut,
                     (unsigned long)g_inW, (unsigned long)g_inH, (unsigned long)g_outW, (unsigned long)g_outH);
        }
    } @catch (NSException* ex) {
        if (!g_encLogged) {
            g_encLogged = true;
            log_line_always("MFX NATIVE EXCEPTION: %s", ex.reason.UTF8String);
        }
    }
}

// The tonemap pass (ord52): the first writer of the target-res RGB10A2 scene. It reads the pre-tonemap HDR
// (FSR's output, g_fsrOut, grabbed at its creation), so our image has to be in that texture before this pass.
static bool is_scene_pass(MTLRenderPassDescriptor* d) {
    id<MTLTexture> c0 = d.colorAttachments[0].texture;
    return c0 && c0.pixelFormat == MTLPixelFormatRGB10A2Unorm && g_outW && c0.width == g_outW && c0.height == g_outH;
}
