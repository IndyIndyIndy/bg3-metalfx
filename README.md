# BG3 MetalFX

Replaces Baldur's Gate 3's upscaler (FSR 1.0) with **MetalFX Temporal**, and can add **MetalFX frame
interpolation** on top. It hooks Metal at runtime, so no game files are modified, and it requires an 
Apple Silicon Mac on macOS 26 or newer. For more details on how it works, you can go to 
`docs/HOW-IT-WORKS.md`.

> **Experimental.** The mod hooks into a closed game at runtime, without any support from Larian, so
> expect bugs, visual glitches and the occasional crash. Reports are welcome, see `docs/BUG-REPORTS.md`.
> Nothing in the game's own files is changed. Deleting the `BG3MetalFX` folder puts everything back the
> way it was.

## Performance

The following settings were all tested in the same scene with every single setting at "Ultra" + TAA active 
on a MacBook Pro with M4 Pro, internal display at 3024×1964 and 60 Hz, measured with the Metal HUD. 

The output is 3024×1964 in every case, the render resolution is what the game draws before upscaling:

| Setting                                | Render resolution | Pixels |  fps | vs native |                      |
|----------------------------------------|-------------------|-------:|-----:|----------:|----------------------|
| Native, no upscaling                   | 3024×1964         | 100 %  |  ~30 |           | ██████               |
| FSR 1.0, Quality                       | 2016×1309         |  44 %  |  ~46 |    ~+50 % | █████████            |
| MetalFX Temporal, Performance          | 1512×982          |  25 %  |  ~51 |    ~+70 % | ██████████           |
| MetalFX Temporal + frame interpolation | 1512×982          |  25 %  | ~102 |   ~+240 % | ████████████████████ |

The percentages are against native. Against the game's own FSR 1.0 at Quality, MetalFX Temporal is about
11 % faster at equal or better image quality, because it starts from a lower render resolution, and with
frame interpolation about twice as fast. The roughly 100 fps with interpolation count every presented image,
about 50 rendered ones and those generated between them, so the input latency stays that of 50 fps.

## Install

Install once, then pick how to start the game. Both start options use the same installed files.

1. Download `BG3MetalFX-vX.Y.Z.zip` from this project's **Releases** page.
2. Unzip it into `~/Library/Application Support/BG3Mods/`, which gives
   `~/Library/Application Support/BG3Mods/BG3MetalFX/` holding `bg3metalfx.dylib`, `mod.toml` and
   `steam-launch.sh`.
3. Start the game one of the two ways below. On the first launch the mod writes its `config.toml`
   next to the dylib. 

To confirm it loaded, open `~/Library/Logs/BG3MetalFX.log`, which should show a `=== BG3MetalFX RUN START`
line. To remove the mod, delete the `BG3MetalFX` folder. To update, replace it with a newer release.

## Starting the game

The mod is a dylib that has to be loaded into the game's process, so the game has to start with
`DYLD_INSERT_LIBRARIES` pointing at it. A Steam launch option or a Terminal line can arrange that.

Only the Steam version is tested. The GOG version most likely works in a similar same way, started 
from the Terminal with `BG3` set to wherever its app bundle lives, but without a GOG copy I was not 
able to test this.

### Through Steam (no Terminal after setup)

`steam-launch.sh` comes with the release for this. Copy it somewhere without spaces in the path, since
Steam splits its launch options on those:

```bash
cp ~/Library/Application\ Support/BG3Mods/BG3MetalFX/steam-launch.sh ~/bg3metalfx-steam.sh
chmod +x ~/bg3metalfx-steam.sh
```

Then in Steam, right-click Baldur's Gate 3, **Properties**, **Launch Options**, and enter the path with
`%command%` after it:

```
/Users/YOURNAME/bg3metalfx-steam.sh %command%
```

Start the game from Steam as usual. The wrapper finds the installed dylib on its own, so a mod update
needs no change here, and it starts the game unmodded rather than failing if the dylib is missing. Clear
the launch options to play without the mod.

### From the Terminal (with steam path as example)

```bash
BG3="$HOME/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3"
MOD="$HOME/Library/Application Support/BG3Mods/BG3MetalFX/bg3metalfx.dylib"
arch -arm64 env DYLD_INSERT_LIBRARIES="$MOD" "$BG3/Baldur's Gate 3.app/Contents/MacOS/Baldur's Gate 3"
```

`arch -arm64` is there because the game ships x86_64 and arm64 in one binary while the mod is arm64
only. `env` has to come after `arch` and not before it, because macOS strips `DYLD_INSERT_LIBRARIES`
when it starts a system binary like `arch`, and `env` then sets it again for the game. The binary inside
the bundle is called directly for the same reason, since `open -a` would drop the variable too.

This starts the game outside Steam's or GOG's launcher.

## Build it yourself

With the Xcode Command Line Tools present (`xcode-select --install`):

```bash
./pack.sh --install     # build, then install the dylib, mod.toml and steam-launch.sh
```

`./release.sh` builds the same thing and produces `dist/BG3MetalFX-vX.Y.Z.zip`, the archive to attach
to a GitHub release. Both install the same three files, so a source install and a downloaded one behave
the same way.

## Configure

Settings live in `$BG3MODS_HOME/BG3MetalFX/config.toml` (default
`~/Library/Application Support/BG3Mods/BG3MetalFX/config.toml`). The file is written on first launch 
and re-read while the game runs: edit, save, and most changes apply within a second. Keys marked 
`[RESTART]` in the file are read at launch.

The most important settings:

| Key            | Meaning                                                                                                                                                               |
|----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `mode`         | `metalfx` (the mod), `fsr` (the game's own upscaler, untouched), `none` (passthrough)                                                                                 |
| `render_scale` | BG3's FSR quality step, written into the game's settings at launch. `performance` (2.0x) is the tested setting, and `auto` leaves the game's setting alone            |
| `sharpness`    | post-upscale sharpening. `0.15` default, `0` off, `0.3` should roughly match FSR's RCAS                                                                               |
| `frame_interp` | MetalFX frame interpolation on. Needs `frame_cap`, and takes about 0.6 GB more memory                                                                                 |
| `frame_cap`    | the mod's frame limiter. For interpolation use at most half the display refresh (`30` on 60 Hz, `60` on 120 Hz), with `30` as the tested base (30 rendered, 60 shown) |
| `fi_ui`        | keep the HUD out of the interpolation (default on)                                                                                                                    |
| `metal_hud`    | Apple's Metal Performance HUD, with its own position, size and element keys                                                                                           |

The rest of the file covers colour reproduction, the encode path, mip bias, chroma fine-tuning, logging
and GPU capture, each key documented where it stands.

## In-game settings

- **TAA must stay on.** The mod recognises a world frame by BG3's TAA pass and MetalFX needs the jitter
  data, that is only available with TAA. With TAA off the game silently runs its own FSR.
- **BG3's frame limiter must be off or match `frame_cap`.** With frame interpolation the mod paces the
  game itself, and a second limiter set to a different rate breaks the pairing of rendered and generated
  frames. (Without it, the frame rate can stutter a lot.)
- **VSync must be on (triple buffered)** with frame interpolation. The mod paces presentation to the
  display's refresh through a display link, and with VSync off the presented frames are not refresh-synced,
  which shows as black flicker and frame-rate drops.
- BG3's FSR *quality* step is the render resolution MetalFX upscales from (`render_scale` writes it). 
  "Performance" is recommended.
- BG3's *sharpness* slider does nothing in metalfx mode, so use `sharpness` in the config instead.

## Known limitations

- **The game window must be the display's size** (fullscreen or a full-size window). A smaller window
  makes BG3 keep its render targets at the old size and draw into a smaller viewport, and MetalFX then
  stands down and the game's FSR renders. The `STATUS` line in the log says PARTIAL when that happens,
  see **Logs and problems**.
- **Frame interpolation needs a base the GPU can hold.** In scenes where a rendered frame takes longer
  than the frame cap allows (heavy Act 3 crowds at Ultra, for example), frames are dropped and the
  interpolator restarts its history, which shows as stutter. Lower graphics settings or a lower
  `frame_cap` are the remedy, and the mod does not throttle the game to the GPU's pace on its own.
- Not tested: `encode_path = "event"` together with frame interpolation, variable refresh rate
  (ProMotion) pacing, external displays other than 60 and 120 Hz.

## Logs and problems

Diagnostics go to `~/Library/Logs/BG3MetalFX.log`. By default a run writes its banner, a `STATUS` line
saying whether MetalFX, the grading and the frame interpolation are active (again whenever that verdict
changes), and errors. To get more report data, use `logging = true`. If something in your game looks wrong,
see `docs/BUG-REPORTS.md` on how to report problems.

## Documentation

- `docs/HOW-IT-WORKS.md`: How the mod works on the technical side.
- `docs/BUG-REPORTS.md`: How to report a problem with the mod.
- `docs/CAPTURE-GUIDE.md`: How to take a GPU capture (for development).
- `docs/RELEASING.md`: How a release is built and published.

## Possible future work

- **MetalFX Spatial as a third mode.**
- **Windowed and borderless play below the display size**
- **A longer jitter sequence.** At 2.0x a temporal upscaler works best with about 32 sub-pixel camera 
  positions before the pattern repeats, and BG3's TAA offers only 8.
- **Test other mac hardware and the gog version**
- **A better test pipeline**

## License

MIT, see `LICENSE`.
