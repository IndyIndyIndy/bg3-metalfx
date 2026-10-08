# Reporting a problem

The same symptom can have several causes, and usually only the log tells them apart, so a description on
its own is rarely enough to act on.

## First checks

For visual glitches, two switches in `config.toml` show which part the problem comes from:

1. `frame_interp = false`. If the problem stays it belongs to the upscaler, if it goes away it belongs to
   the interpolation layer.
2. `mode = "fsr"`. If the problem stays it is the game's, not the mod's.

Both results go into the report, since they narrow the cause down to one part of the mod.
Note the in-game settings as well, especially TAA, because the mod needs it on to work.

## Turn the log on

Set `logging = true`, reproduce the problem for about a minute so the periodic reports are written
(they appear every 600 presented frames), quit the game, and copy `~/Library/Logs/BG3MetalFX.log`. Turn
`logging` off again afterwards, the file can grow very fast.

Send the whole file rather than excerpts, because the run banner and the counters around an event are
what make it readable.

## What to attach

- the log
- `config.toml` from `~/Library/Application Support/BG3Mods/BG3MetalFX/` (or under `$BG3MODS_HOME` if that is set)
- a screenshot, or a short recording for anything that moves. Shake and double edges show up best on a
  slow camera pan along a building edge.
- the filled-in template

## Template

```
Symptom:
Happens with frame_interp = false:  yes / no
Happens with mode = "fsr":          yes / no
Scene / save:
When (start, load, menu return, camera move, ...):
Frequency (every time, sometimes, once):

Mac / chip:
macOS:
Display (res, Hz, ProMotion, internal/external):
BG3 version:
Window mode (fullscreen, borderless, windowed):
In-game: TAA on/off, FSR step, frame limiter, VSync, preset:
```
