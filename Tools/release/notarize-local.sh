#!/bin/bash
# Signs, notarizes and staples a Slyy Mailr DMG on a Mac, using a Developer ID .p12
# and an App Store Connect API key (.p8). Nothing is uploaded except to Apple's notary service.
#
#   Tools/release/notarize-local.sh <input.dmg or Slyy Mailr.app> <DeveloperID.p12> <AuthKey_XXXX.p8> <KEY_ID> <ISSUER_ID>
#
# Prompts for the .p12 password. Writes dist/slyy-mailr-<version>-mac-apple-silicon.dmg (+ .sha256).
set -euo pipefail

INPUT=${1:?input .dmg or .app}
P12=${2:?Developer ID Application .p12}
P8=${3:?App Store Connect API key .p8}
KEY_ID=${4:?API key id}
ISSUER=${5:-}   # empty for Individual API keys
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENTITLEMENTS="$ROOT/Tools/release/SlyyMailr-macOS.entitlements"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [ -n "${KC:-}" ] && security delete-keychain "$KC" 2>/dev/null || true' EXIT

# 1. The app: copy it out of the DMG if needed.
if [[ "$INPUT" == *.dmg ]]; then
  MNT=$(hdiutil attach -nobrowse -readonly "$INPUT" | awk -F'\t' '/\/Volumes\//{print $3}' | tail -1)
  cp -R "$MNT/Slyy Mailr.app" "$WORK/"
  hdiutil detach "$MNT" -quiet
else
  cp -R "$INPUT" "$WORK/"
fi
APP="$WORK/Slyy Mailr.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

# 2. Temporary keychain with the Developer ID identity.
read -r -s -p "Password for $(basename "$P12"): " P12PW; echo
KC="$WORK/signing.keychain-db"; KCPW=$(uuidgen)
security create-keychain -p "$KCPW" "$KC"
security unlock-keychain -p "$KCPW" "$KC"
security import "$P12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
IDENTITY=$(security find-identity -v -p codesigning "$KC" | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' identity in $P12"; exit 1; }
echo "Signing as: $IDENTITY"

# 3. Sign app (hardened runtime), build and sign DMG.
codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
mkdir -p "$WORK/dmg" "$ROOT/dist"
cp -R "$APP" "$WORK/dmg/"; ln -s /Applications "$WORK/dmg/Applications"
DMG="$ROOT/dist/slyy-mailr-$VERSION-mac-apple-silicon.dmg"
hdiutil create -volname "Slyy Mailr $VERSION" -srcfolder "$WORK/dmg" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp -s "$IDENTITY" "$DMG"

# 4. Notarize, staple, check.
AUTH=(--key "$P8" --key-id "$KEY_ID"); [ -n "$ISSUER" ] && AUTH+=(--issuer "$ISSUER")
xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --timeout 30m
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Notarized: $DMG"
