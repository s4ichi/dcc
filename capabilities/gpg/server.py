"""GPG signing sidecar (docs/gpg.md).

POST /sign takes a git commit / tag object and returns an armored detached signature and
gpg's --status-fd output as JSON. Called by the agent container's gpg.program wrapper (gpg-sign-client.sh).

- The signing key is fixed by DCC_GPG_SIGNING_KEY (set by entrypoint.sh from signing-key.txt).
  Clients cannot choose the key
- Only git objects (first line "tree <sha>" or "object <sha>") are accepted as payload
- With --pinentry-mode error, an uncached passphrase fails immediately instead of hanging
  (warm it with capabilities/gpg/warm.sh on the host)

Environment variables:
  DCC_GPG_SIGNING_KEY  fingerprint of the signing key
  BIND_ADDR            listen address (default: 127.0.0.1)
  BIND_PORT            listen port (default: 8081)
"""

import json
import os
import re
import signal
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SIGNING_KEY = os.environ.get("DCC_GPG_SIGNING_KEY", "")
BIND_ADDR = os.environ.get("BIND_ADDR", "127.0.0.1")
BIND_PORT = int(os.environ.get("BIND_PORT", "8081"))
TIMEOUT_SEC = 30
MAX_PAYLOAD = 1 << 20  # more than enough for a git commit / tag object

# A commit starts with "tree <sha>", a tag with "object <sha>" (64 hex digits in sha256 repositories)
GIT_OBJECT_RE = re.compile(rb"\A(tree|object) [0-9a-f]{40,64}\n")


def sign(payload):
    """Make a detached signature of payload. Returns (signature, status, error)."""
    if not SIGNING_KEY:
        return None, "", "no signing key configured (set git user.signingkey on the host and recreate)"
    cmd = [
        "gpg", "--batch", "--no-tty", "--pinentry-mode", "error",
        "--status-fd", "2", "--armor", "--detach-sign",
        "--local-user", SIGNING_KEY, "--output", "-", "-",
    ]
    try:
        proc = subprocess.run(cmd, input=payload, capture_output=True, timeout=TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        return None, "", "gpg timed out"

    status = proc.stderr.decode(errors="replace")
    if proc.returncode != 0:
        sys.stderr.write(status)
        return None, status, (
            f"gpg exited {proc.returncode}"
            " (passphrase not cached? run capabilities/gpg/warm.sh on the host to warm)"
        )
    return proc.stdout.decode(), status, None


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/sign":
            self._send(404, {"message": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_PAYLOAD:
            self._send(400, {"message": "missing or oversized payload"})
            return
        payload = self.rfile.read(length)
        if not GIT_OBJECT_RE.match(payload):
            self._send(403, {"message": "payload is not a git commit/tag object; refusing to sign"})
            return
        signature, status, err = sign(payload)
        if signature is None:
            self._send(503, {"message": err, "status": status})
            return
        self._send(200, {"signature": signature, "status": status})

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        # Do not log the payload or signature. Only method / path / status.
        sys.stderr.write(f"{self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}\n")


def main():
    # Without a handler, PID 1 ignores SIGTERM and docker stop waits for the grace period (10 seconds)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server = ThreadingHTTPServer((BIND_ADDR, BIND_PORT), Handler)
    sys.stderr.write(f"gpg-signer: listening on {BIND_ADDR}:{BIND_PORT} (key: {SIGNING_KEY or '(none)'})\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
