#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-release}"
version="${APP_VERSION:-$(cat VERSION)}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Ungültige VERSION" >&2; exit 2; }
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
./scripts/build-icon.sh "$app/Contents/Resources/AppIcon.icns"
cp scripts/cleanup-user.sh "$app/Contents/Resources/cleanup-user.sh"
cp scripts/uninstall.sh "$app/Contents/Resources/uninstall.sh"
cp scripts/install.sh "$app/Contents/Resources/install.sh"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>de.wiwaltill.MacPowerSchedule.app</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleName</key><string>Mac Power Schedule</string>
<key>CFBundleExecutable</key><string>PowerSchedule</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
identity="${CODESIGN_IDENTITY:--}"
sign_flags=(--timestamp=none)
if [[ "$identity" != "-" ]]; then sign_flags=(--timestamp); fi
codesign --force --options runtime "${sign_flags[@]}" --sign "$identity" "$app/Contents/MacOS/PowerScheduler"
codesign --force --options runtime "${sign_flags[@]}" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/Mac-Power-Schedule.zip"
(cd dist && shasum -a 256 Mac-Power-Schedule.zip > SHA256SUMS.txt)
printf 'App: %s\n' "$app"
