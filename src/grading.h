#pragma once
#include <cstdint>
#include <cstddef>

// CPU side of the ord50 grading harvest. The GPU kernel accumulates
// input->output pairs of BG3's PPColorGradingApplyLUTPS into a N^3 cell grid (PQ-encoded output
// values in fixed point + a sample count per cell), and this module turns those sums into a dense
// RGBA16F 3D LUT (average per measured cell, holes filled from neighbours) and computes the
// pair-consistency statistics that verify ord50 really reads the snapshotted texture.
//
// Fixed-point scales, must match the Metal harvest kernel:
//   sumR/G/B accumulate PQ-encoded output (in [0,1]) x GRAD_SUM_SCALE
//   sumSq    accumulates squared PQ-luma (in [0,1])  x GRAD_SUMSQ_SCALE
// With counts capped at GRAD_CAP_COUNT the sums stay below 2^32 (65535 x 30000 ~ 1.97e9, because the
// kernel reserves a count slot BEFORE adding to the sums, so racing threads cannot overshoot).
constexpr float GRAD_SUM_SCALE = 65535.0f;
constexpr float GRAD_SUMSQ_SCALE = 16384.0f;
constexpr uint32_t GRAD_CAP_COUNT = 30000;

struct GradCell {
    uint32_t sumR, sumG, sumB, sumSq, count;
};

struct GradStats {
    int measuredCells;   // cells with count >= minCount (before hole filling)
    int totalCells;      // N^3
    uint64_t samples;    // total accumulated sample count
    float meanStd;       // mean per-cell stddev of PQ-luma (consistency: ~0 => pure color map)
    float maxStd;        // worst per-cell stddev of PQ-luma
};

// Rebuild the dense LUT from the accumulated cells. outRGBA16F must hold N*N*N*4 halfs and is
// laid out x-fastest (idx = (z*N + y)*N + x), matching MTLTexture replaceRegion. Cells with
// count < minCount are holes and get filled by iterative averaging of measured/filled neighbours.
// If NO cell is measured, outRGBA16F is left untouched (measuredCells == 0).
GradStats grading_rebuild(const GradCell* cells, int N, uint32_t minCount, uint16_t* outRGBA16F);

// Halve all sums and counts (exponential forgetting -> adapts to area/grading changes).
void grading_decay(GradCell* cells, int N);

// IEEE 754 float -> half (round to nearest even) and half -> float
uint16_t grading_float_to_half(float f);
float grading_half_to_float(uint16_t h);
