"""Shared by the sidecar server tests (capabilities/*/server.py). Run with `make test` (stdlib only).

Each test loads a fresh copy of a server.py with a patched environment, serves its Handler on an ephemeral
loopback port in a thread, and puts fake CLIs (aws / gh) first on PATH. docs/testing.md
"""

import http.client
import importlib.util
import io
import os
import shutil
import stat
import sys
import tempfile
import threading
import unittest
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]

# Loading capabilities/*/server.py must not leave __pycache__ in the sidecar build contexts
sys.dont_write_bytecode = True


class ServerTestCase(unittest.TestCase):
    """Subclasses set `module` (directory name under capabilities/) and may override `server_env()`."""

    module = ""

    def server_env(self):
        return {}

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix=f"dcc-{self.module}-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        env = {"PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}"}
        env.update(self.server_env())
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)

        # The servers log to sys.stderr; keep it for assertions instead of printing it
        self.log = io.StringIO()
        stderr = mock.patch.object(sys, "stderr", self.log)
        stderr.start()
        self.addCleanup(stderr.stop)

        self.server_module = self.load()
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), self.server_module.Handler)
        thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def load(self):
        """A fresh copy of capabilities/<module>/server.py (module-level settings are read from the environment)."""
        path = REPO / "capabilities" / self.module / "server.py"
        spec = importlib.util.spec_from_file_location(f"{self.module}_server_{uuid.uuid4().hex}", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def fake_cli(self, name, script):
        """An executable `name` on PATH running the given bash script."""
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + script)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.httpd.server_address[1], timeout=60)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            resp = conn.getresponse()
            return resp.status, dict(resp.getheaders()), resp.read()
        finally:
            conn.close()
