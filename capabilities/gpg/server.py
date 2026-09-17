"""GPG 署名 sidecar (docs/gpg.md).

POST /sign で git の commit / tag オブジェクトを受け取り、armor 形式の detached 署名と
gpg の --status-fd 出力を JSON で返す。本体の gpg.program wrapper (gpg-sign-client.sh) が呼ぶ。

- 署名鍵は DCC_GPG_SIGNING_KEY (entrypoint.sh が signing-key.txt から設定) で固定。
  クライアントは鍵を選べない
- payload は git オブジェクト (先頭行が "tree <sha>" または "object <sha>") しか受け付けない
- --pinentry-mode error により、パスフレーズが未キャッシュなら hang せず即失敗する
  (ホストの capabilities/gpg/warm.sh で warm する)

環境変数:
  DCC_GPG_SIGNING_KEY  署名鍵の fingerprint
  BIND_ADDR            listen アドレス (デフォルト: 127.0.0.1)
  BIND_PORT            listen ポート (デフォルト: 8081)
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
MAX_PAYLOAD = 1 << 20  # git のコミット / タグオブジェクトとしては十分過ぎる上限

# commit は "tree <sha>"、tag は "object <sha>" で始まる (sha256 リポジトリは 64 桁)
GIT_OBJECT_RE = re.compile(rb"\A(tree|object) [0-9a-f]{40,64}\n")


def sign(payload):
    """payload に detached 署名する。(signature, status, error) を返す。"""
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
        # payload や署名はログに出さない。method / path / status のみ。
        sys.stderr.write(f"{self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}\n")


def main():
    # PID 1 はハンドラが無いと SIGTERM を無視し、docker stop が猶予期間 (10 秒) 待つことになる
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server = ThreadingHTTPServer((BIND_ADDR, BIND_PORT), Handler)
    sys.stderr.write(f"gpg-signer: listening on {BIND_ADDR}:{BIND_PORT} (key: {SIGNING_KEY or '(none)'})\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
