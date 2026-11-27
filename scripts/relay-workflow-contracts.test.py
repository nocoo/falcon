#!/usr/bin/env python3
"""Contract tests for Falcon relay CI/CD workflows and husky wiring.

Stdlib only. Expects files under .github/, .husky/, and scripts/relay-*.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE_CI_SHA = "9933a7461a312cfaac526ccc5907357a7e3f669a"
BASE_CI_PIN = f"nocoo/base-ci/.github/workflows/{{name}}.yml@{BASE_CI_SHA}"


def read(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        raise FileNotFoundError(relative)
    return path.read_text(encoding="utf-8")


def uses_refs(text: str) -> list[str]:
    return re.findall(r"^\s*(?:-\s*)?uses:\s*(\S+)", text, flags=re.MULTILINE)


class WorkflowContractTests(unittest.TestCase):
    def test_pipeline_workflow_exists_and_triggers(self) -> None:
        text = read(".github/workflows/pipeline.yml")
        self.assertRegex(text, r"(?m)^name:\s*Pipeline\s*$")
        self.assertIn("pull_request:", text)
        self.assertRegex(text, r"branches:\s*\[\s*main\s*\]")
        self.assertIn("push:", text)
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("tags:", text)
        self.assertNotIn("BASE_CI_SHA", text)
        self.assertFalse((ROOT / ".github/workflows/ci.yml").exists())
        self.assertFalse((ROOT / ".github/workflows/release.yml").exists())

    def test_pipeline_delegates_quality_and_deploy(self) -> None:
        pipeline_text = read(".github/workflows/pipeline.yml")
        slots_text = read(".github/workflows/quality-slots.yml")
        pipeline_refs = uses_refs(pipeline_text)
        self.assertEqual(
            pipeline_refs,
            [
                "./.github/workflows/quality-slots.yml",
                BASE_CI_PIN.format(name="deploy-worker"),
            ],
        )
        self.assertNotIn("ci-gate:", pipeline_text)
        self.assertNotIn("CI Gate", pipeline_text)
        for ref in uses_refs(slots_text):
            if ref.startswith("nocoo/base-ci/"):
                self.assertRegex(ref, r"@[a-f0-9]{40}$")
                self.assertTrue(ref.endswith(BASE_CI_SHA))

    def test_worker_quality_gate_is_service_scoped(self) -> None:
        text = read(".github/workflows/quality-slots.yml")
        self.assertRegex(text, r"working-directory:\s*services/relay")
        self.assertRegex(text, r"BUN_VERSION:\s*['\"]1\.4\.3['\"]")
        self.assertRegex(text, r"NODE_VERSION:\s*['\"]26\.12\.1['\"]")
        self.assertRegex(text, r"services/relay/bun\.lock")
        self.assertIn("bun run typecheck", text)
        self.assertIn("bun run lint", text)
        self.assertIn("bun run test:coverage", text)
        self.assertIn("bun run build", text)
        self.assertIn("bun run test:http", text)
        self.assertIn("nocoo/base-ci/.github/actions/lint-workflows@", text)
        self.assertIn("nocoo/base-ci/.github/actions/scan-secrets@", text)
        self.assertIn("nocoo/base-ci/.github/actions/scan-dependencies@", text)

    def test_check_index_install_uses_copyfile_backend(self) -> None:
        text = read("scripts/relay-check-index.py")
        self.assertIn("--backend=copyfile", text)
        self.assertIn("--offline", text)
        self.assertIn("--frozen-lockfile", text)

    def test_native_job_uses_documented_xcode_commands_without_swift_95_gate(self) -> None:
        text = read(".github/workflows/quality-slots.yml")
        self.assertRegex(text, r"(?m)^\s*l1-native-swift:\s*$")
        self.assertIn("L1: Unit (Swift)", text)
        self.assertIn("S2: Lint (Swift)", text)
        self.assertIn("macos", text.lower())
        self.assertIn(
            "DEVELOPER_DIR: /Applications/Xcode.app/Contents/Developer",
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
        self.assertIn("FALCON_PYTHON", text)
        self.assertIn("typesafe-sdk==0.7.1", text)
        self.assertIn("fetch-depth: 0", text)
        self.assertIn("Restore git commit mtimes", text)
        self.assertNotIn(".build/out/Products/Debug/codecov", text)
        self.assertIn("build/verification/native-codecov", text)
        self.assertIn("actions/cache@", text)
        self.assertIn("actions/upload-artifact@", text)
        self.assertIn("native-codecov", text)
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

    def test_worker_build_passes_git_sha_and_uploads_artifact(self) -> None:
        ci = read(".github/workflows/quality-slots.yml")
        self.assertRegex(ci, r"GIT_SHA=.*GITHUB_SHA")
        self.assertIn("b1-relay-build", ci)
        self.assertIn("services/relay/.cloudflare/output/", ci)
        self.assertIn("include-hidden-files: true", ci)

    def test_ci_checks_production_prebuilt_deployment(self) -> None:
        scripts = json.loads(read("services/relay/package.json"))["scripts"]
        self.assertEqual(scripts["build"], "cf build --mode production")
        self.assertEqual(
            scripts["test:http"],
            "bun run build && cf deploy --prebuilt --mode production --dry-run"
            " && bun run test:harness",
        )

    def test_sdk_check_selects_supported_python_explicitly(self) -> None:
        text = read("scripts/check-sdk.sh")
        self.assertIn("uv run --python 3.12.14 --no-project", text)
        self.assertIn("--with 'typesafe-sdk==0.7.1'", text)

    def test_helpers_job_runs_relay_helper_tests(self) -> None:
        text = read(".github/workflows/quality-slots.yml")
        self.assertRegex(text, r"(?m)^\s*l1-relay:\s*$")
        self.assertIn("L1: Unit (Relay)", text)
        self.assertIn("scripts/relay-verify-production.test.py", text)
        self.assertIn("scripts/relay-workflow-contracts.test.py", text)
        self.assertNotIn("relay-bootstrap-hooks", text)
        # Python helpers must not claim Worker coverage floors.
        helpers_block = re.search(
            r"(?ms)^\s*l1-relay:\n(.*?)(?=^\s*[a-z0-9-]+:\s*$)",
            text,
        )
        self.assertIsNotNone(helpers_block)
        assert helpers_block is not None
        body = helpers_block.group(1)
        self.assertNotIn("95%", body)
        self.assertNotIn("80%", body)
        self.assertNotIn("coverage-path", body)
        self.assertIn("nocoo/base-ci/.github/actions/z1-gate@", text)
        self.assertIn("needs-json: ${{ toJSON(needs) }}", text)
        self.assertIn("l1-relay", text)
        self.assertIn("l1-native-swift", text)
        self.assertIn("l3-integration", text)
        self.assertNotIn("needs.workflow-lint", text)
        self.assertNotIn("needs.native", text)
        self.assertEqual(read(".github/workflows/pipeline.yml").count("gitleaks"), 0)

    def test_deploy_is_gated_on_quality_and_reuses_b1(self) -> None:
        text = read(".github/workflows/pipeline.yml")
        self.assertRegex(text, r"(?m)^name:\s*Pipeline\s*$")
        self.assertIn("needs: [quality]", text)
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("workflow_run:", text)
        self.assertIn(BASE_CI_PIN.format(name="deploy-worker"), text)
        self.assertRegex(text, r"deploy-cli:\s*cf")
        self.assertRegex(text, r"cf-version:\s*['\"]?1\.0\.0-beta\.13['\"]?")
        self.assertRegex(text, r"runtime-version:\s*['\"]1\.4\.3['\"]")
        self.assertRegex(text, r"node-version:\s*['\"]26\.12\.1['\"]")
        self.assertRegex(text, r"working-directory:\s*services/relay")
        self.assertRegex(text, r"artifact-name:\s*b1-relay-build")
        self.assertRegex(text, r"artifact-path:\s*services/relay/\.cloudflare/output")
        self.assertNotIn("build-command:", text)
        self.assertRegex(text, r"environment:\s*.*production")
        self.assertIn("scripts/relay-verify-production", text)
        self.assertTrue(
            "concurrency-group:" in text or "cancel-in-progress: false" in text
        )

    def test_no_floating_action_pins_in_owned_workflows(self) -> None:
        for relative in (
            ".github/workflows/pipeline.yml",
            ".github/workflows/quality-slots.yml",
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

    def test_relay_package_prepare_bootstraps_husky(self) -> None:
        package = json.loads(read("services/relay/package.json"))
        prepare = package.get("scripts", {}).get("prepare", "")
        self.assertIn("relay-bootstrap-hooks.sh", prepare)
        self.assertNotIn("ignore-scripts", prepare)

    def test_check_index_and_verify_entrypoints_exist(self) -> None:
        self.assertTrue((ROOT / "scripts/relay-check-index.py").is_file())
        self.assertTrue((ROOT / "scripts/relay-verify-production.py").is_file())


if __name__ == "__main__":
    unittest.main()
