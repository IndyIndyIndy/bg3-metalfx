# Making releases

The release is one zip with the `BG3MetalFX/` folder. The dylib is ad-hoc signed, which is all that is
needed to inject it, and the game starts with it through a Steam launch option or a Terminal line, see
the README.

Building needs the Xcode Command Line Tools on macOS (`xcode-select --install`).

## The mod

1. Edit `VERSION` and add the entry to `../CHANGELOG.md`. `VERSION` is the single source, `../pack.sh`
   compiles it into the log banner and `../release.sh` names the zip after it, and the git tag has to match
   it, so that a bug report names its own build.
2. `../release.sh` writes `dist/BG3MetalFX-v1.0.1.zip`, holding the `BG3MetalFX/` folder with
   `bg3metalfx.dylib`, `mod.toml` and `steam-launch.sh`.
3. Test it, see below.
4. Commit, tag `v1.0.1`, push, then draft a GitHub release for that tag and attach the zip.

## Test before publishing

Install from the zip rather than from `../build`, so the test covers what actually ships:

```bash
unzip -o dist/BG3MetalFX-v*.zip -d ~/Library/Application\ Support/BG3Mods/
```

Launch and check that `~/Library/Logs/BG3MetalFX.log` opens with `=== BG3MetalFX RUN START`, and that
the `STATUS` line a few hundred presents later reports MetalFX as active. Worth doing through both
start options, since they build the launch line differently.

Once per release, install from a browser download rather than from `dist/`, so the files carry the
quarantine attribute macOS puts on anything that came off the network. A local build never has it, which
makes it the only difference between the two.

## Release notes

State the requirements every time: Apple Silicon, macOS 26 or newer, and BG3 started through the
Steam launch option or the Terminal.
