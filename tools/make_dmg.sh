#!/usr/bin/env bash
# Build ZoiaCanvas Release and package it as a drag-to-install DMG:
# app icon on the left, an /Applications symlink on the right.
#
# Usage: tools/make_dmg.sh
#
# Signing: if a "Developer ID Application" identity is in the keychain,
# the app is re-signed with it (hardened runtime + audio-input
# entitlement) so the DMG passes Gatekeeper on other Macs. Otherwise the
# development signature from the build is kept and the script warns —
# fine for your own machines, blocked on everyone else's.
#
# Notarization: set NOTARY_PROFILE to a `notarytool store-credentials`
# profile name to notarize and staple after signing. Skipped otherwise.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ZoiaCanvas"
DIST="$REPO/dist"
BUILD="$(mktemp -d /tmp/zoiacanvas-build.XXXXXX)"
STAGE="$(mktemp -d /tmp/zoiacanvas-dmg.XXXXXX)"
trap 'rm -rf "$BUILD" "$STAGE"' EXIT

cd "$REPO"
[ -d "$APP_NAME.xcodeproj" ] || xcodegen generate

echo "==> Building Release"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration Release -derivedDataPath "$BUILD" \
    build | tail -3

APP="$BUILD/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$APP/Contents/Info.plist")"

DEV_ID="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"

if [ -n "$DEV_ID" ]; then
    echo "==> Signing with: $DEV_ID (hardened runtime)"
    codesign --force --sign "$DEV_ID" --options runtime --timestamp \
        --entitlements "$REPO/tools/$APP_NAME.entitlements" "$APP"
    codesign --verify --strict --deep "$APP"
else
    echo "warning: no Developer ID Application identity in keychain." >&2
    echo "warning: keeping the development signature — Gatekeeper will" >&2
    echo "warning: block this app on other people's Macs." >&2
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "$DEV_ID" ]; then
        echo "error: NOTARY_PROFILE set but no Developer ID identity;" \
             "notarization requires a Developer ID signature" >&2
        exit 1
    fi
    echo "==> Notarizing (profile: $NOTARY_PROFILE)"
    ditto -c -k --keepParent "$APP" "$BUILD/$APP_NAME.zip"
    xcrun notarytool submit "$BUILD/$APP_NAME.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

echo "==> Staging DMG contents"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/$APP_NAME-$VERSION.dmg"
RW_DMG="$BUILD/rw.dmg"
mkdir -p "$DIST"
rm -f "$DMG"

echo "==> Creating DMG"
hdiutil create -srcfolder "$STAGE" -volname "$APP_NAME" \
    -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null

MOUNT="/Volumes/$APP_NAME"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT" -nobrowse >/dev/null

# Finder window layout: icon view, app left, Applications right.
osascript <<EOF
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 760, 560}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set position of item "$APP_NAME.app" of container window to {150, 160}
        set position of item "Applications" of container window to {410, 160}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
sync
hdiutil detach "$MOUNT" >/dev/null

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 \
    -ov -o "$DMG" >/dev/null

if [ -n "$DEV_ID" ]; then
    codesign --force --sign "$DEV_ID" --timestamp "$DMG"
fi

echo "==> $DMG"
