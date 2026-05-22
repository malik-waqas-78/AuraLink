#!/bin/bash
set -e

echo "🚀 Starting AuraLink Build Process..."

# Clean previous build
rm -rf AuraLink AuraLink.app

# Get the macOS SDK Path
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/AuraLinkModuleCache"
mkdir -p "$MODULE_CACHE_DIR"
echo "📦 Using macOS SDK: $SDK_PATH"

# Compile Swift code
echo "⚙️ Compiling Swift source..."
swiftc main.swift \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos13.0 \
  -O \
  -framework Cocoa \
  -framework SwiftUI \
  -framework IOBluetooth \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework AVFoundation \
  -framework ServiceManagement \
  -o AuraLink

echo "📂 Creating .app bundle structure..."
mkdir -p AuraLink.app/Contents/MacOS
mkdir -p AuraLink.app/Contents/Resources

# Move binary and Info.plist
mv AuraLink AuraLink.app/Contents/MacOS/AuraLink
cp Info.plist AuraLink.app/Contents/Info.plist

# Copy app logo into Resources for menu bar icon
if [ -f "AuraLinkLogo.png" ]; then
    cp AuraLinkLogo.png AuraLink.app/Contents/Resources/AuraLinkLogo.png
    echo "🎨 Copied AuraLinkLogo.png into app bundle Resources."
    
    # Generate .icns app icon from the logo PNG
    echo "🖼️  Generating macOS app icon (.icns)..."
    ICONSET_DIR="AuraLink.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"
    
    sips -z 16 16     AuraLinkLogo.png --out "$ICONSET_DIR/icon_16x16.png"      > /dev/null 2>&1
    sips -z 32 32     AuraLinkLogo.png --out "$ICONSET_DIR/icon_16x16@2x.png"   > /dev/null 2>&1
    sips -z 32 32     AuraLinkLogo.png --out "$ICONSET_DIR/icon_32x32.png"      > /dev/null 2>&1
    sips -z 64 64     AuraLinkLogo.png --out "$ICONSET_DIR/icon_32x32@2x.png"   > /dev/null 2>&1
    sips -z 128 128   AuraLinkLogo.png --out "$ICONSET_DIR/icon_128x128.png"    > /dev/null 2>&1
    sips -z 256 256   AuraLinkLogo.png --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null 2>&1
    sips -z 256 256   AuraLinkLogo.png --out "$ICONSET_DIR/icon_256x256.png"    > /dev/null 2>&1
    sips -z 512 512   AuraLinkLogo.png --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null 2>&1
    sips -z 512 512   AuraLinkLogo.png --out "$ICONSET_DIR/icon_512x512.png"    > /dev/null 2>&1
    sips -z 1024 1024 AuraLinkLogo.png --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null 2>&1
    
    if iconutil -c icns "$ICONSET_DIR" -o AuraLink.app/Contents/Resources/AppIcon.icns 2> /dev/null; then
        echo "✅ Generated AppIcon.icns in app bundle."
    else
        echo "⚠️ iconutil rejected the generated iconset; falling back to tiff2icns."
        TEMP_ICON_TIFF="${TMPDIR:-/tmp}/AuraLinkLogo.tiff"
        sips -s format tiff AuraLinkLogo.png --out "$TEMP_ICON_TIFF" > /dev/null 2>&1
        tiff2icns "$TEMP_ICON_TIFF" AuraLink.app/Contents/Resources/AppIcon.icns
        rm -f "$TEMP_ICON_TIFF"
        echo "✅ Generated fallback AppIcon.icns in app bundle."
    fi
    rm -rf "$ICONSET_DIR"
fi

# Make executable
chmod +x AuraLink.app/Contents/MacOS/AuraLink

echo "🔏 Applying Apple Silicon ad-hoc code signature..."
codesign --force --deep --sign - AuraLink.app

echo "📦 Packaging AuraLink into AuraLink.zip..."
rm -f AuraLink.zip
zip -q -r AuraLink.zip AuraLink.app

echo "✅ Build Completed Successfully! Created AuraLink.app and AuraLink.zip"
