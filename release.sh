#!/bin/bash
# Build a distributable release of BG3 MetalFX: the BG3MetalFX/ mod folder (mod.toml plus the built,
# ad-hoc-signed dylib) staged and zipped, ready to attach to a GitHub release.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

./pack.sh                                   # builds and ad-hoc-signs build/bg3metalfx.dylib
VERSION="$(cat VERSION)"

STAGE="dist/BG3MetalFX"                      # folder name must match the mod's config folder (BG3MetalFX)
rm -rf dist
mkdir -p "$STAGE"
cp build/bg3metalfx.dylib "$STAGE/bg3metalfx.dylib"
cp mod.toml "$STAGE/mod.toml"
( cd dist && zip -r -X "BG3MetalFX-v$VERSION.zip" BG3MetalFX >/dev/null )

echo "Staged:  $STAGE/  (bg3metalfx.dylib + mod.toml)"
echo "Archive: dist/BG3MetalFX-v$VERSION.zip  ->  attach to the GitHub release tagged v$VERSION"
echo "         unzips into ~/Library/Application Support/BG3Mods/"
