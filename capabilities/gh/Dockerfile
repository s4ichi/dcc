# GitHub token sidecar.
# gh state (hosts.yml containing the refresh token, and refresh.lock) is mounted only into this container.
# server.py returns the result of `gh auth token` (a short-lived access token) on 127.0.0.1:8082
# (netns shared with the agent container). docs/github.md
FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl python3 \
  && rm -rf /var/lib/apt/lists/*

# Expiring credentials need 2.103.0 or later, so pin a version instead of using apt's stable.
# Renovate bumps it (renovate.json). Verified with the checksums from the same release
# renovate: datasource=github-releases depName=cli/cli extractVersion=^v(?<version>.+)$
ARG GH_VERSION=2.103.3
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

# Run as non-root. An empty named volume inherits this directory's owner and mode on first mount
RUN useradd --create-home --shell /usr/sbin/nologin gh \
  && install -d -m 0700 -o gh -g gh /home/gh/.config/gh

COPY server.py /server.py

USER gh
ENTRYPOINT ["python3", "/server.py"]
