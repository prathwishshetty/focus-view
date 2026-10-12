#!/usr/bin/env bash
# Builds Focus with SwiftPM and wraps it in a runnable Focus.app.
#
#   scripts/bundle.sh            # release build → build/Focus.app
#   scripts/bundle.sh debug      # debug build
#
# Without signing settings the app is ad-hoc signed, which is enough to run it
# locally. Passkeys and security keys need it signed with your Apple Developer
# identity and a provisioning profile that includes the web browser passkey
# entitlement. Put these in signing.env (see signing.env.example) or the
# environment:
#
#   FOCUS_SIGN_IDENTITY          "Apple Development: …" or "Developer ID Application: …"
#   FOCUS_PROVISIONING_PROFILE   path to the app's .provisionprofile
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Focus.app"

if [[ -f "$ROOT/signing.env" ]]; then
    # shellcheck source=/dev/null
    source "$ROOT/signing.env"
fi
IDENTITY="${FOCUS_SIGN_IDENTITY:-}"
PROFILE="${FOCUS_PROVISIONING_PROFILE:-}"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product Focus
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Focus" "$APP/Contents/MacOS/Focus"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -z "$IDENTITY" ]]; then
    codesign --force --sign - --timestamp=none "$APP" >/dev/null
    echo "Built $APP (ad-hoc signed: passkeys are unavailable; see signing.env.example)"
    exit 0
fi

PLISTBUDDY=/usr/libexec/PlistBuddy
ENTITLEMENTS="$ROOT/build/Focus.entitlements"
cp "$ROOT/Support/Focus.entitlements" "$ENTITLEMENTS"

if [[ -n "$PROFILE" ]]; then
    [[ -f "$PROFILE" ]] || { echo "error: provisioning profile not found: $PROFILE" >&2; exit 1; }
    DECODED="$ROOT/build/profile.plist"
    security cms -D -i "$PROFILE" > "$DECODED"
    entitlement() { "$PLISTBUDDY" -c "Print :Entitlements:$1" "$DECODED" 2>/dev/null || true; }

    APP_ID="$(entitlement com.apple.application-identifier)"
    TEAM_ID="$(entitlement com.apple.developer.team-identifier)"
    [[ -n "$TEAM_ID" ]] || TEAM_ID="$("$PLISTBUDDY" -c "Print :TeamIdentifier:0" "$DECODED" 2>/dev/null || true)"
    if [[ -z "$APP_ID" || -z "$TEAM_ID" || "$APP_ID" == *"*"* ]]; then
        echo "error: $PROFILE needs an explicit App ID (not a wildcard)" >&2
        exit 1
    fi

    # The app takes the profile's bundle identifier, so the two always match.
    "$PLISTBUDDY" -c "Set :CFBundleIdentifier ${APP_ID#"$TEAM_ID".}" "$APP/Contents/Info.plist"
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

    "$PLISTBUDDY" -c "Add :com.apple.application-identifier string $APP_ID" "$ENTITLEMENTS"
    "$PLISTBUDDY" -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS"
    # Only claim the passkey entitlement once Apple has granted it, or macOS
    # refuses to launch the app.
    if [[ "$(entitlement com.apple.developer.web-browser.public-key-credential)" == "true" ]]; then
        "$PLISTBUDDY" -c "Add :com.apple.developer.web-browser.public-key-credential bool true" "$ENTITLEMENTS"
        PASSKEYS="on"
    else
        PASSKEYS="off: the profile doesn't include the web browser passkey entitlement yet"
    fi
else
    PASSKEYS="off: set FOCUS_PROVISIONING_PROFILE"
fi

codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" "$APP" >/dev/null
echo "Built $APP (signed by $IDENTITY; passkeys $PASSKEYS)"
