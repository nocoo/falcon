#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
: "${FALCON_CODE_SIGN_IDENTITY:?Set the explicitly selected signing identity; use - only for an explicitly authorized ad-hoc release}"

scripts/build-app.sh Release "arm64 x86_64"
app="build/Build/Products/Release/Falcon.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg="build/Falcon-${version}-universal.dmg"
if [[ -e "$dmg" ]]; then
  echo "Refusing to overwrite $dmg" >&2
  exit 1
fi
codesign --force --options runtime --sign "$FALCON_CODE_SIGN_IDENTITY" "$app"
codesign --verify --deep --strict "$app"
codesign --display --verbose=4 "$app"
lipo "$app/Contents/MacOS/Falcon" -verify_arch arm64 x86_64
staging=$(mktemp -d "${TMPDIR:-/tmp}/falcon-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Falcon.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Falcon -srcfolder "$staging" -ov -format UDZO "$dmg"
hdiutil verify "$dmg"
(cd build && shasum -a 256 "${dmg##*/}" > "${dmg##*/}.sha256")
echo "Created $dmg (not notarized)."
