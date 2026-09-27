#include "grading.h"
#include <cstring>
#include <cmath>
#include <vector>

uint16_t grading_float_to_half(float f) {
    uint32_t x;
    memcpy(&x, &f, 4);
    uint32_t sign = (x >> 16) & 0x8000u;
    int32_t exp = (int32_t)((x >> 23) & 0xFFu) - 127 + 15;
    uint32_t mant = x & 0x7FFFFFu;

    if (((x >> 23) & 0xFFu) == 0xFFu) return (uint16_t)(sign | 0x7C00u | (mant ? 0x200u : 0u));   // inf/nan
    if (exp >= 0x1F) return (uint16_t)(sign | 0x7C00u);                                           // overflow -> inf
    if (exp <= 0) {                                                                               // subnormal/zero
        if (exp < -10) return (uint16_t)sign;
        mant |= 0x800000u;
        uint32_t shift = (uint32_t)(14 - exp);
        uint32_t half_mant = mant >> shift;
        uint32_t rem = mant & ((1u << shift) - 1u), halfway = 1u << (shift - 1);
        if (rem > halfway || (rem == halfway && (half_mant & 1u))) half_mant++;
        return (uint16_t)(sign | half_mant);
    }

    uint32_t half_mant = mant >> 13, rem = mant & 0x1FFFu;
    if (rem > 0x1000u || (rem == 0x1000u && (half_mant & 1u))) {
        half_mant++;
        if (half_mant == 0x400u) {
            half_mant = 0;
            exp++;
            if (exp >= 0x1F) return (uint16_t)(sign | 0x7C00u);
        }
    }

    return (uint16_t)(sign | ((uint32_t)exp << 10) | half_mant);
}

float grading_half_to_float(uint16_t h) {
    uint32_t sign = (h >> 15) & 1u, exp = (h >> 10) & 0x1Fu, mant = h & 0x3FFu, f;
    if (exp == 0) {
        if (mant == 0) f = sign << 31;
        else {   // subnormal: normalise
            exp = 127 - 15 + 1;
            while (!(mant & 0x400u)) {
                mant <<= 1;
                exp--;
            }
            mant &= 0x3FFu;
            f = (sign << 31) | (exp << 23) | (mant << 13);
        }
    } else if (exp == 0x1Fu) {
        f = (sign << 31) | (0xFFu << 23) | (mant << 13);
    } else {
        f = (sign << 31) | ((exp - 15 + 127) << 23) | (mant << 13);
    }

    float out;
    memcpy(&out, &f, 4);
    return out;
}

GradStats grading_rebuild(const GradCell* cells, int N, uint32_t minCount, uint16_t* outRGBA16F) {
    const int NC = N * N * N;
    GradStats st = {0, NC, 0, 0.0f, 0.0f};
    std::vector<float> val(NC * 3, 0.0f);
    std::vector<uint8_t> filled(NC, 0);
    double stdSum = 0.0;

    for (int i = 0; i < NC; i++) {
        const GradCell& c = cells[i];
        st.samples += c.count;
        if (c.count < minCount || c.count == 0) continue;
        float inv = 1.0f / ((float)c.count * GRAD_SUM_SCALE);
        float r = c.sumR * inv, g = c.sumG * inv, b = c.sumB * inv;
        val[i * 3 + 0] = r;
        val[i * 3 + 1] = g;
        val[i * 3 + 2] = b;
        filled[i] = 1;
        st.measuredCells++;

        // Consistency: per-cell stddev of the PQ-luma samples. A pure color->color map has ~0,
        // spread means ord50's input is NOT the snapshotted texture (or grading varies spatially).
        float meanL = (r + g + b) / 3.0f;
        float meanL2 = c.sumSq / ((float)c.count * GRAD_SUMSQ_SCALE);
        float var = meanL2 - meanL * meanL;
        float sd = var > 0.0f ? sqrtf(var) : 0.0f;
        stdSum += sd;
        if (sd > st.maxStd) st.maxStd = sd;
    }
    if (st.measuredCells == 0) return st;
    st.meanStd = (float)(stdSum / st.measuredCells);

    // Hole fill: iteratively average the already-filled 6-neighbours (double-buffered flags so a
    // pass expands the filled front by exactly one cell, no directional sweep bias).
    std::vector<uint8_t> prev = filled;
    int remaining = NC - st.measuredCells;
    while (remaining > 0) {
        int added = 0;
        for (int z = 0; z < N; z++)
            for (int y = 0; y < N; y++)
                for (int x = 0; x < N; x++) {
                    int i = (z * N + y) * N + x;
                    if (prev[i]) continue;
                    float acc[3] = {0, 0, 0};
                    int n = 0;
                    const int off[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
                    for (auto& o : off) {
                        int nx = x + o[0], ny = y + o[1], nz = z + o[2];
                        if (nx < 0 || ny < 0 || nz < 0 || nx >= N || ny >= N || nz >= N) continue;
                        int j = (nz * N + ny) * N + nx;
                        if (!prev[j]) continue;
                        acc[0] += val[j * 3];
                        acc[1] += val[j * 3 + 1];
                        acc[2] += val[j * 3 + 2];
                        n++;
                    }
                    if (n > 0) {
                        val[i * 3] = acc[0] / n;
                        val[i * 3 + 1] = acc[1] / n;
                        val[i * 3 + 2] = acc[2] / n;
                        filled[i] = 1;
                        added++;
                    }
                }
        if (added == 0) break;   // unreachable in a connected grid, but never loop forever
        prev = filled;
        remaining -= added;
    }

    const uint16_t one = grading_float_to_half(1.0f);
    for (int i = 0; i < NC; i++) {
        outRGBA16F[i * 4 + 0] = grading_float_to_half(val[i * 3 + 0]);
        outRGBA16F[i * 4 + 1] = grading_float_to_half(val[i * 3 + 1]);
        outRGBA16F[i * 4 + 2] = grading_float_to_half(val[i * 3 + 2]);
        outRGBA16F[i * 4 + 3] = one;
    }

    return st;
}

void grading_decay(GradCell* cells, int N) {
    const int NC = N * N * N;
    for (int i = 0; i < NC; i++) {
        cells[i].sumR >>= 1;
        cells[i].sumG >>= 1;
        cells[i].sumB >>= 1;
        cells[i].sumSq >>= 1;
        cells[i].count >>= 1;
    }
}
