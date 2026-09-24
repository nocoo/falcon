#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
scripts/build-app.sh Debug
open build/Build/Products/Debug/Falcon.app
