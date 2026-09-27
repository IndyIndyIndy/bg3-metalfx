// The annotated default config.toml, written on first launch (see load_config in config.cpp).
static const char* const kConfigTemplate = R"CFGTOML(# ============================================================================
#  BG3MetalFX - configuration
# ============================================================================
# This mod replaces Baldur's Gate 3's FSR 1.0 upscaler with MetalFX Temporal
# and can add MetalFX frame interpolation on top. It changes nothing in the
# game's files, it only hooks Metal at runtime.
#
# HOW TO EDIT: change a value, save. Most settings apply within a second while
# the game is running, so you can compare things live. Settings marked
# [RESTART] are read once at launch.
#
# Lines starting with '#' are comments. Delete any line to fall back to its
# built-in default, and every default is written out below as the active value.
#
# The settings that matter for playing: mode, render_scale, sharpness, and the
# FRAME INTERPOLATION section.

# ============================================================================
#  THE BASICS
# ============================================================================

# Which upscaler runs. Switch this live to compare.
#   metalfx  MetalFX Temporal (this mod)
#   fsr      BG3's own FSR 1.0, untouched, with the mod out of the way
#   none     passthrough as well, and for native resolution also turn FSR off in
#            BG3's graphics options
mode = "metalfx"

# [RESTART] The resolution BG3 renders at before upscaling. Lower = faster and
# softer. This writes BG3's own FSR1Mode setting, so the game really runs at
# that step and its menu agrees (a one-time backup of graphicSettings.lsx is
# kept next to it). Percentages are per axis, and pixel counts are for a 3024x1964
# display:
#   ultra_quality  77%   2328x1512   1.30x
#   quality        67%   2016x1309   1.50x
#   balanced       59%   1778x1155   1.70x
#   performance    50%   1512x982    2.00x
#   auto                 leave whatever BG3's graphics menu is set to
# At the same input resolution FSR 1.0 is cheaper than MetalFX Temporal, and the
# gain comes from running MetalFX at a lower step with equal or better image
# quality. BG3's TAA must stay on: MetalFX reads the pass right before it.
render_scale = "auto"

# Post-upscale sharpening, 0 = off. MetalFX has no sharpening of its own,
# while FSR 1.0 looks crisp because of its RCAS pass, so a MetalFX image can
# read as softer at first glance even when it carries more real detail.
# 0.15 is a moderate default, 0.3 matches RCAS. BG3's own sharpness slider
# does nothing in metalfx mode (it only feeds FSR's RCAS pass).
sharpness = 0.15

# ============================================================================
#  COLOUR
# ============================================================================
# BG3 grades and tonemaps its image in several steps. MetalFX is fed the sharp
# picture from BEFORE those steps, so they are reproduced: the tonemap runs
# natively (BG3 tonemaps our image itself), the render-resolution grading is
# learned as a 3D lookup table from BG3's own input/output pairs and applied to
# our image. All three are on by default and cost about 0.7 ms together.

# Learn BG3's colour grading and apply it. Self-calibrating per area, and a
# measurement whose pairs disagree is discarded instead of applied.
grading_harvest = true
grading_apply = true

# Add BG3's bloom as a separate layer (bloomed scene minus pre-bloom scene).
# Without this, bright highlights lose their glow.
grading_bloom = true

# ============================================================================
#  FRAME INTERPOLATION
# ============================================================================
# MetalFX frame interpolation shows one generated image between two rendered
# frames. The mod takes over the presentation for that: BG3 renders into the
# mod's textures, a display-link presenter shows interpolated and real images
# in turn. Tested operating point: frame_cap = 30 on a 60 or 120 Hz display
# gives a steady 60 presented fps from 30 rendered ones.
#
# Requirements: BG3's own frame limiter OFF (the mod caps), TAA ON, and VSync ON
# (triple buffered): the display-link presenter paces to the display's refresh, so
# with VSync off the frames are not refresh-synced, the picture flickers black and
# the frame rate drops. The HUD, text and cursor are not interpolated (see fi_ui),
# so they stay sharp.

# [RESTART] Turn frame interpolation on.
frame_interp = false

# The mod's frame limiter (0 = off). Frame interpolation presents TWICE the base
# rate, so frame_cap must be at most HALF the display's refresh: 30 on a 60 Hz
# display (the tested sweet spot), 60 on a 120 Hz display. Setting it higher than
# half (e.g. 40 on 60 Hz, which asks for 80 Hz) cannot be presented and stutters.
# For frame_cap = 40 you need a 120 Hz display (set it in BG3's graphics settings)
# and hardware that holds a steady 40 fps everywhere at your graphics settings.
# Belongs to frame interpolation: without it the mod does not cap (BG3 presents
# its own frames, and capping those judders), use BG3's own frame limiter then.
frame_cap = 0

# [RESTART] Keep the screen-space UI out of the interpolation: the world is interpolated
# without the HUD and the frame's own UI layer is put back on both images.
# false interpolates the finished frame, and the HUD warps with the world.
fi_ui = true

# ============================================================================
#  ON-SCREEN INFORMATION
# ============================================================================

# [RESTART] Apple's Metal Performance HUD: frame rate, frame time, per-encoder
# GPU times, memory, and a MetalFX section with input/target resolution and the
# frame interpolator's state. Works in every mode.
metal_hud = false

# Where it sits, one of Metal's MTL_HUD_ALIGNMENT tokens: topleft / topcenter /
# topright / centerleft / centered / centerright / bottomleft / bottomcenter /
# bottomright. Empty = Apple's default.
metal_hud_position = ""

# Size and opacity. 0 = leave Apple's default alone.
metal_hud_scale = 0
metal_hud_opacity = 0

# Break the GPU time down per encoder type (vertex / fragment / compute / blit).
metal_hud_encoder_timing = false

# Add a power-draw graph.
metal_hud_energy = false

# Draw a reference line at this frame rate in the graphs. 0 = none.
metal_hud_target_fps = 0

# Which rows to show, comma-separated. Empty = Apple's default set. Names:
# fpsgraph, frameinterval, frameintervalgraph, frameintervalhistogram,
# framenumber, gputime, gputimeline, cmdbufgputimeline, metalcpu, metalfx,
# memory, presenttime, presenttimegraph, presentdelay, presenthistogram,
# refreshrate, thermal, energy, deviceinfo, processinfo.
metal_hud_elements = ""

# ============================================================================
#  PERFORMANCE
# ============================================================================
# Only change if you know, what you are doing.

# [RESTART] Where MetalFX is encoded. Two paths, same picture:
#   separate  our own command buffer, committed before the game's. MetalFX sees
#             the previous frame's snapshot, so the world is one frame late on
#             screen, and in return Metal overlaps our work with the next frame and
#             while testing, this path was consistently about 1.25 ms per frame faster.
#             Default.
#   event     a second GPU queue synchronised with events: no world latency,
#             those 1.25 ms slower. If the picture ever freezes while sound
#             keeps playing, the log says EVENT WATCH and the mod falls back to
#             separate on its own.
encode_path = "separate"

# With MetalFX doing the upscale, BG3's FSR compute is suppressed, and that
# leaves BG3's FSR_* passes computing an image nobody reads. This skips them.
skip_fsr_tonemap = true

# ============================================================================
#  IMAGE STABILITY
# ============================================================================
# Reach for these if the picture shimmers or ghosts. The defaults tested best.

# Force a MetalFX history reset every N frames (0 = off). Diagnostic: the picture
# softens on every reset and sharpens again as the history rebuilds, which shows
# how many frames MetalFX needs to converge.
mfx_reset_period = 0

# Texture detail. BG3 picks texture mip levels for the render resolution, so at
# 2.0x the output shows half-resolution texture detail. The standard remedy is a
# mip bias of log2(input/output): -1.0 at 2.0x, -0.58 at 1.5x. BG3 streams its
# world textures through Granite virtual texturing, which picks the mip in the
# shader, so the bias is applied to Granite's LOD factor (vt_mip_bias), and the
# sampler bias (mip_bias) reaches the remaining material samplers.
vt_mip_bias_auto = true
vt_mip_bias = 0.0
mip_bias = 0.0

# Colour fine-tuning of the graded image. 1.0 = off for all of them.
# chroma_saturation scales the distance from grey (try 1.05, then 1.10 if
# textured surfaces read flatter than in vanilla), and the gains are per channel
# and applied last.
chroma_saturation = 1.0
chroma_gain_r = 1.0
chroma_gain_g = 1.0
chroma_gain_b = 1.0

# Constant exposure for the temporal scaler's history (0 = none). MetalFX
# multiplies the input colour by this before rectifying its history, and the
# natural value is 1 / mean feed luminance.
mfx_exposure_value = 0.0

# ============================================================================
#  LOGGING
# ============================================================================

# Master switch for ~/Library/Logs/BG3MetalFX.log. Off: one banner line per
# run plus errors. On: the periodic reports (every 600 frames) and the
# diagnostics below, several hundred lines per minute.
logging = false

# Log the attachment layout of every distinct render pass once (needs logging).
log_passes = false

# ============================================================================
#  DIAGNOSTICS AND TECHNICAL SETTINGS
# ============================================================================
# Development tools and internals. All fine to leave alone.

# [RESTART] Arm a GPU capture. Metal's capture layer is switched on at launch,
# but nothing is recorded until you hold Ctrl+Shift+C in game. Each press
# writes ~/Desktop/BG3_capture.gputrace (then -2, -3, ...). Open them in Xcode.
# Costs performance while armed, so switch it off afterwards.
gpu_capture = false

# How many frames a capture spans.
gpu_capture_frames = 5

# Frame interpolation internals.
#   fi_motion_key   which frame's depth/motion the interpolator pairs with the
#                   world image. auto (default) follows encode_path. current /
#                   previous force it, and it is switchable live for A/B tests.
#   virtual_swapchain  [RESTART] BG3 renders into the mod's textures and the mod
#                   presents. Turned on by frame_interp, and alone it is a passthrough
#                   presenter.
fi_motion_key = "auto"
virtual_swapchain = false

# Which image MetalFX reconstructs from. pre_taa (default): the sharp image
# before BG3's TAA, most detail, but with the per-frame noise BG3 renders on
# purpose (SSR, SSAO, dithered transparency). post_taa: BG3's resolved image,
# softer but free of that noise.
mfx_input = "pre_taa"

# [RESTART] Apple's MetalFX exposure overlay. Covers the image while on.
mfx_exposure_tool = false

# How BG3's motion vectors map onto MetalFX: BG3's velocity is in render
# pixels, the unit MetalFX wants, and -1 flips the direction as MetalFX's convention
# requires.
mv_scale_x = -1.0
mv_scale_y = -1.0

# Suppress FSR but do not write our image: shows what BG3's final pass
# produces on its own.
bypass_composite = false
)CFGTOML";
