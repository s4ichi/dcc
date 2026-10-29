# カスタマイズ

個人・組織固有の値（ユーザー / uid、イメージタグ、タイムゾーン、ホスト側のパス、ポートなど）はリポジトリに
焼き込んでいない。利用者は次の 2 つで自分の環境に合わせる。どちらも gitignore 済みで、リポジトリの追跡ファイルは
編集しなくてよい。

- **`DCC_*` 環境変数**（シェル、または `.env`）: 値を変える
- **`local/`**: イメージにレイヤを足す、compose に bind や環境変数を足す

## 環境変数（`DCC_*`）

**すべて任意で、未設定なら既定値で動く。** 一覧と既定値は [`.env.example`](../.env.example) が正。設定方法は 2 つ:

- シェルで `export DCC_...=...`（`dcc` と devcontainer の両方に効く）
- `${DCC_CONFIG_DIR}/.env`（`.env.example` をコピーして編集）。`dcc` が起動時に bash として
  読んで export する。シェルの環境変数が優先。compose 自身も同じファイルを読むが、devcontainer 経由では
  project directory が変わるため読まれない（[devcontainer.md](devcontainer.md)）

| 変数 | 既定値 | 内容 |
|---|---|---|
| `DCC_CONFIG_DIR` | `~/.config/dcc` | このリポジトリの場所。`.env` を読む前に決まるので `.env` には書けない |
| `DCC_ENV_FILE` | `$DCC_CONFIG_DIR/.env` | 読み込む env ファイル |
| `DCC_WORKSPACE` | `$PWD` | ワークスペースの既定（引数で上書き可） |
| `DCC_CREDS` | 空 | `--creds` の既定値（[credentials.md](credentials.md)） |
| `DCC_AGENT` | `claude` | `--agent` の既定値。`claude` か `codex` |
| `DCC_CLAUDE_ARGS` / `DCC_CODEX_ARGS` | 空 / `-c sandbox_mode=danger-full-access -c check_for_update_on_startup=false` | `dcc` がエージェントの起動時に利用者の引数の前へ足す引数。空白区切りで引用は解釈しない。空文字を設定すると何も足さない。codex の既定の理由は [codex.md](codex.md) |
| `DCC_VERBOSE` | 空 | `1` で compose / フックの出力を常に流す（既定では失敗時だけ全部出す） |
| `DCC_LOCAL_DIR` | `$DCC_CONFIG_DIR/local` | 個人設定の置き場。`Dockerfile` / `compose.yml` があれば自動で使う（下記） |
| `DCC_COMPOSE_FILES` | 空 | `local/compose.yml` に加えてさらに足す compose overlay（コロン区切りの絶対パス） |
| `DCC_USER` / `DCC_UID` / `DCC_GID` | `agent` / `1000` / `$DCC_UID` | コンテナ内ユーザー。Dockerfile の build arg に渡る。Linux ホストで uid ≠ 1000 のときに合わせる |
| `DCC_IMAGE` | `dcc:local` | 本体イメージのタグ（全ワークスペースで共有。ユーザー / uid を変えたら別タグにする） |
| `DCC_BASE_IMAGE` | `dcc:base` | `local/Dockerfile` 使用時の base イメージ（このリポジトリの Dockerfile）のタグ。変えたら `FROM` も合わせる |
| `DCC_DIND_IMAGE` | `docker:dind-rootless` | Docker sidecar のイメージ（バージョン固定など） |
| `DCC_GO_VERSION` | Dockerfile の既定 | 本体イメージの Go バージョン（build arg） |
| `DCC_TZ` | `$TZ`、無ければ `UTC` | 本体のタイムゾーン |
| `DCC_CONTAINER_ENV_<NAME>` | なし | コンテナ内の環境変数 `NAME` として渡す（例: `DCC_CONTAINER_ENV_GOPRIVATE`）。コンテナ作成時に固定（下記） |
| `DCC_GITCONFIG` | `~/.gitconfig` | 常時マウントするホスト側パス |
| `DCC_CLAUDE_DIR` / `DCC_CLAUDE_JSON` | `~/.claude` / `~/.claude.json` | `claude` モジュールが共有するホスト側パス |
| `DCC_CLAUDE_HOME_VOLUME` | `dcc-claude-home` | `claude` モジュール無効時に `~/.claude` になる空の外部 volume の名前（全ワークスペース共有） |
| `DCC_CODEX_DIR` | `~/.codex` | `codex` モジュールが共有するホスト側パス |
| `DCC_CODEX_HOME_VOLUME` | `dcc-codex-home` | `codex` モジュール無効時に `~/.codex` になる空の外部 volume の名前（全ワークスペース共有） |
| `DCC_AWS_DIR` | `~/.aws` | `aws` モジュールが sidecar に渡す `config` / `login/cache` の親 |
| `DCC_AWS_REGION` / `DCC_AWS_PROFILE` | `AWS_REGION` → `AWS_DEFAULT_REGION` → `us-east-1` / `AWS_PROFILE` → `default` | `aws` sidecar の region / profile |
| `DCC_AWS_CREDENTIALS_PORT` | `8080` | credential endpoint のポート（共有 netns 内で inner container の `-p` と衝突する場合に変える） |
| `DCC_GNUPG_DIR` | `$GNUPGHOME`、無ければ `~/.gnupg` | ホストの GnuPG ホーム（`private-keys-v1.d` を sidecar に ro bind、export 時の `GNUPGHOME`） |
| `DCC_GPG_SIGNING_KEY` | `git config user.signingkey` | 署名鍵（fingerprint / keyid / email） |
| `DCC_GPG_EXPORT_DIR` | `$DCC_CONFIG_DIR/capabilities/gpg/gnupg-host` | ホスト側 export の出力先 |
| `DCC_GPG_SIGNER_PORT` | `8081` | 署名 API のポート |
| `DCC_SSH_DIR` / `DCC_SSH_CONFIG` / `DCC_SSH_KNOWN_HOSTS` | `$DCC_CONFIG_DIR/capabilities/ssh/{data,config,known_hosts}` | `ssh` モジュールの秘密鍵置き場 / 接続設定 / ホスト鍵 |
| `DCC_GH_HOST` | `github.com` | `gh` モジュールが token を発行するホスト（GitHub Enterprise ならそのホスト名） |
| `DCC_GH_HOME_VOLUME` | `dcc-gh-home` | `gh-token` sidecar の状態（refresh token）を置く外部 volume の名前（全ワークスペース共有。`dcc up` / `dcc gh-login` が作る） |
| `DCC_GH_TOKEN_PORT` | `8082` | access token endpoint のポート |

`DCC_BUILD_CONTEXT` / `DCC_DOCKERFILE` / `DCC_CONTAINER_ENV_FILE` と `LOCAL_WORKSPACE_FOLDER` /
`LOCAL_WORKSPACE_BASENAME` / `COMPOSE_PROJECT_NAME` は `dcc` が compose に伝えるための内部変数で、利用者は設定しない
（devcontainer から使う場合を除く。[devcontainer.md](devcontainer.md)）。

### コンテナに環境変数を渡す

ホストの環境変数はコンテナに渡らない。渡したいものだけ `DCC_CONTAINER_ENV_<NAME>=value` で指定する。

```bash
# .env
DCC_CONTAINER_ENV_GOPRIVATE='github.com/<org>/*'
DCC_CONTAINER_ENV_EDITOR=vim
```

`dcc` がこれらを dotenv 形式の一時ファイルに集め、compose の `env_file` で読ませる（compose は動的な変数名を
補間できないため）。値はコンテナ作成時に固定されるので、変更は `dcc recreate`。ホスト側の `dcc` プロセス自身に
環境変数を付けたいだけなら、`.env` に素の `NAME=value` を書けばよい。

## 個人設定の置き場 `local/`

`${DCC_CONFIG_DIR}/local/`（`DCC_LOCAL_DIR` で変更可）に決まった名前のファイルを置くと
`dcc` が自動で使う。環境変数の設定は要らない。dotfiles で管理するなら `local/` を symlink にするか、
`DCC_LOCAL_DIR` に dotfiles 内のディレクトリを指定する。

```
<repo>/
├── .env                 # DCC_* の設定（任意）
└── local/
    ├── Dockerfile       # あれば本体イメージにレイヤを足す
    └── compose.yml      # あれば compose overlay として足す
```

### `local/compose.yml`: compose overlay

base の compose にはホストに必ずあるものしか bind しない。個人環境にしか無いファイル（`~/.gitconfig` が
include する `~/.gitconfig.local` など。無くても git は include を無視する）や個人ツール向けの設定は
ここに書く。credential overlay の後にマージされる。さらに別ファイルを足すなら `DCC_COMPOSE_FILES`。

```yaml
services:
  agent:
    environment:
      MY_TOOL_MARKER: "1"
    volumes:
      - type: bind
        source: ${HOME}/.gitconfig.local
        target: /home/agent/.gitconfig.local
        read_only: true
```

ここに足した bind は境界を広げる。ホストのファイルを渡すときは、本体コンテナが侵害されたときに何が漏れるかを
[boundaries.md](boundaries.md) の考え方で確認する。

### `local/Dockerfile`: イメージにレイヤを足す

このリポジトリの `Dockerfile` は変えずに、個人のツールを足したイメージを本体として使う。
先頭を `FROM dcc:base` にした普通の Dockerfile を置くだけでよい。

```dockerfile
FROM dcc:base

USER root
RUN apt-get update && apt-get install -y ripgrep fd-find && rm -rf /var/lib/apt/lists/*
COPY --chown=agent:agent bin/ /home/agent/.local/bin/

USER agent
RUN curl -fsSL https://example.com/install.sh | sh
```

内部では 2 段ビルドになる:

```
<repo>/Dockerfile ──build──► dcc:base   (DCC_BASE_IMAGE)
                                  │ FROM
local/Dockerfile  ──build──► dcc:local  (DCC_IMAGE) ← 本体コンテナが使う
```

- `dcc build` は base → 個人の順に両方を build する（`--no-cache` は両方に効く）。`dcc` / `dcc up` は
  base が無ければ先に作り、本体イメージが無ければ compose が自動で build する
- `COPY` の元（build context）は `local/`
- base の `ENV`（`PATH` など）と `WORKDIR` は継承される。root が必要な処理は `USER root` で行い、
  最後に `USER agent` へ戻す。ユーザー名を `DCC_USER` で変えている場合は `ARG USERNAME` を宣言すれば
  base と同じ build args（`USERNAME` / `USER_UID` / `USER_GID` / `GO_VERSION` / `BASE_IMAGE`）を受け取れる
- `DCC_USER` / `DCC_UID` を変える場合は base も変わるので、`DCC_BASE_IMAGE` と `DCC_IMAGE` の両方に
  別のタグを付け、`FROM` も合わせる
- devcontainer 経由（`dcc` を通らない）では自動検出されない。先に `dcc build` するか、
  [devcontainer.md](devcontainer.md) の手順で base を build して `DCC_BUILD_CONTEXT` / `DCC_DOCKERFILE`
  を export する

### base イメージの中身を減らしたいとき

このリポジトリの `Dockerfile` には Claude Code と Codex CLI のほか、Go / AWS CLI / `gh` / `yq` / `duckdb` / `uv` / `jsonnet` / Node.js / Java（Corretto） / `d2` などが入っている
（[architecture.md](architecture.md) の「本体イメージ」）。足すのは `local/Dockerfile` で済むが、減らす仕組みは無い。
不要なレイヤがあるなら fork して `Dockerfile` を編集する。Docker CLI（sidecar への接続）、git / gnupg / curl / jq
（`gpg` モジュールの wrapper が使う）は外さないこと。sudo は入れない（入れても compose の `no-new-privileges` で動かない。[boundaries.md](boundaries.md)）。

## ホスト側の前提

| パス / コマンド | 用途 | 無い場合 |
|---|---|---|
| `docker`（compose plugin 込み） | コンテナ実行 | `dcc` が動かない |
| `shasum` または `sha256sum` | compose プロジェクト名のハッシュ | どちらかは必要 |
| `~/.gitconfig`（`DCC_GITCONFIG`） | git 設定（常時マウント） | 下記「bind のソースが無いとき」。空でよいので作る（`touch ~/.gitconfig`） |
| `~/.claude/`、`~/.claude.json`（`DCC_CLAUDE_DIR` / `DCC_CLAUDE_JSON`） | `claude` モジュール時のみ | ホストで Claude Code を一度でも起動していれば存在する。`initialize.sh claude` が事前に警告する |
| `~/.codex/`（`DCC_CODEX_DIR`） | `codex` モジュール時のみ | ホストで Codex を一度でも起動していれば存在する。`initialize.sh codex` が事前に警告する |
| `~/.aws/config`、`~/.aws/login/cache`（`DCC_AWS_DIR`） | `aws` モジュール時のみ | `initialize.sh aws` が事前に警告する。ホストで `aws login` する |
| `~/.gnupg/private-keys-v1.d/`（`DCC_GNUPG_DIR`）、`gpg` コマンド | `gpg` モジュール時のみ | `initialize.sh gpg` が警告する。`gpg` コマンドが無いだけなら署名なしで動く |
| `devcontainer` CLI / VS Code Dev Containers | devcontainer から compose を参照して使う場合のみ（[devcontainer.md](devcontainer.md)） | `dcc` には不要 |

### 準備が必要なディレクトリ

次はリポジトリ配下の gitignore 済みディレクトリで、**使うモジュールの分だけ**利用者が用意する。

| ディレクトリ | 内容 | 準備 |
|---|---|---|
| `capabilities/ssh/data/`（`DCC_SSH_DIR`） | コンテナ専用の SSH 秘密鍵 `id_ed25519`。接続設定とホスト鍵は追跡対象で準備不要 | [ssh.md](ssh.md) のセットアップ |
| `capabilities/gpg/gnupg-host/`（`DCC_GPG_EXPORT_DIR`） | ホストの公開鍵・署名鍵情報の export | 不要（`initialize.sh gpg` が毎回生成する） |
| `.env`、`local/` | 上記 | 任意。無ければ既定値と base のイメージ / compose だけで動く |

### bind のソースが無いとき

bind のソースがホストに無い場合の挙動は docker compose のバージョンと Docker ランタイムで異なり、
エラーで `up` が失敗するか、**空のディレクトリが自動で作られる**（ランタイムによっては root 所有）。
後者はファイルを期待するパス（`~/.gitconfig`、`~/.claude.json`、`~/.aws/config`）にディレクトリができるので、
気付かずに放置すると後で困る。`lifecycle_hooks/initialize.sh` が選択したモジュールのソースを事前に確認して
警告するので、警告が出たら先に実体を用意する。

## ホスト OS 依存

| 箇所 | 依存 | 備考 |
|---|---|---|
| `dcc` の `sha256_prefix` | macOS の `shasum` / Linux の `sha256sum` | 両対応 |
| [gpg.md](gpg.md) / [ssh.md](ssh.md) の設計理由 | macOS の gpg-agent / ssh-agent の socket が VM を越えない、ホスト gpg が keyboxd | Linux ホストでも同じ設計で動くが、理由の一部は macOS 固有 |
| [claude-code.md](claude-code.md) / [mcp.md](mcp.md) の Keychain | macOS の Claude Code は token を Keychain に置く | Linux ホストでは `~/.claude/.credentials.json` にあり、`claude` モジュール有効時はコンテナと共有される |
| [claude-code.md](claude-code.md) の `HOST_HOME` symlink | ホストのホームが `/Users/<user>`（macOS）や `/home/<user>`（Linux） | `$HOME` から取るので OS 非依存 |
| uid 不一致（[git.md](git.md)） | macOS では VM のファイル共有が uid をマップする | Linux ホストで uid ≠ 1000 の場合、bind したファイルへの書き込みが失敗しうる。`DCC_UID` / `DCC_GID` を合わせる（`DCC_IMAGE` も別タグに） |

## fork を公開する前に

`.env`、`local/`、`capabilities/{ssh,gh}/data/`、`capabilities/gpg/gnupg-host/`、`.claude/` は gitignore 済みだが、
fork を公開するなら追跡対象と履歴に秘密情報が無いことを確認する。

```bash
# 秘密情報を含むディレクトリが追跡されていないこと（出力が空）
git ls-files capabilities/ssh/data capabilities/gh/data capabilities/gpg/gnupg-host .claude local .env

# 過去のコミットで誤って add していないこと（出力が空）
git log --all --diff-filter=A --name-only --format= | sort -u \
  | grep -E '^(\.env$|local/|\.claude/|capabilities/(ssh|gh)/data/|capabilities/gpg/gnupg-host/)'
```

履歴に含まれていた場合は、その鍵 / token を失効させたうえで、新しいリポジトリへ squash して移すのが安全。
