# Changelog

## 1.0.0

First release.

- MetalFX Temporal replaces BG3's FSR 1.0 upscale, and the result goes to BG3's own tonemap and display
  grading, the render-resolution colour grading and the bloom are reproduced from the game's own passes.
- MetalFX frame interpolation over a virtual swapchain with a display-link presenter, and the HUD stays out of
  the interpolation. Tested at a 30 fps base on 60 and 120 Hz displays.
- Granite virtual-texture mip bias and a sampler mip bias for sharper textures at the higher output
  resolution.
- Annotated `config.toml` written on first launch, re-read while the game runs.
- Requires an Apple Silicon Mac with macOS 26 or newer and the BG3 Mod Loader.
