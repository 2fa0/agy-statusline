#!/bin/sh
set -eu
cd "$(dirname "$0")"
obj=$(mktemp "${TMPDIR:-/tmp}/agy-statusline.XXXXXX.o")
bin=$(mktemp "${TMPDIR:-/tmp}/agy-statusline.XXXXXX")
trap 'rm -f "$obj" "$bin"' EXIT
"${ZIG:-zig}" build-obj main.zig -O ReleaseFast -lc -fcompiler-rt -femit-bin="$obj"
clang "$obj" -lsqlite3 -o "$bin"
install -m 755 "$bin" ./agy-statusline.new
mv -f ./agy-statusline.new ./agy-statusline
