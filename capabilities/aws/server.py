"""Credential endpoint compatible with the AWS Container Credential Provider (docs/aws.md).

GET /credentials runs `aws configure export-credentials --format process`,
converts its output to the format the SDK expects via AWS_CONTAINER_CREDENTIALS_FULL_URI, and returns it.
Long-lived keys (no SessionToken / Expiration) are refused with 503. No refresh / cache (the SDK caches on its own until Expiration, and the CLI prepares credentials through
the login / SSO mechanisms).

Environment variables:
  AWS_PROFILE  profile passed to export-credentials (default: default)
  BIND_ADDR    listen address (default: 127.0.0.1; assumes the netns is shared with the agent container.
               Do not change it: the SDK rejects http:// endpoints other than loopback. docs/aws.md)
  BIND_PORT    listen port (default: 8080)
"""

import json
import os
import signal
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROFILE = os.environ.get("AWS_PROFILE", "default")
BIND_ADDR = os.environ.get("BIND_ADDR", "127.0.0.1")
BIND_PORT = int(os.environ.get("BIND_PORT", "8080"))
TIMEOUT_SEC = 30


def export_credentials():
    """CLI process format -> Container Credential Provider format. On failure, (None, reason)."""
    cmd = ["aws", "configure", "export-credentials", "--profile", PROFILE, "--format", "process"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        return None, "aws configure export-credentials timed out"

    if proc.returncode != 0:
        # The CLI's stderr is diagnostics such as "token expired" and contains no secrets, but
        # it is not returned to the client; only logged in the sidecar.
        sys.stderr.write(proc.stderr)
        return None, f"aws configure export-credentials failed (exit {proc.returncode}); see sidecar logs"

    try:
        src = json.loads(proc.stdout)
    except ValueError:
        return None, "unexpected output from aws configure export-credentials"

    # Only temporary credentials leave the sidecar: a profile with static keys would otherwise hand a long-lived
    # key to the agent container (and the SDKs' container provider requires Token / Expiration anyway). docs/aws.md
    if not src.get("SessionToken") or not src.get("Expiration"):
        return None, (
            f"profile {PROFILE} resolves to long-lived keys (no SessionToken / Expiration); "
            "only temporary credentials are served (use aws login, SSO or a role)"
        )
    return {
        "AccessKeyId": src["AccessKeyId"],
        "SecretAccessKey": src["SecretAccessKey"],
        "Token": src["SessionToken"],
        "Expiration": src["Expiration"],
    }, None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/credentials":
            self._send(404, {"Code": "NotFound", "Message": "not found"})
            return
        creds, reason = export_credentials()
        if creds is None:
            self._send(503, {"Code": "CredentialsUnavailable", "Message": reason})
            return
        self._send(200, creds)

    def _send(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        # The default access log prints the request line as is. Here nothing from the response or
        # headers is included; only method / path / status is logged.
        sys.stderr.write(f"{self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}\n")


def main():
    server = ThreadingHTTPServer((BIND_ADDR, BIND_PORT), Handler)
    # Started directly as ENTRYPOINT it becomes PID 1, so without a registered handler the kernel
    # ignores SIGTERM and docker stop blocks until SIGKILL after the grace period (10 seconds).
    # Stateless, so no graceful shutdown is needed (in-flight threads are daemons and exit immediately).
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))
    sys.stderr.write(f"aws-credentials: profile={PROFILE} listening on {BIND_ADDR}:{BIND_PORT}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
