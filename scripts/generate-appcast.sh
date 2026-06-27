#!/bin/bash
# Generate Sparkle Appcast
#
# This script generates an appcast.xml file for Sparkle auto-updates.
# It's designed to be run from GitHub Actions during the release process.
#
# Usage: ./scripts/generate-appcast.sh <archive.zip> <version> <download_url>
#
# Environment variables:
#   SPARKLE_EDDSA_PRIVATE_KEY - The EdDSA private key for signing
#
# Example:
#   SPARKLE_EDDSA_PRIVATE_KEY="..." ./scripts/generate-appcast.sh \
#     ClaudeBar-1.0.0.zip 1.0.0 https://github.com/.../ClaudeBar-1.0.0.zip

set -e

if [ $# -lt 3 ]; then
    echo "Usage: $0 <archive.zip> <version> <download_url>"
    exit 1
fi

ARCHIVE="$1"
VERSION="$2"
DOWNLOAD_URL="$3"

if [ ! -f "$ARCHIVE" ]; then
    echo "Error: Archive not found: $ARCHIVE"
    exit 1
fi

if [ -z "$SPARKLE_EDDSA_PRIVATE_KEY" ]; then
    echo "Error: SPARKLE_EDDSA_PRIVATE_KEY environment variable not set"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Find Sparkle's sign_update tool
SIGN_UPDATE=""
for path in \
    "$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
    "$PROJECT_ROOT/.build/checkouts/Sparkle/bin/sign_update" \
    "$PROJECT_ROOT/.build/checkouts/Sparkle/sign_update"
do
    if [ -x "$path" ]; then
        SIGN_UPDATE="$path"
        break
    fi
done

if [ -z "$SIGN_UPDATE" ]; then
    echo "Error: sign_update not found. Run 'swift build' first."
    exit 1
fi

echo "Signing archive: $ARCHIVE"

# Get file size
FILE_SIZE=$(stat -f%z "$ARCHIVE" 2>/dev/null || stat -c%s "$ARCHIVE" 2>/dev/null)

# Sign the archive and get the EdDSA signature
# sign_update reads the private key from stdin
SIGNATURE=$("$SIGN_UPDATE" "$ARCHIVE" --ed-key-file <(echo "$SPARKLE_EDDSA_PRIVATE_KEY") 2>/dev/null || \
            echo "$SPARKLE_EDDSA_PRIVATE_KEY" | "$SIGN_UPDATE" "$ARCHIVE" -s - 2>/dev/null)

if [ -z "$SIGNATURE" ]; then
    echo "Error: Failed to sign archive"
    exit 1
fi

# Extract just the signature part (format: sparkle:edSignature="..." length="...")
ED_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'edSignature="[^"]*"' | sed 's/edSignature="//;s/"//')

if [ -z "$ED_SIGNATURE" ]; then
    # Try alternate output format
    ED_SIGNATURE="$SIGNATURE"
fi

echo "Signature: $ED_SIGNATURE"

# Get current date in RFC 2822 format
PUB_DATE=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")

# Generate appcast.xml
APPCAST_FILE="${PROJECT_ROOT}/appcast.xml"

cat > "$APPCAST_FILE" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>ClaudeBar Updates</title>
    <link>https://tddworks.github.io/claudebar/appcast.xml</link>
    <description>Most recent updates for ClaudeBar</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure
        url="${DOWNLOAD_URL}"
        sparkle:edSignature="${ED_SIGNATURE}"
        length="${FILE_SIZE}"
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>
EOF

echo "Generated appcast.xml at $APPCAST_FILE"
echo ""
echo "Contents:"
cat "$APPCAST_FILE"
