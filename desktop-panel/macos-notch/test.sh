#!/bin/sh
set -eu
cd "$(dirname "$0")"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/agy-notch-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -module-cache-path "${SWIFT_MODULE_CACHE_PATH:-$test_dir/cache}" \
  Sources/StatusModel.swift Tests/main.swift \
  -framework AppKit -framework Combine -o "$test_dir/tests"
"$test_dir/tests"
