#!/bin/bash
set -e

DIST_MODE=false
if [[ "$1" == "--dist" ]]; then
    DIST_MODE=true
fi

APP_NAME="Solo STT"
BUNDLE_ID="com.solo.stt"
EXECUTABLE="Solo_STT"
BUILD_DIR=".build/release"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

echo "Building release..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "Resources/silero_vad.mlmodelc" "$APP_DIR/Contents/Resources/silero_vad.mlmodelc"

cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Solo STT</string>
    <key>CFBundleDisplayName</key>
    <string>Solo STT</string>
    <key>CFBundleIdentifier</key>
    <string>com.solo.stt</string>
    <key>CFBundleVersion</key>
    <string>2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundleExecutable</key>
    <string>Solo_STT</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Solo STT needs microphone access for speech recognition.</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Signing app..."
if $DIST_MODE; then
    echo "Dist mode: ad-hoc signing for distribution..."
    codesign --force --sign - --deep "$APP_DIR"
else
    if security find-identity -p codesigning 2>/dev/null | grep -q "Solo STT Dev"; then
        codesign --force --sign "Solo STT Dev" --deep "$APP_DIR"
    else
        echo "Certificate 'Solo STT Dev' not found, signing ad-hoc..."
        codesign --force --sign - --deep "$APP_DIR"
    fi
fi

if $DIST_MODE; then
    echo "Creating DMG..."
    rm -f "$DMG_PATH"
    DMG_STAGE="$BUILD_DIR/dmg_stage"
    rm -rf "$DMG_STAGE"
    mkdir -p "$DMG_STAGE"
    cp -R "$APP_DIR" "$DMG_STAGE/"
    ln -s /Applications "$DMG_STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH"
    rm -rf "$DMG_STAGE"
    xattr -cr "$DMG_PATH"
    echo ""
    echo "=== Dist build ready ==="
    echo "DMG: $DMG_PATH"
    echo ""
    echo "На другом компе если не открывается:"
    echo "  xattr -cr /path/to/Solo\\ STT.app"
    echo "  или: правый клик → Открыть"
else
    INSTALL_DIR="/Applications/$APP_NAME.app"
    echo "Installing to $INSTALL_DIR..."
    pkill -9 -f "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    rm -rf "$INSTALL_DIR"
    cp -R "$APP_DIR" "$INSTALL_DIR"
    echo "Done: $INSTALL_DIR"
    echo "Run: open \"$INSTALL_DIR\""
fi
