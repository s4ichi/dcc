# dcc — Claude Code / Codex をコンテナに閉じ込めて動かす

> Run Claude Code or OpenAI Codex CLI inside a Docker Compose sandbox. The host's secrets (AWS, GPG, SSH,
> GitHub, `~/.claude`, `~/.codex`) are opt-in per module, Docker is provided by a rootless sidecar instead of
> the host socket, and signing / AWS / GitHub credentials are brokered by sidecars so that long-lived keys never enter
> the container. Documentation is written in Japanese.

`dcc` は、任意のディレクトリで [Claude Code](https://claude.com/claude-code) や [Codex CLI](https://github.com/openai/codex) を
**ホストから隔離したコンテナの中で**起動するための docker compose 設定と、その薄いラッパー CLI。

```bash
cd ~/src/my-project
dcc                     # コンテナを作って（あれば再利用して）中で claude を起動
dcc --agent codex       # 同じコンテナで codex を起動
dcc --creds gpg,ssh     # 署名と GitHub への SSH だけを渡して起動
```

## なぜ

コーディングエージェントは任意のコマンドを実行できる。読み込んだ Web ページやドキュメントに仕込まれた指示で、
認証情報の持ち出しやホストの改変を試みることもありうる。このリポジトリは**本体コンテナは侵害されうる**という
前提に立ち、「何を許可するか」ではなく「コンテナからは何に到達できないか」を compose の構成で決める。

- **秘密情報は選んだものだけ渡す。** `aws` / `gpg` / `ssh` / `gh` / `claude` / `codex` はモジュールになっていて、
  `--creds` で明示しない限り何もマウントされない
- **長期鍵をコンテナに持ち込まない。** GPG 署名、AWS、GitHub（`gh`）は sidecar が代行し、本体が受け取るのは署名結果と
  有効期限付きの一時 credential / access token だけ。SSH にはコンテナ専用に作った鍵を渡す
- **ホストの Docker を渡さない。** コンテナ内の `docker` は rootless な dind sidecar に繋がる。
  `docker run --privileged -v /:/host` をされても、届くのは sidecar の中まで
- **特権と秘密情報を同居させない。** `privileged` が付くのは秘密情報を一切持たない Docker sidecar だけ
- **生成物は静的。** compose ファイルは Jsonnet から生成してコミットしてあり、何がマウントされるかを
  ファイルとしてレビューできる。`dcc` は `-f` を並べて `docker compose` を呼ぶだけ

```
 host                         compose project（ワークスペースごとに 1 つ）
 ────                         ┌────────────────────────────────────────────────────────────┐
  dcc ─ docker compose ─────► │  agent（本体・非特権）              docker（sidecar）         │
                              │   claude / codex が動く場所  TLS    rootless dockerd          │
  ~/src/my-project ◄─ bind ─► │   /workspaces/my-project  ───────►  privileged はここだけ     │
  ~/.gitconfig ─── ro ──────► │   ~/.gitconfig                      秘密情報のマウントなし    │
                              │          │ 127.0.0.1（netns 共有）                           │
  --creds で選んだときだけ:    │          ▼                                                   │
  ~/.gnupg の署名鍵 ─ ro ───► │  gpg-signer（commit / tag への署名だけを代行）               │
  ~/.aws の login ── ro ────► │  aws-credentials（一時 credential だけを発行）               │
  dcc gh-login ─► volume ───► │  gh-token（数時間で失効する access token だけを発行）        │
                              └────────────────────────────────────────────────────────────┘
```

## 必要なもの

- `docker`（compose plugin 込み）。Docker Desktop / Rancher Desktop / OrbStack / Linux ネイティブのいずれか
- bash、`shasum` または `sha256sum`
- ホストに `~/.gitconfig` があること（read-only で常時マウントする。無ければ `touch ~/.gitconfig`）
- `gpg` モジュールを使う場合のみ、ホストに `gpg`

ホストは macOS を主に想定している。Linux でも動くが、uid が 1000 でない場合は `DCC_UID` を合わせる
（[docs/customization.md](docs/customization.md)）。devcontainer CLI は不要。

## クイックスタート

```bash
# 1. このリポジトリを ~/.config/dcc に clone しておく
#    （別の場所に置くなら DCC_CONFIG_DIR を export する）

# 2. dcc を PATH の通った場所に置く
ln -s ~/.config/dcc/dcc ~/.local/bin/dcc

# 3. 作業したいディレクトリで起動する
cd ~/src/my-project
dcc
```

初回はイメージの build に数分かかる。起動すると Claude Code がコンテナ内で立ち上がるので、初回だけ `/login` する。
ホストの認証（macOS の Keychain）は渡さない。コンテナで取った認証は volume `dcc-claude-home`
（`claude` モジュール有効時はホストの `~/.claude`）に残り、作り直しても全ワークスペースで使い回される。
Codex も同じ作りで、初回だけコンテナ内でログインする（ブラウザ方式はコンテナに届かないので `codex login --device-auth` か API key。
[docs/codex.md](docs/codex.md)）。

claude を終了してもコンテナは残る。次の `dcc` は同じコンテナに繋がる。止めるときは `dcc stop`、消すときは `dcc clear`。

## 使い方

```
dcc [command] [workspace] [options] [args...]
```

| コマンド | 動作 |
|---|---|
| `dcc` | コンテナを起動（無ければ作成）してエージェントを実行 |
| `dcc up` | 起動 / 作成だけ行う |
| `dcc exec [args]` | エージェントを実行する。`--` 以降と未知のオプションはエージェントに渡る（例: `dcc exec -- --resume`） |
| `dcc stop [--all]` | 停止（`--all` で全ワークスペース） |
| `dcc clear [--all] [--volumes]` | 削除。`--volumes` で sidecar の named volume（イメージキャッシュ等）も削除 |
| `dcc recreate` | 削除して作り直す。compose や credential の変更を反映するときに使う |
| `dcc build [opts]` | イメージを build する（例: `dcc build --no-cache`）。反映には `dcc recreate` |
| `dcc creds` | モジュールの一覧と、このワークスペースの現在の選択を表示 |
| `dcc gh-login [args]` | `gh` モジュールの token を用意する（`gh auth login --expiring`。全ワークスペース共有） |
| `dcc list` / `dcc inspect` | 全ワークスペースのコンテナを一覧 / 詳細表示 |

実行するエージェントは `--agent claude|codex`（既定は `DCC_AGENT`、無ければ `claude`）で選ぶ。両方とも同じコンテナに
入っているので、コンテナを作り直さずに呼び出しごとに切り替えられる。

ワークスペースは第 1 引数のディレクトリ → `DCC_WORKSPACE` → `$PWD` の順で決まり、コンテナ内では
`/workspaces/<ディレクトリ名>` に見える。ワークスペースごとに独立した compose プロジェクト
（`dcc-<名前>-<パスのハッシュ>`）が作られる。

## credential モジュール

何も指定しなければ、コンテナに渡るのはワークスペースと `~/.gitconfig`（ro）だけ。

```bash
dcc --creds gpg,ssh          # 選んだモジュールだけを有効にして作成
dcc                          # 以後はフラグ無しで同じコンテナ（同じ選択）に繋がる
dcc recreate --creds aws,gh  # 選択を変えるときは作り直す
export DCC_CREDS=gpg,ssh     # 新規作成時の既定値
```

| モジュール | コンテナからできること | 渡し方 | 事前準備 | 詳細 |
|---|---|---|---|---|
| `gpg` | commit / tag への署名 | **代行**。秘密鍵は `gpg-signer` sidecar だけが持つ | ホストで `user.signingkey` を設定 | [docs/gpg.md](docs/gpg.md) |
| `aws` | ホストで login 済みの 1 profile の一時 credential の取得 | **代行**。`aws-credentials` sidecar が発行する | ホストで `aws login` | [docs/aws.md](docs/aws.md) |
| `ssh` | GitHub への SSH 接続 | コンテナ専用の鍵を ro で渡す | `capabilities/ssh/data/` に専用鍵を作る | [docs/ssh.md](docs/ssh.md) |
| `gh` | `gh` による GitHub API 操作と HTTPS の git | **代行**。refresh token は `gh-token` sidecar だけが持ち、本体は短命の access token を毎回受け取る | ホストで `dcc gh-login` | [docs/github.md](docs/github.md) |
| `claude` | ホストと同じ Claude Code の設定・履歴・プラグインで動く | ホストの `~/.claude` を **rw 共有** | なし | [docs/claude-code.md](docs/claude-code.md) |
| `codex` | ホストと同じ Codex の設定・履歴・**認証**で動く | ホストの `~/.codex` を **rw 共有** | なし | [docs/codex.md](docs/codex.md) |

選択の解決順や、既存コンテナとの不一致（drift）の扱いは [docs/credentials.md](docs/credentials.md)。

## セキュリティモデル

本体コンテナが乗っ取られたときに、攻撃者が得られるものの上限:

| 境界 | 上限 |
|---|---|
| `gpg` | commit / tag に署名させられる。鍵とパスフレーズは漏れない |
| `aws` | 有効期限付きの一時 credential。長期鍵と login セッションは漏れない |
| `ssh` | コンテナ専用の鍵が漏れる。被害はそれに与えた権限の範囲で、GitHub 側で失効できる |
| `gh` | 数時間で失効する access token。refresh token は漏れない |
| `claude` | 有効時は**ホストの Claude Code の設定の改変、token と履歴の持ち出し**（最大の穴。必要なワークスペースでだけ有効にする）。無効時は volume 内の token と履歴だけ |
| `codex` | 有効時は**ホストの Codex の token の持ち出しと設定の改変**（`auth.json` は平文のファイルで、`notify` や hooks を書き換えられるとホストでコマンドが走る。`claude` より重い）。無効時は volume 内の token と履歴だけ |
| Docker | sidecar 内の uid 1000 の権限。ホストの Docker とワークスペース以外のファイルには届かない |

この構成が**守らないもの**:

- **外向きの通信は制限しない。** ワークスペースの中身と、コンテナに渡した credential で取得できるものは外部へ送信されうる
- **ワークスペースは rw。** コンテナ内の操作はそのままホストのファイルに反映される
- エージェント自体の権限設定（Claude Code の permissions / hooks、Codex の承認ポリシー）は扱わない。コンテナは
  「突破されたときの被害の上限」を決めるもので、エージェント側の設定の代わりにはならない
- **Codex 自身の sandbox は既定で外している。** コンテナの中では動かないことが多く、動いても Docker sidecar への通信を切ってしまうため、
  コンテナを sandbox と位置づけている（`DCC_CODEX_ARGS` で変更可。[docs/codex.md](docs/codex.md)）

境界の総論は [docs/boundaries.md](docs/boundaries.md)、境界ごとの設計理由と既知の穴は各ページにある。

## カスタマイズ

個人・組織固有の値はリポジトリに書かず、既定値付きの `DCC_*` 環境変数（シェル、または `.env`）で与える。
一覧は [`.env.example`](.env.example)。

- コンテナに環境変数を渡す: `DCC_CONTAINER_ENV_<NAME>=value`
- イメージにツールを足す: `local/Dockerfile`（`FROM dcc:base`）
- bind や環境変数を足す: `local/compose.yml`

`local/` と `.env` は gitignore 済みで、置くだけで `dcc` が使う。詳細は [docs/customization.md](docs/customization.md)。

## devcontainer CLI / VS Code から使う

同じ compose ファイルは `devcontainer.json` の `dockerComposeFile` からも参照でき、credential モジュールも同じように使える
（[docs/devcontainer.md](docs/devcontainer.md)）。

## ドキュメント

| | |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 構成要素、compose プロジェクトの構造、ライフサイクル、CLI の仕様 |
| [docs/boundaries.md](docs/boundaries.md) | ホストとの境界の総論、設計原則、マウント一覧 |
| [docs/credentials.md](docs/credentials.md) | credential モジュールの選択と仕組み、モジュールの追加方法 |
| [docs/customization.md](docs/customization.md) | `DCC_*` 環境変数、`local/`、ホスト側の前提 |
| [docs/README.md](docs/README.md) | 全ページの索引（境界ごとのページを含む）と用語 |

## 開発

```bash
make generate   # template.jsonnet から compose ファイルを生成する
make fmt        # jsonnetfmt
make check      # shellcheck + bats + Jsonnet の評価
```

`docker-compose*.yml` と `capabilities/*/compose.yml` は生成物なので直接編集せず、`template.jsonnet` を変えて
`make generate` する。必要なツールは `jsonnet`（go-jsonnet）、`shellcheck`、`bats`
（macOS: `brew install go-jsonnet shellcheck bats-core`）。本体イメージには `jsonnet` は入っているが
`shellcheck` / `bats` は無く、コンテナ内に sudo も無いので、コンテナ内で `make check` まで回すなら
`local/Dockerfile` で足す（[docs/customization.md](docs/customization.md)）。
コードの構成と規約は [CLAUDE.md](CLAUDE.md) と [docs/architecture.md](docs/architecture.md)。

## License

[MIT](LICENSE)
