#!/bin/zsh
# Example Intune shell script (run as root, "Run script as signed-in user" = No).
# Downloads a vendor DMG and installs it into the signed-in user's ~/Applications.
# Requires the decant package (uk.street365.decant) to be deployed first.
# Set DMG_URL and EXPECTED_TEAM_ID for each app, and optionally EXPECTED_BUNDLE_ID and DMG_SHA256.
set -uo pipefail

DMG_URL="https://example.com/downloads/Example.dmg"
# Required: the vendor's Team ID. Find it with: decant check-app /Applications/Example.app
# Without it, anything notarized that turns up at DMG_URL would be installed.
EXPECTED_TEAM_ID=""
EXPECTED_BUNDLE_ID=""   # recommended, e.g. com.example.app
DMG_SHA256=""           # optional: pins one exact release, so it must be updated with every release

TOOL=/usr/local/bin/decant
if [[ ! -x $TOOL ]]; then
    echo "decant is not installed; deploy the uk.street365.decant package first"
    exit 1
fi
if [[ -z $EXPECTED_TEAM_ID ]]; then
    echo "Set EXPECTED_TEAM_ID in this script"
    exit 64
fi

WORK=$(mktemp -d /private/tmp/decant.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
DMG="$WORK/download.dmg"

# HTTPS only, including redirects.
if ! /usr/bin/curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location \
        --max-time 900 --output "$DMG" "$DMG_URL"; then
    echo "Download failed: $DMG_URL"
    exit 20
fi
if [[ -n "$DMG_SHA256" ]]; then
    ACTUAL=$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print $1}')
    if [[ "$ACTUAL" != "$DMG_SHA256" ]]; then
        echo "Checksum mismatch: expected $DMG_SHA256, got $ACTUAL"
        exit 20
    fi
fi

ARGS=(install "$DMG" --expect-team-id "$EXPECTED_TEAM_ID")
[[ -n $EXPECTED_BUNDLE_ID ]] && ARGS+=(--expect-bundle-id "$EXPECTED_BUNDLE_ID")
# Add --all-users to install into every local account's ~/Applications instead.
$TOOL "${ARGS[@]}"
