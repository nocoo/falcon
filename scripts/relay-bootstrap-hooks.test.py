#!/usr/bin/env python3
"""Tests for scripts/relay-bootstrap-hooks.sh Husky integration."""

from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "relay-bootstrap-hooks.sh"


def write(path: Path, content: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(mode)


class BootstrapHooksTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(SCRIPT.is_file())
        self.temporary = tempfile.TemporaryDirectory(prefix="falcon-relay-bootstrap-")
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        subprocess.run(["git", "init", "-b", "main"], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=self.root, check=True)
        write(self.root / ".husky" / "pre-commit", "#!/bin/sh\nexit 0\n", 0o755)
        # Bootstrap validates registries via the real check-index script.
        check_index = ROOT / "scripts" / "relay-check-index.py"
        write(
            self.root / "scripts" / "relay-check-index.py",
            check_index.read_text(encoding="utf-8"),
            0o755,
        )
        write(self.root / "scripts" / "relay-verify-production.py", "#!/usr/bin/env python3\nprint(0)\n", 0o755)
        write(self.root / "README", "x\n")
        subprocess.run(["git", "add", "."], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=self.root, check=True, capture_output=True)
        # Copy bootstrap script under test into the fixture repo path expected by relative docs,
        # but invoke the real script with cwd=fixture via bash and GIT top-level.
        self.bootstrap = self.root / "scripts" / "relay-bootstrap-hooks.sh"
        self.bootstrap.write_bytes(SCRIPT.read_bytes())
        self.bootstrap.chmod(0o755)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _env(self, **extra: str) -> dict[str, str]:
        env = {
            **os.environ,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        }
        env.pop("BUN_CONFIG_REGISTRY", None)
        env.update(extra)
        return env

    def _install_husky_stub(self) -> None:
        husky = self.root / "services" / "relay" / "node_modules" / ".bin" / "husky"
        write(
            husky,
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                # Mimic husky: create .husky/_ launcher and set hooksPath to .husky/_
                mkdir -p .husky/_
                printf '*\\n' > .husky/_/.gitignore
                printf '#!/usr/bin/env sh\\necho stub-h\\n' > .husky/_/h
                chmod +x .husky/_/h
                for hook in pre-commit; do
                  printf '#!/usr/bin/env sh\\n. "$(dirname "$0")/h"\\n' > ".husky/_/$hook"
                  chmod +x ".husky/_/$hook"
                done
                git config core.hooksPath .husky/_
                printf 'husky-stub-ok dir=%s\\n' "${1:-.husky}"
                """
            ),
            0o755,
        )

    def _registry(self) -> str:
        result = subprocess.run(
            ["git", "config", "--get", "falcon.relayRegistry"],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=False,
        )
        return result.stdout.strip() if result.returncode == 0 else ""

    def test_fails_when_husky_bin_missing(self) -> None:
        result = subprocess.run(
            ["bash", str(self.bootstrap)],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=False,
            env=self._env(),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(result.stderr + result.stdout, r"(?i)husky")

    def test_runs_service_husky_to_create_launcher(self) -> None:
        self._install_husky_stub()
        result = subprocess.run(
            ["bash", str(self.bootstrap)],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=False,
            env=self._env(),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / ".husky" / "_" / "h").is_file())
        hooks_path = subprocess.run(
            ["git", "config", "--get", "core.hooksPath"],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
        self.assertEqual(hooks_path, ".husky/_")
        self.assertTrue((self.root / ".husky" / "pre-commit").is_file())
        self.assertEqual(self._registry(), "")

    def test_records_healthy_registry_from_env(self) -> None:
        self._install_husky_stub()
        registry = "https://packagefeedproxy.microsoft.io/npm/"
        result = subprocess.run(
            ["bash", str(self.bootstrap)],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=False,
            env=self._env(BUN_CONFIG_REGISTRY=registry),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self._registry(), registry)
        self.assertRegex(result.stdout + result.stderr, r"falcon\.relayRegistry")

    def test_preserves_existing_registry_when_env_absent(self) -> None:
        self._install_husky_stub()
        existing = "https://packagefeedproxy.microsoft.io/npm/"
        subprocess.run(
            ["git", "config", "falcon.relayRegistry", existing],
            cwd=self.root,
            check=True,
            capture_output=True,
        )
        result = subprocess.run(
            ["bash", str(self.bootstrap)],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=False,
            env=self._env(),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self._registry(), existing)
        self.assertRegex(result.stdout + result.stderr, r"(?i)preserving")

    def test_rejects_invalid_registry_urls(self) -> None:
        self._install_husky_stub()
        cases = [
            "http://example.com/npm/",
            "https://user:secret@example.com/npm/",
            "https://example.com/npm/?token=1",
            "https://example.com/npm/#frag",
        ]
        for url in cases:
            with self.subTest(url=url):
                before = self._registry()
                result = subprocess.run(
                    ["bash", str(self.bootstrap)],
                    cwd=self.root,
                    text=True,
                    capture_output=True,
                    check=False,
                    env=self._env(BUN_CONFIG_REGISTRY=url),
                )
                self.assertNotEqual(result.returncode, 0)
                combined = result.stdout + result.stderr
                self.assertNotIn("secret", combined)
                self.assertNotIn("token=1", combined)
                self.assertEqual(self._registry(), before)


if __name__ == "__main__":
    unittest.main()
