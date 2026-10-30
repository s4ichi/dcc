"""Endpoint that hands GitHub access tokens to the agent container (docs/github.md).

GET /token runs `gh auth token --hostname $GH_HOST` and returns its output as text/plain.
With expiring credentials, gh refreshes the access token with the refresh token as needed before returning it
(gh itself serializes single use of the refresh token with a flock on ~/.config/gh/refresh.lock).
The sidecar does not cache (unnecessary, since gh returns the unexpired token as is).

Environment variables:
  GH_HOST    host to issue tokens for (default: github.com)
  BIND_ADDR  listen address (default: 127.0.0.1; assumes the netns is shared with the agent container)
  BIND_PORT  listen port (default: 8082)
"""

import os
import signal
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GH_HOST = os.environ.get("GH_HOST", "github.com")
BIND_ADDR = os.environ.get("BIND_ADDR", "127.0.0.1")
BIND_PORT = int(os.environ.get("BIND_PORT", "8082"))
TIMEOUT_SEC = 30

# Do not use token env vars that may come from the agent container (gh prefers GH_TOKEN and does not refresh).
# Drop GH_DEBUG too (do not log the refresh traffic)
GH_ENV = {
    k: v
    for k, v in os.environ.items()
    if k not in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_DEBUG", "DEBUG")
}
GH_ENV["GH_PROMPT_DISABLED"] = "1"


def auth_token():
    """Access token. On failure, (None, reason)."""
    cmd = ["gh", "auth", "token", "--hostname", GH_HOST]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_SEC, env=GH_ENV)
    except subprocess.TimeoutExpired:
        return None, "gh auth token timed out"

    if proc.returncode != 0:
        # gh's stderr is diagnostics such as "not logged in". Not returned to the client; only logged in the sidecar
        sys.stderr.write(proc.stderr)
        return None, f"no usable token for {GH_HOST}; run 'dcc gh-login' on the host (see gh-token sidecar logs)"

    token = proc.stdout.strip()
    if not token:
        return None, "gh auth token returned nothing"
    return token, None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/token":
            self._send(404, "not found\n")
            return
        token, reason = auth_token()
        if token is None:
            self._send(503, reason + "\n")
            return
        self._send(200, token)

    def _send(self, status, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        # Log only method / path / status so the token is never included
        sys.stderr.write(f"{self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}\n")


def main():
    server = ThreadingHTTPServer((BIND_ADDR, BIND_PORT), Handler)
    # Because it receives SIGTERM as PID 1 (same as capabilities/aws/server.py)
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))
    sys.stderr.write(f"gh-token: host={GH_HOST} listening on {BIND_ADDR}:{BIND_PORT}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
