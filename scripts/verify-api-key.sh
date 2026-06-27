#!/bin/bash
#
# verify-api-key.sh - Verify an App Store Connect API key (.p8) is valid
#
# Usage: ./scripts/verify-api-key.sh <path-to-p8>
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

P8_FILE="$1"

if [ -z "$P8_FILE" ]; then
    echo "Usage: $0 <path-to-p8>"
    echo ""
    echo "Example: $0 AuthKey_ABC123.p8"
    exit 1
fi

if [ ! -f "$P8_FILE" ]; then
    echo -e "${RED}ERROR: File not found: $P8_FILE${NC}"
    exit 1
fi

echo "========================================"
echo "  API Key (.p8) Verification Tool"
echo "========================================"
echo ""
echo "File: $P8_FILE"
echo "Size: $(ls -lh "$P8_FILE" | awk '{print $5}')"
echo ""

echo "--- Checking file format ---"

# Check first line
FIRST_LINE=$(head -1 "$P8_FILE")
if [ "$FIRST_LINE" != "-----BEGIN PRIVATE KEY-----" ]; then
    echo -e "${RED}FAIL: File does not start with '-----BEGIN PRIVATE KEY-----'${NC}"
    echo ""
    echo "First line is: $FIRST_LINE"
    echo ""
    echo "This is not a valid .p8 file."
    exit 1
fi
echo -e "${GREEN}PASS: Starts with '-----BEGIN PRIVATE KEY-----'${NC}"

# Check last line
LAST_LINE=$(tail -1 "$P8_FILE")
if [ "$LAST_LINE" != "-----END PRIVATE KEY-----" ]; then
    echo -e "${RED}FAIL: File does not end with '-----END PRIVATE KEY-----'${NC}"
    echo ""
    echo "Last line is: $LAST_LINE"
    exit 1
fi
echo -e "${GREEN}PASS: Ends with '-----END PRIVATE KEY-----'${NC}"

# Check line count (should be around 6-8 lines)
LINE_COUNT=$(wc -l < "$P8_FILE" | tr -d ' ')
if [ "$LINE_COUNT" -lt 3 ]; then
    echo -e "${RED}FAIL: File too short ($LINE_COUNT lines)${NC}"
    exit 1
fi
echo -e "${GREEN}PASS: File has $LINE_COUNT lines${NC}"

# Try to read it as a private key
echo ""
echo "--- Checking key validity ---"

if openssl ec -in "$P8_FILE" -noout 2>/dev/null; then
    echo -e "${GREEN}PASS: Valid EC private key${NC}"
else
    echo -e "${YELLOW}WARNING: Could not verify key type (may still work)${NC}"
fi

# Extract Key ID from filename
echo ""
echo "--- Extracting Key ID ---"

FILENAME=$(basename "$P8_FILE")
if [[ "$FILENAME" =~ AuthKey_([A-Z0-9]+)\.p8 ]]; then
    KEY_ID="${BASH_REMATCH[1]}"
    echo -e "${GREEN}Key ID from filename: $KEY_ID${NC}"
else
    echo -e "${YELLOW}Could not extract Key ID from filename${NC}"
    echo "Expected format: AuthKey_XXXXXXXXXX.p8"
fi

# Summary
echo ""
echo "========================================"
echo "  Summary"
echo "========================================"
echo -e "${GREEN}SUCCESS: API key file appears valid${NC}"
echo ""
echo "To use with GitHub Actions:"
echo "  base64 -i \"$P8_FILE\" | tr -d '\\n' | pbcopy"
echo ""
echo "Then add these secrets to GitHub:"
echo "  APP_STORE_CONNECT_API_KEY_P8  = the base64 string"
if [ -n "$KEY_ID" ]; then
echo "  APP_STORE_CONNECT_KEY_ID      = $KEY_ID"
else
echo "  APP_STORE_CONNECT_KEY_ID      = <from App Store Connect>"
fi
echo "  APP_STORE_CONNECT_ISSUER_ID   = <from App Store Connect>"
