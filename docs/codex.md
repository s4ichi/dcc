# Codex CLI の設定・状態

**モジュール名: `codex`** — `dcc --creds codex` を指定したときだけホストの `~/.codex` を共有する（[credentials.md](credentials.md)）。
Codex CLI 自体は本体イメージに常に入っており、モジュールを外しても `dcc --agent codex` で動く。その場合はホストの設定・履歴・認証とは
無関係な空の環境になる（下記）。Claude Code の同じ話は [claude-code.md](claude-code.md)。

このページの Codex の仕様に関する記述は Codex CLI 0.154.0 時点の公式ドキュメントとソースに基づく。
**実機で未確認の点は「未検証の前提」にまとめてある。**

## 守るもの

| 実体 | 所在 | 性質 |
|---|---|---|
| `~/.codex/auth.json` | ホスト / コンテナ | ChatGPT ログインの token（refresh token を含む）または API key。**平文**。保存先の既定は OS を問わずこのファイルで、macOS でも Keychain ではない（`cli_auth_credentials_store = "file"` が既定） |
| `~/.codex/config.toml` | ホスト | モデル、sandbox / 承認の設定、MCP サーバー、`notify`。**書き換えられると、ホストで Codex を動かしたときに実行されるコマンドが変わる** |
| `~/.codex/hooks.json`、`rules/` | ホスト | ライフサイクルフックと、sandbox の外で実行を許すコマンドの規則 |
| `~/.codex/.credentials.json` | ホスト / コンテナ | MCP サーバーの OAuth token（keyring が使えないときの保存先。コンテナには keyring が無い） |
| `~/.codex/sessions/`、`history.jsonl` | ホスト | セッション履歴（会話内容） |
| `~/.codex/AGENTS.md` | ホスト | 全プロジェクト共通の指示 |

## 境界

| 軸 | モジュール有効（ホストと共有） | モジュール無効（空の volume） |
|---|---|---|
| できること | コンテナ内の Codex はホストと同じ設定・履歴・認証で動き、それらを**書き換えられる** | Codex の既定設定で動く。ホストのものは何も見えず、何も変えられない |
| 届く範囲 | `~/.codex` はホストと **rw で共有**（ディレクトリ単位） | ホストの `~/.codex` には到達しない。`~/.codex` は全ワークスペース共有の volume |
| 鍵の渡し方 | **ホストの token をそのまま共有する**（`auth.json` は平文のファイル）。コンテナ内でログインする必要は無い | コンテナ内で認証し、結果は volume に残る。ホストには一切戻らない |

## 侵害時に漏れるもの

本体コンテナが乗っ取られた場合:

- **モジュール有効**: `~/.codex` 配下はすべて読み書きできる。[claude-code.md](claude-code.md) の `claude` モジュールと同じ類の穴だが、**一段重い**:
  - **ホストの Codex の token が持ち出せる。** Claude Code（macOS）の token は Keychain にあってコンテナに渡らないが、Codex の `auth.json` は
    既定で平文のファイルなので、共有した時点でホストのログインそのものがコンテナに渡る
  - `config.toml` の `notify`、`hooks.json`、`[mcp_servers.*]` の `command` を書き換えられる。いずれも Codex が外部コマンドを起動する設定なので、
    **次にホストで Codex を起動したとき、ホスト上で攻撃者のコマンドが走る**（コンテナからホストへ抜ける経路になる）
  - sandbox / 承認の設定（`sandbox_mode`、`approval_policy`、`rules/`）を緩められる。ホストの Codex にも効く
  - セッション履歴（会話内容）を読める
- **モジュール無効**: 持ち出せるのは volume 内の token（コンテナで取得したもの）とコンテナ側の履歴だけ。ホストには何も無く、ホストの設定も変えられない
- どちらでも、Codex 自身の sandbox は既定で外してあるので（下記）、Codex が実行するコマンドは本体コンテナの権限でそのまま動く。
  被害の上限を決めるのはコンテナの外枠（[boundaries.md](boundaries.md)）

## なぜこの構成か

- **`~/.claude` と対称にする**: 既定は共有しない側に倒し、共有はモジュールで選ぶ。共有するかどうかは「ホストの Codex の認証と設定をコンテナから
  読み書きされてよいか」の判断で、ワークスペースごとに変えられる。上のとおり共有の代償は `claude` モジュールより大きいので、必要なワークスペースでだけ有効にする
- **ディレクトリ単位で渡し、ファイル単位では渡さない**: Codex は `config.toml` を一時ファイル + `rename` で書き換える（プロジェクトの trust 判定、`/model`、
  `codex mcp add` などで日常的に起きる）。single-file bind はマウントポイントなので `rename` が失敗する。`auth.json` だけを渡す、`config.toml` だけを ro で渡す、
  といった細分化はしない
- **共有しないときは空の固定名 volume**: コンテナローカルだと `dcc recreate` で token が消えて毎回ログインになる。compose の volume はプロジェクト名で
  プレフィックスされるのでワークスペースごとにログインが要る。固定名（`dcc-codex-home`）の external volume にすると全ワークスペースで 1 回のログインで済み、
  `dcc clear --volumes` でも消えない
- **Codex 自身の sandbox を既定で外す**: Codex の Linux sandbox は bubblewrap で、非特権の user namespace の作成が要る。非特権のコンテナの中ではこれが
  許可されないことが多い。加えて、既定の `workspace-write` は実行するコマンドのネットワークを切り離すので、TCP で繋ぐ Docker sidecar
  （`DOCKER_HOST=tcp://docker:2376`）にも、`aws` / `gpg` のモジュール sidecar（`127.0.0.1`）にも届かなくなる。このリポジトリでは
  **コンテナを sandbox と位置づけ**、`dcc` が `-c sandbox_mode=danger-full-access` を渡す。この設定では Codex は bubblewrap を使わない
- **承認ポリシーには触らない**: いつ確認を求めるかは利用者の好みで、`config.toml` か引数で決めればよい。`dcc` が外すのは「コンテナ内では動かないか、
  動いても sidecar を使えなくするもの」だけ
- **`--sandbox` ではなく `-c` で渡す**: `-c key=value` は `config.toml` の上書きで、専用の引数より優先度が低い。利用者が
  `dcc exec --agent codex -- --sandbox workspace-write` のように重ねても、同じ引数が二重になることを避けられる
- **公式の install.sh を使わず、イメージに焼き込む**: install.sh は shell profile を書き換え、本体を `~/.codex/packages/` 配下に置く。`~/.codex` は
  volume / ホストの bind になるので、実体をそこに置くとイメージと食い違う（[claude-code.md](claude-code.md) で Claude Code の実体を volume にしないのと同じ理由）。
  GitHub Releases（`CODEX_VERSION` のタグ）の `codex-package-<target>.tar.gz`（`codex` に加えて `bwrap` と `rg` を同梱）を `/opt/codex` に展開し、同じリリースの
  `codex-package_SHA256SUMS` で検証する。Node.js は要らない
- **起動時の更新チェックを切る**: 実体は root 所有の `/opt/codex` にあり、コンテナ内からの自己更新は想定しない。更新はイメージの rebuild で行う

## 仕組み

### モジュール有効（`capabilities/codex/compose.yml`）

| ホスト側 | コンテナ側 | モード | 内容 |
|---|---|---|---|
| `~/.codex/`（`DCC_CODEX_DIR`） | `/home/agent/.codex/` | **rw** | 設定、認証情報、セッション履歴、MCP の token |

base の volume と同じ target `/home/agent/.codex` を bind で上書きする（compose の同一 target は後勝ち）。`initialize.sh codex` がホスト側の
ディレクトリの存在を事前に警告する。

### モジュール無効（base）

| ホスト側 | コンテナ側 | モード | 内容 |
|---|---|---|---|
| volume `dcc-codex-home`（`DCC_CODEX_HOME_VOLUME`。external、全ワークスペース共有） | `/home/agent/.codex/` | rw | 空で始まる。認証情報と履歴はここに残る |

`dcc up` が volume を無ければ作る（external なので compose は作らない。devcontainer からは `docker volume create dcc-codex-home`）。
base の compose が参照するので、**Codex を使わない場合もこの volume は作られる**（空のまま）。所有者はイメージの `~/.codex`（コンテナユーザー所有）を初回 mount で引き継ぎ、postCreate はそれを確認して `chmod 700` するだけ。

### 起動と既定引数

```bash
dcc --agent codex                       # up + codex を起動
dcc exec --agent codex -- resume --all  # `--` 以降は codex に渡る
export DCC_AGENT=codex                  # 既定のエージェントを codex にする
```

`claude` と `codex` は同じコンテナに入っており、どちらを起動するかは呼び出しごとに選ぶ。`dcc` は起動時に、利用者の引数の前へ次を足す。

| 変数 | 既定値 | 内容 |
|---|---|---|
| `DCC_CODEX_ARGS` | `-c sandbox_mode=danger-full-access -c check_for_update_on_startup=false` | `codex` の前置引数 |
| `DCC_CLAUDE_ARGS` | 空 | `claude` の前置引数 |

値は空白で分割されるだけで、引用は解釈されない。**空文字を設定すると何も足さない**（`DCC_CODEX_ARGS=`）。Codex の sandbox を使いたい場合は
空にしたうえで、コンテナで bubblewrap が動くこと、`[sandbox_workspace_write] network_access = true` にしないと sidecar に届かないことを確認する。

### ログイン（モジュール無効のとき）

ブラウザでのログインは、Codex が**コンテナ内の** `127.0.0.1:1455` で callback を待つ。本体コンテナはポートをホストに公開していないので
（[docker.md](docker.md)）、ホストのブラウザからは届かない。次のどちらかを使う。

- **device code**: コンテナ内で `codex login --device-auth`。表示された URL をホストのブラウザで開いてコードを入力する。beta の機能で、
  ChatGPT 側（個人ならセキュリティ設定、ワークスペースなら管理者の権限設定）で device code ログインを有効にしておく必要がある
- **API key**: コンテナ内で `printenv OPENAI_API_KEY | codex login --with-api-key`（key は stdin から読まれる）

どちらも結果は `~/.codex/auth.json`（volume）に残り、`dcc recreate` と全ワークスペースを跨いで使い回される。確認は `codex login status`、消すのは `codex logout`。

モジュール有効のときはホストの `auth.json` がそのまま使われるので、ログインは要らない。token の更新（期限が近いと Codex が refresh して `auth.json` に
書き戻す）はホストとコンテナで同じファイルに対して行われる。コピーではないので「片方の更新でもう片方が無効になる」問題は無いが、
ホストとコンテナで同時に Codex を動かすと書き込みが競合しうる。

### MCP サーバー

設定は `config.toml` の `[mcp_servers.<name>]`、または `codex mcp add`。remote サーバーの OAuth は `codex mcp login <name> --no-browser` を使う
（認可 URL を表示し、ブラウザでの認可後にリダイレクトされた URL を貼り付ける方式。callback のポートをホストに公開しなくてよい）。
token は keyring の無いコンテナでは `~/.codex/.credentials.json` に平文で残る。stdio サーバーの実行コマンドが**コンテナ内**に必要なことは
[mcp.md](mcp.md) の「stdio サーバー」と同じ。

### 環境変数

Codex は既定では親プロセスの環境変数をすべて、実行するコマンドに引き継ぐ（`shell_environment_policy.inherit = "all"`、名前に `KEY` / `SECRET` /
`TOKEN` を含む変数の除外は既定で無効）。そのため compose が本体に設定する `DOCKER_HOST` / `DOCKER_CERT_PATH` / `DOCKER_TLS_VERIFY`、
`gpg` モジュールの `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0`、`aws` モジュールの `AWS_CONTAINER_CREDENTIALS_FULL_URI` は
Codex が実行する `docker` / `git` / `aws` からそのまま見える。`config.toml` で `inherit = "core"` にしたり `ignore_default_excludes = false` に
したりするとこれらが落ちる（後者は `GIT_CONFIG_KEY_0` が `*KEY*` に一致する）ので、共有した `config.toml` でそうしている場合は注意する。

## 未検証の前提

次は公式ドキュメントとソースからの推定で、**このリポジトリのイメージ上では実際に動かして確認していない。** `dcc build` のあと、ホストで確認する。

| 前提 | 確認方法 | 外れていた場合 |
|---|---|---|
| `codex` が `-c key=value`（`--config`）を受け付け、`-c sandbox_mode=danger-full-access` で sandbox が外れる | `docker run --rm dcc:local codex --help` に `-c, --config` があること。`dcc --agent codex` で起動し `/status` の sandbox が `danger-full-access` であること | `DCC_CODEX_ARGS="--sandbox danger-full-access"` にする（`--sandbox` の存在はソースで確認済み。利用者が `--sandbox` を重ねると引数が重複しうる） |
| 非特権コンテナでは bubblewrap が user namespace を作れない（sandbox を外す既定の根拠の 1 つ） | `docker run --rm dcc:local /opt/codex/codex-resources/bwrap --unshare-user true; echo $?` が非 0 で、`No permissions to create new namespace` の類が出ること | 動く環境なら Codex の sandbox を併用できる。ただし `workspace-write` がネットワークを切る点は変わらないので、既定を変える理由にはならない |
| `codex-package-<target>.tar.gz` の中身が `bin/codex` / `codex-resources/` / `codex-path/` で、`codex-package_SHA256SUMS` が `sha256sum -c` の形式である | `dcc build` の Codex のレイヤが通ること（形式が違えば build がそこで失敗する） | `Dockerfile` の Layer 11 を実際のレイアウトに合わせる |

## 制約・既知の穴

- **モジュール有効時は、ホストの Codex の token が平文でコンテナに渡り、ホストで実行されるコマンドの設定（`notify` / hooks / MCP）にコンテナ内から
  書き込める。** 防ぎたいワークスペースでは無効にする
- Codex 自身の sandbox は既定で外してある。Codex が実行するコマンドを止めるのは、承認ポリシー（利用者の設定）とコンテナの外枠だけ
- グローバルな skills（`~/.agents/skills`）は `~/.codex` の外にあるので、モジュールを有効にしても渡らない。必要なら `local/compose.yml` で bind する
  （[customization.md](customization.md)）
- `codex resume` / `codex fork` は既定で作業ディレクトリが同じセッションだけを対象にする。ホストでは `/Users/<user>/src/foo`、コンテナでは
  `/workspaces/foo` になるので、共有していても互いのセッションは既定の一覧に出ない（`--all` で出る）
- プロジェクトを信頼するかの判定（trust）も `config.toml` にパスで記録される。コンテナのパスはホストと違うので、コンテナ側で改めて聞かれる
- 版は `Dockerfile` の `CODEX_VERSION`（リリースのタグ）で固定している。更新はこの値を上げて `dcc build` → `dcc recreate`。
  起動時の更新通知は既定引数で切ってある
- `/opt/codex` は約 260 MB あり、Codex を使わない場合もイメージに含まれる
- 複数の `dcc exec --agent codex` を同じコンテナで同時に動かすと、Codex の共有バックグラウンドサーバーを共有する。切り離すなら `--no-daemon`
- Codex は既定で利用状況のメトリクスを送信する。止めるなら `config.toml` に `[analytics] enabled = false`
