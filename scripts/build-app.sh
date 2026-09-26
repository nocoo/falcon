#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
falcon_arch="${2:-$(uname -m)}"
xcodegen generate --quiet
xcodebuild -project Falcon.xcodeproj -scheme Falcon -configuration "${1:-Debug}" \
  -derivedDataPath build ARCHS="$falcon_arch" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO build
