#!/bin/bash
# Builds a universal Flick.app by hand (no Xcode) and zips it as Flick.zip.
# Usage: Scripts/build_app.sh [version]
#   version defaults to the latest git tag (without leading "v"), else 0.1.0.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Flick"
BUNDLE_ID="com.example.flick"
ICON_SRC="Resources/icon_1024.png"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
fi
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-parse --short HEAD 2>/dev/null || echo 0)"

echo "==> Building universal binary ($APP_NAME $VERSION+$BUILD_NUMBER)"
# `--arch` would route SwiftPM to XCBuild (requires Xcode); build per-triple
# with the native build system instead and merge with lipo.
swift build -c release --triple arm64-apple-macosx
swift build -c release --triple x86_64-apple-macosx
ARM_BIN=".build/arm64-apple-macosx/release/$APP_NAME"
X86_BIN=".build/x86_64-apple-macosx/release/$APP_NAME"
for bin in "$ARM_BIN" "$X86_BIN"; do
    if [ ! -f "$bin" ]; then
        echo "error: expected binary at $bin" >&2
        exit 1
    fi
done

APP="$APP_NAME.app"
echo "==> Assembling $APP"
rm -rf "$APP" "$APP_NAME.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/$APP_NAME"

ICON_ENTRY=""
if [ -f "$ICON_SRC" ]; then
    echo "==> Generating AppIcon.icns"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    # iconutil requires the classic iconset naming convention.
    for spec in "16 16" "32 16@2x" "32 32" "64 32@2x" "128 128" "256 128@2x" "256 256" "512 256@2x" "512 512" "1024 512@2x"; do
        size="${spec%% *}"
        name="${spec##* }"
        sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${name}.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
    ICON_ENTRY="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
"
else
    echo "==> No $ICON_SRC found, skipping icon"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
                <string>public.camera-raw-image</string>
                <string>public.jpeg</string>
                <string>public.png</string>
                <string>com.compuserve.gif</string>
                <string>public.heic</string>
                <string>public.heif</string>
                <string>public.tiff</string>
                <string>public.bmp</string>
                <string>org.webmproject.webp</string>
                <string>com.microsoft.ico</string>
                <string>com.adobe.raw-image</string>
            </array>
        </dict>
    </array>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
${ICON_ENTRY}    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> Creating $APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$APP_NAME.zip"

echo "==> Done: $APP and $APP_NAME.zip"
