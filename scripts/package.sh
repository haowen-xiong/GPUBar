#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${GPUBAR_BUILD_DIR:-$project_dir/.build}"
output_dir="${1:-$project_dir/dist}"
mkdir -p "$output_dir"
swift build --package-path "$project_dir" --scratch-path "$build_dir" -c release --product GPUBar \
  -Xswiftc -gnone \
  -Xswiftc -file-prefix-map -Xswiftc "$project_dir=GPUBar" \
  -Xswiftc -file-compilation-dir -Xswiftc .
binary_dir="$(swift build --package-path "$project_dir" --scratch-path "$build_dir" -c release --show-bin-path)"
app_dir="$output_dir/GPUBar.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/GPUBar" "$app_dir/Contents/MacOS/GPUBar"
strip -S "$app_dir/Contents/MacOS/GPUBar"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.haowen.GPUBar</string>
<key>CFBundleName</key><string>GPUBar</string>
<key>CFBundleDisplayName</key><string>GPUBar</string>
<key>CFBundleExecutable</key><string>GPUBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.1</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.haowen.GPUBar "$app_dir"
codesign --verify --strict "$app_dir"
echo "$app_dir"
