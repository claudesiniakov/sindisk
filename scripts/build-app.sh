#!/usr/bin/env bash
# Собирает SinDisk.app (arm64) из Swift-пакета и упаковывает в build/SinDisk.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.1.0)}"
APP="build/SinDisk.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SinDisk"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SinDisk"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SinDisk</string>
  <key>CFBundleDisplayName</key><string>SinDisk</string>
  <key>CFBundleIdentifier</key><string>com.claudesiniakov.sindisk</string>
  <key>CFBundleExecutable</key><string>SinDisk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© claudesiniakov</string>
</dict>
</plist>
PLIST

# Ad-hoc подпись (без Developer ID). Для распространения нужна подпись и нотаризация.
codesign --force --deep --options runtime --sign - "$APP"
codesign --verify --verbose "$APP"

ditto -c -k --keepParent "$APP" build/SinDisk.zip
echo "Готово: $APP и build/SinDisk.zip (версия $VERSION)"
