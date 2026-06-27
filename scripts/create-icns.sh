#!/bin/bash
#
# create-icns.sh - Create .icns file from a source PNG image
#
# Usage: ./scripts/create-icns.sh <source-png> <output-icns>
#
# Example:
#   ./scripts/create-icns.sh Sources/Media.xcassets/AppIcon.appiconset/ClaudeBar.png AppIcon.icns
#

set -e

SOURCE_PNG="$1"
OUTPUT_ICNS="$2"

if [ -z "$SOURCE_PNG" ] || [ -z "$OUTPUT_ICNS" ]; then
    echo "Usage: $0 <source-png> <output-icns>"
    echo ""
    echo "Creates a macOS .icns file from a source PNG (should be 1024x1024)"
    exit 1
fi

if [ ! -f "$SOURCE_PNG" ]; then
    echo "ERROR: Source file not found: $SOURCE_PNG"
    exit 1
fi

# Create temporary iconset directory
ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET_DIR"

echo "Creating icon sizes from $SOURCE_PNG..."

# Generate all required sizes
sips -z 16 16     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16.png"      > /dev/null
sips -z 32 32     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png"   > /dev/null
sips -z 32 32     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32.png"      > /dev/null
sips -z 64 64     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png"   > /dev/null
sips -z 128 128   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128.png"    > /dev/null
sips -z 256 256   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256.png"    > /dev/null
sips -z 512 512   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512.png"    > /dev/null
sips -z 1024 1024 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null

# Convert iconset to icns
echo "Converting to .icns..."
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

# Cleanup
rm -rf "$(dirname "$ICONSET_DIR")"

echo "Created: $OUTPUT_ICNS"
ls -lh "$OUTPUT_ICNS"
