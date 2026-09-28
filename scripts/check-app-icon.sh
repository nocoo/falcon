#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?Usage: scripts/check-app-icon.sh path/to/Falcon.app}"
icon=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIconFile' "$app/Contents/Info.plist")
if [[ "$icon" != "Falcon" ]]; then
  echo "Expected CFBundleIconFile=Falcon in $app" >&2
  exit 1
fi
cmp Sources/Falcon/Resources/Falcon.icns "$app/Contents/Resources/$icon.icns"
echo "Verified packaged Falcon icon and Finder metadata."
