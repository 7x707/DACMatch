#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/outputs/DAC Match.app"
contents_dir="$app_dir/Contents"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$project_dir"
mkdir -p "$project_dir/work/clang-cache" "$project_dir/work/swiftpm-cache"
DEVELOPER_DIR="$developer_dir" \
CLANG_MODULE_CACHE_PATH="$project_dir/work/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/work/swiftpm-cache" \
swift build -c release --disable-sandbox

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp ".build/release/DACMatch" "$contents_dir/MacOS/DACMatch"
cp "Resources/Info.plist" "$contents_dir/Info.plist"
cp "Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
cp -R "Resources/zh-Hans.lproj" "$contents_dir/Resources/zh-Hans.lproj"
cp -R "Resources/zh-Hant.lproj" "$contents_dir/Resources/zh-Hant.lproj"
cp -R "Resources/en.lproj" "$contents_dir/Resources/en.lproj"
chmod +x "$contents_dir/MacOS/DACMatch"

codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
