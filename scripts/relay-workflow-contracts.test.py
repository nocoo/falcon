#!/usr/bin/env python3
"""Contract tests for Falcon relay CI/CD workflows and husky wiring.

Stdlib only. Expects files under .github/, .husky/, and scripts/relay-*.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE_CI_SHA = "0394178ebcff0418c442d84a84119220f31f8987"
BASE_CI_PIN = f"nocoo/base-ci/.github/workflows/{{name}}.yml@{BASE_CI_SHA}"


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        raise FileNotFoundError(relative)
    return path.read_text(encoding="utf-8")


def uses_refs(text: str) -> list[str]:
    return re.findall(r"(?:^\s+uses:\s*|uses:\s*)(\S+)", text, flags=re.MULTILINE)


class WorkflowContractTests(unittest.TestCase):
    def test_ci_workflow_exists_and_triggers(self) -> None:
        text = read(".github/workflows/ci.yml")
        self.assertRegex(text, r"(?m)^name:\s*CI\s*$")
        self.assertIn("pull_request:", text)
        self.assertRegex(text, r"branches:\s*\[\s*main\s*\]")
        self.assertIn("push:", text)
        self.assertNotIn("BASE_CI_SHA", text)

    def test_ci_pins_base_ci_quality_test_job_and_workflow_lint(self) -> None:
        text = read(".github/workflows/ci.yml")
        refs = uses_refs(text)
        self.assertIn(BASE_CI_PIN.format(name="quality"), refs)
        self.assertIn(BASE_CI_PIN.format(name="test-job"), refs)
        self.assertIn(BASE_CI_PIN.format(name="workflow-lint"), refs)
        for ref in refs:
            if ref.startswith("nocoo/base-ci/"):
                self.assertRegex(ref, r"@[a-f0-9]{40}$")
                self.assertTrue(ref.endswith(BASE_CI_SHA))

    def test_worker_quality_gate_is_service_scoped(self) -> None:
        text = read(".github/workflows/ci.yml")
        self.assertRegex(text, r"working-directory:\s*services/relay")
        self.assertRegex(text, r"runtime-version:\s*['\"]1\.4\.3['\"]")
        self.assertRegex(text, r"node-version:\s*['\"]26\.8\.1['\"]")
        self.assertRegex(text, r"coverage-path:\s*services/relay/coverage")
        self.assertRegex(text, r"lockfiles:\s*bun\.lock")
        self.assertIn("bun run typecheck", text)
        self.assertIn("bun run lint", text)
        self.assertIn("bun run test:coverage", text)
        self.assertIn("bun run test:http", text)
        self.assertIn("security-command:", text)
        self.assertIn("gitleaks", text)
        self.assertIn("GITHUB_WORKSPACE", text)

    def test_check_index_install_uses_copyfile_backend(self) -> None:
        text = read("scripts/relay-check-index.py")
        self.assertIn("--backend=copyfile", text)
        self.assertIn("--offline", text)
        self.assertIn("--frozen-lockfile", text)

    def test_native_job_uses_documented_xcode_commands_without_swift_95_gate(self) -> None:
        text = read(".github/workflows/ci.yml")
        self.assertIn("macos", text.lower())
        self.assertIn(
            "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer",
            text,
        )
        self.assertIn("0.13.1", text)
        self.assertIn("0.65.1", text)
        self.assertIn(
            "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0",
            text,
        )
        self.assertIn("shasum", text)
        self.assertIn("uv", text)
        self.assertIn("swiftlint", text)
        self.assertNotIn("brew install uv swiftlint", text)
        self.assertIn("swift test --enable-code-coverage", text)
        self.assertIn("--show-codecov-path", text)
        self.assertIn("scripts/check-sdk.sh", text)
        self.assertNotIn(".build/out/Products/Debug/codecov", text)
        self.assertIn("build/verification/native-codecov", text)
        self.assertIn("artifact-name:", text)
        self.assertIn("artifact-path:", text)
        self.assertIn("swiftlint lint --strict", text)
        self.assertIn(
            "xcrun swift-format lint --strict --recursive Sources Tests",
            text,
        )
        self.assertNotRegex(
            text,
            r"(?i)(?:fail|enforce|require)[^\n]{0,40}swift[^\n]{0,40}(?:95|coverage floor)",
        )
        self.assertNotRegex(
            text,
            r"(?i)swift[^\n]{0,40}(?:95%|coverage floor)[^\n]{0,40}(?:fail|enforce|require)",
        )
        self.assertIn("Swift coverage gaps remain explicit", text)

    def test_worker_build_passes_git_sha_env(self) -> None:
        ci = read(".github/workflows/ci.yml")
        deploy = read(".github/workflows/deploy.yml")
        self.assertRegex(ci, r"GIT_SHA=.*GITHUB_SHA")
        self.assertIn("GIT_SHA=", deploy)
        self.assertIn("inputs.exact-sha", deploy)

    def test_helpers_job_runs_relay_python_tests_and_shell_syntax(self) -> None:
        text = read(".github/workflows/ci.yml")
        self.assertRegex(text, r"(?m)^\s*helpers:\s*$")
        self.assertGreaterEqual(
            uses_refs(text).count(BASE_CI_PIN.format(name="test-job")),
            2,
        )
        self.assertIn("scripts/relay-*.test.py", text)
        self.assertIn("bash -n", text)
        self.assertIn("relay-bootstrap-hooks.sh", text)
        # Python helpers must not claim Worker 95% coverage.
        helpers_block = re.search(
            r"(?ms)^\s*helpers:\n(.*?)(?=^\s*[a-z0-9-]+:\s*$)",
            text,
        )
        self.assertIsNotNone(helpers_block)
        assert helpers_block is not None
        body = helpers_block.group(1)
        self.assertNotIn("95%", body)
        self.assertNotIn("coverage-path", body)
        self.assertIn("needs.helpers.result", text)
        self.assertIn("needs.helpers.outputs.tested-sha", text)
        # Coverage artifact remains Worker-scoped only.
        self.assertRegex(text, r"coverage-path:\s*services/relay/coverage")
        self.assertEqual(text.count("coverage-path:"), 1)

    def test_deploy_is_dispatch_only_with_source_proof(self) -> None:
        text = read(".github/workflows/deploy.yml")
        self.assertRegex(text, r"(?m)^name:\s*Deploy\s*$")
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("source-run-id:", text)
        self.assertIn("exact-sha:", text)
        self.assertNotIn("workflow_run:", text)
        self.assertIn(BASE_CI_PIN.format(name="deploy-worker"), text)
        self.assertRegex(text, r"deploy-cli:\s*cf")
        self.assertRegex(text, r"cf-version:\s*['\"]?1\.0\.0-beta\.13['\"]?")
        self.assertRegex(text, r"runtime-version:\s*['\"]1\.4\.3['\"]")
        self.assertRegex(text, r"node-version:\s*['\"]26\.8\.1['\"]")
        self.assertRegex(text, r"working-directory:\s*services/relay")
        self.assertRegex(text, r"environment:\s*.*production")
        self.assertIn("source-sha:", text)
        self.assertIn("inputs.exact-sha", text)
        self.assertIn("inputs.source-run-id", text)
        self.assertIn("scripts/relay-verify-production", text)
        self.assertIn("cloudflare.config.ts", text.lower() + text)
        # Prefer an explicit non-cancel note via reusable concurrency; caller may set group.
        self.assertTrue(
            "concurrency-group:" in text or "cancel-in-progress: false" in text
        )

    def test_no_floating_action_pins_in_owned_workflows(self) -> None:
        for relative in (
            ".github/workflows/ci.yml",
            ".github/workflows/deploy.yml",
        ):
            text = read(relative)
            for ref in uses_refs(text):
                if ref.startswith("./"):
                    continue
                self.assertRegex(
                    ref,
                    r".+@[a-f0-9]{40}$",
                    msg=f"{relative} has non-immutable ref: {ref}",
                )


class HuskyAndScriptContractTests(unittest.TestCase):
    def test_pre_commit_invokes_index_check_only(self) -> None:
        text = read(".husky/pre-commit")
        self.assertIn(":scripts/relay-check-index.py", text)
        self.assertIn("git", text)
        self.assertIn("show", text)
        self.assertIn("compile(", text)
        self.assertNotIn("|", text)
        self.assertNotIn("swift test", text)
        self.assertNotIn("95%", text)

    def test_bootstrap_uses_service_husky_bin(self) -> None:
        text = read("scripts/relay-bootstrap-hooks.sh")
        self.assertIn("services/relay/node_modules/.bin/husky", text)
        self.assertIn("relay-hooks-bootstrap", text)
        self.assertNotIn("FALCON_RELAY_HOOKS_APPROVE", text)
        self.assertNotRegex(text, r"(?m)^\s*git config core\.hooksPath \.husky\s*$")
        self.assertIn(".husky/_", text)

    def test_check_index_and_verify_entrypoints_exist(self) -> None:
        self.assertTrue((ROOT / "scripts/relay-check-index.py").is_file())
        self.assertTrue((ROOT / "scripts/relay-verify-production.py").is_file())


if __name__ == "__main__":
    unittest.main()
