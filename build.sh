#!/bin/bash
set -e

echo "🚀 Starting AuraLink Build Process..."

# Clean previous build
rm -rf AuraLink AuraLink.app

# Get the macOS SDK Path
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)
echo "📦 Using macOS SDK: $SDK_PATH"

# Compile Swift code
echo "⚙️ Compiling Swift source..."
swiftc main.swift \
  -parse-as-library \
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

# Make executable
chmod +x AuraLink.app/Contents/MacOS/AuraLink

echo "🔏 Applying Apple Silicon ad-hoc code signature..."
codesign --force --deep --sign - AuraLink.app

echo "📦 Packaging AuraLink into AuraLink.zip..."
rm -f AuraLink.zip
zip -q -r AuraLink.zip AuraLink.app

echo "✅ Build Completed Successfully! Created AuraLink.app and AuraLink.zip"
