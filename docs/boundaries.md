# ホストとの境界

ホスト（開発者のマシン）とコンテナの間で、何を・どの方向に・どの権限で共有しているかの総論。
個別の境界は各ページ（[github.md](github.md) など）を参照。各ページは同じ構成
（守るもの / 境界 / 侵害時に漏れるもの / なぜこの構成か / 仕組み / 制約・既知の穴）で書く（[README.md](README.md)）。

## 前提

本体コンテナはエージェント（Claude Code / Codex CLI）が任意のコードを実行しうる場所であり、**侵害されうる前提**で境界を引く。
読んだ Web ページやドキュメントに仕込まれた指示で、認証情報の持ち出しを試みることがある。
したがって「何を許可するか」ではなく「本体からは何に到達できないか」を決める。

境界は 3 つの軸で考える:

| 軸 | 問い | この設計での扱い |
|---|---|---|
| **できること** | どの操作を許すか | 主にエージェント側の設定（Claude Code の `settings.json` の permissions / hooks、Codex の承認ポリシー）の領域で、このリポジトリでは扱わない。代行実行（gpg / aws / gh）では sidecar 側が受け付ける操作を絞ることで実現する |
| **届く範囲** | どのファイル・リソースに到達できるか | 本体には選んだものだけを、できるだけ ro で bind する。特権（Docker sidecar）と秘密情報は同じコンテナに置かない。inner container にはワークスペースしか見せない |
| **鍵の渡し方** | 認証情報をどう渡すか | 可能なものは代行実行（本体は鍵を受け取らない）。そうでないものはコンテナ専用の鍵を作って権限を絞り、平文で渡す。長期鍵はコンテナに持ち込まない |

## 設計原則

1. **秘密情報は選んだものだけ渡す。** `aws` / `gpg` / `ssh` / `gh` / `claude` / `codex` はモジュール化されており、`dcc --creds` で明示しない限りマウントされない（[credentials.md](credentials.md)）
2. **特権と秘密情報を同居させない。** `privileged: true` を持つ Docker sidecar には秘密情報を一切渡さない。渡し先は本体か、`aws-credentials` / `gpg-signer` / `gh-token` のような非特権のモジュール sidecar だけ。本体は非特権（ユーザー `agent` uid 1000。sudo なし、`no-new-privileges`、`cap_drop: ALL`）
3. **鍵を取りに行くのは本体ではなく sidecar。** 署名（gpg）、AWS、GitHub（gh）は代行実行で、本体が受け取るのは署名結果と有効期限付きの一時 credential / access token だけ
4. **長期鍵をコンテナに持ち込まない。** ホストの `~/.ssh`、`~/.aws/credentials`、`~/.gnupg` の秘密鍵、Keychain の token は渡さない。渡すのはコンテナ専用に作った鍵（`ssh`）か、sidecar だけが持つ refresh token（`gh`）で、権限を絞る。**例外は `codex` モジュール**で、有効にするとホストの `~/.codex/auth.json`（Codex の token。平文のファイル）がそのままコンテナに渡る。既定では渡さず、コンテナ内で別にログインする（[codex.md](codex.md)）
5. **read-only が原則。** 書き込みが必要なもの（`~/.claude`、`~/.codex`、ワークスペース、`gh-token` sidecar の状態 volume）だけ rw にする
6. **single-file bind mount を避ける。** コンテナ内で atomic write（tmp → rename）されるファイルを single-file で bind すると `rename` が EXDEV で失敗し壊れる。該当するものは `.host` として ro で渡し、postCreate でコピーする（`~/.claude.json`）か、親ディレクトリごと渡す（`~/.codex/config.toml`）
7. **ホストの Docker を渡さない。** `/var/run/docker.sock` はコンテナに渡さない。Docker は rootless の sidecar が提供する（[docker.md](docker.md)）
8. **macOS Keychain は渡さない。** Claude Code 本体と MCP サーバーの認証はコンテナ内で行い、結果は `~/.claude/.credentials.json` に残す（[mcp.md](mcp.md)）

## 境界ごとの要約

「鍵の渡し方」は安全な順に **代行実行 > ストア経由の注入 > 平文の環境変数 / ファイル > 直読み**。

| 境界 | 守るもの | 鍵の渡し方 | 本体が侵害されたときの上限 | 詳細 |
|---|---|---|---|---|
| `gpg` | 署名鍵、パスフレーズ | 代行実行（sidecar が署名） | commit / tag に署名させられる。鍵は漏れない | [gpg.md](gpg.md) |
| `aws` | login セッション、長期鍵 | 代行実行（sidecar が一時 credential を発行） | 有効期限付きの一時 credential。長期鍵は漏れない | [aws.md](aws.md) |
| `ssh` | ホストの秘密鍵、agent | 平文（コンテナ専用鍵を ro bind） | 専用鍵が漏れる。被害は鍵の権限の範囲 | [ssh.md](ssh.md) |
| `gh` | ホストの token（Keychain）、refresh token | 代行実行（sidecar が短命の access token を発行） | 数時間で失効する access token。refresh token は漏れない | [github.md](github.md) |
| git | gitconfig | 渡さない（ro） | 設定が読める。書き換えは不可 | [git.md](git.md) |
| `claude` | 設定、履歴、token | コンテナ内で認証（平文で `~/.claude` に残る） | 有効時: **ホストの設定の改変、token と履歴の持ち出し**。最大の穴。無効時: volume 内の token と履歴のみ | [claude-code.md](claude-code.md) |
| `codex` | 設定、履歴、token（`auth.json`） | 有効時: **ホストの token を平文のまま共有**。無効時: コンテナ内で認証（volume に残る） | 有効時: **ホストの token の持ち出し、ホストで実行されるコマンドの設定（`notify` / hooks / MCP）の改変**。`claude` より重い。無効時: volume 内の token と履歴のみ | [codex.md](codex.md) |
| MCP | サーバー設定、token | コンテナ内で認証（Keychain は渡さない） | コンテナで取った token が漏れる | [mcp.md](mcp.md) |
| Docker | ホストの Docker、ホストのファイル | 渡さない（sidecar が提供） | sidecar 内の uid 1000 の権限。ワークスペース以外は見えない | [docker.md](docker.md) |

## マウント一覧（本体コンテナ）

「モジュール」が `常時` のものは base compose（`docker-compose.yml`）に含まれ、それ以外は
`capabilities/<name>/compose.yml` の overlay として `dcc --creds <name>` で選んだときだけ追加される。

| モジュール | ホスト側 | コンテナ側 | モード | 種別 | 詳細 |
|---|---|---|---|---|---|
| 常時 | `$LOCAL_WORKSPACE_FOLDER` | `/workspaces/$LOCAL_WORKSPACE_BASENAME` | rw | bind (cached) | ワークスペース。`docker-compose.workspace.yml` で本体と sidecar に同一パスで bind。devcontainer 経由ではワークスペース側の compose が与える（[devcontainer.md](devcontainer.md)） |
| 常時 | `~/.gitconfig`（`DCC_GITCONFIG`） | `~/.gitconfig` | ro | bind | [git.md](git.md)。include 先の個人ファイルは bind しない（必要なら `local/compose.yml`） |
| 常時 | volume `dcc-claude-home`（`DCC_CLAUDE_HOME_VOLUME`、external、全ワークスペース共有、空で始まる） | `~/.claude` | rw | volume | [claude-code.md](claude-code.md)。`claude` モジュールが同じ target を bind で上書きする |
| `claude` | `~/.claude`（`DCC_CLAUDE_DIR`） | `~/.claude` | **rw** | bind | [claude-code.md](claude-code.md) |
| `claude` | `~/.claude.json`（`DCC_CLAUDE_JSON`） | `~/.claude.json.host` | ro | bind | [claude-code.md](claude-code.md)。postCreate でローカルへコピー |
| 常時 | volume `dcc-codex-home`（`DCC_CODEX_HOME_VOLUME`、external、全ワークスペース共有、空で始まる） | `~/.codex` | rw | volume | [codex.md](codex.md)。`codex` モジュールが同じ target を bind で上書きする |
| `codex` | `~/.codex`（`DCC_CODEX_DIR`） | `~/.codex` | **rw** | bind | [codex.md](codex.md)。`auth.json`（token）を含む。ディレクトリ単位で渡す |
| 常時 | `<repo>/lifecycle_hooks/` | `/usr/local/lib/dcc/hooks` | ro | bind | [architecture.md](architecture.md) |
| 常時 | volume `docker-certs` | `/certs` | ro | volume | [docker.md](docker.md)。sidecar が生成した TLS 証明書 |
| `aws` | なし（`aws-credentials` sidecar が `127.0.0.1:8080` で一時 credential を発行） | 環境変数 `AWS_CONTAINER_CREDENTIALS_FULL_URI` のみ | — | — | [aws.md](aws.md) |
| `gpg` | なし（`gpg-signer` sidecar が `127.0.0.1:8081` で署名 API を提供） | 環境変数 `DCC_GPG_SIGN_URI` と wrapper のみ | — | — | [gpg.md](gpg.md) |
| `gpg` | `<repo>/capabilities/gpg/gnupg-host` | `~/.gnupg-host` | ro | bind | [gpg.md](gpg.md)。export した公開鍵・ownertrust（検証用） |
| `gpg` | `<repo>/capabilities/gpg/gpg-sign-client.sh` | `/usr/local/lib/dcc/gpg-sign-client.sh` | ro | bind | [gpg.md](gpg.md)。`gpg.program` wrapper |
| `ssh` | `<repo>/capabilities/ssh/data` | `~/.ssh` | ro | bind | [ssh.md](ssh.md)。コンテナ専用の秘密鍵のみ |
| `ssh` | `<repo>/capabilities/ssh/config` | `/etc/ssh/ssh_config.d/github.conf` | ro | bind | [ssh.md](ssh.md)。追跡対象 |
| `ssh` | `<repo>/capabilities/ssh/known_hosts` | `/etc/ssh/ssh_known_hosts` | ro | bind | [ssh.md](ssh.md)。追跡対象 |
| `gh` | なし（`gh-token` sidecar が `127.0.0.1:8082` で access token を発行） | 環境変数 `DCC_GH_TOKEN_URI` / `DCC_GH_HOST` のみ | — | — | [github.md](github.md) |
| `gh` | `<repo>/capabilities/gh/gh-token-client.sh` | `/usr/local/lib/dcc/gh-token-client.sh`、`/usr/local/bin/gh` | ro | bind | [github.md](github.md)。`gh` の wrapper と git の credential helper |

`<repo>` はこのリポジトリ。compose ファイル内では `${DCC_CONFIG_DIR}` 基準の絶対パスで書かれ、ホスト側のパスは `DCC_*` 環境変数で変更できる（[customization.md](customization.md)）。

## マウント一覧（sidecar）

Docker sidecar（`privileged`）にはホストの `$HOME` 配下を一切渡さない。inner container から見えるホストのファイルは**ワークスペースだけ**。

| ホスト側 | コンテナ側 | モード | 種別 |
|---|---|---|---|
| `$LOCAL_WORKSPACE_FOLDER` | `/workspaces/$LOCAL_WORKSPACE_BASENAME` | rw | bind |
| volume `docker-certs` | `/certs` | rw | volume |
| volume `docker-data` | `/home/rootless/.local/share/docker` | rw | volume |

モジュール sidecar（非特権）:

| sidecar | ホスト側 | コンテナ側 | モード |
|---|---|---|---|
| `aws-credentials` | `~/.aws/config`、`~/.aws/login/cache` | `/root/.aws/config`、`/root/.aws/login/cache` | ro |
| `gpg-signer` | `~/.gnupg/private-keys-v1.d`、`<repo>/capabilities/gpg/gnupg-host` | `/host-keys`、`/gnupg-host` | ro |
| `gh-token` | volume `dcc-gh-home`（`DCC_GH_HOME_VOLUME`、external、全ワークスペース共有。`dcc gh-login` が書く） | `/home/gh/.config/gh` | rw |

## 方向性: ホストへ戻るもの / 戻らないもの

| 対象 | コンテナ内の変更はホストに反映されるか |
|---|---|
| ワークスペース | **される**（同一 bind） |
| `~/.claude`（セッション履歴、プラグイン、設定、コンテナで取得した OAuth token） | `claude` 有効時は**される**（token はホストの Claude Code からは参照されない）。無効時はされない（volume に閉じる） |
| `~/.claude.json` | されない（コンテナローカルのコピー） |
| `~/.codex`（設定、認証、セッション履歴） | `codex` 有効時は**される**（設定の変更も token の更新もホストの Codex にそのまま効く）。無効時はされない（volume に閉じる） |
| `~/.ssh` | されない（コンテナ専用。ホストのものとは別物） |
| gh の認証状態 | されない（`dcc-gh-home` volume に閉じる。ホストの gh とは別物） |
| `~/.gnupg`、`~/.gitconfig*`、`~/.aws` | されない（ro、または本体に無い） |
| git の `safe.directory` | されない（コンテナ内の system gitconfig） |
| Docker イメージ・コンテナ | ホストの Docker には**現れない**。sidecar の `docker-data` volume に閉じる |

## uid の扱い

- 本体コンテナのユーザーは `agent`（uid 1000。`DCC_USER` / `DCC_UID` で変更可）。macOS ホストでは Docker Desktop / Rancher Desktop などの VM を経由するため、bind mount 上のファイルはコンテナから基本的に読み書きできる
- git は所有者 uid の不一致を `dubious ownership` として拒否するので、postCreate（root 側）でワークスペースを `safe.directory` に登録する（[git.md](git.md)）
- sidecar の dockerd も uid 1000 で動く。inner container 内の root は userns 内の root で、ワークスペース上のファイルは uid 1000 として書かれる

## ネットワークの境界

- 本体と sidecar は netns を共有する。sidecar で `-p 3000:80` したポートは本体の `localhost:3000` で届く。ホストからは届かない（compose に `ports` を書いていない）
- 本体 → ホスト（`host.docker.internal` 等）の到達性は Docker ランタイム依存。設定では特別扱いしていない
- inner container → 親 netns の `127.0.0.1` には届かない（rootlesskit の `--disable-host-loopback`）
- モジュール sidecar の endpoint（`127.0.0.1:8080` / `8081` / `8082`）は共有 netns の内側だけで到達可能。ホスト・inner container・他の compose project からは届かない
- **外向きの通信は制限していない**（下記）

## この設計が守らないもの

コンテナは「本体が侵害されたときの被害の上限」を決めるもので、侵害そのものを防ぐものではない。次は範囲外。

- **外向きの通信。** 本体と inner container からインターネットへの通信は制限しない。ワークスペースの中身と、
  本体に渡した credential で取得できるもの（一時 credential、専用 token で読めるリポジトリなど）は外部へ送信されうる。
  制限したい場合は Docker ランタイムやホスト側のネットワークで行う
- **ワークスペース。** rw の bind なので、コンテナ内の操作はそのままホストのファイルに反映される。ワークスペース内の
  秘密情報（`.env` など）は本体から読める。ホストで実行されるファイル（git hooks、ビルドスクリプト、エディタの設定）を
  書き換えられる点にも注意する。書き込みはコンテナユーザー（uid `DCC_UID`、既定 1000）として行われ、Linux ホストでは
  その uid のファイルになる（root では書けない。上記「本体コンテナ内の権限」）
- **このリポジトリ自身（`DCC_CONFIG_DIR`）をワークスペースにしたとき。** `dcc` / `lib/*.sh` / `.env`（bash として source される）/
  `lifecycle_hooks/initialize.sh` / `capabilities/gpg/*.sh` はホストで実行され、`capabilities/*/Dockerfile` と `server.py` は
  秘密情報を持つ sidecar のイメージになる。これらが rw のワークスペースとしてコンテナに見えている間は、本体が書いた変更が
  次の `dcc` 実行でホスト上と sidecar 内で動く。つまり境界は無い。このリポジトリを `dcc` の中で編集するなら、
  `--no-creds` にし、ホストで `git diff` を見てから `dcc` を実行する。モジュールを有効にしたまま開かない
- **本体に渡した credential の利用。** 代行実行でも「署名させる」「一時 credential を取る」こと自体は本体から自由にできる。
  専用の鍵（`ssh`）と、失効前の access token（`gh`）は読み出せる。被害の上限は各ページの「侵害時に漏れるもの」のとおり
- **本体コンテナ内の権限。** コンテナユーザー（`agent`）は root に上がれない（sudo なし、`no-new-privileges` で setuid / file capability が
  無効、`cap_drop: ALL` で root にも capability が無い）。root が要るコンテナ作成後の処理は `dcc` が `compose exec --user root` で
  `postCreate-root.sh` として実行する。それでも境界はコンテナの外枠（非特権、ホストの Docker socket なし、選んだマウントだけ）で引いており、
  コンテナ内のファイル（`/etc`、イメージの中身）はエージェントのユーザー権限の範囲でしか守られない
- **エージェントの権限設定。** Claude Code の permissions / hooks / sandbox、Codex の承認ポリシーは利用者の設定の領域で、このリポジトリでは扱わない。
  唯一の例外として、**Codex 自身の sandbox は `dcc` が既定で外す**（コンテナ内では動かないことが多く、動いても sidecar への通信を切るため。[codex.md](codex.md)）
