#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec uv run --no-project --with 'typesafe-sdk==0.7.1' python -c '
import os
import subprocess
import sys

environment = os.environ.copy()
environment["FALCON_PYTHON"] = sys.executable
raise SystemExit(subprocess.call(
    ["swift", "test", "--enable-code-coverage", "--filter", "officialPythonSDKCallsRealLoopback"],
    env=environment,
))
'
