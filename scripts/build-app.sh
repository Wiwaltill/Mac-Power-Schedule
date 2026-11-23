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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
sparkle="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Sparkle-LICENSE.txt"
public_key="$(cat assets/sparkle-public-key.txt)"
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
<key>SUFeedURL</key><string>https://github.com/Wiwaltill/Mac-Power-Schedule/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>$public_key</string>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
identity="${CODESIGN_IDENTITY:--}"
sign_flags=(--timestamp=none)
if [[ "$identity" != "-" ]]; then sign_flags=(--timestamp); fi
framework="$app/Contents/Frameworks/Sparkle.framework"
for nested in Versions/B/XPCServices/Downloader.xpc Versions/B/XPCServices/Installer.xpc Versions/B/Updater.app Versions/B/Autoupdate; do
    codesign --force --options runtime "${sign_flags[@]}" --preserve-metadata=entitlements --sign "$identity" "$framework/$nested"
done
codesign --force --options runtime "${sign_flags[@]}" --sign "$identity" "$framework"
codesign --force --options runtime "${sign_flags[@]}" --sign "$identity" "$app/Contents/MacOS/PowerScheduler"
codesign --force --options runtime "${sign_flags[@]}" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/Mac-Power-Schedule.zip"
(cd dist && shasum -a 256 Mac-Power-Schedule.zip > SHA256SUMS.txt)
printf 'App: %s\n' "$app"
