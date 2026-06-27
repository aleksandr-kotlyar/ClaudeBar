#!/usr/bin/env bash
# Fetches and installs the MAC_APP_STORE provisioning profile from App Store Connect.
# Prints the profile name to stdout — used by CI: PP_NAME=$(./scripts/install-mas-profile.sh)
#
# Requires: asccli, jq
# Requires env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY

set -euo pipefail

BUNDLE_ID="${BUNDLE_ID:-com.tddworks.claudebar}"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Resolve bundle ID resource ID
BUNDLE_ID_ID=$(asc bundle-ids list --identifier "$BUNDLE_ID" --platform macos \
  | jq -r '.data[0].id')

# Fetch MAC_APP_STORE profile
PROFILE_JSON=$(asc profiles list --bundle-id-id "$BUNDLE_ID_ID" --type MAC_APP_STORE)
PROFILE_CONTENT=$(echo "$PROFILE_JSON" | jq -r '.data[0].profileContent // .data[0].attributes.profileContent')

# Decode (ASC returns non-line-wrapped base64; -A handles that) and install
PP_PATH="$WORK_DIR/mas.provisionprofile"
printf '%s' "$PROFILE_CONTENT" \
  | openssl base64 -d -A \
  | cat > "$PP_PATH"

security cms -D -i "$PP_PATH" > "$WORK_DIR/profile.plist"
PP_UUID=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$WORK_DIR/profile.plist")
PP_NAME=$(/usr/libexec/PlistBuddy -c 'Print Name' "$WORK_DIR/profile.plist")

mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PP_PATH" "$HOME/Library/MobileDevice/Provisioning Profiles/$PP_UUID.provisionprofile"

echo "Installed: $PP_NAME ($PP_UUID)" >&2
echo "$PP_NAME"
