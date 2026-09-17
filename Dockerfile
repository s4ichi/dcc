# syntax=docker/dockerfile:1
#
# 本体イメージ (compose の agent サービス)。Claude Code と開発ツールを入れた非特権のコンテナで、
# dockerd は含まない (Docker は rootless の sidecar が提供する。docs/docker.md)。
# devcontainer features は使わず、すべてここに焼き込む。
#
# build は compose 経由 (`dcc build`)。ARG は compose の build.args から渡る:
#   USERNAME / USER_UID / USER_GID  ← DCC_USER / DCC_UID / DCC_GID
#   GO_VERSION                      ← DCC_GO_VERSION
# 個人のツールはこのファイルを編集せず、`FROM dcc:base` する local/Dockerfile で足す
# (docs/customization.md)。

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
# recommends / suggests / doc / man / locale を入れずにイメージを小さく保つ。
# ユーザーは sudo NOPASSWD (postCreate が system gitconfig などを書く)。境界はコンテナの外枠で引くので、
# コンテナ内の root 権限は許容している (docs/boundaries.md)。
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
      sudo \
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
    echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"

# Layer 2: Docker CLI (+ buildx / compose plugin)
#
# dockerd はこのイメージでは動かさない。compose の sidecar (docker:dind-rootless) が TLS 付き
# tcp/2376 で提供し、本体は DOCKER_HOST / DOCKER_TLS_VERIFY / DOCKER_CERT_PATH 環境変数で繋ぐ。
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
    curl -fsSL "https://dl.google.com/go/go${GO_VERSION}.linux-${goarch}.tar.gz" \
      | tar -xz -C /usr/local; \
    mkdir -p /go/bin; \
    chown -R "${USERNAME}:${USERNAME}" /go

# Layer 5: Claude Code CLI (native install into the container user's home)
#
# コンテナのユーザーとして install.sh を実行し、~/.local/bin/claude (実体は ~/.local/share/claude) に置く。
# Claude Code の自動更新と `claude doctor` はこの場所を管理インストールとして扱うため、root で
# /usr/local/bin に置くと "~/.local/bin/claude missing or broken" の警告が出る。
# ここで入る版が正で volume にはしない。postCreate の `claude update` がコンテナ層で最新化する
# (docs/claude-code.md)。~/.local/bin は上の ENV PATH で通してある (非対話シェルでも解決できる)。
RUN set -eux; \
    su - "${USERNAME}" -c 'curl -fsSL https://claude.ai/install.sh | bash'; \
    chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.local"; \
    test -x "/home/${USERNAME}/.local/bin/claude"

# Layer 6: yq (YAML/JSON/XML processor, latest release)
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  yqarch=amd64 ;; \
      aarch64) yqarch=arm64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yqarch}" \
      -o /usr/local/bin/yq; \
    chmod 0755 /usr/local/bin/yq

# Layer 7: duckdb CLI (latest release)
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  ddbarch=amd64 ;; \
      aarch64) ddbarch=arm64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-${ddbarch}.zip" \
      -o /tmp/duckdb.zip; \
    unzip -q /tmp/duckdb.zip -d /usr/local/bin; \
    chmod 0755 /usr/local/bin/duckdb; \
    rm -f /tmp/duckdb.zip

# Layer 8: jsonnet / jsonnetfmt (go-jsonnet)
#
# このリポジトリ自身の `make generate / fmt / check` をコンテナ内で実行できるようにする。
# go-jsonnet のリリースアセットはファイル名にバージョンを含み latest URL で取れないため、
# Layer 4 の Go でソースからビルドする。ビルドキャッシュは破棄してイメージを肥大させない。
RUN set -eux; \
    GOBIN=/usr/local/bin go install \
      github.com/google/go-jsonnet/cmd/jsonnet@latest \
      github.com/google/go-jsonnet/cmd/jsonnetfmt@latest; \
    rm -rf /root/.cache/go-build /go/pkg; \
    chown -R "${USERNAME}:${USERNAME}" /go; \
    jsonnet --version; \
    jsonnetfmt --version

# Layer 9: AWS CLI v2 (latest release)
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  awsarch=x86_64 ;; \
      aarch64) awsarch=aarch64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${awsarch}.zip" \
      -o /tmp/awscliv2.zip; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    rm -rf /tmp/awscliv2.zip /tmp/aws; \
    aws --version

# Layer 10: uv / uvx (Python package & project manager, latest release)
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  uvarch=x86_64 ;; \
      aarch64) uvarch=aarch64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-${uvarch}-unknown-linux-gnu.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local/bin; \
    chmod 0755 /usr/local/bin/uv /usr/local/bin/uvx; \
    uv --version

USER ${USERNAME}
WORKDIR /workspaces
