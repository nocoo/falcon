#!/usr/bin/env python3
"""Check-only index-snapshot gate for services/relay (Worker L1 only).

Exports the Git index to an owned temporary directory, runs offline
`bun install --frozen-lockfile --backend=copyfile` into that snapshot from the
host Bun cache, then typecheck/lint/test:coverage. Does not symlink worktree
node_modules. Does not claim whole-repo L1.
"""

from __future__ import annotations

import json
import math
import os
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse

SERVICE = Path("services/relay")
MARKER_NAME = "_test_marker"
FLOOR = 95.0
REGISTRY_CONFIG_KEY = "falcon.relayRegistry"
LIMIT_SECONDS = float(os.environ.get("FALCON_RELAY_CHECK_SECONDS", "120"))

_active_child: subprocess.Popen[bytes] | None = None


class GateError(RuntimeError):
    pass


def which(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise GateError(f"missing required tool: {name}")
    return path


def host_home() -> Path:
    return Path(pwd.getpwuid(os.getuid()).pw_dir)


def resolve_bun_cache() -> Path:
    configured = os.environ.get("BUN_INSTALL_CACHE_DIR", "").strip()
    if configured:
        cache = Path(configured)
    else:
        cache = host_home() / ".bun" / "install" / "cache"
    if not cache.is_dir():
        raise GateError(f"missing Bun install cache (offline): {cache}")
    return cache.resolve()


def validate_registry_url(url: str) -> str:
    """Accept only plain HTTPS registry roots; never echo credential-bearing input."""
    raw = url.strip()
    if not raw:
        raise GateError("registry URL is empty")
    parsed = urlparse(raw)
    if parsed.scheme != "https":
        raise GateError("registry URL must use https")
    if parsed.username is not None or parsed.password is not None or "@" in (parsed.netloc or ""):
        raise GateError("registry URL must not contain credentials")
    if parsed.query:
        raise GateError("registry URL must not contain a query")
    if parsed.fragment:
        raise GateError("registry URL must not contain a fragment")
    if not parsed.hostname:
        raise GateError("registry URL host is missing")
    if parsed.params:
        raise GateError("registry URL must not contain params")
    return raw


def read_relay_registry(root: Path) -> str | None:
    result = subprocess.run(
        ["git", "config", "--get", REGISTRY_CONFIG_KEY],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    if not value:
        return None
    return validate_registry_url(value)


def terminate_active(sig: int = signal.SIGTERM) -> None:
    child = _active_child
    if child is None or child.pid is None:
        return
    pgid = child.pid
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        pass
    try:
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
    finally:
        # Leader may exit on SIGTERM while a grandchild ignores it; always escalate.
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def run(args: list[str], cwd: Path, env: dict[str, str], deadline: float) -> None:
    global _active_child
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise GateError("relay check timed out")
    print("relay-check-index:", " ".join(args), flush=True)
    child = subprocess.Popen(
        args,
        cwd=cwd,
        env=env,
        start_new_session=True,
    )
    _active_child = child
    try:
        try:
            code = child.wait(timeout=remaining)
        except subprocess.TimeoutExpired as error:
            terminate_active(signal.SIGTERM)
            raise GateError("relay check timed out") from error
        except BaseException:
            terminate_active(signal.SIGTERM)
            raise
        if code != 0:
            raise GateError(f"command failed ({code}): {' '.join(args)}")
    finally:
        if _active_child is child:
            _active_child = None


def assert_coverage(service_dir: Path) -> None:
    summary = service_dir / "coverage" / "coverage-summary.json"
    if not summary.is_file():
        raise GateError(f"missing coverage report: {summary}")
    data = json.loads(summary.read_text(encoding="utf-8"))
    total = data.get("total")
    if not isinstance(total, dict):
        raise GateError("coverage report missing total")
    for name in ("statements", "branches", "functions", "lines"):
        bucket = total.get(name)
        if not isinstance(bucket, dict):
            raise GateError(f"coverage report missing {name}")
        if "pct" not in bucket or "total" not in bucket:
            raise GateError(f"coverage report missing {name}.pct or {name}.total")
        try:
            count = float(bucket["total"])
            pct = float(bucket["pct"])
        except (TypeError, ValueError) as error:
            raise GateError(f"coverage {name} is not numeric") from error
        if not math.isfinite(count) or count <= 0:
            raise GateError(f"coverage {name} total absent or zero")
        if not math.isfinite(pct):
            raise GateError(f"coverage {name} pct is nonfinite")
        print(f"relay coverage {name}={pct:.2f}% total={count:.0f}", flush=True)
        if pct < FLOOR:
            raise GateError(f"coverage {name} {pct:.2f}% < {FLOOR}%")


def owned_scratch(root: Path) -> Path:
    path = Path(tempfile.mkdtemp(prefix="relay-index-"))
    if path.is_symlink():
        raise GateError("scratch run directory must not be a symlink")
    marker = path / MARKER_NAME
    marker.write_text(f"run-id={path.name}\nroot={root}\n", encoding="utf-8")
    return path


def validate_cleanup_target(path: Path) -> None:
    if path.is_symlink() or not path.is_dir():
        raise GateError(f"refusing cleanup: not a real directory: {path}")
    marker = path / MARKER_NAME
    if marker.is_symlink() or not marker.is_file():
        raise GateError(f"refusing cleanup: missing fixture marker in {path}")
    expected = f"run-id={path.name}"
    lines = marker.read_text(encoding="utf-8").splitlines()
    if expected not in lines:
        raise GateError(f"refusing cleanup: marker mismatch in {path}")


def cleanup(path: Path | None) -> None:
    if path is None:
        return
    try:
        validate_cleanup_target(path)
    except GateError as error:
        print(str(error), file=sys.stderr, flush=True)
        return
    shutil.rmtree(path, ignore_errors=False)


def snapshot_env(
    scratch: Path,
    git_sha: str,
    registry: str | None = None,
) -> dict[str, str]:
    home = scratch / "home"
    home.mkdir(parents=True, exist_ok=True)
    tmp = scratch / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    env = {
        "PATH": os.environ.get("PATH", ""),
        "LANG": os.environ.get("LANG", "C"),
        "LC_ALL": os.environ.get("LC_ALL", "C"),
        "HOME": str(home),
        "TMPDIR": str(tmp),
        "TMP": str(tmp),
        "TEMP": str(tmp),
        "CI": "1",
        "GIT_SHA": git_sha,
    }
    if registry is not None:
        env["BUN_CONFIG_REGISTRY"] = registry
    return env


def offline_install(service: Path, env: dict[str, str], cache: Path, deadline: float) -> None:
    if not (service / "package.json").is_file() or not (service / "bun.lock").is_file():
        raise GateError("index snapshot missing package.json or bun.lock")
    run(
        [
            "bun",
            "install",
            "--offline",
            "--frozen-lockfile",
            "--ignore-scripts",
            "--backend=copyfile",
            f"--cache-dir={cache}",
        ],
        service,
        env,
        deadline,
    )


def main() -> int:
    deadline = time.monotonic() + LIMIT_SECONDS
    which("git")
    which("bun")
    cache = resolve_bun_cache()
    root = Path(
        subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
        ).strip()
    )
    git_sha = subprocess.check_output(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        text=True,
    ).strip()
    # Read from the real repo before the index snapshot; snapshot env drops ambient registry.
    registry = read_relay_registry(root)
    scratch: Path | None = None
    try:
        scratch = owned_scratch(root)
        snapshot = scratch / "source"
        snapshot.mkdir()
        prefix = str(snapshot) if str(snapshot).endswith(os.sep) else f"{snapshot}{os.sep}"
        run(
            ["git", "checkout-index", "--all", "--ignore-skip-worktree-bits", f"--prefix={prefix}"],
            root,
            os.environ.copy(),
            deadline,
        )
        service = snapshot / SERVICE
        if not service.is_dir():
            raise GateError(f"index snapshot missing {SERVICE}")
        env = snapshot_env(scratch, git_sha, registry)
        offline_install(service, env, cache, deadline)
        for command in ("typecheck", "lint", "test:coverage"):
            run(["bun", "run", command], service, env, deadline)
        assert_coverage(service)
        print("relay-check-index: services/relay index snapshot ok", flush=True)
        return 0
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"relay-check-index failed: {error}", file=sys.stderr, flush=True)
        return 1
    finally:
        terminate_active(signal.SIGTERM)
        cleanup(scratch)


def _handle_signal(signum: int, _frame) -> None:
    terminate_active(signal.SIGTERM)
    raise SystemExit(128 + signum)


def _validate_registry_cli(url: str) -> int:
    try:
        print(validate_registry_url(url))
        return 0
    except GateError as error:
        # Never print the raw URL; it may contain credentials.
        print(f"relay-check-index: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--validate-registry":
        raise SystemExit(_validate_registry_cli(sys.argv[2]))
    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)
    try:
        raise SystemExit(main())
    except BaseException:
        terminate_active(signal.SIGTERM)
        raise
