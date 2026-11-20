#!/bin/sh
set -eu
cd "$(dirname "$0")"
# backend.zig embeds VERSION, but @embedFile cannot reach outside its own
# package root, so mirror the canonical root file next to the source.
cp ../VERSION VERSION
build_tmp=$(mktemp -d "${TMPDIR:-/tmp}/agy-desktop-backend.XXXXXX")
obj="$build_tmp/backend.o"
bin="$build_tmp/backend"
trap 'rm -rf "$build_tmp"' EXIT
"${ZIG:-zig}" build-obj backend.zig -O ReleaseSafe -lc -fcompiler-rt -fstrip -femit-bin="$obj"
"${CC:-cc}" "$obj" -lsqlite3 -o "$bin"
if [ "$(uname -s)" = Darwin ]; then
  codesign --force --sign - --identifier io.github.2fa0.agy-desktop-status "$bin"
fi
install -m 755 "$bin" sidecars/status/agy-desktop-backend.new
mv -f sidecars/status/agy-desktop-backend.new sidecars/status/agy-desktop-backend
