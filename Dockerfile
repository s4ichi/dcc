# syntax=docker/dockerfile:1
#
# Agent image (the agent service in compose). An unprivileged container with Claude Code / Codex CLI and dev tools;
# it does not include dockerd (Docker is provided by the rootless sidecar. docs/docker.md).
# devcontainer features are not used; everything is baked in here.
#
# Built via compose (`dcc build`). ARGs come from build.args in compose:
#   USERNAME / USER_UID / USER_GID  ← DCC_USER / DCC_UID / DCC_GID
#   GO_VERSION                      ← DCC_GO_VERSION
# Versions of downloaded tools are pinned by an ARG right before each layer (never latest; the same Dockerfile gives the same versions).
# Downloads are checked with sha256. Where the distributor publishes a checksum file (Go / yq / uv / Codex) we check against it
# (same origin, so this detects corruption and substitution in transit); where not (duckdb / AWS CLI / Volta / d2 /
# Claude Code's install.sh) the sha256 is written in an ARG and checked. To bump a version, rewrite the ARG default and sha256.
# Things installed via apt (Docker CLI / gh / Corretto, etc.) rely on apt's signature verification and are not version-pinned.
# Add personal tools in a local/Dockerfile that does `FROM dcc:base` instead of editing this file
# (docs/customization.md).

FROM debian:bookworm-slim

ARG USERNAME=agent
ARG USER_UID=1000
ARG USER_GID=${USER_UID}
ARG GO_VERSION=1.26.3

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV DOCKER_BUILDKIT=1
ENV GOROOT=/usr/local/go
ENV GOPATH=/go
ENV PATH=/home/${USERNAME}/.local/bin:/usr/local/go/bin:/go/bin:$PATH

# Layer 1: APT lean config + base packages + container user
#
# Keep the image small by not installing recommends / suggests / doc / man / locale.
# No sudo. Steps that need root in the container (system gitconfig, etc.) go in lifecycle_hooks/postCreate-root.sh
# and dcc calls them with `compose exec --user root`. compose sets no-new-privileges and cap_drop ALL, so
# the agent's processes cannot become root (docs/boundaries.md).
# ~/.claude and ~/.codex are created and owned here. An empty named volume inherits this directory's owner and mode
# on first mount, so postCreate does not need to chown (root has no CAP_CHOWN).
RUN set -eux; \
    { \
      echo 'APT::Install-Recommends "false";'; \
      echo 'APT::Install-Suggests "false";'; \
      echo 'Acquire::Languages "none";'; \
    } > /etc/apt/apt.conf.d/99lean; \
    { \
      echo 'path-exclude=/usr/share/doc/*'; \
      echo 'path-exclude=/usr/share/man/*'; \
      echo 'path-exclude=/usr/share/info/*'; \
      echo 'path-exclude=/usr/share/lintian/*'; \
      echo 'path-exclude=/usr/share/linda/*'; \
      echo 'path-exclude=/usr/share/locale/*'; \
      echo 'path-include=/usr/share/locale/locale.alias'; \
    } > /etc/dpkg/dpkg.cfg.d/01_nodoc; \
    apt-get update; \
    apt-get install -y \
      apt-transport-https \
      ca-certificates \
      curl \
      g++ \
      gcc \
      git \
      git-lfs \
      gnupg \
      iproute2 \
      jq \
      less \
      libc6-dev \
      libffi-dev \
      make \
      net-tools \
      openssh-client \
      pigz \
      pinentry-curses \
      procps \
      python-is-python3 \
      python3 \
      python3-pip \
      python3-venv \
      rsync \
      strace \
      tree \
      unzip \
      wget \
      zip \
    ; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*; \
    if ! getent group "${USERNAME}" >/dev/null 2>&1; then \
      groupadd --gid "${USER_GID}" "${USERNAME}"; \
    fi; \
    if ! id -u "${USERNAME}" >/dev/null 2>&1; then \
      useradd \
        --uid "${USER_UID}" \
        --gid "${USER_GID}" \
        --create-home \
        --shell /bin/bash \
        "${USERNAME}"; \
    fi; \
    install -d -m 0700 -o "${USERNAME}" -g "${USER_GID}" \
      "/home/${USERNAME}/.claude" "/home/${USERNAME}/.codex"

# Layer 2: Docker CLI (+ buildx / compose plugin)
#
# dockerd does not run in this image. The compose sidecar (docker:dind-rootless) provides it with TLS on
# tcp/2376, and the agent container connects via the DOCKER_HOST / DOCKER_TLS_VERIFY / DOCKER_CERT_PATH env vars.
RUN set -eux; \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
      https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y \
      docker-buildx-plugin \
      docker-ce-cli \
      docker-compose-plugin \
    ; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*

# Layer 3: GitHub CLI
RUN set -eux; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
      https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y gh; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*

# Layer 4: Go compiler
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  goarch=amd64 ;; \
      aarch64) goarch=arm64 ;; \
      armv7l)  goarch=armv6l ;; \
      i686)    goarch=386 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    url="https://dl.google.com/go/go${GO_VERSION}.linux-${goarch}.tar.gz"; \
    curl -fsSL -o /tmp/go.tgz "${url}"; \
    echo "$(curl -fsSL "${url}.sha256")  /tmp/go.tgz" | sha256sum -c -; \
    tar -xz -C /usr/local -f /tmp/go.tgz; \
    rm -f /tmp/go.tgz; \
    mkdir -p /go/bin; \
    chown -R "${USERNAME}:${USERNAME}" /go

# Layer 5: Claude Code CLI (native install into the container user's home)
#
# Run install.sh as the container user and place it at ~/.local/bin/claude (the binary lives in ~/.local/share/claude).
# Claude Code's auto-update and `claude doctor` treat this location as the managed install, so putting it in
# /usr/local/bin as root produces the "~/.local/bin/claude missing or broken" warning.
# The version installed here is authoritative and is not a volume. `claude update` in postCreate updates it in the container layer
# (docs/claude-code.md). ~/.local/bin is on PATH via the ENV PATH above (resolvable from non-interactive shells too).
# install.sh is not run via `curl | bash`; its sha256 is checked, then it runs with CLAUDE_CODE_VERSION as the argument.
# install.sh itself verifies the binary against the checksum in the distributor's manifest. The sha256 changes when the
# distributor updates install.sh, so if the build fails, re-fetch it with `curl -fsSL https://claude.ai/install.sh | sha256sum` and review the diff.
ARG CLAUDE_CODE_VERSION=2.1.308
ARG CLAUDE_INSTALL_SHA256=3a68d3406cf674e17bed1733a4dcf37805e2e47d87417700007d7e1aa766a944
RUN set -eux; \
    curl -fsSL -o /tmp/claude-install.sh https://claude.ai/install.sh; \
    echo "${CLAUDE_INSTALL_SHA256}  /tmp/claude-install.sh" | sha256sum -c -; \
    chmod 0644 /tmp/claude-install.sh; \
    su - "${USERNAME}" -c "bash /tmp/claude-install.sh ${CLAUDE_CODE_VERSION}"; \
    rm -f /tmp/claude-install.sh; \
    chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.local"; \
    test -x "/home/${USERNAME}/.local/bin/claude"

# Layer 6: yq (YAML/JSON/XML processor)
ARG YQ_VERSION=v4.54.1
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  yqarch=amd64 ;; \
      aarch64) yqarch=arm64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    base="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}"; \
    mkdir -p /tmp/yq; \
    cd /tmp/yq; \
    curl -fsSL -O "${base}/yq_linux_${yqarch}"; \
    curl -fsSL -O "${base}/checksums-bsd"; \
    grep -E "^SHA256 \(yq_linux_${yqarch}\) = " checksums-bsd | sha256sum -c -; \
    install -m 0755 "yq_linux_${yqarch}" /usr/local/bin/yq; \
    cd /; \
    rm -rf /tmp/yq

# Layer 7: duckdb CLI
ARG DUCKDB_VERSION=v1.5.6
ARG DUCKDB_SHA256_AMD64=6e89deac1ebbc36eed0291caf8b567b030c7b86ac35998f71854e22b3c5d5e2f
ARG DUCKDB_SHA256_ARM64=c544e92c9b7c31fc53c2139802cabd8e2d1b2b3e3f933117f31611239c1402db
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  ddbarch=amd64; sha="${DUCKDB_SHA256_AMD64}" ;; \
      aarch64) ddbarch=arm64; sha="${DUCKDB_SHA256_ARM64}" ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-${ddbarch}.zip" \
      -o /tmp/duckdb.zip; \
    echo "${sha}  /tmp/duckdb.zip" | sha256sum -c -; \
    unzip -q /tmp/duckdb.zip -d /usr/local/bin; \
    chmod 0755 /usr/local/bin/duckdb; \
    rm -f /tmp/duckdb.zip

# Layer 8: jsonnet / jsonnetfmt (go-jsonnet)
#
# Make it possible to run this repo's own `make generate / fmt / check` inside the container.
# go-jsonnet is built from source with the Go from Layer 4. The build cache is discarded to keep the image small.
ARG JSONNET_VERSION=v0.22.0
RUN set -eux; \
    GOBIN=/usr/local/bin go install \
      github.com/google/go-jsonnet/cmd/jsonnet@${JSONNET_VERSION} \
      github.com/google/go-jsonnet/cmd/jsonnetfmt@${JSONNET_VERSION}; \
    rm -rf /root/.cache/go-build /go/pkg; \
    chown -R "${USERNAME}:${USERNAME}" /go; \
    jsonnet --version; \
    jsonnetfmt --version

# Layer 9: AWS CLI v2
ARG AWSCLI_VERSION=2.38.1
ARG AWSCLI_SHA256_X86_64=b11ed416d91f4251da363a17706938eeaf0e520745754c104c0c1890dd8363c7
ARG AWSCLI_SHA256_AARCH64=91360c0adb2ae508334ff657dce4787b598b443a11cf3dc58e08b74f12e16009
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  awsarch=x86_64; sha="${AWSCLI_SHA256_X86_64}" ;; \
      aarch64) awsarch=aarch64; sha="${AWSCLI_SHA256_AARCH64}" ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${awsarch}-${AWSCLI_VERSION}.zip" \
      -o /tmp/awscliv2.zip; \
    echo "${sha}  /tmp/awscliv2.zip" | sha256sum -c -; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/awscliv2.zip /tmp/aws; \
    aws --version

# Layer 10: uv / uvx (Python package & project manager)
ARG UV_VERSION=0.13.1
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  uvarch=x86_64 ;; \
      aarch64) uvarch=aarch64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    base="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"; \
    tgz="uv-${uvarch}-unknown-linux-gnu.tar.gz"; \
    mkdir -p /tmp/uv; \
    cd /tmp/uv; \
    curl -fsSL -O "${base}/${tgz}"; \
    curl -fsSL -O "${base}/${tgz}.sha256"; \
    sha256sum -c "${tgz}.sha256"; \
    tar -xz --strip-components=1 -C /usr/local/bin -f "${tgz}"; \
    cd /; \
    rm -rf /tmp/uv; \
    chmod 0755 /usr/local/bin/uv /usr/local/bin/uvx; \
    uv --version

# Layer 11: Codex CLI (standalone package; no Node needed)
#
# codex-package-* bundles codex-resources/bwrap and codex-path/rg in addition to bin/codex (the single-binary
# tarball does not). The official install.sh is not used: it rewrites the shell profile and puts the binary under CODEX_HOME (~/.codex),
# and ~/.codex is a volume / host bind, so putting the binary there diverges for the same reason the claude binary
# is not a volume. The version extracted to /opt/codex is authoritative; to update, bump CODEX_VERSION and rebuild.
# Verified with codex-package_SHA256SUMS from the same release (even with --ignore-missing, it fails if nothing was verified).
ARG CODEX_VERSION=rust-v0.163.0
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  codextarget=x86_64-unknown-linux-musl ;; \
      aarch64) codextarget=aarch64-unknown-linux-musl ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    base="https://github.com/openai/codex/releases/download/${CODEX_VERSION}"; \
    mkdir -p /tmp/codex /opt/codex; \
    cd /tmp/codex; \
    curl -fsSL -O "${base}/codex-package-${codextarget}.tar.gz"; \
    curl -fsSL -O "${base}/codex-package_SHA256SUMS"; \
    sha256sum -c --ignore-missing codex-package_SHA256SUMS; \
    tar -xzf "codex-package-${codextarget}.tar.gz" -C /opt/codex; \
    ln -s /opt/codex/bin/codex /usr/local/bin/codex; \
    cd /; \
    rm -rf /tmp/codex; \
    codex --version

# Layer 12: Volta + Node.js (the default node is a pinned LTS version)
#
# Volta is installed into ~/.volta as the container user. Adding / switching versions (`volta install node@<ver>`) and
# npm global installs work without root. The installer (volta-install.sh) is not used; the release tarball is checked with sha256
# and extracted to ~/.volta/bin (that is all the installer does; the shell profile rewrite was already disabled
# with --skip-setup). PATH is set via ENV (shims resolve from non-interactive shells too). In projects that pin a version
# with volta.node in package.json, the shim follows that. The aarch64 archive name is `linux-arm`.
ARG VOLTA_VERSION=2.0.2
ARG VOLTA_SHA256_X86_64=6cec054c911fb925b629a09455775af6e95dc0f5694a4c28b63979ab9ef18037
ARG VOLTA_SHA256_AARCH64=1eb92f8b711753aa576352b2e580b2f3fdadeab8664929ca1da3d0de65448517
ARG NODE_VERSION=24.22.0
ENV VOLTA_HOME=/home/${USERNAME}/.volta
ENV PATH=${VOLTA_HOME}/bin:$PATH
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  voltaos=linux; sha="${VOLTA_SHA256_X86_64}" ;; \
      aarch64) voltaos=linux-arm; sha="${VOLTA_SHA256_AARCH64}" ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/volta-cli/volta/releases/download/v${VOLTA_VERSION}/volta-${VOLTA_VERSION}-${voltaos}.tar.gz" \
      -o /tmp/volta.tgz; \
    echo "${sha}  /tmp/volta.tgz" | sha256sum -c -; \
    install -d -o "${USERNAME}" -g "${USER_GID}" "${VOLTA_HOME}" "${VOLTA_HOME}/bin"; \
    tar -xz -C "${VOLTA_HOME}/bin" -f /tmp/volta.tgz; \
    chown -R "${USERNAME}:${USER_GID}" "${VOLTA_HOME}"; \
    rm -f /tmp/volta.tgz; \
    su - "${USERNAME}" -c "VOLTA_HOME=${VOLTA_HOME} PATH=${VOLTA_HOME}/bin:\$PATH volta install node@${NODE_VERSION}"; \
    test -x "${VOLTA_HOME}/bin/node"; \
    node --version; \
    npm --version

# Layer 13: shared libraries and fonts needed to run headless Chromium
#
# The browser itself is not installed. Playwright and similar fetch a matching build per library version into ~/.cache,
# so baking one into the image would mismatch versions. Only the shared libraries that need root are installed up front (`playwright install-deps
# chromium`'s list for Debian 12, minus xvfb).
# Fonts affect rendering (glyph widths and overlaps). CJK is installed so Japanese does not render as tofu.
RUN set -eux; \
    apt-get update; \
    apt-get install -y \
      fontconfig \
      fonts-liberation \
      fonts-noto-cjk \
      fonts-noto-color-emoji \
      libasound2 \
      libatk-bridge2.0-0 \
      libatk1.0-0 \
      libatspi2.0-0 \
      libcairo2 \
      libcups2 \
      libdbus-1-3 \
      libdrm2 \
      libfontconfig1 \
      libfreetype6 \
      libgbm1 \
      libglib2.0-0 \
      libnspr4 \
      libnss3 \
      libpango-1.0-0 \
      libx11-6 \
      libxcb1 \
      libxcomposite1 \
      libxdamage1 \
      libxext6 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
    ; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*; \
    fc-cache -f

# Layer 14: Java (Amazon Corretto 21 LTS, for JVM-based tools such as TLC / Apalache)
RUN set -eux; \
    curl -fsSL https://apt.corretto.aws/corretto.key \
      | gpg --dearmor -o /usr/share/keyrings/corretto-keyring.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/corretto-keyring.gpg] https://apt.corretto.aws stable main" \
      > /etc/apt/sources.list.d/corretto.list; \
    apt-get update; \
    apt-get install -y java-21-amazon-corretto-jdk; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*; \
    java -version

# Layer 15: D2 (CLI for the diagram description language)
#
# Use the distributed binary instead of building from source (keeps the bundled layout engines identical to the release).
ARG D2_VERSION=v0.9.0
ARG D2_SHA256_AMD64=5669ddc46b99e942cc96078f4a4e36d5e62103348f4c05179ede27802fdd87a9
ARG D2_SHA256_ARM64=ac2c028697199479acb321db1e3d68caee9f2ba492ed73caa3cd13f3829bf913
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  d2arch=amd64; sha="${D2_SHA256_AMD64}" ;; \
      aarch64) d2arch=arm64; sha="${D2_SHA256_ARM64}" ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/terrastruct/d2/releases/download/${D2_VERSION}/d2-${D2_VERSION}-linux-${d2arch}.tar.gz" \
      -o /tmp/d2.tgz; \
    echo "${sha}  /tmp/d2.tgz" | sha256sum -c -; \
    tar -xz -C /tmp -f /tmp/d2.tgz; \
    install -m 0755 "/tmp/d2-${D2_VERSION}/bin/d2" /usr/local/bin/d2; \
    rm -rf "/tmp/d2-${D2_VERSION}" /tmp/d2.tgz; \
    d2 --version

# Layer 16: where the credential modules plug into the image
#
# The modules bind directories of the repository (not single files, which would go stale when git or an editor
# replaces them; docs/boundaries.md). Without a module the directory is absent and both hooks are no-ops:
#   /usr/local/lib/dcc/gh  gh module: its gh wrapper must win over /usr/bin/gh, so the directory goes first on PATH
#   /etc/ssh/dcc           ssh module: github.conf (+ known_hosts it points at), included from ssh_config.d
ENV PATH=/usr/local/lib/dcc/gh:$PATH
RUN echo 'Include /etc/ssh/dcc/*.conf' >/etc/ssh/ssh_config.d/dcc.conf

USER ${USERNAME}
WORKDIR /workspaces
