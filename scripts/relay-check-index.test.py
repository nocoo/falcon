#!/usr/bin/env python3
"""Index-snapshot pre-commit tests for scripts/relay-check-index.py."""

from __future__ import annotations

import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "relay-check-index.py"
MARKER = "_test_marker"


def write(path: Path, content: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(mode)


def stub_bin(directory: Path, name: str, script: str) -> None:
    path = directory / name
    write(path, "#!/bin/bash\n" + script + "\n", 0o755)


def load_module():
    spec = importlib.util.spec_from_file_location("relay_check_index", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def coverage_json(pct: float = 96.0, total: int = 10, **metric_overrides) -> str:
    bucket = {"pct": pct, "total": total}
    payload = {
        "total": {
            "lines": dict(bucket),
            "statements": dict(bucket),
            "functions": dict(bucket),
            "branches": dict(bucket),
        }
    }
    payload["total"].update(metric_overrides)
    return json.dumps(payload)


class CoverageAndCleanupUnitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = load_module()

    def test_rejects_nan_coverage(self) -> None:
        with tempfile.TemporaryDirectory(prefix="falcon-cov-") as temporary:
            summary = Path(temporary) / "coverage" / "coverage-summary.json"
            write(
                summary,
                coverage_json(lines={"pct": float("nan"), "total": 10}),
            )
            with self.assertRaises(self.mod.GateError):
                self.mod.assert_coverage(Path(temporary))

    def test_rejects_absent_or_zero_totals(self) -> None:
        with tempfile.TemporaryDirectory(prefix="falcon-cov-") as temporary:
            root = Path(temporary)
            summary = root / "coverage" / "coverage-summary.json"
            write(summary, coverage_json(total=0))
            with self.assertRaises(self.mod.GateError):
                self.mod.assert_coverage(root)
            write(
                summary,
                json.dumps(
                    {
                        "total": {
                            "lines": {"pct": 96.0},
                            "statements": {"pct": 96.0},
                            "functions": {"pct": 96.0},
                            "branches": {"pct": 96.0},
                        }
                    }
                ),
            )
            with self.assertRaises(self.mod.GateError):
                self.mod.assert_coverage(root)

    def test_cleanup_only_marked_nonsymlink_run_dir(self) -> None:
        with tempfile.TemporaryDirectory(prefix="falcon-clean-") as temporary:
            base = Path(temporary)
            run_dir = base / "relay-index-abc"
            run_dir.mkdir()
            write(run_dir / MARKER, f"run-id={run_dir.name}\n")
            self.mod.cleanup(run_dir)
            self.assertFalse(run_dir.exists())

            alien = base / "alien"
            alien.mkdir()
            write(alien / "keep.txt", "x\n")
            self.mod.cleanup(alien)
            self.assertTrue((alien / "keep.txt").is_file())

            target = base / "real-run"
            target.mkdir()
            write(target / MARKER, f"run-id={target.name}\n")
            link = base / "link-run"
            link.symlink_to(target, target_is_directory=True)
            self.mod.cleanup(link)
            self.assertTrue(target.is_dir())
            self.assertTrue(link.is_symlink())

    def test_cleanup_rejects_impostor_run_id_substring(self) -> None:
        with tempfile.TemporaryDirectory(prefix="falcon-impostor-") as temporary:
            base = Path(temporary)
            run_dir = base / "relay-index-abc"
            run_dir.mkdir()
            # Substring lookalike must not authorize cleanup.
            write(run_dir / MARKER, f"run-id={run_dir.name}-extra\nroot=x\n")
            self.mod.cleanup(run_dir)
            self.assertTrue(run_dir.is_dir())
            write(run_dir / MARKER, f"xrun-id={run_dir.name}\n")
            self.mod.cleanup(run_dir)
            self.assertTrue(run_dir.is_dir())
            write(run_dir / MARKER, f"run-id={run_dir.name}\nroot=x\n")
            self.mod.cleanup(run_dir)
            self.assertFalse(run_dir.exists())

    def test_validate_registry_url_healthy_and_rejects(self) -> None:
        healthy = "https://packagefeedproxy.microsoft.io/npm/"
        self.assertEqual(self.mod.validate_registry_url(healthy), healthy)
        self.assertEqual(
            self.mod.validate_registry_url(f"  {healthy}  "),
            healthy,
        )
        for bad in (
            "http://example.com/npm/",
            "https://user:secret@example.com/npm/",
            "https://example.com/npm/?x=1",
            "https://example.com/npm/#frag",
            "",
            "   ",
        ):
            with self.subTest(bad=bad):
                with self.assertRaises(self.mod.GateError):
                    self.mod.validate_registry_url(bad)

    def test_snapshot_env_forwards_registry_only_when_provided(self) -> None:
        with tempfile.TemporaryDirectory(prefix="falcon-snap-env-") as temporary:
            scratch = Path(temporary)
            default_env = self.mod.snapshot_env(scratch, "abc123")
            self.assertNotIn("BUN_CONFIG_REGISTRY", default_env)
            self.assertEqual(default_env["GIT_SHA"], "abc123")
            registry = "https://packagefeedproxy.microsoft.io/npm/"
            with_registry = self.mod.snapshot_env(scratch, "abc123", registry)
            self.assertEqual(with_registry["BUN_CONFIG_REGISTRY"], registry)


class CheckIndexTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(SCRIPT.is_file(), "relay-check-index.py missing")
        self.temporary = tempfile.TemporaryDirectory(prefix="falcon-relay-index-")
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        self.bin = Path(self.temporary.name) / "bin"
        self.bin.mkdir()
        self.cache = Path(self.temporary.name) / "bun-cache"
        self.cache.mkdir()
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ.get('PATH', '')}",
            "HOME": str(Path(self.temporary.name) / "home"),
            "BUN_INSTALL_CACHE_DIR": str(self.cache),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        }
        Path(self.env["HOME"]).mkdir()
        self.init_repo()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def init_repo(self) -> None:
        subprocess.run(["git", "init", "-b", "main"], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=self.root, check=True)
        write(
            self.root / "services" / "relay" / "package.json",
            json.dumps(
                {
                    "name": "falcon-relay",
                    "scripts": {
                        "typecheck": "true",
                        "lint": "true",
                        "test:coverage": "true",
                    },
                }
            ),
        )
        write(self.root / "services" / "relay" / "bun.lock", '{"lockfileVersion": 1}\n')
        write(self.root / "services" / "relay" / "src" / "index.ts", "export const ok = true;\n")
        poison = self.root / "services" / "relay" / "node_modules" / "POISON"
        poison.mkdir(parents=True)
        write(poison / "index.js", "throw new Error('stale worktree deps')\n")
        subprocess.run(["git", "add", "services/relay"], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=self.root, check=True, capture_output=True)

    def install_healthy_stubs(self) -> None:
        summary = coverage_json()
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                f"""
                set -euo pipefail
                echo "bun stub: $* HOME=$HOME" >&2
                case "${{1:-}}" in
                  install)
                    for flag in --offline --frozen-lockfile --ignore-scripts --backend=copyfile; do
                      printf '%s\\n' "$*" | grep -F -q -- "$flag" || {{
                        echo "missing $flag" >&2
                        exit 93
                      }}
                    done
                    printf '%s\\n' "$*" | grep -E -q -- '--cache-dir(=| )' || {{
                      echo "missing --cache-dir" >&2
                      exit 93
                    }}
                    case "$PWD" in
                      */services/relay) ;;
                      *) echo "install cwd not snapshot service: $PWD" >&2; exit 94 ;;
                    esac
                    case "$HOME" in
                      */relay-index-*/home) ;;
                      *) echo "snapshot HOME not scratch: $HOME" >&2; exit 92 ;;
                    esac
                    test -n "${{GIT_SHA:-}}"
                    # Must install into snapshot; ignore any worktree node_modules.
                    rm -rf node_modules
                    mkdir -p node_modules
                    printf 'snapshot\\n' > node_modules/INSTALLED_IN_SNAPSHOT
                    # Record lock bytes actually present in this cwd.
                    cp bun.lock node_modules/LOCK_USED
                    exit 0
                    ;;
                  run)
                    shift
                    case "${{1:-}}" in
                      typecheck|lint)
                        test -n "${{GIT_SHA:-}}"
                        case "$HOME" in
                          */relay-index-*/home) ;;
                          *) echo "snapshot HOME not scratch: $HOME" >&2; exit 92 ;;
                        esac
                        test -f node_modules/INSTALLED_IN_SNAPSHOT
                        test ! -e node_modules/POISON
                        exit 0
                        ;;
                      test:coverage)
                        test -f node_modules/INSTALLED_IN_SNAPSHOT
                        test ! -e node_modules/POISON
                        mkdir -p coverage
                        printf '%s\\n' '{summary}' > coverage/coverage-summary.json
                        echo ok 1 - stub
                        exit 0
                        ;;
                      *)
                        echo "unexpected bun run $*" >&2
                        exit 90
                        ;;
                    esac
                    ;;
                  *)
                    echo "unexpected bun $*" >&2
                    exit 91
                    ;;
                esac
                """
            ).strip(),
        )

    def run_check(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT)],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_healthy_index_snapshot_passes(self) -> None:
        self.install_healthy_stubs()
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        status = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertEqual(status.stdout.strip(), "")
        self.assertTrue(
            (self.root / "services" / "relay" / "node_modules" / "POISON").exists(),
            "worktree poison tree must remain untouched",
        )

    def test_default_registry_omits_bun_config_registry_in_snapshot(self) -> None:
        observed = Path(self.temporary.name) / "registry-env-default"
        self.install_healthy_stubs()
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                f"""
                set -euo pipefail
                case "${{1:-}}" in
                  install)
                    if [[ -n "${{BUN_CONFIG_REGISTRY+x}}" ]]; then
                      echo "unexpected BUN_CONFIG_REGISTRY=${{BUN_CONFIG_REGISTRY-}}" >&2
                      exit 95
                    fi
                    printf 'absent\\n' > "{observed}"
                    rm -rf node_modules
                    mkdir -p node_modules
                    printf 'snapshot\\n' > node_modules/INSTALLED_IN_SNAPSHOT
                    exit 0
                    ;;
                  run)
                    shift
                    case "${{1:-}}" in
                      typecheck|lint) exit 0 ;;
                      test:coverage)
                        mkdir -p coverage
                        printf '%s\\n' '{coverage_json()}' > coverage/coverage-summary.json
                        exit 0
                        ;;
                    esac
                    ;;
                esac
                exit 1
                """
            ).strip(),
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(observed.read_text(encoding="utf-8"), "absent\n")

    def test_forwards_falcon_relay_registry_into_snapshot_install(self) -> None:
        registry = "https://packagefeedproxy.microsoft.io/npm/"
        subprocess.run(
            ["git", "config", "falcon.relayRegistry", registry],
            cwd=self.root,
            check=True,
            capture_output=True,
        )
        # Ambient env must not be the source; only repo git config.
        self.env.pop("BUN_CONFIG_REGISTRY", None)
        observed = Path(self.temporary.name) / "registry-env-forwarded"
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                f"""
                set -euo pipefail
                case "${{1:-}}" in
                  install)
                    for flag in --offline --frozen-lockfile --ignore-scripts --backend=copyfile; do
                      printf '%s\\n' "$*" | grep -F -q -- "$flag" || exit 93
                    done
                    printf '%s\\n' "${{BUN_CONFIG_REGISTRY:-}}" > "{observed}"
                    rm -rf node_modules
                    mkdir -p node_modules
                    printf 'snapshot\\n' > node_modules/INSTALLED_IN_SNAPSHOT
                    exit 0
                    ;;
                  run)
                    shift
                    case "${{1:-}}" in
                      typecheck|lint) exit 0 ;;
                      test:coverage)
                        mkdir -p coverage
                        printf '%s\\n' '{coverage_json()}' > coverage/coverage-summary.json
                        exit 0
                        ;;
                    esac
                    ;;
                esac
                exit 1
                """
            ).strip(),
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(observed.read_text(encoding="utf-8"), f"{registry}\n")

    def test_rejects_invalid_falcon_relay_registry_config(self) -> None:
        subprocess.run(
            ["git", "config", "falcon.relayRegistry", "https://user:secret@example.com/npm/"],
            cwd=self.root,
            check=True,
            capture_output=True,
        )
        self.install_healthy_stubs()
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertRegex(combined, r"(?i)credential|registry")
        self.assertNotIn("secret", combined)

    def test_stale_worktree_node_modules_cannot_affect_snapshot(self) -> None:
        self.install_healthy_stubs()
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # Stub typecheck fails if snapshot still sees worktree POISON; success proves isolation.
        self.assertIn("bun install --offline", result.stdout + result.stderr)
        self.assertTrue(
            (self.root / "services" / "relay" / "node_modules" / "POISON").exists()
        )

    def test_changed_lock_installs_exactly_from_snapshot(self) -> None:
        self.install_healthy_stubs()
        lock = self.root / "services" / "relay" / "bun.lock"
        staged = '{"lockfileVersion": 1, "packages": {"exact": "1.0.0"}}\n'
        lock.write_text(staged, encoding="utf-8")
        subprocess.run(["git", "add", "services/relay/bun.lock"], cwd=self.root, check=True)
        # Divergent dirty worktree lock must not be what install sees.
        lock.write_text('{"lockfileVersion": 1, "packages": {"worktree": "9.9.9"}}\n', encoding="utf-8")

        observed = Path(self.temporary.name) / "observed-lock"
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                f"""
                set -euo pipefail
                case "${{1:-}}" in
                  install)
                    for flag in --offline --frozen-lockfile --ignore-scripts --backend=copyfile; do
                      printf '%s\\n' "$*" | grep -F -q -- "$flag" || exit 93
                    done
                    cp bun.lock "{observed}"
                    rm -rf node_modules
                    mkdir -p node_modules
                    printf 'snapshot\\n' > node_modules/INSTALLED_IN_SNAPSHOT
                    exit 0
                    ;;
                  run)
                    shift
                    case "${{1:-}}" in
                      typecheck|lint)
                        test -f node_modules/INSTALLED_IN_SNAPSHOT
                        exit 0
                        ;;
                      test:coverage)
                        mkdir -p coverage
                        printf '%s\\n' '{coverage_json()}' > coverage/coverage-summary.json
                        exit 0
                        ;;
                    esac
                    ;;
                esac
                exit 1
                """
            ).strip(),
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(observed.read_text(encoding="utf-8"), staged)

    def test_rejects_missing_bun_cache(self) -> None:
        self.install_healthy_stubs()
        missing = Path(self.temporary.name) / "missing-cache"
        self.env["BUN_INSTALL_CACHE_DIR"] = str(missing)
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr + result.stdout, r"(?i)cache")

    def test_staged_bug_fails_despite_unstaged_fix(self) -> None:
        self.install_healthy_stubs()
        bug = self.root / "services" / "relay" / "src" / "index.ts"
        bug.write_text("export const ok = false; // staged bug\n", encoding="utf-8")
        subprocess.run(["git", "add", "services/relay/src/index.ts"], cwd=self.root, check=True)
        bug.write_text("export const ok = true; // unstaged fix\n", encoding="utf-8")
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                f"""
                set -euo pipefail
                case "${{1:-}}" in
                  install)
                    rm -rf node_modules
                    mkdir -p node_modules
                    printf 'snapshot\\n' > node_modules/INSTALLED_IN_SNAPSHOT
                    exit 0
                    ;;
                  run)
                    shift
                    case "${{1:-}}" in
                      typecheck)
                        if grep -q 'staged bug' src/index.ts; then
                          echo 'typecheck failed on staged bug' >&2
                          exit 1
                        fi
                        exit 0
                        ;;
                      lint) exit 0 ;;
                      test:coverage)
                        mkdir -p coverage
                        printf '%s\\n' '{coverage_json()}' > coverage/coverage-summary.json
                        echo ok
                        exit 0
                        ;;
                    esac
                    ;;
                esac
                exit 1
                """
            ).strip(),
        )
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("unstaged fix", bug.read_text(encoding="utf-8"))
        indexed = subprocess.run(
            ["git", "show", ":services/relay/src/index.ts"],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertIn("staged bug", indexed.stdout)

    def test_rejects_missing_bun(self) -> None:
        self.env["PATH"] = str(self.bin)
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr + result.stdout, r"(?i)missing|bun")

    def test_rejects_coverage_below_95(self) -> None:
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                f"""
                set -euo pipefail
                case "${{1:-}}" in
                  install)
                    mkdir -p node_modules
                    printf 'snapshot\\n' > node_modules/INSTALLED_IN_SNAPSHOT
                    exit 0
                    ;;
                  run)
                    shift
                    case "${{1:-}}" in
                      typecheck|lint) exit 0 ;;
                      test:coverage)
                        mkdir -p coverage
                        printf '%s\\n' '{coverage_json(pct=90.0)}' > coverage/coverage-summary.json
                        echo ok
                        exit 0
                        ;;
                    esac
                    ;;
                esac
                exit 1
                """
            ).strip(),
        )
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr + result.stdout, r"(?i)coverage|95")

    def test_rejects_missing_coverage_report(self) -> None:
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                """
                set -euo pipefail
                case "${1:-}" in
                  install)
                    mkdir -p node_modules
                    printf 'snapshot\\n' > node_modules/INSTALLED_IN_SNAPSHOT
                    exit 0
                    ;;
                  run)
                    shift
                    case "${1:-}" in
                      typecheck|lint) exit 0 ;;
                      test:coverage)
                        mkdir -p coverage
                        echo ok
                        exit 0
                        ;;
                    esac
                    ;;
                esac
                exit 1
                """
            ).strip(),
        )
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr + result.stdout, r"(?i)coverage|report|missing")

    def test_rejects_empty_suite_via_zero_totals(self) -> None:
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                f"""
                set -euo pipefail
                case "${{1:-}}" in
                  install)
                    mkdir -p node_modules
                    printf 'snapshot\\n' > node_modules/INSTALLED_IN_SNAPSHOT
                    exit 0
                    ;;
                  run)
                    shift
                    case "${{1:-}}" in
                      typecheck|lint) exit 0 ;;
                      test:coverage)
                        mkdir -p coverage
                        printf '%s\\n' '{coverage_json(pct=100.0, total=0)}' > coverage/coverage-summary.json
                        exit 0
                        ;;
                    esac
                    ;;
                esac
                exit 1
                """
            ).strip(),
        )
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_lint_warnings_nonzero(self) -> None:
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                """
                set -euo pipefail
                case "${1:-}" in
                  install)
                    mkdir -p node_modules
                    printf 'snapshot\\n' > node_modules/INSTALLED_IN_SNAPSHOT
                    exit 0
                    ;;
                  run)
                    shift
                    case "${1:-}" in
                      typecheck) exit 0 ;;
                      lint)
                        echo 'warning: example' >&2
                        exit 1
                        ;;
                      test:coverage) exit 0 ;;
                    esac
                    ;;
                esac
                exit 1
                """
            ).strip(),
        )
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)

    def test_interrupt_terminates_child_group_and_cleans_scratch(self) -> None:
        observe = Path(self.temporary.name) / "observe"
        observe.mkdir()
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                f"""
                set -euo pipefail
                case "${{1:-}}" in
                  install)
                    printf '%s\\n' "$(dirname "$HOME")" > "{observe}/scratch"
                    printf '%s\\n' "$$" > "{observe}/child"
                    # Grandchild in the same process group (no setsid).
                    sleep 120 &
                    printf '%s\\n' "$!" > "{observe}/grandchild"
                    wait
                    exit 0
                    ;;
                esac
                exit 1
                """
            ).strip(),
        )
        proc = subprocess.Popen(
            [sys.executable, str(SCRIPT)],
            cwd=self.root,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.time() + 5
            while time.time() < deadline and not (observe / "grandchild").is_file():
                if proc.poll() is not None:
                    out, err = proc.communicate()
                    self.fail(f"gate exited early: {proc.returncode}\n{out}\n{err}")
                time.sleep(0.05)
            self.assertTrue((observe / "child").is_file())
            self.assertTrue((observe / "grandchild").is_file())
            child = int((observe / "child").read_text().strip())
            grandchild = int((observe / "grandchild").read_text().strip())
            scratch = Path((observe / "scratch").read_text().strip())
            os.kill(proc.pid, signal.SIGTERM)
            try:
                out, err = proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                out, err = proc.communicate(timeout=5)
                self.fail(f"gate did not exit after SIGTERM\n{out}\n{err}")
            self.assertNotEqual(proc.returncode, 0, out + err)
            time.sleep(0.2)

            def alive(pid: int) -> bool:
                try:
                    os.kill(pid, 0)
                    return True
                except OSError:
                    return False

            self.assertFalse(alive(child), f"child {child} still alive")
            self.assertFalse(alive(grandchild), f"grandchild {grandchild} still alive")
            self.assertFalse(scratch.exists(), f"scratch left behind: {scratch}")
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            if proc.stdout:
                proc.stdout.close()
            if proc.stderr:
                proc.stderr.close()

    def test_interrupt_sigkills_term_ignoring_grandchild(self) -> None:
        observe = Path(self.temporary.name) / "observe-ign"
        observe.mkdir()
        grandchild = None
        child = None
        stub_bin(
            self.bin,
            "bun",
            textwrap.dedent(
                f"""
                set -euo pipefail
                case "${{1:-}}" in
                  install)
                    printf '%s\\n' "$(dirname "$HOME")" > "{observe}/scratch"
                    printf '%s\\n' "$$" > "{observe}/child"
                    # Same process group; ignore SIGTERM so leader exit alone is insufficient.
                    bash -c 'trap "" TERM; exec sleep 120' &
                    printf '%s\\n' "$!" > "{observe}/grandchild"
                    wait || true
                    exit 0
                    ;;
                esac
                exit 1
                """
            ).strip(),
        )
        proc = subprocess.Popen(
            [sys.executable, str(SCRIPT)],
            cwd=self.root,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        def alive(pid: int) -> bool:
            try:
                os.kill(pid, 0)
                return True
            except OSError:
                return False

        def kill_observed() -> None:
            for path_name in ("grandchild", "child"):
                path = observe / path_name
                if not path.is_file():
                    continue
                try:
                    pid = int(path.read_text().strip())
                except ValueError:
                    continue
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
            if child is not None:
                try:
                    os.killpg(child, signal.SIGKILL)
                except OSError:
                    pass

        try:
            deadline = time.time() + 5
            while time.time() < deadline and not (observe / "grandchild").is_file():
                if proc.poll() is not None:
                    out, err = proc.communicate()
                    self.fail(f"gate exited early: {proc.returncode}\n{out}\n{err}")
                time.sleep(0.05)
            child = int((observe / "child").read_text().strip())
            grandchild = int((observe / "grandchild").read_text().strip())
            os.kill(proc.pid, signal.SIGTERM)
            try:
                out, err = proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                kill_observed()
                proc.kill()
                out, err = proc.communicate(timeout=5)
                self.fail(f"gate did not exit after SIGTERM\n{out}\n{err}")
            self.assertNotEqual(proc.returncode, 0, out + err)
            time.sleep(0.2)
            self.assertFalse(
                alive(grandchild),
                f"SIGTERM-ignoring grandchild {grandchild} still alive",
            )
        finally:
            kill_observed()
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            if proc.stdout:
                proc.stdout.close()
            if proc.stderr:
                proc.stderr.close()


class StagedGateLauncherTests(unittest.TestCase):
    def test_pre_commit_runs_staged_gate_not_worktree(self) -> None:
        text = (ROOT / ".husky" / "pre-commit").read_text(encoding="utf-8")
        self.assertIn(":scripts/relay-check-index.py", text)
        self.assertIn("check_output", text)
        self.assertIn("compile(", text)
        self.assertNotRegex(text, r"exec python3 scripts/relay-check-index\.py")
        self.assertNotIn("|", text)

    def test_staged_gate_bug_not_masked_by_worktree_fix(self) -> None:
        with tempfile.TemporaryDirectory(prefix="falcon-staged-gate-") as temporary:
            root = Path(temporary) / "repo"
            root.mkdir()
            subprocess.run(["git", "init", "-b", "main"], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            write(
                root / "scripts" / "relay-check-index.py",
                "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n",
                0o755,
            )
            write(root / "README", "x\n")
            subprocess.run(["git", "add", "."], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "commit", "-m", "init"], cwd=root, check=True, capture_output=True)
            # Stage a buggy gate; leave a fixed worktree copy.
            write(
                root / "scripts" / "relay-check-index.py",
                "#!/usr/bin/env python3\nimport sys\nprint('staged bug', file=sys.stderr)\nsys.exit(7)\n",
                0o755,
            )
            subprocess.run(
                ["git", "add", "scripts/relay-check-index.py"],
                cwd=root,
                check=True,
                capture_output=True,
            )
            write(
                root / "scripts" / "relay-check-index.py",
                "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n",
                0o755,
            )
            launcher = textwrap.dedent(
                """\
                import subprocess, sys
                data = subprocess.check_output(["git", "show", ":scripts/relay-check-index.py"])
                exec(compile(data, "scripts/relay-check-index.py", "exec"), {"__name__": "__main__"})
                """
            )
            result = subprocess.run(
                [sys.executable, "-c", launcher],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
            self.assertIn("staged bug", result.stderr)

    def test_missing_staged_gate_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="falcon-missing-gate-") as temporary:
            root = Path(temporary) / "repo"
            root.mkdir()
            subprocess.run(["git", "init", "-b", "main"], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            write(root / "README", "x\n")
            subprocess.run(["git", "add", "."], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "commit", "-m", "init"], cwd=root, check=True, capture_output=True)
            launcher = textwrap.dedent(
                """\
                import subprocess, sys
                data = subprocess.check_output(["git", "show", ":scripts/relay-check-index.py"])
                exec(compile(data, "scripts/relay-check-index.py", "exec"), {"__name__": "__main__"})
                """
            )
            result = subprocess.run(
                [sys.executable, "-c", launcher],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
