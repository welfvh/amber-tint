#!/bin/bash
# Build Amber Tint — single-file Swift → .app bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Amber Tint"
APP_DIR="$SCRIPT_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"

echo "Building Amber Tint..."

# Compile
swiftc "$SCRIPT_DIR/amber-tint.swift" \
    -o "/tmp/amber-tint" \
    -O \
    -parse-as-library \
    -framework CoreGraphics \
    -framework AppKit \
    -framework SwiftUI

# Assemble .app bundle
rm -rf "$APP_DIR"
mkdir -p "$MACOS"
cp /tmp/amber-tint "$MACOS/amber-tint"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"

# Ad-hoc sign for local dev
codesign -s - --force "$APP_DIR"

echo "Built: $APP_DIR"

# Also build a standalone gamma reset utility
cat > /tmp/reset-gamma.swift << 'EOF'
import CoreGraphics
CGDisplayRestoreColorSyncSettings()
print("Gamma restored.")
EOF
swiftc /tmp/reset-gamma.swift -o "$SCRIPT_DIR/reset-gamma" -framework CoreGraphics
echo "Built: $SCRIPT_DIR/reset-gamma"
