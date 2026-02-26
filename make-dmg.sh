#!/bin/bash
set -e

APP_NAME="Solo STT"
DMG_NAME="Solo_STT"
BUILD_DIR=".build/release"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_DIR="/tmp/dmg_staging"
DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"

# 1. Build app if needed
if [ ! -d "$APP_DIR" ]; then
    echo "App not found, building..."
    bash build-app.sh
fi

# 2. Prepare staging directory
echo "Preparing DMG..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

cat > "$DMG_DIR/Установка.txt" << 'README'
Solo STT — голосовой ввод для macOS
====================================

УСТАНОВКА:
1. Перетащите "Solo STT" в папку "Applications"

ПЕРВЫЙ ЗАПУСК:
1. Правый клик по "Solo STT" → "Открыть" → "Открыть"
   (или в Terminal: xattr -cr "/Applications/Solo STT.app")
2. Дайте разрешения Accessibility и Microphone в System Settings
3. Приложение появится в меню-баре (иконка микрофона)

ИСПОЛЬЗОВАНИЕ:
- Зажмите правый Option — говорите — отпустите
- Текст автоматически вставится в активное приложение
- Клик по иконке в меню-баре → Настройки (модель, язык, микрофон)

ТРЕБОВАНИЯ:
- macOS 15+
- ~1.5 GB для модели (скачивается при первом запуске)
README

# 3. Create DMG
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_DIR"

echo ""
echo "Done: $DMG_PATH"
echo "Size: $(du -h "$DMG_PATH" | cut -f1)"
