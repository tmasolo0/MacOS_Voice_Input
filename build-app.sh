#!/bin/bash
set -e

APP_NAME="Solo STT"
BUNDLE_ID="com.solo.stt"
EXECUTABLE="Solo_STT"
BUILD_DIR=".build/release"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "Building release..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

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
    <string>1.1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
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
if security find-identity -p codesigning 2>/dev/null | grep -q "Solo STT Dev"; then
    codesign --force --sign "Solo STT Dev" --deep "$APP_DIR"
else
    echo "Certificate 'Solo STT Dev' not found, signing ad-hoc..."
    codesign --force --sign - --deep "$APP_DIR"
fi

INSTALL_DIR="/Applications/$APP_NAME.app"
echo "Installing to $INSTALL_DIR..."
pkill -9 -f "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"

echo "Done: $INSTALL_DIR"
echo "Run: open \"$INSTALL_DIR\""
