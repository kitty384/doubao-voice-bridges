#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$project_root/.build/swiftpm-cache" \
    "$project_root/.build/swiftpm-config" "$project_root/.build/swiftpm-security"
swift build --disable-sandbox \
    --cache-path "$project_root/.build/swiftpm-cache" \
    --config-path "$project_root/.build/swiftpm-config" \
    --security-path "$project_root/.build/swiftpm-security" \
    -c debug -j 2
binary="$(swift build --disable-sandbox --show-bin-path -c debug)"/DoubaoVoiceBridge
"$binary" --logic-self-test
if [[ "${BRIDGE_RUN_GUI_SELF_TESTS:-0}" == "1" ]]; then
    "$binary" --self-test
fi
