# GPG 署名 sidecar。
# 秘密鍵 (署名鍵の keygrip のみ) とパスフレーズキャッシュはこのコンテナに閉じる。
# entrypoint がコンテナローカルの keyring を組み立て、server.py が 127.0.0.1:8081 で
# 署名 API を listen する (本体とは netns 共有)。
FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends gnupg pinentry-curses python3 \
  && rm -rf /var/lib/apt/lists/*

COPY server.py /server.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY gpg-warm.sh /usr/local/bin/gpg-warm.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/gpg-warm.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
