#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-release}"
[[ "$mode" == release || "$mode" == debug ]] || exit 2
# Build both architectures for Intel Mac minis and Apple Silicon.
for arch in arm64 x86_64; do
    swift build -c "$mode" --arch "$arch"
done
app="$PWD/dist/Mac Power Schedule.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for product in PowerSchedule PowerScheduler; do
    /usr/bin/lipo -create ".build/arm64-apple-macosx/$mode/$product" ".build/x86_64-apple-macosx/$mode/$product" -output "$app/Contents/MacOS/$product"
done
cp scripts/install.sh "$app/Contents/Resources/install.sh"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>de.wiwaltill.MacPowerSchedule.app</string>
<key>CFBundleName</key><string>Mac Power Schedule</string>
<key>CFBundleExecutable</key><string>PowerSchedule</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
identity="${CODESIGN_IDENTITY:--}"
codesign --force --options runtime --sign "$identity" "$app/Contents/MacOS/PowerScheduler"
codesign --force --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/Mac-Power-Schedule.zip"
printf 'App: %s\n' "$app"
