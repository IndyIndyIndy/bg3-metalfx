#!/bin/bash
# pack.sh:           build build/bg3metalfx.dylib
# pack.sh --install: build, then install dylib + mod.toml into $BG3MODS_HOME/BG3MetalFX
#
# Loaded the same way as the other mods (dropped into the BG3Mods folder, injected via
# DYLD_INSERT_LIBRARIES by the loader). Not compiled with ARC on purpose; see interposer.mm.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

mkdir -p build
VERSION="$(cat VERSION)"   # one source for the version: the log banner, the release zip and the git tag
# Toolchain, compiler and SDK together. Two are installed here and they must not be mixed: only the
# Command Line Tools SDK carries the macOS 27 headers this code needs behind its @available checks
# (requiresPrevColorTexture), while Xcode's linker cannot parse that SDK's .tbd stubs and fails with
# "tapi error: malformed file, unknown architecture arm64e.x1". So build with the CLT clang against the
# CLT SDK, and fall back to xcrun where the CLT are not installed.
CLT=/Library/Developer/CommandLineTools
if [ -x "$CLT/usr/bin/clang++" ] && [ -d "$CLT/SDKs/MacOSX.sdk" ]; then
    CXX="$CLT/usr/bin/clang++"
    SYSROOT="-isysroot $CLT/SDKs/MacOSX.sdk"
else
    CXX="$(xcrun -f clang++)"
    SYSROOT="-isysroot $(xcrun --show-sdk-path)"
fi
# -mmacosx-version-min=26.0: without it the dylib inherits the SDK's minimum (27.0 here) and dyld
# refuses to load it on macOS 26 before a line of our code runs ("built for macOS 27.0 which is newer than running OS").
# Anything newer than 26 in the code sits behind `if (@available(macOS 27.0, *))`.
# Warnings are errors: the same flags lint.sh uses, so a build that passes is lint-clean.
"$CXX" $SYSROOT -arch arm64 -std=c++17 -O2 -Wall -Wextra -Wshadow -Wno-unused-parameter -Wimplicit-fallthrough -Werror \
    -mmacosx-version-min=26.0 -dynamiclib -DBG3MFX_VERSION="\"$VERSION\"" \
    -framework Metal -framework MetalFX -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -o build/bg3metalfx.dylib src/interposer.mm src/config.cpp src/grading.cpp
# Must not be silenced: an unsigned dylib is refused at load time on arm64.
codesign -s - -f build/bg3metalfx.dylib
echo "Built: build/bg3metalfx.dylib (version $VERSION)"

if [ "${1:-}" = "--install" ]; then
    HOME_DIR="${BG3MODS_HOME:-$HOME/Library/Application Support/BG3Mods}"
    DEST="$HOME_DIR/BG3MetalFX"
    mkdir -p "$DEST"
    # Install onto a FRESH INODE (copy + atomic rename), never `cp` over the live file. The kernel
    # caches a code signature per inode, so overwriting in place leaves it pointing at the old cdhash
    # and dyld SIGKILLs the next launch with "CODESIGNING, Code 2, Invalid Page", while the file
    # itself still verifies fine.
    cp build/bg3metalfx.dylib "$DEST/.bg3metalfx.dylib.new"
    mv -f "$DEST/.bg3metalfx.dylib.new" "$DEST/bg3metalfx.dylib"
    cp mod.toml "$DEST/.mod.toml.new" && mv -f "$DEST/.mod.toml.new" "$DEST/mod.toml"
    cp steam-launch.sh "$DEST/.steam-launch.sh.new" && mv -f "$DEST/.steam-launch.sh.new" "$DEST/steam-launch.sh"
    echo "Installed: $DEST"
fi
