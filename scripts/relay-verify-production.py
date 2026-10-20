#!/usr/bin/env python3
"""Verify https://falcon.hexly.ai/api/live against project.yml and a proven SHA."""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_URL = "https://falcon.hexly.ai/api/live"
VERSION_RE = re.compile(
    r'(?m)^\s*MARKETING_VERSION:\s*["\']?([0-9]+\.[0-9]+\.[0-9]+)["\']?\s*$'
)


def repo_root() -> Path:
    override = os.environ.get("FALCON_VERIFY_ROOT")
    if override:
        return Path(override)
    return Path(__file__).resolve().parents[1]


def expected_version(root: Path) -> str:
    text = (root / "project.yml").read_text(encoding="utf-8")
    match = VERSION_RE.search(text)
    if not match:
        raise SystemExit("MARKETING_VERSION missing from project.yml")
    return match.group(1)


def expected_sha() -> str:
    sha = os.environ.get("FALCON_VERIFY_SHA") or os.environ.get("GITHUB_SHA")
    if not sha:
        raise SystemExit("FALCON_VERIFY_SHA or GITHUB_SHA required")
    return sha.strip()


def fetch(url: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            if response.status != 200:
                raise SystemExit(f"live HTTP {response.status}")
            payload = response.read()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"live HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise SystemExit(f"live request failed: {error}") from error
    try:
        data = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"live JSON invalid: {error}") from error
    if not isinstance(data, dict):
        raise SystemExit("live payload must be an object")
    return data


def main() -> int:
    root = repo_root()
    url = os.environ.get("FALCON_VERIFY_URL", DEFAULT_URL)
    version = expected_version(root)
    sha = expected_sha()
    data = fetch(url)
    status = data.get("status")
    actual_version = data.get("version")
    actual_sha = data.get("gitSha") or data.get("git_sha")
    if status != "ok":
        raise SystemExit(f"live status {status!r} != ok")
    if actual_version != version:
        raise SystemExit(f"live version {actual_version!r} != {version!r}")
    if actual_sha != sha:
        raise SystemExit(f"live gitSha {actual_sha!r} != {sha!r}")
    print(f"verified {url} status=ok version={version} gitSha={sha}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - boundary
        print(f"verify failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
