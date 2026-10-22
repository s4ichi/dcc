# アーキテクチャ

構成要素、設定の生成フロー、compose プロジェクトの構造、ライフサイクル、CLI の仕様。
用語は [README.md](README.md) の「用語」を参照。

## 目的

コーディングエージェント（Claude Code / Codex CLI）をホスト（開発者のマシン）から隔離したコンテナ内で動かす。要件は次の 3 つ。

1. **ホストの秘密情報を必要最小限だけ、できるだけ read-only でコンテナに渡す。**
2. **コンテナ内から Docker が使える**（`docker run` / `docker compose` / `docker build`）。ただし
   エージェントが Docker 経由でホストや本体コンテナの権限を昇格できないこと。
3. 任意のワークスペース（プロジェクトディレクトリ）から 1 コマンドで起動できること。

## 構成要素

| パス | 役割 |
|---|---|
| `template.jsonnet` | 設定の単一ソース。ここだけを編集する |
| `docker-compose.yml` | 生成物（base）。`agent`（本体）と `docker`（sidecar）の 2 サービス定義。常時マウントのみ。ワークスペースの bind は含まない |
| `docker-compose.workspace.yml` | 生成物（overlay）。`dcc` 用のワークスペース bind（本体と sidecar に同一パス）と `dcc.workspace` ラベル。`dcc` が export する `LOCAL_WORKSPACE_FOLDER` / `LOCAL_WORKSPACE_BASENAME` で補間する。devcontainer から使う場合はワークスペース側の compose で代替（[devcontainer.md](devcontainer.md)） |
| `capabilities/<name>/compose.yml` | 生成物（overlay）。credential モジュールごとの compose 断片（`services.agent` への追記やモジュール専用 sidecar の追加。[credentials.md](credentials.md)） |
| `docker-compose.base-image.yml` | 生成物（overlay）。`local/Dockerfile` があるときに base イメージ（このリポジトリの `Dockerfile` → `DCC_BASE_IMAGE`）を build するための `agent` の `image` / `build` 上書き。`dcc build` / `dcc up` だけが使う（[customization.md](customization.md)） |
| `Dockerfile` | 本体イメージ。`debian:bookworm-slim` ベース、dockerd は含まない。個人のレイヤは `local/Dockerfile` で `FROM` して足す |
| `local/` | gitignore 済み。個人の `Dockerfile` / `compose.yml` を置くと `dcc` が自動で使う（`DCC_LOCAL_DIR` で場所を変更可。[customization.md](customization.md)） |
| `Makefile` | `generate` / `fmt` / `check`（= `lint` + `test` + Jsonnet の評価）/ `clean` |
| `dcc` + `lib/*.sh` | ワークスペース単位のライフサイクル CLI（up / exec / stop / clear / recreate / build）。`docker compose` の薄いラッパーで devcontainer CLI には依存しない。`dcc` は入口で、実装は `lib/`（下記「`dcc` の実装」） |
| `test/dcc.bats` | `dcc` の関数テスト（`make test`）。docker には触らない |
| `lifecycle_hooks/initialize.sh` | ホスト側の前処理（引数のモジュール名ごとに export / 事前チェック）。`dcc up` と devcontainer の `initializeCommand` から呼ぶ |
| `lifecycle_hooks/postCreate.sh` | コンテナ作成後フック（コンテナ内で実行）。`dcc` は作成直後に自前で呼び、devcontainer では `postCreateCommand` に書く |
| `capabilities/gpg/` | `gpg` モジュールの署名 sidecar（`server.py` が commit / tag に署名）とホスト側スクリプト（`export-host-keys.sh` / `warm.sh`）。[gpg.md](gpg.md) |
| `capabilities/claude/` | `claude` モジュールの overlay（ホストの `~/.claude` / `~/.claude.json` の bind）。[claude-code.md](claude-code.md) |
| `capabilities/codex/` | `codex` モジュールの overlay（ホストの `~/.codex` の bind）。[codex.md](codex.md) |
| `capabilities/aws/` | `aws` モジュールの credential sidecar のイメージ（[aws.md](aws.md)） |
| `capabilities/ssh/data/`, `capabilities/gh/data/`, `capabilities/gpg/gnupg-host/` | gitignore 済み。コンテナへ bind するホスト側の実体（[boundaries.md](boundaries.md)） |

## 設定の生成フロー

```
template.jsonnet ──(make generate = jsonnet -S -m .)──► docker-compose.yml               (base)
                                                          ├► docker-compose.workspace.yml     (dcc 用ワークスペース overlay)
                                                          ├► docker-compose.base-image.yml    (local/Dockerfile 使用時の base build 用)
                                                          └► capabilities/<name>/compose.yml  (overlay × モジュール数)

dcc up --creds a,b ──► docker compose -p <project> -f base -f workspace -f capabilities/a/compose.yml -f capabilities/b/compose.yml up -d --no-recreate
```

- トップレベルは `{ '<出力ファイル名>': <string>, ... }`。`jsonnet -S -m .` が各フィールドを同名ファイルに
  書き出す。生成物はすべて静的にコミットし、`dcc` は起動時に環境変数を export するだけで
  ファイルの生成・書き換えはしない。
- `bind(source, target, readonly)` / `volume(...)` ヘルパは compose の long syntax を返す。
- compose ファイル中の `${VAR}` は **docker compose が補間する**。`${HOME}` はシェル由来、
  `${DCC_CONFIG_DIR}`（このリポジトリの場所。未設定時の既定値 `~/.config/dcc` を
  compose 側に持つ）と `${DCC_CREDS}` は `dcc` が export する。`${LOCAL_WORKSPACE_FOLDER}` /
  `${LOCAL_WORKSPACE_BASENAME}` は workspace overlay だけが使い、未設定なら `:?run via dcc` で失敗する。
- 利用者ごとの値（ユーザー / uid、イメージ、タイムゾーン、ホスト側パス、ポートなど）はすべて既定値付きの
  `${DCC_*}` で、個人・組織固有の値はリポジトリに焼き込まない。`dcc` は `${DCC_CONFIG_DIR}/.env` を読んで
  export する。一覧は [`.env.example`](../.env.example) と [customization.md](customization.md)。
- **リポジトリ内のファイル（`capabilities/…`、`lifecycle_hooks/`、build context）はすべて
  `${DCC_CONFIG_DIR}` 基準の絶対パス**で書く。compose の project directory（最初の `-f` の親）に
  依存しないので、`-f` の並びや呼び出し元（`dcc` / devcontainer CLI）を問わず同じ場所を指す。

## compose プロジェクトの構造

```
 host                                compose project: dcc-<basename>-<sha256(path)[:8]>
 ────                                ┌─────────────────────────────────────────────────────────┐
  dcc ── export ──►                  │  agent (本体)                       docker (sidecar)     │
   COMPOSE_PROJECT_NAME              │   image: dcc:local                   image: docker:*-dind-rootless
   DCC_CONFIG_DIR                    │   user: agent (uid 1000)             privileged: true (ここだけ)
   LOCAL_WORKSPACE_FOLDER            │   privileged なし                    dockerd rootless (uid 1000)
   LOCAL_WORKSPACE_BASENAME          │   network_mode: service:docker ◄──── netns 共有        │
   DCC_CREDS                         │   DOCKER_HOST=tcp://docker:2376 ───► tcp/2376 (TLS)     │
   ▼                                 │   /certs:ro ◄──── volume docker-certs ───► /certs       │
  docker compose -p … up -d          │   /workspaces/<name> ◄─ host ws ─► /workspaces/<name>   │
   -f base -f workspace -f <overlay>… │   ~/.gnupg-host ~/.ssh ~/.claude …（--creds で選んだものだけ）  │
  docker compose exec … postCreate.sh │                                     volume docker-data   │
                                     └─────────────────────────────────────────────────────────┘
```

### プロジェクト名

`COMPOSE_PROJECT_NAME = dcc-<basename を小文字化し [a-z0-9_-] 以外を削除>-<ワークスペース絶対パスの sha256 先頭 8 桁>`

- `dcc` はすべての compose 呼び出しに `-p` で渡す。未設定だと compose ファイルのディレクトリ名
  になり全ワークスペースが同じプロジェクトに衝突する。
- basename は compose のプロジェクト名に使える文字（`[a-z0-9_-]`）だけに落とす。
- パスのハッシュにより、同名ディレクトリが別の場所にあっても衝突しない。
- named volume（`docker-data` / `docker-certs`）はこのプロジェクト名でプレフィックスされるため、
  ワークスペースごとに独立する。
- devcontainer CLI から使う場合のプロジェクト名は CLI が決める（`<basename>_devcontainer`。
  [devcontainer.md](devcontainer.md)）。

### `agent`（本体）サービス

- `image: dcc:local` + `build:` を併記し、全ワークスペースで 1 つのイメージタグを共有する
  （`image` がないと `<project>-agent` としてワークスペースごとにビルドされる）。
- `command: ['sleep', 'infinity']` でコンテナを生かし、`dcc` は `docker compose exec` でエージェント（`claude` / `codex`）を起動する。
  どちらを起動するかはコンテナの属性ではなく、呼び出しごとに `--agent` で選ぶ。
  `init: true` で tini を PID 1 にし、`stop` の SIGTERM が `sleep` に届いて即終了するようにする
  （`sleep` が PID 1 だと SIGTERM を無視し、grace period の 10 秒待ってから kill される）。
- `network_mode: service:docker` で sidecar の netns に join する。副作用として `ports` / `hostname` /
  `dns` / `extra_hosts` はこのサービスに書けない。
- `depends_on: docker: condition: service_started`。netns を join するために sidecar が先に起動していれば
  よく、dockerd の準備完了は待たない（起動直後の数秒は `docker` コマンドが失敗しうる。postCreate は
  docker を使わない）。
- 環境変数: `DOCKER_HOST` / `DOCKER_TLS_VERIFY` / `DOCKER_CERT_PATH`（[docker.md](docker.md)）、
  `HOST_HOME`（ホストの `$HOME`。[claude-code.md](claude-code.md) の plugin パス解決に使う）、
  `DCC_CREDS`（有効な credential モジュール、カンマ区切り）、`TZ`。利用者の環境変数は
  `DCC_CONTAINER_ENV_<NAME>` から `dcc` が集めた dotenv ファイルを `env_file` で読む（[customization.md](customization.md)）。
- volume: `~/.gitconfig`（ro bind）、`~/.claude` / `~/.codex`（固定名の external volume `dcc-claude-home` / `dcc-codex-home`。
  `claude` / `codex` モジュールが同じ target をホストの bind で上書きする）、`/certs`（ro）、`lifecycle_hooks/`（ro bind）。ワークスペースは
  workspace overlay、それ以外は credential overlay が足す（一覧は [boundaries.md](boundaries.md)）。
- ラベル `dcc.credentials`: `DCC_CREDS` と同じ値。フラグ無しの `dcc` が既存コンテナの選択を引き継ぐのと、
  不一致（drift）の検出に使う（[credentials.md](credentials.md)）。workspace overlay は `dcc.workspace`
  （ホスト側のワークスペースパス）を付け、横断操作（`dcc list` など）が本体コンテナの列挙に使う。

### `docker`（sidecar）サービス

詳細は [docker.md](docker.md)。要点:

- `docker:<ver>-dind-rootless`。dockerd は uid 1000 の rootless。
- `privileged: true` はこのサービスにだけ付ける。秘密情報は一切マウントしない。
- `sysctls: net.ipv4.ip_unprivileged_port_start=0` で 1024 未満のポート公開を許可。
- volume: ワークスペース（workspace overlay。本体と同一パス）、`docker-certs`、`docker-data`。

## 本体イメージ（Dockerfile）

`debian:bookworm-slim` に以下をレイヤで積む。devcontainer features は使わない（feature の
インストール失敗を避けるため、すべて Dockerfile に焼き込む）。

GitHub Releases などから取るツールの版は、各レイヤ直前の `ARG`（`YQ_VERSION` / `DUCKDB_VERSION` /
`JSONNET_VERSION` / `AWSCLI_VERSION` / `UV_VERSION` / `CODEX_VERSION` / `VOLTA_VERSION` / `NODE_VERSION` /
`D2_VERSION`）の既定値で固定し、`latest` は取らない（同じ Dockerfile なら build のたびに同じ版になる）。
上げるときは既定値を書き換える。apt で入れるもの（Docker CLI / `gh` / Corretto / Debian のパッケージ）と、
postCreate で更新する Claude Code は固定しない。

| Layer | 内容 |
|---|---|
| 1 | APT lean 設定（recommends/suggests/doc/man/locale を除外）、基本パッケージ、コンテナユーザー（既定 `agent`）作成（uid/gid 1000、sudo NOPASSWD） |
| 2 | Docker CLI + buildx + compose plugin（dockerd なし） |
| 3 | GitHub CLI (`gh`) |
| 4 | Go（`GO_VERSION` build arg、`GOROOT=/usr/local/go`、`GOPATH=/go`） |
| 5 | Claude Code CLI（コンテナユーザーとして `install.sh` を実行し `~/.local/bin/claude` に配置。自動更新・doctor がこの場所を管理インストールとして扱う） |
| 6 | `yq` |
| 7 | `duckdb` CLI |
| 8 | `jsonnet` / `jsonnetfmt`（go-jsonnet を Go でビルド） |
| 9 | AWS CLI v2 |
| 10 | `uv` / `uvx` |
| 11 | Codex CLI（GitHub Releases の `codex-package-<target>.tar.gz` を `codex-package_SHA256SUMS` で検証して `/opt/codex` に展開し、`/usr/local/bin/codex` に symlink。`bwrap` と `rg` を同梱。Node は不要。更新はイメージの rebuild。[codex.md](codex.md)） |
| 12 | Volta と Node.js（既定の `node` は `NODE_VERSION` の LTS）。コンテナユーザーとして `~/.volta`（`VOLTA_HOME`）に入れ、`~/.volta/bin` を `PATH` に通す。版の追加・切り替えは `volta install node@<ver>`、プロジェクトの `package.json` の `volta.node` があればそちらに従う。コンテナ内での追加はコンテナ層に載るので recreate で消える |
| 13 | headless Chromium の実行に要る共有ライブラリとフォント（Liberation / Noto CJK / Noto Color Emoji）。ブラウザ本体は入れない（Playwright などがライブラリの版に合うビルドを `~/.cache` に取得する） |
| 14 | Java（Amazon Corretto 21 LTS。Corretto の apt リポジトリから） |
| 15 | `d2`（配布バイナリ） |

基本パッケージには git / git-lfs / gnupg / pinentry-curses / openssh-client / curl / jq / rsync /
strace / gcc / g++ / make / python3 / pip / venv などが含まれる。

`PATH` は `~/.volta/bin:~/.local/bin:/usr/local/go/bin:/go/bin:$PATH`。`LANG=LC_ALL=C.UTF-8`。
最終 `USER` はコンテナユーザー（既定 `agent`）、`WORKDIR` は `/workspaces`。

ユーザー名 / uid / gid / Go バージョンは compose の `build.args`（`DCC_USER` / `DCC_UID` / `DCC_GID` /
`DCC_GO_VERSION`）から `ARG` に渡る。個人のツールを足すときはこの Dockerfile を編集せず、
`FROM dcc:base` する `local/Dockerfile` を置く。`dcc` がそれを見つけると、このリポジトリの
Dockerfile を `DCC_BASE_IMAGE` として先に build し、`local/Dockerfile` の成果物を `DCC_IMAGE` として
本体コンテナに使う（compose には `DCC_BUILD_CONTEXT` / `DCC_DOCKERFILE` を export して伝える。
[customization.md](customization.md)）。

## ライフサイクルフック

フックは devcontainer のライフサイクル名に合わせて `lifecycle_hooks/<name>.sh` に置き、`dcc` と
devcontainer の両方から同じスクリプトを呼ぶ。

**`initialize.sh <module>...`（ホスト側）**: コンテナ作成 / 起動の前にホストで実行する。引数のモジュール名
ごとに前処理と bind ソースの事前チェックを行う（`gpg`: 公開鍵 / 署名鍵情報の export、
`aws` / `ssh` / `gh` / `claude`: ソースの存在チェック）。`dcc up` は選択したモジュール名を渡して呼び、devcontainer では
`initializeCommand` に書く。

**`postCreate.sh`（コンテナ側）**: `lifecycle_hooks/` を丸ごと `/usr/local/lib/dcc/hooks`
に read-only bind し、そこから実行する。`dcc up` はコンテナ作成後に `docker compose exec` で一度だけ呼ぶ
（実行済みはコンテナローカルのマーカー `~/.dcc-postcreate-done` で判定。途中で失敗すればマーカーが無いので
次の `up` で再実行される）。devcontainer では `postCreateCommand` に同じパスを書く。
ワークスペースを cwd としてコンテナユーザーで実行され、次を行う:

1. `claude update`（焼き込み版をコンテナ層で最新化。recreate で焼き込み版に戻る。失敗は警告のみ）
2. `~/.claude` の初期化。`claude` 有効時は `~/.claude.json.host` → `~/.claude.json` のコピー、無効時は volume の所有者修正のみ（[claude-code.md](claude-code.md)）。
   `~/.codex` も同様に、`codex` 無効時だけ volume の所有者を直す（[codex.md](codex.md)。Codex はここでは更新しない）
3. `$HOST_HOME` → `$HOME` の symlink 作成（ホストでインストールした plugin の絶対パス解決。[claude-code.md](claude-code.md)）
4. `git config --system --add safe.directory <workspace>`（[git.md](git.md)）
5. 検証用 keyring の構築と `gpg.program` の登録（`~/.gnupg-host` がある = `gpg` 有効時のみ。[gpg.md](gpg.md)）

## CLI

### `dcc`

```
dcc [command] [workspace] [options] [args...]
```

- ワークスペースは引数 → `DCC_WORKSPACE` → `$PWD` の順で決まる。
  第 1 非オプション引数がディレクトリならワークスペースとして扱う。
- 設定ディレクトリは `DCC_CONFIG_DIR`（デフォルト `~/.config/dcc`）。起動時に
  `${DCC_CONFIG_DIR}/.env`（`DCC_ENV_FILE` で変更可）を bash として読み、`DCC_*` を export する
  （シェルの環境変数が優先）。
- `local/compose.yml`（`DCC_LOCAL_DIR`）があれば、次いで `DCC_COMPOSE_FILES`（コロン区切り）の
  compose ファイルを `-f` の末尾に足す（`up` / `build`）。
- credential オプション `--creds` / `--all-creds` / `--no-creds` と `DCC_CREDS` は
  [credentials.md](credentials.md)。
- 実行するエージェントは `--agent claude|codex` → `DCC_AGENT` → `claude` の順で決まる（`default` / `exec` で有効）。
  `dcc` は起動時に `DCC_CLAUDE_ARGS` / `DCC_CODEX_ARGS` の引数を利用者の引数の前に足す。codex の既定は Codex 自身の sandbox を
  外すもの（[codex.md](codex.md)）。

| コマンド | 動作 |
|---|---|
| `dcc`（デフォルト） | `up` → gpg warm（`gpg` 有効時） → エージェントを exec |
| `dcc up` | `initialize.sh <選択モジュール>` → drift の検査 → （必要なら volume `dcc-claude-home` / `dcc-codex-home` の作成、base イメージの build）→ `docker compose -f base -f workspace -f <overlay>… [-f local/compose.yml] [-f $DCC_COMPOSE_FILES] up -d --no-recreate` → 未実行なら `postCreate.sh` |
| `dcc exec [args]` | `up` → gpg warm（`capabilities/gpg/warm.sh`） → `docker compose exec -u agent -w /workspaces/<name> agent <claude\|codex> [既定引数] [args]` |
| `dcc creds` | モジュール一覧、既定値、今回の解決結果、実行中コンテナの選択を表示 |
| `dcc stop [--all]` | `docker compose -p <project> stop`（`--all` で全ワークスペースの全プロジェクト） |
| `dcc clear [--all] [--volumes]` | `docker compose -p <project> down [--volumes]`。`--volumes` で sidecar の named volume も削除、`--all` で全ワークスペース |
| `dcc recreate` | `clear` → `up`（named volume は残る） |
| `dcc build [opts]` | `docker compose -f <base> -f <全 overlay> build [opts]`（`agent` とモジュール専用 sidecar をすべてビルド）。`local/Dockerfile` があればその前に `-f docker-compose.base-image.yml` 付きで `build agent` し base を作る |
| `dcc list` / `ls` | 全ワークスペースの本体コンテナ一覧（ID / status / name / project / credentials / workspace） |
| `dcc inspect` | 各本体コンテナの name / status / workspace / project / credentials / image |

横断操作（`list` / `inspect` / `--all`）は本体コンテナのワークスペースラベル（`dcc` が付ける
`dcc.workspace`、または devcontainer CLI が付ける `devcontainer.local_folder`）で本体を列挙し、
`com.docker.compose.project` ラベルからプロジェクトを特定して compose 単位で操作する。
compose ラベルの無いコンテナは対象外としてスキップする。

### `dcc` の実装

`dcc` は `DCC_CONFIG_DIR` を解決して `lib/*.sh` を source し、`main` で
`load_config → parse_args → resolve_workspace → resolve_creds → コマンド` の順に呼ぶだけ。

| ファイル | 役割 |
|---|---|
| `lib/log.sh` | 出力の形式（`step` / `warn` / `fail` / `done_step`）、外部コマンドの実行と失敗時のダンプ（`run_step`）、フック出力の変換（`relay`） |
| `lib/config.sh` | `.env` の読み込み、既定値、`DCC_CONTAINER_ENV_*`、`local/Dockerfile` の検出 |
| `lib/cli.sh` | 引数（`parse_args`）、ワークスペースと compose プロジェクト名（`resolve_workspace`）、ヘッダーと usage |
| `lib/creds.sh` | credential モジュールの解決（`resolve_creds`）、`-f` の並び（`compose_files`）、drift 検査（`check_drift`） |
| `lib/docker.sh` | docker / compose の状態を**読むだけ**の関数（`container_id` / `agent_label` / `project_services` …） |
| `lib/project.sh` | compose プロジェクトを**変える**関数（`up_container` / `build_image` / `stop_containers` / `clear_containers` …） |
| `lib/all.sh` | 全ワークスペース横断（`list` / `inspect` / `for_each_project`） |

規約:

- 関数は「docker の状態を読む」（`docker.sh`）か「変える」（`project.sh`）のどちらか一方
- グローバル変数を書くのは `load_config` / `parse_args` / `resolve_workspace` / `resolve_creds` だけで、以降は読むだけ
- トップレベルで実行するのは `dcc` 末尾の `main` だけ。`dcc` を source すると関数定義だけが読まれるので、
  テスト（`test/dcc.bats`）は関数を直接呼び、docker を呼ぶ関数は stub に差し替える
- ログは stderr に 1 行 1 情報（`▸ <主語> <述語>`）。compose やフックの出力は成功時には出さず、失敗時にだけ
  全部出す（`DCC_VERBOSE=1` で常時流す）。フックは `<主語>: <述語>` / `warn: <主語>: <述語>` の行を出し、
  `dcc` がそれを自分の行形式に変換する

## 運用上の注意

- **sidecar だけを再起動しない**（`docker compose restart docker` など）。本体の netns が古い sandbox
  に取り残されて Docker に繋がらなくなる。復旧は `dcc recreate`。`dcc stop` → `dcc up` の順なら
  問題ない（sidecar が先に起動し、本体が新しい netns に join する）。
- compose ファイルの変更は既存コンテナに反映されない（`dcc up` は `--no-recreate`）。
  `dcc recreate` する。credential の選択変更も同様で、`dcc` は不一致を警告する（`dcc recreate` で作り直し）。
- イメージの再ビルドは `dcc build [--no-cache]`。ビルド後も既存コンテナは古いイメージのままなので
  `dcc recreate` が必要。
- rootless の制約: cgroup リソース制限（`--memory` / `--cpus`）は無視される。inner container の
  `--privileged` は userns 内の権限でしかない。inner container から親 netns の `127.0.0.1` には届かない。

