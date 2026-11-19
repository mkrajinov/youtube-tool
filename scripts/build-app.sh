#!/usr/bin/env bash
# Builds YouTubeTool.app in the project root from the Swift package.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="YouTubeTool.app"

./scripts/fetch-tools.sh
swift build -c "$CONFIG" --product YouTubeTool
BIN="$(swift build -c "$CONFIG" --show-bin-path)/YouTubeTool"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/YouTubeTool"
for tool in yt-dlp ffmpeg ffprobe deno; do
  cp "vendor/tools/$tool" "$APP/Contents/Helpers/$tool"
done
[[ -f Assets/AppIcon.icns ]] || ./scripts/make-icon.sh
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp vendor/tools/versions.json "$APP/Contents/Resources/tool-versions.json"  # Helpers may only hold code

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>YouTube Tool</string>
  <key>CFBundleDisplayName</key><string>YouTube Tool</string>
  <key>CFBundleIdentifier</key><string>local.youtubetool</string>
  <key>CFBundleExecutable</key><string>YouTubeTool</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signatures, inside-out: helpers first, then the app. No --deep, and no hardened
# runtime (deno's JIT would need extra entitlements under it).
for tool in yt-dlp ffmpeg ffprobe deno; do
  codesign --force --sign - "$APP/Contents/Helpers/$tool"
done
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

# Smoke test: every helper must still run after re-signing.
H="$APP/Contents/Helpers"
echo "yt-dlp  $("$H/yt-dlp" --version)"
echo "ffmpeg  $("$H/ffmpeg" -hide_banner -version | head -1)"
echo "ffprobe $("$H/ffprobe" -hide_banner -version | head -1)"
echo "deno    $("$H/deno" --version | head -1)"
touch "$APP"  # nudge Finder/Dock to pick up a changed icon
echo "Built $(pwd)/$APP ($(du -sh "$APP" | cut -f1))"
