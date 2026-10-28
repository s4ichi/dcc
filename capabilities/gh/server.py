"""本体に GitHub の access token を配る endpoint (docs/github.md).

GET /token で `gh auth token --hostname $GH_HOST` を実行し、その出力を text/plain で返す。
expiring credentials なら gh が必要に応じて refresh token で access token を更新してから返す
(refresh token の単回使用は gh 自身が ~/.config/gh/refresh.lock の flock で直列化する)。
sidecar 側ではキャッシュしない (gh が失効前の token をそのまま返すので不要)。

環境変数:
  GH_HOST    token を発行するホスト (デフォルト: github.com)
  BIND_ADDR  listen アドレス (デフォルト: 127.0.0.1。本体コンテナと netns を共有する前提)
  BIND_PORT  listen ポート (デフォルト: 8082)
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

# 本体から渡りうる token 系の環境変数は使わない (gh は GH_TOKEN を優先し、refresh しない)。
# GH_DEBUG も落とす (refresh の通信内容をログに出さない)
GH_ENV = {
    k: v
    for k, v in os.environ.items()
    if k not in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_DEBUG", "DEBUG")
}
GH_ENV["GH_PROMPT_DISABLED"] = "1"


def auth_token():
    """access token。失敗時は (None, reason)."""
    cmd = ["gh", "auth", "token", "--hostname", GH_HOST]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_SEC, env=GH_ENV)
    except subprocess.TimeoutExpired:
        return None, "gh auth token timed out"

    if proc.returncode != 0:
        # gh の stderr は "not logged in" 等の診断情報。クライアントには返さず sidecar のログにだけ出す
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
        # token を含めないよう method / path / status だけを記録する
        sys.stderr.write(f"{self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}\n")


def main():
    server = ThreadingHTTPServer((BIND_ADDR, BIND_PORT), Handler)
    # PID 1 で SIGTERM を受けるため (capabilities/aws/server.py と同じ)
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))
    sys.stderr.write(f"gh-token: host={GH_HOST} listening on {BIND_ADDR}:{BIND_PORT}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
