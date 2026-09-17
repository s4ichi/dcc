"""AWS Container Credential Provider 互換の credential endpoint (docs/aws.md).

GET /credentials で `aws configure export-credentials --format process` を実行し、
その出力を SDK が AWS_CONTAINER_CREDENTIALS_FULL_URI 経由で期待する形式に変換して返す。
refresh / cache は行わない (SDK は Expiration まで自前でキャッシュし、CLI は login / SSO の
仕組みで credential を用意する)。

環境変数:
  AWS_PROFILE  export-credentials に渡す profile (デフォルト: default)
  BIND_ADDR    listen アドレス (デフォルト: 127.0.0.1。本体コンテナと netns を共有する前提。
               SDK は loopback 以外の http:// endpoint を拒否するので変えない。docs/aws.md)
  BIND_PORT    listen ポート (デフォルト: 8080)
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
    """CLI の process 形式 → Container Credential Provider 形式。失敗時は (None, reason)."""
    cmd = ["aws", "configure", "export-credentials", "--profile", PROFILE, "--format", "process"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        return None, "aws configure export-credentials timed out"

    if proc.returncode != 0:
        # CLI の stderr は "token expired" 等の診断情報で secret は含まないが、
        # クライアントには返さず sidecar のログにだけ出す。
        sys.stderr.write(proc.stderr)
        return None, f"aws configure export-credentials failed (exit {proc.returncode}); see sidecar logs"

    try:
        src = json.loads(proc.stdout)
    except ValueError:
        return None, "unexpected output from aws configure export-credentials"

    creds = {
        "AccessKeyId": src["AccessKeyId"],
        "SecretAccessKey": src["SecretAccessKey"],
    }
    if src.get("SessionToken"):
        creds["Token"] = src["SessionToken"]
    if src.get("Expiration"):
        creds["Expiration"] = src["Expiration"]
    return creds, None


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
        # デフォルトの access log は request line をそのまま出す。ここではレスポンス内容や
        # ヘッダを一切含めず、method / path / status だけを記録する。
        sys.stderr.write(f"{self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}\n")


def main():
    server = ThreadingHTTPServer((BIND_ADDR, BIND_PORT), Handler)
    # ENTRYPOINT 直起動で PID 1 になるため、ハンドラを登録しないと SIGTERM はカーネルに
    # 無視され、docker stop が猶予期間 (10 秒) 後の SIGKILL までブロックする。
    # 状態を持たないので graceful shutdown は不要 (処理中スレッドは daemon で即終了)。
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))
    sys.stderr.write(f"aws-credentials: profile={PROFILE} listening on {BIND_ADDR}:{BIND_PORT}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
