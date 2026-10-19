#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
build_dir="$project_dir/.build/tests"
mkdir -p "$build_dir/module-cache" "$build_dir/tmp"
export TMPDIR="$build_dir/tmp/"
export CLANG_MODULE_CACHE_PATH="$build_dir/module-cache"
# Do not use -Ounchecked: the test suite uses precondition assertions.
xcrun --sdk macosx swiftc -module-cache-path "$build_dir/module-cache" \
  "$project_dir/Sources/MappingCore.swift" "$project_dir/Tests/main.swift" \
  -o "$build_dir/mapping-tests"
"$build_dir/mapping-tests"
