#!/bin/bash
#
# verify-p12.sh - Verify a .p12 certificate is valid for code signing
#
# Usage: ./scripts/verify-p12.sh <path-to-p12> [password]
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

P12_FILE="$1"
P12_PASSWORD="${2:-}"

if [ -z "$P12_FILE" ]; then
    echo "Usage: $0 <path-to-p12> [password]"
    echo ""
    echo "Example: $0 certificate.p12 mypassword"
    exit 1
fi

if [ ! -f "$P12_FILE" ]; then
    echo -e "${RED}ERROR: File not found: $P12_FILE${NC}"
    exit 1
fi

echo "========================================"
echo "  P12 Certificate Verification Tool"
echo "========================================"
echo ""
echo "File: $P12_FILE"
echo "Size: $(ls -lh "$P12_FILE" | awk '{print $5}')"
echo ""

# Prompt for password if not provided
if [ -z "$P12_PASSWORD" ]; then
    echo -n "Enter P12 password: "
    read -s P12_PASSWORD
    echo ""
fi

echo ""
echo "--- Checking P12 file validity ---"

# Check if P12 is valid (try with -legacy flag for OpenSSL 3.x compatibility)
if ! openssl pkcs12 -in "$P12_FILE" -passin pass:"$P12_PASSWORD" -noout 2>/dev/null; then
    # Try with -legacy flag for OpenSSL 3.x (macOS Keychain uses legacy algorithms)
    if ! openssl pkcs12 -in "$P12_FILE" -passin pass:"$P12_PASSWORD" -legacy -noout 2>/dev/null; then
        echo -e "${RED}FAIL: Invalid P12 file or wrong password${NC}"
        exit 1
    fi
    LEGACY_FLAG="-legacy"
    echo -e "${GREEN}PASS: P12 file is valid (using legacy mode for OpenSSL 3.x)${NC}"
else
    LEGACY_FLAG=""
    echo -e "${GREEN}PASS: P12 file is valid${NC}"
fi

echo ""
echo "--- Checking for certificate ---"

# Check for certificate
CERT_OUTPUT=$(openssl pkcs12 -in "$P12_FILE" -passin pass:"$P12_PASSWORD" $LEGACY_FLAG -nokeys 2>/dev/null || echo "")
CERT_COUNT=$(echo "$CERT_OUTPUT" | grep -c "BEGIN CERTIFICATE" || echo "0")

if [ "$CERT_COUNT" -eq 0 ]; then
    echo -e "${RED}FAIL: No certificate found in P12${NC}"
    echo ""
    echo "Your P12 contains only the private key, not the certificate."
    echo "You need to export from Keychain Access -> My Certificates,"
    echo "selecting the certificate (not the key)."
    HAS_CERT=false
else
    echo -e "${GREEN}PASS: Found $CERT_COUNT certificate(s)${NC}"
    HAS_CERT=true
fi

echo ""
echo "--- Checking for private key ---"

# Check for private key
KEY_OUTPUT=$(openssl pkcs12 -in "$P12_FILE" -passin pass:"$P12_PASSWORD" $LEGACY_FLAG -nocerts -nodes 2>/dev/null || echo "")
KEY_COUNT=$(echo "$KEY_OUTPUT" | grep -c "PRIVATE KEY" || echo "0")

if [ "$KEY_COUNT" -eq 0 ]; then
    echo -e "${RED}FAIL: No private key found in P12${NC}"
    echo ""
    echo "Your P12 contains only the certificate, not the private key."
    echo "The private key must exist in your Keychain and be associated"
    echo "with the certificate when exporting."
    HAS_KEY=false
else
    echo -e "${GREEN}PASS: Found $KEY_COUNT private key(s)${NC}"
    HAS_KEY=true
fi

# If we have a certificate, show details
if [ "$HAS_CERT" = true ]; then
    echo ""
    echo "--- Certificate details ---"

    # Extract certificate info
    CERT_INFO=$(openssl pkcs12 -in "$P12_FILE" -passin pass:"$P12_PASSWORD" $LEGACY_FLAG -nokeys 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null || echo "")

    if [ -n "$CERT_INFO" ]; then
        SUBJECT=$(echo "$CERT_INFO" | grep "subject=" | sed 's/subject=//' || echo "Unknown")
        ISSUER=$(echo "$CERT_INFO" | grep "issuer=" | sed 's/issuer=//' || echo "Unknown")
        NOT_BEFORE=$(echo "$CERT_INFO" | grep "notBefore=" | sed 's/notBefore=//' || echo "Unknown")
        NOT_AFTER=$(echo "$CERT_INFO" | grep "notAfter=" | sed 's/notAfter=//' || echo "Unknown")

        echo "Subject: $SUBJECT"
        echo "Issuer:  $ISSUER"
        echo "Valid from: $NOT_BEFORE"
        echo "Valid until: $NOT_AFTER"

        # Check if it's a Developer ID Application certificate
        echo ""
        echo "--- Checking certificate type ---"

        if echo "$SUBJECT" | grep -q "Developer ID Application"; then
            echo -e "${GREEN}PASS: Certificate is 'Developer ID Application' type${NC}"
            echo "This certificate is suitable for distributing apps outside the App Store."
        elif echo "$SUBJECT" | grep -q "Apple Development"; then
            echo -e "${YELLOW}WARNING: Certificate is 'Apple Development' type${NC}"
            echo "This certificate is for local development only."
            echo "Users will see Gatekeeper warnings when running your app."
            echo "For proper distribution, you need a 'Developer ID Application' certificate."
        elif echo "$SUBJECT" | grep -q "Mac Developer"; then
            echo -e "${YELLOW}WARNING: Certificate is 'Mac Developer' type${NC}"
            echo "This certificate is for local development only."
            echo "You need a 'Developer ID Application' certificate for GitHub releases."
        elif echo "$SUBJECT" | grep -q "Apple Distribution"; then
            echo -e "${YELLOW}WARNING: Certificate is 'Apple Distribution' type${NC}"
            echo "This certificate is for App Store distribution only."
            echo "You need a 'Developer ID Application' certificate for GitHub releases."
        else
            echo -e "${YELLOW}WARNING: Unknown certificate type${NC}"
            echo "Expected 'Developer ID Application' for GitHub releases."
        fi

        # Check expiration
        echo ""
        echo "--- Checking expiration ---"

        if [ -n "$NOT_AFTER" ] && [ "$NOT_AFTER" != "Unknown" ]; then
            # Try to parse the date (macOS format)
            if EXPIRY_TIMESTAMP=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$NOT_AFTER" "+%s" 2>/dev/null); then
                NOW_TIMESTAMP=$(date "+%s")
                if [ "$NOW_TIMESTAMP" -gt "$EXPIRY_TIMESTAMP" ]; then
                    echo -e "${RED}FAIL: Certificate has EXPIRED${NC}"
                    echo "Expired on: $NOT_AFTER"
                    echo "Please renew at https://developer.apple.com/account/resources/certificates"
                else
                    DAYS_LEFT=$(( (EXPIRY_TIMESTAMP - NOW_TIMESTAMP) / 86400 ))
                    if [ "$DAYS_LEFT" -lt 30 ]; then
                        echo -e "${YELLOW}WARNING: Certificate expires in $DAYS_LEFT days${NC}"
                    else
                        echo -e "${GREEN}PASS: Certificate is valid for $DAYS_LEFT more days${NC}"
                    fi
                fi
            else
                echo "Could not parse expiration date: $NOT_AFTER"
            fi
        fi
    else
        echo "Could not extract certificate details"
    fi
fi

# Final summary
echo ""
echo "========================================"
echo "  Summary"
echo "========================================"

if [ "$HAS_CERT" = true ] && [ "$HAS_KEY" = true ]; then
    echo -e "${GREEN}SUCCESS: P12 file contains both certificate and private key${NC}"
    echo ""
    echo "To use with GitHub Actions:"
    echo "  base64 -i \"$P12_FILE\" | tr -d '\\n' | pbcopy"
    echo ""
    echo "Then add as APPLE_CERTIFICATE_P12 secret in GitHub."
    exit 0
else
    echo -e "${RED}FAILED: P12 file is incomplete${NC}"
    echo ""
    if [ "$HAS_CERT" = false ] && [ "$HAS_KEY" = true ]; then
        echo "Problem: Has private key but NO certificate"
        echo ""
        echo "Fix: You need to combine the certificate with the key."
        echo "See: ./scripts/combine-cert-key.sh"
    elif [ "$HAS_CERT" = true ] && [ "$HAS_KEY" = false ]; then
        echo "Problem: Has certificate but NO private key"
        echo ""
        echo "Fix: The private key must be in your Keychain and associated"
        echo "with the certificate. If the key is lost, you need to create"
        echo "a new certificate at https://developer.apple.com/account/resources/certificates"
    else
        echo "Problem: Has neither certificate nor private key"
        echo ""
        echo "The P12 file appears to be empty or corrupted."
    fi
    exit 1
fi
