#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
build_dir="$project_dir/.build"
app_name="DoubaoHeadsetBridge"
stage_dir="$build_dir/app-stage"
stage_app="$stage_dir/$app_name.app"
app_dir="$project_dir/dist/$app_name.app"

# Build into a clean staging bundle, leaving the previous output usable if
# compilation fails. No compiler cache is written into the user's home folder.
rm -rf -- "$stage_dir"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources" "$build_dir/tmp"
export TMPDIR="$build_dir/tmp/"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
architectures=(arm64 x86_64)
executables=()
sources=(
  "$project_dir/Sources/MappingCore.swift"
  "$project_dir/Sources/AudioRoute.swift"
  "$project_dir/Sources/HeadsetCapture.swift"
  "$project_dir/Sources/main.swift"
)

for arch in "${architectures[@]}"; do
  arch_dir="$build_dir/$arch"
  mkdir -p "$arch_dir/module-cache"
  export CLANG_MODULE_CACHE_PATH="$arch_dir/module-cache"
  xcrun --sdk macosx swiftc -O -sdk "$sdk_path" -target "$arch-apple-macos12.0" \
    -module-cache-path "$arch_dir/module-cache" "${sources[@]}" \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics \
    -framework CoreAudio -framework IOKit -o "$arch_dir/$app_name"
  executables+=("$arch_dir/$app_name")
done

xcrun lipo -create "${executables[@]}" -output "$stage_app/Contents/MacOS/$app_name"
cp "$project_dir/Info.plist" "$stage_app/Contents/Info.plist"
/usr/bin/plutil -lint "$stage_app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier local.doubao.HeadsetBridge "$stage_app"
/usr/bin/codesign --verify --deep --strict --all-architectures --verbose=2 "$stage_app"
xcrun lipo "$stage_app/Contents/MacOS/$app_name" -verify_arch arm64 x86_64

mkdir -p "$project_dir/dist"
rm -rf -- "$app_dir"
mv "$stage_app" "$app_dir"
printf '已生成（arm64 / x86_64，本地临时签名）：%s\n' "$app_dir"
