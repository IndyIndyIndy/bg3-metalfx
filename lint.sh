#!/bin/bash
# lint.sh: static checks without building. Exit code 1 if anything fails.
#   1. clang with the strict warning set, warnings are errors (the same flags pack.sh builds with)
#   2. the Clang static analyzer over the whole translation unit (MRC retain/release, nil, dead stores)
#   3. the shell scripts parse
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
fail=0
step() { printf '\n== %s\n' "$1"; }

# Same toolchain as pack.sh, see the comment there: compiler and SDK have to come from the same
# install, or the macOS 27 headers are missing.
CLT=/Library/Developer/CommandLineTools
if [ -x "$CLT/usr/bin/clang++" ] && [ -d "$CLT/SDKs/MacOSX.sdk" ]; then
    CXX="$CLT/usr/bin/clang++"
    FLAGS="-isysroot $CLT/SDKs/MacOSX.sdk"
else
    CXX="$(xcrun -f clang++)"
    FLAGS="-isysroot $(xcrun --show-sdk-path)"
fi
FLAGS="$FLAGS -arch arm64 -std=c++17 -mmacosx-version-min=26.0"
WARN="-Wall -Wextra -Wshadow -Wno-unused-parameter -Wimplicit-fallthrough -Werror"
SRC="src/interposer.mm src/config.cpp src/grading.cpp"

step "compiler warnings"
"$CXX" $FLAGS $WARN -fsyntax-only $SRC || fail=1

step "static analyzer"
# unix.Errno is off: it flags every fclose after a failed call even where errno is never read.
out=$("$CXX" $FLAGS --analyze -Xanalyzer -analyzer-output=text \
      -Xanalyzer -analyzer-disable-checker -Xanalyzer unix.Errno $SRC 2>&1)
if printf '%s' "$out" | grep -q "warning:"; then printf '%s\n' "$out" | grep -A3 "warning:"; fail=1; else echo "clean"; fi

step "shell"
# One call per file: `bash -n a b c` parses only a and turns the rest into positional parameters.
for s in pack.sh lint.sh release.sh; do bash -n "$s" || fail=1; done

printf '\n'
if [ $fail -eq 0 ]; then echo "lint: OK"; else echo "lint: FAILED"; fi
exit $fail
