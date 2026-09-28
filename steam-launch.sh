#!/bin/bash
# Steam launch-option wrapper for BG3 MetalFX.
#
# macOS Steam does not run launch options through a shell (like in linux). It splits them on whitespace, execs the first
# token and passes whatever %command% expanded to as the next argument, so a `VAR=value %command%` prefix
# fails with "OS Error 260". This script takes that first slot instead and receives the game's .app
# bundle in $1.
#
# Copy it somewhere without spaces in the path, because Steam splits on those:
#
#     cp steam-launch.sh ~/bg3metalfx-steam.sh
#
# then set the launch options in Steam to:
#
#     /Users/YOURNAME/bg3metalfx-steam.sh %command%
set -eu

APP="${1:?no app bundle passed by Steam}"
shift

MODS="${BG3MODS_HOME:-$HOME/Library/Application Support/BG3Mods}"
DYLIB="$MODS/BG3MetalFX/bg3metalfx.dylib"

EXE="$(defaults read "$APP/Contents/Info" CFBundleExecutable 2>/dev/null || echo "Baldur's Gate 3")"
BIN="$APP/Contents/MacOS/$EXE"

[ -x "$BIN" ] || { echo "steam-launch: no executable at $BIN" >&2; exit 1; }

# Without the mod the game still has to start, or a failed install looks like a broken game.
[ -f "$DYLIB" ] || { echo "steam-launch: no dylib at $DYLIB, starting unmodded" >&2; exec "$BIN" "$@"; }

# arch -arm64 because the game is universal and the mod is arm64 only. env has to come after arch, since
# macOS strips DYLD_INSERT_LIBRARIES when it starts a system binary like arch. exec, so Steam keeps
# seeing one process and playtime and the overlay still work.
exec arch -arm64 env DYLD_INSERT_LIBRARIES="$DYLIB" "$BIN" "$@"
