#!/bin/sh
set -eu
cd "$(dirname "$0")"

OUT_DIR="../sidecars/status"
mkdir -p "$OUT_DIR"

if [ "$(uname -s)" != Darwin ]; then
  echo "agy-notch is macOS-only; skipping."
  exit 0
fi

build_dir=$(mktemp -d "${TMPDIR:-/tmp}/agy-notch-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
ARCH="$(uname -m)"
swiftc \
  -O \
  -module-cache-path "${SWIFT_MODULE_CACHE_PATH:-$build_dir/cache}" \
  -target "${ARCH}-apple-macosx13.0" \
  Sources/StatusModel.swift \
  Sources/NotchView.swift \
  Sources/NotchWindow.swift \
  Sources/main.swift \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -o "$OUT_DIR/agy-notch.new"

codesign --force --sign - --identifier io.github.2fa0.agy-notch "$OUT_DIR/agy-notch.new"
mv -f "$OUT_DIR/agy-notch.new" "$OUT_DIR/agy-notch"
chmod 755 "$OUT_DIR/agy-notch"
echo "Built $OUT_DIR/agy-notch"
