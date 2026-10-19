#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

# Keep compiler/SwiftPM caches in the project so restricted build environments work.
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$project_root/.build/swiftpm-cache" \
    "$project_root/.build/swiftpm-config" "$project_root/.build/swiftpm-security"
for architecture in x86_64 arm64; do
    swift build --disable-sandbox \
        --cache-path "$project_root/.build/swiftpm-cache" \
        --config-path "$project_root/.build/swiftpm-config" \
        --security-path "$project_root/.build/swiftpm-security" \
        -c release --arch "$architecture" -j 2
done

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/doubao-voice-bridge.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT

stage_app="$stage_root/远控听写 Fn.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$project_root/Resources/Info.plist" "$stage_app/Contents/Info.plist"

lipo -create \
    "$project_root/.build/x86_64-apple-macosx/release/DoubaoVoiceBridge" \
    "$project_root/.build/arm64-apple-macosx/release/DoubaoVoiceBridge" \
    -output "$stage_app/Contents/MacOS/DoubaoVoiceBridge"
chmod 755 "$stage_app/Contents/MacOS/DoubaoVoiceBridge"

codesign --force --sign - \
    --identifier com.lyp.DoubaoVoiceBridge.Fn \
    --requirements '=designated => identifier "com.lyp.DoubaoVoiceBridge.Fn"' \
    "$stage_app"

mkdir -p "$project_root/dist"
output_app="$project_root/dist/远控听写 Fn.app"
if [[ -e "$output_app" ]]; then
    rm -rf "$output_app"
fi
ditto "$stage_app" "$output_app"

plutil -lint "$output_app/Contents/Info.plist"
codesign --verify --deep --strict --all-architectures "$output_app"
lipo "$output_app/Contents/MacOS/DoubaoVoiceBridge" -verify_arch arm64 x86_64
file "$output_app/Contents/MacOS/DoubaoVoiceBridge"
"$output_app/Contents/MacOS/DoubaoVoiceBridge" --logic-self-test
if [[ "${BRIDGE_RUN_GUI_SELF_TESTS:-0}" == "1" ]]; then
    "$output_app/Contents/MacOS/DoubaoVoiceBridge" --self-test
fi
print "Built: $output_app"
