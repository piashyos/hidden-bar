#!/bin/sh
# Собирает build/HiddenBar.app: release-бинарь + Info.plist + иконка (AppIcon.icon → Assets.car и .icns)
set -e
cd "$(dirname "$0")"
swift build -c release
APP="$PWD/build/HiddenBar.app" # абсолютный: actool разрешает относительные пути от cwd своего демона
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/HiddenBar" "$APP/Contents/MacOS/"
xcrun actool "$PWD/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$PWD/build/icon.plist" \
    --output-format human-readable-text
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>HiddenBar</string>
    <key>CFBundleIdentifier</key><string>local.hiddenbar</string>
    <key>CFBundleName</key><string>HiddenBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# постоянная подпись: разрешение «Универсальный доступ» переживает пересборку (ad hoc меняется каждый раз)
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"
echo "$APP"
