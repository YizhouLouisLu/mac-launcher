#!/bin/bash
# Sign one .app bundle with the stable self-signed identity when it exists.
#
# Why this exists: an ad-hoc signature's designated requirement is the cdhash, so every
# rebuild produces a different identity and macOS drops the Accessibility grant that
# snippet pasting depends on. Signing with a certificate makes the requirement
# identity-based, so the grant survives rebuilds.
#
# Create the identity once with (see P1-NOTES.md):
#   openssl req -x509 -newkey rsa:2048 -nodes ... ; security import key.pem ...
#   security import cert.pem ... ; security add-trusted-cert -r trustRoot ...
#
# usage: sign.sh <app-path> <bundle-identifier>
set -euo pipefail

APP="$1"
IDENTIFIER="$2"
IDENTITY="MacLauncher Dev"

# Finder/fileprovider detritus makes codesign fail with "resource fork, Finder
# information, or similar detritus not allowed", so it is cleared before every signing.
xattr -cr "$APP"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier "$IDENTIFIER" "$APP"
else
  echo "note: signing identity \"$IDENTITY\" not found; using ad-hoc." >&2
  echo "      Accessibility grants will NOT survive rebuilds until that identity exists." >&2
  codesign --force --sign - --identifier "$IDENTIFIER" "$APP"
fi

codesign -v "$APP"
