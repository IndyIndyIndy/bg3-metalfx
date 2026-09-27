// Granite virtual-texture mip bias: BG3 picks the mip level in the shader, so a sampler bias cannot reach
// it, so we scale the tileset's LOD derivative factor instead.

// Granite virtual-texture mip bias
//
// The LOD chain in every VT material fragment shader, decoded from the AIR:
//     %13 = CB_EngineParams[0].zw                          tileset UV scale
//     %15 = %13 * dfdx(uv)                                 derivative in tileset space
//     %23 = TilesetData[tileset].matrix0.col0               <-- OUR TARGET
//     %28 = %23.zw
//     %29 = %15 * %28                                      derivative scaled by col0.zw
//     %36 = 0.5 * log2(max(dot(%29,%29), dot(%30,%30)))     = log2(|derivative|)
//     %41 = min(anisoRatio, %23.y)                          anisotropy clamp, also from col0
//     %43 = %36 - %41 - 0.5                                 Granite's own fixed bias
//
// log2(s * d) = log2(d) + log2(s), so scaling col0.zw by s shifts the LOD by exactly log2(s).
// A -1.0 bias (the standard value at 2.0x, log2(inW/outW)) means HALVING col0.zw.
//
// col0.zw feeds only those two multiplies (both into the LOD), while col0.y is the aniso clamp, columns 1..3
// are UV and page-table addressing. So a wrong scale is a wrong mip, never broken addressing.
//
// Bind point: VirtualTexture_TilesetDataBuffer, GraniteTilesetConstantBuffer { [2 x float4x4] } = 128 B
// per tileset, air.read_write, fragment index 25 in every shader variant that declares it.
#define VT_ENTRY 128                                     // bytes per tileset entry
#define VT_IDX 25                                        // fragment buffer index
#define VT_MAXENT 4096                                   // never walk further than this into the ring buffer
static uint32_t jp_hash(const void* p, NSUInteger n) {   // FNV-1a over the bytes we would copy
    const unsigned char* b = (const unsigned char*)p;
    uint32_t h = 2166136261u;
    for (NSUInteger i = 0; i < n; i++) {
        h ^= b[i];
        h *= 16777619u;
    }
    return h;
}

static bool g_vtEverWrote = false;   // some entries carry our factor: a walk is needed even with the bias off, to restore them

// The patch is IN PLACE: BG3's own buffer is what gets bound, nothing is substituted.
static void patch_vt_tileset(id<MTLBuffer> buf, NSUInteger offset, NSUInteger idx) {
    if (idx != VT_IDX || !buf || !g_device) return;
    const bool want = !mod_idle() && (g_vtMipBias != 0.0f || g_vtMipAuto);
    if (!want && !g_vtEverWrote) return;
    if (offset != 0) return;        // the shader indexes the table from the bound offset; only offset 0 is known

    const void* c = buf.contents;   // NULL for private storage: unreadable, leave alone
    const NSUInteger len = buf.length;
    if (!c || len < VT_ENTRY) {
        static bool once = false;
        if (!once) {
            once = true;
            log_line("VT MIP BIAS: the buffer at index %d is not patchable (contents=%s, len=%lu), no bias applied",
                     VT_IDX, c ? "readable" : "NULL", (unsigned long)len);
        }
        return;
    }

    // Read-only probe (logging only): col0 of the first entries and how often the table head changes.
    // The head hash is sampled, not taken every bind (4 KB of shared memory is about 20 us to hash).
    if (len >= 4096 && g_logging) {
        static int logged = 0;
        static uint32_t lastH = 0;
        static uint64_t seen = 0, changed = 0;
        if (logged < 6) {
            const float* f0 = (const float*)c;
            seen++;
            if (seen % 64 == 1) {
                uint32_t h4 = jp_hash(c, 4096);   // only the head: where the tileset array lives
                if (lastH && h4 != lastH) changed++;
                lastH = h4;
            }

            if (seen == 1 || seen % 4000 == 0) {
                logged++;
                log_line("VT PROBE %d [%llu binds, head changed %llu times = %.3f%%]: "
                         "entry0 col0=(%.6f %.6f %.6f %.6f) col1=(%.6f %.6f %.6f %.6f) | "
                         "entry1 col0=(%.6f %.6f %.6f %.6f) | entry2 col0=(%.6f %.6f %.6f %.6f)  "
                         "[col0.zw is the LOD derivative scale: a texture SIZE means vt_mip_bias -0.5 "
                         "has the right sign, a reciprocal means it must be +0.5]",
                         logged, (unsigned long long)seen, (unsigned long long)changed,
                         seen ? 100.0 * (double)changed / (double)seen : 0.0, f0[0], f0[1], f0[2], f0[3], f0[4], f0[5],
                         f0[6], f0[7], f0[32], f0[33], f0[34], f0[35], f0[64], f0[65], f0[66], f0[67]);
            }
        }
    }

    // In place, once per chain, bounded by a signature. The tileset table sits at the head of the
    // 21 MB shared ring and is static (write once).
    // col0.zw is the virtual-texture size in texels, so a negative bias is the sharp direction.
    // Only the head is tileset data, so the walk stops at the  first entry that fails the signature rather than scaling into unrelated ring content.
    // TODO: this test-and-set is not atomic, and s_setFragBuf runs on whichever thread encodes, which
    // BG3 spreads over several at a frame start (see g_capArmed). Two threads can both enter for the
    // same chain, and the second then reads an already scaled col0.zw as its original, so the entry ends
    // up scaled twice and orig[] holds a value the restore walk cannot undo. Make doneChain an atomic
    // and exchange it, the way g_capArmed does.
    static uint32_t doneChain = 0xFFFFFFFFu;
    if (doneChain == g_chainId) return;
    doneChain = g_chainId;

    // 2^bias, or 1.0 when the key is off or the mod idle (restore).
    // AUTO: log2(inW/outW), the mip level BG3 loses by rasterising at render resolution while we
    // present at target resolution, and it follows the render scale instead of being set per step.
    float bias = 0.0f;
    if (want) {
        bias = g_vtMipBias;
        if (g_vtMipAuto && g_inW > 0 && g_outW > 0) bias = log2f((float)g_inW / (float)g_outW);
    }

    const float k = powf(2.0f, bias);
    if (k == 1.0f && !g_vtEverWrote) return;

    static float wrote[VT_MAXENT][2], orig[VT_MAXENT][2];   // what we wrote, and BG3's value it replaced
    static bool haveWrote[VT_MAXENT];
    NSUInteger maxE = len / VT_ENTRY;
    if (maxE > VT_MAXENT) maxE = VT_MAXENT;
    int e = 0;

    for (; e < (int)maxE; e++) {
        float* f = (float*)((char*)c + (size_t)e * VT_ENTRY);
        float x = f[0], y = f[1], zz = f[2], ww = f[3];

        // Is it still ours? Then BG3 has not rewritten the entry, so rewrite from the original only when
        // the factor changed (a live bias change, or a restore to BG3's value at k = 1).
        if (haveWrote[e] && zz == wrote[e][0] && ww == wrote[e][1]) {
            float nz = orig[e][0] * k, nw = orig[e][1] * k;
            if (nz != zz || nw != ww) {
                f[2] = nz;
                f[3] = nw;
                wrote[e][0] = nz;
                wrote[e][1] = nw;
            }
            if (k == 1.0f) haveWrote[e] = false;
            continue;
        }

        bool sig = isfinite(x) && x >= 1.0f && x <= 64.0f && x == floorf(x) && isfinite(y) && y >= 0.0f && y <= 64.0f &&
                   y == floorf(y) && isfinite(zz) && isfinite(ww) && zz >= 64.0f && ww >= 64.0f && zz <= 1048576.0f &&
                   ww <= 1048576.0f;
        if (!sig) break;           // end of the tileset table -> never write past it
        if (k == 1.0f) continue;   // BG3's own value, and no bias wanted

        orig[e][0] = zz;
        orig[e][1] = ww;
        f[2] = zz * k;
        f[3] = ww * k;
        wrote[e][0] = f[2];
        wrote[e][1] = f[3];
        haveWrote[e] = true;
        g_vtEverWrote = true;
        if (g_vtPatched == 0)
            log_line("VT MIP BIAS %+.2f%s: scaling col0.zw by %.4f. entry0 (%.1f %.1f %.1f %.1f)"
                     " -> (%.1f %.1f %.1f %.1f). col0.y is the aniso clamp and col0.x a "
                     "Granite internal, both untouched, as are columns 1..3 (UV / page "
                     "table). Table is static, so this write happens once.",
                     bias, g_vtMipAuto ? " (auto = log2(inW/outW))" : "", k, x, y, zz, ww, f[0], f[1], f[2], f[3]);
        g_vtPatched++;
    }

    g_vtHeld = e;
    if (k == 1.0f) {   // restore walk: once no entry carries our factor, the hook goes back to sleep
        bool any = false;
        for (int i = 0; i < VT_MAXENT && !any; i++) any = haveWrote[i];
        g_vtEverWrote = any;
    }

    static int lastE = -1;
    if (e != lastE) {
        lastE = e;
        log_line("VT MIP BIAS: signature held for %d of %lu possible entries (%d bytes of "
                 "the 21 MB buffer). Stopped at entry %d, everything past it is other ring"
                 "-buffer content and stays untouched.",
                 e, (unsigned long)(len / VT_ENTRY), e * VT_ENTRY, e);
    }
}
