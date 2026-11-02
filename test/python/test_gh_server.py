"""capabilities/gh/server.py: `gh auth token` as a loopback endpoint (docs/github.md)."""

import unittest

from support import ServerTestCase

TOKEN_VARS = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_DEBUG", "DEBUG")


class GhServerTest(ServerTestCase):
    module = "gh"

    def server_env(self):
        env = {name: f"leaked-{name}" for name in TOKEN_VARS}
        env["GH_HOST"] = "ghe.example.com"
        return env

    def fake_gh(self, script):
        self.env_file = self.tmp / "env"
        self.args_file = self.tmp / "args"
        self.fake_cli("gh", f'env > {self.env_file}\necho "$*" >> {self.args_file}\n{script}')

    def test_returns_the_token_as_text(self):
        self.fake_gh("echo gho_example")
        status, headers, body = self.request("GET", "/token")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"gho_example")
        self.assertEqual(headers["Content-Type"], "text/plain; charset=utf-8")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(self.args_file.read_text().strip(), "auth token --hostname ghe.example.com")

    def test_token_env_vars_are_not_passed_to_gh(self):
        # gh prefers GH_TOKEN over its stored (refreshable) credentials, so none may come through
        self.fake_gh("echo gho_example")
        self.request("GET", "/token")
        env = dict(line.split("=", 1) for line in self.env_file.read_text().splitlines() if "=" in line)
        for name in TOKEN_VARS:
            self.assertNotIn(name, env)
        self.assertEqual(env["GH_PROMPT_DISABLED"], "1")

    def test_not_logged_in_is_503_with_the_login_hint(self):
        self.fake_gh("echo 'no oauth token found SENSITIVE' >&2; exit 1")
        status, _, body = self.request("GET", "/token")
        self.assertEqual(status, 503)
        self.assertIn(b"run 'dcc gh-login' on the host", body)
        self.assertNotIn(b"SENSITIVE", body)
        self.assertIn("SENSITIVE", self.log.getvalue())

    def test_empty_token_is_503(self):
        self.fake_gh("echo")
        status, _, body = self.request("GET", "/token")
        self.assertEqual(status, 503)
        self.assertEqual(body, b"gh auth token returned nothing\n")

    def test_timeout_is_503(self):
        self.server_module.TIMEOUT_SEC = 0.5
        self.fake_gh("sleep 3; echo late")
        status, _, body = self.request("GET", "/token")
        self.assertEqual(status, 503)
        self.assertIn(b"timed out", body)

    def test_other_paths_are_404(self):
        self.fake_gh("echo gho_example")
        for path in ("/", "/token/", "/token?x=1"):
            status, _, _ = self.request("GET", path)
            self.assertEqual(status, 404, path)
        self.assertFalse(self.args_file.exists())

    def test_only_get_is_served(self):
        self.fake_gh("echo gho_example")
        status, _, _ = self.request("POST", "/token", body=b"")
        self.assertEqual(status, 501)

    def test_access_log_has_no_token(self):
        self.fake_gh("echo gho_example")
        self.request("GET", "/token")
        self.assertIn("GET /token 200", self.log.getvalue())
        self.assertNotIn("gho_example", self.log.getvalue())


if __name__ == "__main__":
    unittest.main()
