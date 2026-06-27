#!/bin/bash
#
# combine-cert-key.sh - Combine a certificate (.cer) and private key (.p12) into a single .p12
#
# Usage: ./scripts/combine-cert-key.sh <certificate.cer> <privatekey.p12> <output.p12>
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CERT_FILE="$1"
KEY_FILE="$2"
OUTPUT_FILE="$3"

if [ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Usage: $0 <certificate.cer> <privatekey.p12> <output.p12>"
    echo ""
    echo "This script combines a certificate and private key into a single .p12 file"
    echo "that can be used for code signing in GitHub Actions."
    echo ""
    echo "Steps to get the input files from Keychain Access:"
    echo "  1. Export certificate: Select cert -> File -> Export -> .cer format"
    echo "  2. Export private key: Select key -> File -> Export -> .p12 format"
    echo ""
    echo "Example:"
    echo "  $0 cert.cer key.p12 combined.p12"
    exit 1
fi

if [ ! -f "$CERT_FILE" ]; then
    echo -e "${RED}ERROR: Certificate file not found: $CERT_FILE${NC}"
    exit 1
fi

if [ ! -f "$KEY_FILE" ]; then
    echo -e "${RED}ERROR: Key file not found: $KEY_FILE${NC}"
    exit 1
fi

echo "========================================"
echo "  Combine Certificate and Key"
echo "========================================"
echo ""
echo "Certificate: $CERT_FILE"
echo "Private Key: $KEY_FILE"
echo "Output:      $OUTPUT_FILE"
echo ""

# Get password for the existing key.p12
echo -n "Enter password for $KEY_FILE: "
read -s KEY_PASSWORD
echo ""

# Get password for the new combined.p12
echo -n "Enter password for output $OUTPUT_FILE: "
read -s OUTPUT_PASSWORD
echo ""
echo -n "Confirm password: "
read -s OUTPUT_PASSWORD_CONFIRM
echo ""

if [ "$OUTPUT_PASSWORD" != "$OUTPUT_PASSWORD_CONFIRM" ]; then
    echo -e "${RED}ERROR: Passwords do not match${NC}"
    exit 1
fi

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo ""
echo "--- Extracting private key ---"

# Extract private key from the key.p12 (try with -legacy flag for OpenSSL 3.x)
if openssl pkcs12 -in "$KEY_FILE" -passin pass:"$KEY_PASSWORD" -nocerts -nodes -out "$TEMP_DIR/key.pem" 2>/dev/null; then
    echo -e "${GREEN}Extracted private key${NC}"
elif openssl pkcs12 -in "$KEY_FILE" -passin pass:"$KEY_PASSWORD" -legacy -nocerts -nodes -out "$TEMP_DIR/key.pem" 2>/dev/null; then
    echo -e "${GREEN}Extracted private key (using legacy mode for OpenSSL 3.x)${NC}"
else
    echo -e "${RED}ERROR: Failed to extract private key. Wrong password?${NC}"
    exit 1
fi

echo ""
echo "--- Converting certificate ---"

# Try DER format first (most common for .cer from Keychain)
if openssl x509 -in "$CERT_FILE" -inform DER -out "$TEMP_DIR/cert.pem" 2>/dev/null; then
    echo -e "${GREEN}Converted certificate from DER format${NC}"
elif openssl x509 -in "$CERT_FILE" -inform PEM -out "$TEMP_DIR/cert.pem" 2>/dev/null; then
    echo -e "${GREEN}Converted certificate from PEM format${NC}"
else
    echo -e "${RED}ERROR: Failed to read certificate file${NC}"
    exit 1
fi

echo ""
echo "--- Creating combined P12 ---"

# Combine into new P12 (use -legacy for broader compatibility)
if ! openssl pkcs12 -export \
    -out "$OUTPUT_FILE" \
    -inkey "$TEMP_DIR/key.pem" \
    -in "$TEMP_DIR/cert.pem" \
    -legacy \
    -passout pass:"$OUTPUT_PASSWORD" 2>/dev/null; then
    # Fallback without -legacy for older openssl
    if ! openssl pkcs12 -export \
        -out "$OUTPUT_FILE" \
        -inkey "$TEMP_DIR/key.pem" \
        -in "$TEMP_DIR/cert.pem" \
        -passout pass:"$OUTPUT_PASSWORD" 2>/dev/null; then
        echo -e "${RED}ERROR: Failed to create combined P12${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}Created: $OUTPUT_FILE${NC}"

echo ""
echo "--- Verifying combined P12 ---"

# Verify the new P12 (try with -legacy flag for OpenSSL 3.x)
CERT_COUNT=$(openssl pkcs12 -in "$OUTPUT_FILE" -passin pass:"$OUTPUT_PASSWORD" -legacy -nokeys 2>/dev/null | grep -c "BEGIN CERTIFICATE" || \
             openssl pkcs12 -in "$OUTPUT_FILE" -passin pass:"$OUTPUT_PASSWORD" -nokeys 2>/dev/null | grep -c "BEGIN CERTIFICATE" || echo "0")
KEY_COUNT=$(openssl pkcs12 -in "$OUTPUT_FILE" -passin pass:"$OUTPUT_PASSWORD" -legacy -nocerts -nodes 2>/dev/null | grep -c "PRIVATE KEY" || \
            openssl pkcs12 -in "$OUTPUT_FILE" -passin pass:"$OUTPUT_PASSWORD" -nocerts -nodes 2>/dev/null | grep -c "PRIVATE KEY" || echo "0")

if [ "$CERT_COUNT" -gt 0 ] && [ "$KEY_COUNT" -gt 0 ]; then
    echo -e "${GREEN}SUCCESS: Combined P12 contains certificate and private key${NC}"
else
    echo -e "${RED}ERROR: Combined P12 verification failed${NC}"
    exit 1
fi

# Show certificate info
echo ""
echo "--- Certificate details ---"
(openssl pkcs12 -in "$OUTPUT_FILE" -passin pass:"$OUTPUT_PASSWORD" -legacy -nokeys 2>/dev/null || \
 openssl pkcs12 -in "$OUTPUT_FILE" -passin pass:"$OUTPUT_PASSWORD" -nokeys 2>/dev/null) | \
    openssl x509 -noout -subject -dates 2>/dev/null || echo "Could not read certificate details"

echo ""
echo "========================================"
echo "  Done!"
echo "========================================"
echo ""
echo "To use with GitHub Actions:"
echo "  base64 -i \"$OUTPUT_FILE\" | tr -d '\\n' | pbcopy"
echo ""
echo "Then add as APPLE_CERTIFICATE_P12 secret in GitHub."
echo "Add the password as APPLE_CERTIFICATE_PASSWORD secret."
