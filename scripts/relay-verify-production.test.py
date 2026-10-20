#!/usr/bin/env python3
"""Tests for scripts/relay-verify-production.py (stdlib HTTP fixture)."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "relay-verify-production.py"


class LiveHandler(BaseHTTPRequestHandler):
    body = b'{"status":"ok","version":"0.1.7","gitSha":"abc"}'
    status = 200
    seen_headers: dict[str, str] = {}

    def do_GET(self) -> None:  # noqa: N802
        type(self).seen_headers = {k.lower(): v for k, v in self.headers.items()}
        if self.path != "/api/live":
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(self.status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


def serve(handler: type[BaseHTTPRequestHandler]) -> tuple[HTTPServer, str]:
    server = HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    return server, f"http://{host}:{port}/api/live"


def stop(server: HTTPServer) -> None:
    server.shutdown()
    server.server_close()


class VerifyProductionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(SCRIPT.is_file(), "relay-verify-production.py missing")

    def run_verify(self, url: str, sha: str, project_yml: str, env: dict | None = None) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="falcon-relay-verify-") as temporary:
            root = Path(temporary)
            (root / "project.yml").write_text(project_yml, encoding="utf-8")
            command_env = {
                **os.environ,
                "FALCON_VERIFY_URL": url,
                "FALCON_VERIFY_SHA": sha,
                "FALCON_VERIFY_ROOT": str(root),
            }
            if env:
                command_env.update(env)
            return subprocess.run(
                [sys.executable, str(SCRIPT)],
                cwd=root,
                env=command_env,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_accepts_matching_live_payload(self) -> None:
        handler = type(
            "OK",
            (LiveHandler,),
            {
                "body": json.dumps(
                    {"status": "ok", "version": "0.1.7", "gitSha": "deadbeef" * 5}
                ).encode(),
                "status": 200,
                "seen_headers": {},
            },
        )
        server, url = serve(handler)
        try:
            result = self.run_verify(
                url,
                "deadbeef" * 5,
                'MARKETING_VERSION: "0.1.7"\n',
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            cache_control = handler.seen_headers.get("cache-control", "")
            self.assertIn("no-cache", cache_control.lower())
            user_agent = handler.seen_headers.get("user-agent", "")
            self.assertTrue(user_agent, "User-Agent header required")
            self.assertFalse(
                user_agent.lower().startswith("python-urllib/"),
                f"default urllib User-Agent must not be used: {user_agent!r}",
            )
            self.assertEqual(user_agent, "falcon-deploy-verify/1.0")
        finally:
            stop(server)

    def test_rejects_status_not_ok(self) -> None:
        handler = type(
            "BadStatus",
            (LiveHandler,),
            {
                "body": b'{"status":"degraded","version":"0.1.7","gitSha":"aaa"}',
                "status": 200,
                "seen_headers": {},
            },
        )
        server, url = serve(handler)
        try:
            result = self.run_verify(url, "aaa", 'MARKETING_VERSION: "0.1.7"\n')
            self.assertNotEqual(result.returncode, 0)
        finally:
            stop(server)

    def test_rejects_version_mismatch(self) -> None:
        handler = type(
            "BadVersion",
            (LiveHandler,),
            {
                "body": b'{"status":"ok","version":"9.9.9","gitSha":"bbb"}',
                "status": 200,
                "seen_headers": {},
            },
        )
        server, url = serve(handler)
        try:
            result = self.run_verify(url, "bbb", 'MARKETING_VERSION: "0.1.7"\n')
            self.assertNotEqual(result.returncode, 0)
        finally:
            stop(server)

    def test_rejects_git_sha_mismatch(self) -> None:
        handler = type(
            "BadSha",
            (LiveHandler,),
            {
                "body": b'{"status":"ok","version":"0.1.7","gitSha":"ccc"}',
                "status": 200,
                "seen_headers": {},
            },
        )
        server, url = serve(handler)
        try:
            result = self.run_verify(url, "ddd", 'MARKETING_VERSION: "0.1.7"\n')
            self.assertNotEqual(result.returncode, 0)
        finally:
            stop(server)

    def test_rejects_http_error(self) -> None:
        handler = type(
            "HTTP500",
            (LiveHandler,),
            {"body": b"{}", "status": 500, "seen_headers": {}},
        )
        server, url = serve(handler)
        try:
            result = self.run_verify(url, "eee", 'MARKETING_VERSION: "0.1.7"\n')
            self.assertNotEqual(result.returncode, 0)
        finally:
            stop(server)


if __name__ == "__main__":
    unittest.main()
