# GitHub token sidecar。
# gh の状態 (refresh token を含む hosts.yml と refresh.lock) はこのコンテナにだけ mount する。
# server.py が 127.0.0.1:8082 で `gh auth token` の結果 (短命の access token) を返す
# (本体とは netns 共有)。docs/github.md
FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl python3 \
  && rm -rf /var/lib/apt/lists/*

# expiring credentials には 2.103.0 以上が要るので apt の stable ではなく版を固定する。
# 上げるときは ARG の既定値を書き換える。同じリリースの checksums で検証する
ARG GH_VERSION=2.103.0
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  gharch=amd64 ;; \
      aarch64) gharch=arm64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    base="https://github.com/cli/cli/releases/download/v${GH_VERSION}"; \
    mkdir -p /tmp/gh; \
    cd /tmp/gh; \
    curl -fsSL -O "${base}/gh_${GH_VERSION}_linux_${gharch}.tar.gz"; \
    curl -fsSL -O "${base}/gh_${GH_VERSION}_checksums.txt"; \
    sha256sum -c --ignore-missing "gh_${GH_VERSION}_checksums.txt"; \
    tar -xzf "gh_${GH_VERSION}_linux_${gharch}.tar.gz" --strip-components=1 -C /usr/local; \
    cd /; \
    rm -rf /tmp/gh /usr/local/share/man; \
    gh --version

# 非 root で動かす。空の named volume は初回 mount 時にこのディレクトリの所有者とモードを引き継ぐ
RUN useradd --create-home --shell /usr/sbin/nologin gh \
  && install -d -m 0700 -o gh -g gh /home/gh/.config/gh

COPY server.py /server.py

USER gh
ENTRYPOINT ["python3", "/server.py"]
