# Making releases

Two repositories, released independently: **bg3-mod-loader** ships the launcher app, **bg3-metalfx**
ships the mod. Both artifacts are ad-hoc signed, which is all that is needed to inject the mod. The
loader is one of three ways to start the game with the mod, the other two being a Steam launch option
and a Terminal line, so a release has to work without it as well. See the README.

Building needs the Xcode Command Line Tools on macOS (`xcode-select --install`). 

## The mod

1. Edit `VERSION` and add the entry to `CHANGELOG.md`. `VERSION` is the single source, `pack.sh`
   compiles it into the log banner and `release.sh` names the zip after it, and the git tag has to match
   it, so that a bug report names its own build.
2. `./release.sh` writes `dist/BG3MetalFX-v1.0.1.zip`, holding the `BG3MetalFX/` folder with
   `bg3metalfx.dylib` and `mod.toml`.
3. Test it, see below.
4. Commit, tag `v1.0.1`, push, then draft a GitHub release for that tag and attach the zip.

## The loader

`./release.sh` in `../bg3-mod-loader` writes `dist/BG3-Mod-Launcher.zip`, then draft a release and
attach it. Only needed when the loader itself changes.

The app is not notarized, so the first open asks for a right-click. That prompt goes away with a
Developer ID and notarization, and nothing else here depends on it.

## Test before publishing

Install from the zip rather than from `build/`, so the test covers what actually ships:

```bash
unzip -o dist/BG3MetalFX-v*.zip -d ~/Library/Application\ Support/BG3Mods/
```

Launch and check that `~/Library/Logs/BG3MetalFX.log` opens with `=== BG3MetalFX RUN START`, and that
the `STATUS` line a few hundred presents later reports MetalFX as active. Worth doing through the loader
and through at least one of the other two start options, since only the loader forces arm64.

Once per release, install from a browser download rather than from `dist/`, so the files carry the
quarantine attribute macOS puts on anything that came off the network. A local build never has it, which
makes it the only difference between the two.

## Release notes

State the requirements every time: Apple Silicon, macOS 26 or newer, and BG3 launched through the
loader.
