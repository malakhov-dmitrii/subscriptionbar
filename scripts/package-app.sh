#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${TMPDIR:-/tmp}/subscriptionbar-release-build"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/subscriptionbar-clang-cache"
cd "$project_dir"
node "$project_dir/browser-extension/build-firefox.mjs"
swift build -c release --disable-sandbox --scratch-path "$build_dir"
binary_dir="$(swift build -c release --disable-sandbox --scratch-path "$build_dir" --show-bin-path)"
bundle="${SUBSCRIPTIONBAR_BUNDLE_PATH:-$project_dir/dist/SubscriptionBar.app}"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/SubscriptionBar" "$bundle/Contents/MacOS/SubscriptionBar"
cp -R "$binary_dir/SubscriptionBar_SubscriptionCore.bundle" "$bundle/Contents/Resources/"
cp -R "$project_dir/browser-extension" "$bundle/Contents/Resources/"
cp "$project_dir/scripts/install-browser-host.command" "$bundle/Contents/Resources/"
cp "$project_dir/README.md" "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.local.subscriptionbar</string>
<key>CFBundleName</key><string>SubscriptionBar</string>
<key>CFBundleDisplayName</key><string>SubscriptionBar</string>
<key>CFBundleExecutable</key><string>SubscriptionBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>15</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Local personal build</string>
</dict></plist>
PLIST
chmod 755 "$bundle/Contents/MacOS/SubscriptionBar" "$bundle/Contents/Resources/install-browser-host.command"
if [[ "${SUBSCRIPTIONBAR_ADHOC:-0}" == "1" ]]; then
    codesign --force --sign - "$bundle"
else
    # Public certificate fingerprint; override after renewal. Never silently fall
    # back to ad-hoc: that would invalidate the user's saved Keychain trust.
    signing_identity="${SUBSCRIPTIONBAR_SIGNING_IDENTITY:-AFD78FFF19AAFD19596A0BFD41CECFD9E3CE7006}"
    codesign --force --options runtime --timestamp --sign "$signing_identity" "$bundle"
fi
codesign --verify --strict "$bundle"
plutil -lint "$bundle/Contents/Info.plist"
echo "$bundle"
