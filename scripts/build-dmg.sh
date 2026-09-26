#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodegen generate --quiet
xcodebuild -project Falcon.xcodeproj -scheme Falcon -configuration Release \
  -derivedDataPath build ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=93WWLTN9XU -allowProvisioningUpdates build
app="build/Build/Products/Release/Falcon.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
dmg="build/Falcon-${version}-arm64.dmg"
if [[ -e "$dmg" ]]; then
  echo "Refusing to overwrite $dmg" >&2
  exit 1
fi
codesign --verify --deep --strict "$app"
codesign --display --verbose=4 "$app"
if [[ "$(lipo -archs "$app/Contents/MacOS/Falcon")" != "arm64" ]]; then
  echo "Expected an arm64-only executable" >&2
  exit 1
fi
staging=$(mktemp -d "${TMPDIR:-/tmp}/falcon-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Falcon.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname Falcon -srcfolder "$staging" -ov -format ULMO "$dmg"
hdiutil verify "$dmg"
(cd build && shasum -a 256 "${dmg##*/}" > "${dmg##*/}.sha256")
echo "Created $dmg (not notarized)."
