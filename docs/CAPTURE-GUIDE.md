# Taking a GPU capture

Advanced, for development and debugging only. Nothing here is needed to play the mod or to report a
problem with it, `docs/BUG-REPORTS.md` covers that. A GPU capture shows which BG3 passes run, what they
cost and who reads their output, none of which the mod can measure on its own.

Config: `gpu_capture = true`, `gpu_capture_frames = 5` and `metal_hud = false`, the last one so the HUD
overlay does not end up in the capture.

1. Start the game and load the scene to measure.
2. Hold Ctrl+Shift+C.
3. This produces `~/Desktop/BG3_capture.gputrace`
4. Double-click opens the file in Xcode (if Xcode is installed).

This mods own encoders carry their names, starting with `BG3MFX`.
Examples:
`BG3MFX snapshot: colour+depth+motion -> our copies`, `BG3MFX composite: grade+bloom -> FSR-out`,
`BG3MFX out: MetalFX result (target res)`, `BG3MFX target: BG3's FSR-out`.
