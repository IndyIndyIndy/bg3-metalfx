# How it works

## The short version

Baldur's Gate 3 with FSR 1.0 renders the world at a reduced resolution and enlarges it with a sharpening
filter that only ever sees one picture at a time. This mod sits between the game and the graphics
driver, watches the drawing commands go past, and swaps FSR 1.0 for Apple's MetalFX Temporal, which
combines many consecutive frames instead. That gives a sharper picture from fewer rendered pixels, which
is where the performance comes from. On top of that the mod can take over the presentation and let
MetalFX generate an extra image between every two rendered frames, turning 30 rendered frames per second
into 60 shown ones.

## Jitter and temporal accumulation

Every frame the game shifts its camera by a fraction of a pixel in a fixed pattern. That is called
jitter, and the game does it for its own anti-aliasing (TAA), because averaging slightly different sub-pixel
positions smooths edges. A temporal upscaler uses the same trick for a different purpose: eight frames
at half resolution, each seeing the scene from a slightly different offset, together hold more detail
than one frame at half resolution. MetalFX keeps a running history, moves it along with the game's
motion vectors so it lines up with the new frame, and fills the missing pixels from it.

This is why TAA has to stay on. The jitter and the motion vectors only exist because of it, and without
them MetalFX has nothing to accumulate.

## Hooking into a closed game

The game is closed off, with no plugin interface and no way to add a render pass. Every texture, every
shader and every draw still goes through macOS' Metal API, though, and a library loaded into the process
can replace Metal's functions with its own. The mod is such a library, injected at launch through
`DYLD_INSERT_LIBRARIES`, either by a Steam launch option or via Terminal line.

The game does not label its passes, so the mod tells them apart by fingerprint: the shader function
names it can read off the pipeline objects, the pixel formats and sizes of the attached textures, and the
order they appear in a frame. The TAA pass, the motion-vector pass, the depth buffer, the grading, the
bloom and the UI composite were each located this way, partly by disassembling the game's compiled
shaders to confirm what a pass reads and writes.

The MetalFX output goes into the texture, FSR would have written, and the game then tonemaps and grades
it with its own passes exactly as it would have graded FSR's, which keeps the colours (almost) right without 
the mod having to imitate any of those passes.

## Reproducing the game's colour steps

Two of the game's colour steps run before the point where the mod injects its image, so they are missing
from it and have to be reproduced.

- **Colour grading** is learned at runtime. The mod snapshots the game's own input and output of the
  grading pass and fits a 3D lookup table to the pairs, then applies that table to its own image. The
  table is relearned per area, and a measurement whose pairs disagree is thrown away instead of applied.
  No colour values are hard-coded.
- **Bloom** is recovered as a layer, because the game's bloomed scene minus its pre-bloom scene is the
  glow, and that glow is added back on top.

Together they cost about 0.7 ms per frame.

The motion vectors come from the game's TAA, in its own units and sign convention, which the mod derived
from the game's camera matrices. Most engines leave the camera jitter inside their motion vectors and let 
the upscaler remove it, but BG3 computes velocity from un-jittered positions, so its vectors are already 
clean. 

## Performance

MetalFX Temporal at the same input resolution is more expensive than FSR 1.0, because it does far more
work per pixel. The gain comes from running it at a lower resolution step with equal or better image
quality, and the tested operating point is the game's "performance" step (50 % per axis) against FSR 1.0
at "quality" (67 %), which results in 44 % fewer rendered pixels.

Only the pixel work shrinks with the resolution, meaning lighting, shading and the post-processing
chain, and that is where the savings sit, whereas meshes, draw calls and the CPU side of the frame cost
the same either way. The gain is therefore biggest where pixel work dominates, in crowded scenes at high
presets, and narrows in menus and quiet corners.

Measured on a MacBook Pro with M4 Pro at 3024×1964 and Ultra settings: about 11 % more fps and 20 % less
GPU time than FSR 1.0 at Quality, at equal or better image quality. The lower GPU load per frame also
means less heat, so thermal throttling sets in later in a long session, and the frame times should come
out more even.

### Tuning

- **`sharpness`.** MetalFX has no sharpening of its own while FSR 1.0 always runs a sharpening pass, so
  at first glance the MetalFX image can look softer even when it carries more real detail. How much to
  add back is a matter of taste, `0` is closest to the unmodded look, `0.15` a moderate lift, and `0.3`
  roughly matches FSR's own sharpening. BG3's in-game sharpness slider does nothing in metalfx mode, 
  because it only feeds the FSR pass, that the mod replaces.
- **Graphics settings.** The mod only lowers the render resolution. At the same render resolution the
  game's own quality settings between Ultra and Low are worth about 23 % of the frame time, several times
  more than anything left to gain inside the mod, so for fps the graphics menu matters more.
- **`encode_path`.** On the default path the mod encodes MetalFX in its own command buffer and lets the
  GPU overlap it with the game's next frame, which saves about 1.25 ms per frame, roughly 8 % fps, and
  leaves the world on screen one frame old while the HUD is current. The `event` path synchronises the
  two with GPU events, has no world latency, and costs those 1.25 ms. Both produce the same picture.

## Frame interpolation

The game renders every frame as before, and the mod inserts one generated image between each pair, so
a 30 fps base becomes 30 rendered plus 30 generated images => 60 shown.

MetalFX can generate that in-between image from two rendered frames and their depth and motion. The game
presents whenever it likes, however, and has no slot in its loop for an extra image, so the mod takes
the presentation away from it:

1. When the game asks the display for something to render into, the mod hands it a stand-in whose
   texture is one of eight ring textures the mod owns.
2. The game's present call is swallowed, and the finished frame together with its depth, motion and
   camera data is queued for the mod's presenter.
3. A `CAMetalDisplayLink` ticks at twice the frame cap, so 60 Hz for a 30 fps base, and on every tick it
   takes one real drawable and shows either a freshly interpolated image or the real frame, alternating.
   If no new frame has arrived by the next tick, it shows the last real frame again, which is what
   happens wherever the game cannot hold the frame cap.
4. A frame limiter inside the mod holds the game at the base rate, so the ticks and the rendered frames
   stay in step.

The HUD is not interpolated, because the mod snapshots the world before the game draws its UI on top,
hands only the world to the interpolator and puts the frame's own UI layer back on both images, so text
and cursor stay sharp instead of warping with the camera. And the interpolator has to get the matching
depth and motion, since on the default encode path the world in a frame is one frame old and its motion
data has to be one frame old too, which the mod derives from `encode_path`.

Interpolation costs about 3 ms of GPU time per generated image at 3024×1964. It also adds latency,
because the image between two frames can only be made once the second one is finished, so every real
frame reaches the screen one display tick later than it would without interpolation, about 17 ms at
60 Hz on top of the latency of the 30 fps base. The interpolator's history is reset at scene cuts such as
loading screens and menu transitions, and after a dropped frame whose motion it never saw, so the two
frames it blends always belong together.

## Limits

- TAA must be on.
- Frame interpolation is tested at a 30 fps base on 60 and 120 Hz display mode. A 60 fps base on 120 Hz 
  only works where the game holds 60 fps with interpolation on. At Ultra on an M4 Pro it did not, the 
  game then rendered at about 36 fps in the test scenes, the presenter then repeats frames and the pacing 
  turns uneven.
- Frame interpolation sits on top of MetalFX Temporal, so if something looks wrong with it on, turn it
  off first to see which of the two it is.
- The game window has to be the display's size. In a smaller window BG3 keeps its render targets and
  draws into a viewport, the snapshot no longer matches, and MetalFX stands down.
- Pass detection depends on the game's shaders and texture layouts. A game update can change them, and
  the mod then falls back to the game's own FSR and says so in the log rather than drawing garbage.
- Variable refresh rate (ProMotion) pacing is not tested.
