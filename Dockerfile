# syntax=docker/dockerfile:1
#
# 本体イメージ (compose の agent サービス)。Claude Code / Codex CLI と開発ツールを入れた非特権のコンテナで、
# dockerd は含まない (Docker は rootless の sidecar が提供する。docs/docker.md)。
# devcontainer features は使わず、すべてここに焼き込む。
#
# build は compose 経由 (`dcc build`)。ARG は compose の build.args から渡る:
#   USERNAME / USER_UID / USER_GID  ← DCC_USER / DCC_UID / DCC_GID
#   GO_VERSION                      ← DCC_GO_VERSION
# ダウンロードするツールの版は各レイヤ直前の ARG で固定する (latest を取らず、同じ Dockerfile なら同じ版になる)。
# 上げるときは ARG の既定値を書き換える。apt で入れるもの (Docker CLI / gh / Corretto など) は固定しない。
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

# Layer 6: yq (YAML/JSON/XML processor)
ARG YQ_VERSION=v4.54.1
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  yqarch=amd64 ;; \
      aarch64) yqarch=arm64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${yqarch}" \
      -o /usr/local/bin/yq; \
    chmod 0755 /usr/local/bin/yq

# Layer 7: duckdb CLI
ARG DUCKDB_VERSION=v1.5.6
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  ddbarch=amd64 ;; \
      aarch64) ddbarch=arm64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-${ddbarch}.zip" \
      -o /tmp/duckdb.zip; \
    unzip -q /tmp/duckdb.zip -d /usr/local/bin; \
    chmod 0755 /usr/local/bin/duckdb; \
    rm -f /tmp/duckdb.zip

# Layer 8: jsonnet / jsonnetfmt (go-jsonnet)
#
# このリポジトリ自身の `make generate / fmt / check` をコンテナ内で実行できるようにする。
# go-jsonnet は Layer 4 の Go でソースからビルドする。ビルドキャッシュは破棄してイメージを肥大させない。
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
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  awsarch=x86_64 ;; \
      aarch64) awsarch=aarch64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${awsarch}-${AWSCLI_VERSION}.zip" \
      -o /tmp/awscliv2.zip; \
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
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${uvarch}-unknown-linux-gnu.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local/bin; \
    chmod 0755 /usr/local/bin/uv /usr/local/bin/uvx; \
    uv --version

# Layer 11: Codex CLI (standalone package; Node は不要)
#
# codex-package-* は bin/codex に加えて codex-resources/bwrap と codex-path/rg を同梱する (単体バイナリの
# tarball には無い)。公式の install.sh は shell profile を書き換え、本体を CODEX_HOME (~/.codex) 配下に置くので
# 使わない: ~/.codex は volume / ホストの bind になるため、そこに実体を置くと claude の実体を volume に
# しないのと同じ理由で食い違う。/opt/codex に展開したこの版が正で、更新は CODEX_VERSION を上げて rebuild する。
# 同じリリースの codex-package_SHA256SUMS で検証する (--ignore-missing でも、1 つも検証できなければ失敗する)。
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

# Layer 12: Volta + Node.js (既定の node は LTS の固定版)
#
# Volta はコンテナのユーザーとして ~/.volta に入れる。版の追加・切り替え (`volta install node@<ver>`) と
# npm の global install が sudo なしで済む。installer は get.volta.sh (常に最新) ではなく VOLTA_VERSION の
# タグのものを使い、--skip-setup で shell profile を書き換えない。PATH は ENV で通す (非対話シェルでも
# shim を解決できる)。package.json の volta.node で版を固定したプロジェクトでは shim がそちらに従う。
ARG VOLTA_VERSION=2.0.2
ARG NODE_VERSION=24.22.0
ENV VOLTA_HOME=/home/${USERNAME}/.volta
ENV PATH=${VOLTA_HOME}/bin:$PATH
RUN set -eux; \
    su - "${USERNAME}" -c "curl -fsSL https://raw.githubusercontent.com/volta-cli/volta/v${VOLTA_VERSION}/dev/unix/volta-install.sh \
      | VOLTA_HOME=${VOLTA_HOME} bash -s -- --skip-setup --version ${VOLTA_VERSION}"; \
    su - "${USERNAME}" -c "VOLTA_HOME=${VOLTA_HOME} PATH=${VOLTA_HOME}/bin:\$PATH volta install node@${NODE_VERSION}"; \
    test -x "${VOLTA_HOME}/bin/node"; \
    node --version; \
    npm --version

# Layer 13: headless Chromium の実行に要る共有ライブラリとフォント
#
# ブラウザ本体は入れない。Playwright などはライブラリの版ごとに対応するビルドを ~/.cache に取得するので、
# イメージに焼くと版が食い違う。root が要る共有ライブラリだけを先に入れておく (`playwright install-deps
# chromium` の Debian 12 向けの一覧から xvfb を除いたもの)。
# フォントは描画結果 (文字の幅・重なり) を左右する。日本語が豆腐にならないよう CJK を入れる。
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

# Layer 14: Java (Amazon Corretto 21 LTS。TLC / Apalache など JVM 製のツール用)
RUN set -eux; \
    curl -fsSL https://apt.corretto.aws/corretto.key \
      | gpg --dearmor -o /usr/share/keyrings/corretto-keyring.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/corretto-keyring.gpg] https://apt.corretto.aws stable main" \
      > /etc/apt/sources.list.d/corretto.list; \
    apt-get update; \
    apt-get install -y java-21-amazon-corretto-jdk; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*; \
    java -version

# Layer 15: D2 (図の記述言語の CLI)
#
# ソースからビルドせず配布バイナリを使う (同梱のレイアウトエンジンを配布物と揃える)。
ARG D2_VERSION=v0.9.0
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
      x86_64)  d2arch=amd64 ;; \
      aarch64) d2arch=arm64 ;; \
      *) echo "Unsupported architecture: ${arch}"; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/terrastruct/d2/releases/download/${D2_VERSION}/d2-${D2_VERSION}-linux-${d2arch}.tar.gz" \
      | tar -xz -C /tmp; \
    install -m 0755 "/tmp/d2-${D2_VERSION}/bin/d2" /usr/local/bin/d2; \
    rm -rf "/tmp/d2-${D2_VERSION}"; \
    d2 --version

USER ${USERNAME}
WORKDIR /workspaces
