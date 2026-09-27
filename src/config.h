#pragma once
#include <string>
#include <cstddef>

// Runtime configuration of the BG3 MetalFX mod. Lives at $BG3MODS_HOME/BG3MetalFX/config.toml
// (default ~/Library/Application Support/BG3Mods/BG3MetalFX/config.toml) and is re-read while the
// game runs whenever the file's modification time changes.
enum { ENC_SEPARATE = 0, ENC_EVENT = 2 };   // Config::encode_path
struct Config {
    // basics
    int mode;           // 0 = metalfx (our path), 1 = fsr (BG3 untouched), 2 = none (passthrough)
    int render_scale;   // BG3's FSR1Mode written at launch:
                        // -1 leave alone
                        // 0 ultra quality
                        // 1 quality
                        // 2 balanced
                        // 3 performance)
    float sharpness;    // post-upscale sharpening in the LUT apply, 0 = off; 0.15 default

    // colour (native tonemap injection)
    bool grading_harvest;      // learn BG3's colour grading (ord50) as a 3D LUT from input/output pairs
    bool grading_apply;        // apply that LUT to the MetalFX output before it is handed to BG3's tonemap
    bool grading_bloom;        // add BG3's bloom layer (post-ord49 minus TAA-out, upscaled) before the LUT
    float chroma_saturation;   // scales the distance from luma in the LUT apply, 1.0 = off
    float chroma_gain_r, chroma_gain_g, chroma_gain_b;   // per-channel gain applied last, 1.0 = off
    float mfx_exposure_value;   // constant written to a 1x1 exposure texture for the temporal scaler (0 = none)

    // Metal HUD (launch-time environment variables for libMTLHud)
    bool metal_hud;
    char hud_position[24];     // MTL_HUD_ALIGNMENT ("" = leave the HUD's default)
    float hud_scale;           // MTL_HUD_SCALE (0 = default)
    float hud_opacity;         // MTL_HUD_OPACITY (0 = default)
    char hud_elements[256];    // MTL_HUD_ELEMENTS ("" = default)
    bool hud_encoder_timing;   // MTL_HUD_ENCODER_TIMING_ENABLED
    bool hud_energy;           // MTL_HUD_ENERGY_REPORT_ENABLED
    int hud_target_fps;        // MTL_HUD_TARGET_FPS (0 = default)

    // MetalFX temporal scaler
    int encode_path;       // [launch] ENC_SEPARATE: our command buffer on BG3's queue, committed before BG3's frame
                           //     buffer. MetalFX reads the previous frame's snapshot, so the world lags one
                           //     frame, because Metal overlaps our work with BG3's next early passes. Measured the
                           //     fastest (1.25 ms per frame ahead of the zero-latency path).
                           // ENC_EVENT: second queue plus two MTLSharedEvents, same-frame inputs, no world
                           //     latency, at that 1.25 ms. A stalled GPU wait is broken from the CPU by
                           //     the watchdog and the run falls back to separate.
    int mfx_input;         // 0 = pre_taa: the sharp image before BG3's TAA (default).
                           // 1 = post_taa: BG3's resolved image, softer but free of the per-frame noise TAA averages away.
    float mv_scale_x, mv_scale_y;   // motionVectorScale. BG3's velocity is in render pixels, the unit MetalFX
                                    // wants, and -1 flips the direction as MetalFX's convention requires.
    int mfx_reset_period;           // force a history reset every N frames (0 = off); shows the convergence curve
    float mip_bias;                 // lodBias on BG3's material samplers (0 = off); macOS 26+
    float vt_mip_bias;              // mip bias for Granite virtual textures, applied by scaling the tileset's LOD
                                    // factor (a sampler bias cannot reach it), and log2(inW/outW) is the natural value
    bool vt_mip_bias_auto;          // derive vt_mip_bias from the live render scale (overrides vt_mip_bias)


    // frame interpolation
    bool frame_interp;        // [launch] MTLFXFrameInterpolator: one interpolated image between two BG3 frames.
                              // Implies virtual_swapchain and two images per frame
    int frame_cap;            // our frame limiter (0 = off), waits at the start of each frame so BG3's base
                              // rate sits on the cap. Interpolation presents 2 x base and needs that below
                              // the display's refresh, and 30 -> 60 is the tested operating point. Active only
                              // with the virtual swapchain (its display link presents in step with the cap).
    bool fi_ui;               // [launch] interpolate the HUD-free world and re-compose the frame's own UI layer on
                              // both presented images (default true). false interpolates the finished frame.
    bool virtual_swapchain;   // [launch] BG3 renders into our ring textures behind proxy drawables and we present.
                              // The foundation of frame interpolation, and on its own a passthrough presenter
    int fi_motion_key;        // which chain's depth/motion/jitter pairs with the world image: 2 = auto
                              // (derived from encode_path: separate = previous chain, event = own chain),
                              // 1 = current, 0 = previous. Live-switchable for A/B tests.

    // pass suppression
    bool skip_fsr_tonemap;   // swallow BG3's FSR_* render passes in metalfx mode (their consumer, FSR's compute dispatch, is suppressed)
    bool bypass_composite;   // suppress FSR but do not write our image (shows what ord52 reads on its own)

    // logging and diagnostics
    bool logging;       // master switch: false writes only the run banner and errors
    bool log_passes;    // log every distinct render-pass layout (needs logging)
    bool gpu_capture;   // The Xcode GPU capture; Ctrl+Shift+C records gpu_capture_frames presents
    int gpu_capture_frames;
    bool mfx_exposure_tool;   // MTLFX_EXPOSURE_TOOL_ENABLED at launch (Apple's exposure overlay)
};

Config config_defaults();

// Keys the last config parse did not recognise, comma-separated ("" when all were known). The
// interposer names them once per distinct set, so a typo is not silently a default.
extern char g_cfgUnknown[512];

// BG3 derives its render resolution from FSR1Mode in
// ~/Documents/Larian Studios/Baldur's Gate 3/graphicSettings.lsx.
//
// Measured on a 3024x1964 target:
// 0 = Ultra Quality (77%)
// 1 = Quality (66.7%, 2016x1309)
// 2 = Balanced (58.8%, 1778x1155)
// 3 = Performance (50%, 1512x982, exactly 2.0x per axis)
//
// Changes only the value attribute that belongs to `key`, while everything else stays byte for byte.
// Returns false if the key or its value attribute is not found. `oldValue` recieves the previous value.
bool lsx_set_int_setting(std::string& xml, const char* key, int value, int* oldValue);

// Reads graphicSettings.lsx, sets FSR1Mode, writes it back (keeping a one-time .bg3metalfx-backup).
// Returns 1 = changed, 0 = already correct, -1 = failed. `detail` (>= 256 bytes) gets a summary.
int bg3_force_fsr1_mode(int mode, char* detail, size_t detailLen);

// Parses `key = value` lines ('#' comments), overwriting only the keys present.
void config_parse_string(const char* text, Config& cfg);

// Loads config.toml (creating the annotated template if absent).
Config load_config();

// True when config.toml changed since the previous call (mtime), so the poll thread re-reads only then.
bool config_file_changed();
