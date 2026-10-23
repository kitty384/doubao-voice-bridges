#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
build_dir="$project_dir/.build/event-tests"
mkdir -p "$build_dir/module-cache" "$build_dir/tmp"
export TMPDIR="$build_dir/tmp/"
xcrun --sdk macosx swiftc -module-cache-path "$build_dir/module-cache" \
  "$project_dir/Sources/FnPulseEvents.swift" "$project_dir/Tests/FnPulseEventsTests.swift" \
  -framework CoreGraphics -o "$build_dir/fn-event-tests"
"$build_dir/fn-event-tests"
