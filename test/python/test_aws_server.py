"""capabilities/aws/server.py: AWS CLI process credentials -> Container Credential Provider format (docs/aws.md)."""

import json
import unittest

from support import ServerTestCase

PROCESS_OUTPUT = {
    "Version": 1,
    "AccessKeyId": "ASIAEXAMPLE",
    "SecretAccessKey": "secret",
    "SessionToken": "session",
    "Expiration": "2030-01-01T00:00:00+00:00",
}


class AwsServerTest(ServerTestCase):
    module = "aws"

    def server_env(self):
        return {"AWS_PROFILE": "dev"}

    def fake_aws(self, stdout="", stderr="", code=0, sleep=0):
        self.args_file = self.tmp / "args"
        self.fake_cli(
            "aws",
            f'echo "$*" >> {self.args_file}\n'
            f"sleep {sleep}\n"
            f"printf '%s' '{stdout}'\n"
            f"printf '%s' '{stderr}' >&2\n"
            f"exit {code}\n",
        )

    def test_converts_process_output_to_container_format(self):
        self.fake_aws(json.dumps(PROCESS_OUTPUT))
        status, headers, body = self.request("GET", "/credentials")
        self.assertEqual(status, 200)
        self.assertEqual(
            json.loads(body),
            {
                "AccessKeyId": "ASIAEXAMPLE",
                "SecretAccessKey": "secret",
                "Token": "session",
                "Expiration": "2030-01-01T00:00:00+00:00",
            },
        )
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_runs_export_credentials_for_the_configured_profile(self):
        self.fake_aws(json.dumps(PROCESS_OUTPUT))
        self.request("GET", "/credentials")
        self.assertEqual(
            self.args_file.read_text().strip(), "configure export-credentials --profile dev --format process"
        )

    def test_long_lived_keys_are_refused(self):
        # A profile with static keys resolves without SessionToken / Expiration; it must not reach the agent
        for output in (
            {"Version": 1, "AccessKeyId": "AKIASTATIC", "SecretAccessKey": "long-lived-secret"},
            {"Version": 1, "AccessKeyId": "AKIASTATIC", "SecretAccessKey": "long-lived-secret", "SessionToken": "t"},
            {"Version": 1, "AccessKeyId": "AKIASTATIC", "SecretAccessKey": "long-lived-secret", "Expiration": "x"},
        ):
            self.fake_aws(json.dumps(output))
            status, _, body = self.request("GET", "/credentials")
            self.assertEqual(status, 503, output)
            reply = json.loads(body)
            self.assertEqual(reply["Code"], "CredentialsUnavailable")
            self.assertIn("long-lived keys", reply["Message"])
            self.assertIn("profile dev", reply["Message"])
            self.assertNotIn(b"long-lived-secret", body)
            self.assertNotIn(b"AKIASTATIC", body)

    def test_cli_failure_is_503_and_diagnostics_stay_in_the_sidecar(self):
        self.fake_aws(stderr="Error when retrieving token: session expired SENSITIVE", code=255)
        status, _, body = self.request("GET", "/credentials")
        self.assertEqual(status, 503)
        reply = json.loads(body)
        self.assertEqual(reply["Code"], "CredentialsUnavailable")
        self.assertIn("exit 255", reply["Message"])
        self.assertNotIn(b"SENSITIVE", body)
        self.assertIn("SENSITIVE", self.log.getvalue())

    def test_unexpected_output_is_503(self):
        self.fake_aws("not json")
        status, _, body = self.request("GET", "/credentials")
        self.assertEqual(status, 503)
        self.assertIn("unexpected output", json.loads(body)["Message"])

    def test_timeout_is_503(self):
        self.server_module.TIMEOUT_SEC = 0.5
        self.fake_aws(json.dumps(PROCESS_OUTPUT), sleep=3)
        status, _, body = self.request("GET", "/credentials")
        self.assertEqual(status, 503)
        self.assertIn("timed out", json.loads(body)["Message"])

    def test_other_paths_are_404_without_running_the_cli(self):
        self.fake_aws(json.dumps(PROCESS_OUTPUT))
        for path in ("/", "/credentials/", "/credentials?x=1"):
            status, _, _ = self.request("GET", path)
            self.assertEqual(status, 404, path)
        self.assertFalse(self.args_file.exists())

    def test_access_log_has_neither_credentials_nor_query_string(self):
        self.fake_aws(json.dumps(PROCESS_OUTPUT))
        self.request("GET", "/credentials")
        self.request("GET", "/credentials?token=abc")
        log = self.log.getvalue()
        self.assertIn("GET /credentials 200", log)
        for secret in ("secret", "session", "token=abc"):
            self.assertNotIn(secret, log)


if __name__ == "__main__":
    unittest.main()
