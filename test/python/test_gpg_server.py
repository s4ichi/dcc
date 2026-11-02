"""capabilities/gpg/server.py: detached signatures of git objects only, with the pinned key (docs/gpg.md).

Uses the real gpg with a throwaway keyring (skipped when gpg is not installed).
"""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from support import ServerTestCase

COMMIT = b"tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor t <t@example.invalid> 0 +0000\n\nmsg\n"
TAG = b"object 4b825dc642cb6eb9a060e54bf8d69288fbee4904\ntype commit\ntag v1\n\nmsg\n"
SHA256_COMMIT = b"tree " + b"a" * 64 + b"\n\nmsg\n"


def gpg(home, *args, **kwargs):
    return subprocess.run(["gpg", "--homedir", str(home), "--batch", *args], capture_output=True, check=True, **kwargs)


@unittest.skipUnless(shutil.which("gpg"), "gpg not installed")
class GpgServerTest(ServerTestCase):
    module = "gpg"
    signing_key = None  # set per class: the fingerprint, or "" for "no key configured"

    @classmethod
    def setUpClass(cls):
        cls.home = Path(tempfile.mkdtemp(prefix="dcc-gpg-"))
        cls.home.chmod(0o700)
        gpg(cls.home, "--pinentry-mode", "loopback", "--passphrase", "",
            "--quick-gen-key", "server test <server@example.invalid>", "ed25519", "sign", "never")
        colons = gpg(cls.home, "--list-secret-keys", "--with-colons").stdout.decode()
        cls.fpr = next(line.split(":")[9] for line in colons.splitlines() if line.startswith("fpr:"))

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["gpgconf", "--homedir", str(cls.home), "--kill", "all"], check=False)
        shutil.rmtree(cls.home, ignore_errors=True)

    def server_env(self):
        key = self.fpr if self.signing_key is None else self.signing_key
        return {"GNUPGHOME": str(self.home), "DCC_GPG_SIGNING_KEY": key}

    def sign(self, payload, headers=None):
        status, _, body = self.request("POST", "/sign", body=payload, headers=headers)
        return status, json.loads(body)

    def verify(self, payload, signature):
        sig = self.tmp / "sig.asc"
        data = self.tmp / "payload"
        sig.write_text(signature)
        data.write_bytes(payload)
        return subprocess.run(
            ["gpg", "--homedir", str(self.home), "--batch", "--status-fd", "1", "--verify", str(sig), str(data)],
            capture_output=True, text=True,
        )

    def test_signs_a_commit_with_the_pinned_key(self):
        status, reply = self.sign(COMMIT)
        self.assertEqual(status, 200)
        self.assertTrue(reply["signature"].startswith("-----BEGIN PGP SIGNATURE-----"))
        # git reads SIG_CREATED from the status output relayed to fd 2
        self.assertIn("[GNUPG:] SIG_CREATED", reply["status"])
        result = self.verify(COMMIT, reply["signature"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"VALIDSIG {self.fpr}", result.stdout)

    def test_signs_tags_and_sha256_objects(self):
        for payload in (TAG, SHA256_COMMIT):
            status, _ = self.sign(payload)
            self.assertEqual(status, 200, payload[:20])

    def test_refuses_payloads_that_are_not_git_objects(self):
        for payload in (
            b"hello\n",
            b"tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904",  # no newline after the header
            b"tree 4B825DC642CB6EB9A060E54BF8D69288FBEE4904\n",  # uppercase hex
            b"tree 4b825dc642\n",  # too short
            b"parent 4b825dc642cb6eb9a060e54bf8d69288fbee4904\ntree x\n",
            b"\ntree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n",
        ):
            status, reply = self.sign(payload)
            self.assertEqual(status, 403, payload)
            self.assertIn("refusing to sign", reply["message"])

    def test_rejects_empty_oversized_or_malformed_lengths(self):
        self.assertEqual(self.sign(b"")[0], 400)
        # The server answers before reading the body, so only claim the size
        self.assertEqual(self.sign(COMMIT, headers={"Content-Length": str((1 << 20) + 1)})[0], 400)
        self.assertEqual(self.sign(COMMIT, headers={"Content-Length": "abc"})[0], 400)

    def test_only_post_sign_is_served(self):
        self.assertEqual(self.request("POST", "/other", body=COMMIT)[0], 404)
        self.assertEqual(self.request("GET", "/sign")[0], 501)

    def test_access_log_has_neither_payload_nor_signature(self):
        self.sign(COMMIT)
        log = self.log.getvalue()
        self.assertIn("POST /sign 200", log)
        self.assertNotIn("tree ", log)
        self.assertNotIn("BEGIN PGP", log)


class GpgServerWithoutKeyTest(GpgServerTest):
    signing_key = ""

    def test_signs_a_commit_with_the_pinned_key(self):
        status, reply = self.sign(COMMIT)
        self.assertEqual(status, 503)
        self.assertIn("no signing key configured", reply["message"])

    test_signs_tags_and_sha256_objects = None
    test_access_log_has_neither_payload_nor_signature = None


class GpgServerWithUnknownKeyTest(GpgServerTest):
    signing_key = "0000000000000000000000000000000000000000"

    def test_signs_a_commit_with_the_pinned_key(self):
        status, reply = self.sign(COMMIT)
        self.assertEqual(status, 503)
        self.assertIn("gpg exited", reply["message"])
        self.assertIn("warm.sh", reply["message"])

    test_signs_tags_and_sha256_objects = None
    test_access_log_has_neither_payload_nor_signature = None


if __name__ == "__main__":
    unittest.main()
