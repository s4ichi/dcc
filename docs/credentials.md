# credential モジュールの選択的付与

## 概要

ホストの秘密情報は**モジュール**単位に分かれており、`dcc` 起動時に `--creds` で選んだものだけが
本体コンテナにマウントされる。何も指定しなければ秘密情報モジュールは 1 つも渡らない。

| モジュール | 渡すもの | モード | 付随処理 | 詳細 |
|---|---|---|---|---|
| `aws` | 一時 credential（`~/.aws` は本体にマウントしない） | HTTP | `aws-credentials` sidecar が `~/.aws/config` / `~/.aws/login/cache` (ro) から発行 | [aws.md](aws.md) |
| `gpg` | 署名 API（秘密鍵は `gpg-signer` sidecar のみ。本体には公開鍵と `gpg.program` wrapper だけ） | HTTP | `initialize.sh gpg` がホストで公開鍵・keygrip・署名鍵を export、起動後に `capabilities/gpg/warm.sh` で sidecar 内 pinentry を通す（`dcc` は自動） | [gpg.md](gpg.md) |
| `ssh` | `./capabilities/ssh/data` → `~/.ssh`、`./capabilities/ssh/{config,known_hosts}` → `/etc/ssh` | ro | なし | [ssh.md](ssh.md) |
| `gh` | 短命の access token（refresh token は `gh-token` sidecar のみ。本体には `gh` の wrapper と git の credential helper だけ） | HTTP | ホストで一度 `dcc gh-login`（状態は全ワークスペース共有の volume `dcc-gh-home`。`dcc up` / `gh-login` が作る） | [github.md](github.md) |
| `claude` | ホストの `~/.claude` → `~/.claude`、`~/.claude.json` → `~/.claude.json.host` | rw / ro | 外すと `~/.claude` は全ワークスペース共有の空の volume `dcc-claude-home` になる（`dcc up` が作る） | [claude-code.md](claude-code.md) |
| `codex` | ホストの `~/.codex` → `~/.codex`（`auth.json` = ホストの Codex の token を含む） | rw | 外すと `~/.codex` は全ワークスペース共有の空の volume `dcc-codex-home` になる（`dcc up` が作る） | [codex.md](codex.md) |

`claude` / `codex` モジュールは「そのエージェントを使えるようにする」ものではない。エージェントは両方とも本体イメージに入っており、
どちらを起動するかは `--agent` で選ぶ（[architecture.md](architecture.md)）。モジュールが決めるのは、ホストの設定と認証を共有するかどうかだけ。

常時マウント（モジュール化していないもの）: ワークスペース、`~/.gitconfig`（[git.md](git.md)）、
lifecycle hook、Docker TLS 証明書、`claude` / `codex` モジュール無効時の volume。

## 指定方法（`dcc`）

```
dcc [command] [workspace] [options] [args...]

Credential options (default / up / exec / recreate):
  --creds <a,b,...>   有効にするモジュール。カンマ区切り、複数回指定可（和集合）
  --all-creds         全モジュール有効
  --no-creds          最小構成を明示

Environment:
  DCC_CREDS           --creds の既定値（例: DCC_CREDS=gpg,ssh）。フラグ指定があれば使われない

Subcommand:
  dcc creds [workspace]   利用可能なモジュール / 既定値 / 今回の解決結果 / 実行中コンテナの選択を表示
  dcc gh-login [args]     gh モジュールの token を用意する（gh auth login --expiring。github.md）
```

例:

```bash
dcc --creds gpg,ssh                 # 署名と SSH だけ渡して claude を起動
dcc up ~/src/foo --creds=gh         # 別ワークスペースを gh だけで起動
DCC_CREDS=aws,gpg dcc               # 環境変数で既定値
dcc exec --creds gpg -- --resume    # `--` 以降は claude に渡る
dcc creds                           # 状態確認
dcc recreate --all-creds            # 全部渡して作り直し
```

`dcc` が解釈するのは上記のオプションだけ。それ以外の `--xxx` と `--` 以降は位置引数として扱われ、
`exec` では `claude` に透過する。第 1 非オプション引数がディレクトリならワークスペースとして扱う。

フラグを何も付けないときの解決は次の順:

1. 既存コンテナ（停止中も含む）があれば、そのラベル `dcc.credentials` の選択をそのまま使う。
   モジュールは作成時にしか反映できないので、`dcc --creds gpg,ssh` で作ったコンテナには以後 `dcc` だけで接続できる。
   フラグ無しの `dcc recreate` も同じ選択で作り直す
2. 無ければ `DCC_CREDS`
3. それも無ければ最小構成

起動時に stderr へ出るヘッダーの `credentials` 行で確認できる（既存コンテナの選択を採用したときは `(existing container)` が付く）。

## 実行中コンテナとの不一致（drift）

選択はコンテナのラベル `dcc.credentials` と環境変数 `DCC_CREDS`（カンマ区切り）に記録される。
`--creds` / `--all-creds` / `--no-creds` を明示したときは、既存コンテナ（停止中も含む）のラベルと今回の要求を比較する。

| 状況 | 挙動 |
|---|---|
| フラグ無し | 既存の選択をそのまま採用して接続（比較しない） |
| 一致 | そのまま接続 |
| 不一致 | 警告して**既存に接続**（マウントは変わらない）。適用するには `dcc recreate --creds …` |
| 選択は同一だが `aws` の `AWS_PROFILE` が違う | 同様に警告（ラベル `dcc.aws-profile` と比較。フラグ無しでも比較する） |
| 選択は同一だが `gpg` の署名鍵が違う | 同様に警告（実行中の `gpg-signer` が起動時に固定した鍵と、ホストが今 export した `signing-key.txt` を比較。sidecar 停止中は比較しない。フラグ無しでも比較する） |

```
! credentials    container has gpg ssh; requested aws (+aws -gpg -ssh)
                 run 'dcc recreate --creds aws' to apply
```

## 仕組み

```
template.jsonnet ──make generate──►  docker-compose.yml               (base: 常時マウント + sidecar)
                                          docker-compose.workspace.yml     (dcc 用ワークスペース bind)
                                          capabilities/<name>/compose.yml  (services.agent への追記 + モジュール専用 sidecar)

dcc up --creds gpg,ssh
  ├─ resolve_creds     : フラグ > 既存コンテナのラベル > DCC_CREDS の順に選び、名前検証・正規化
  │                      → CREDS="gpg ssh", DCC_CREDS="gpg,ssh" を export
  ├─ initialize.sh gpg ssh : ホスト側の前処理 (gpg の export) と bind ソースの事前チェック
  ├─ check_drift       : 既存コンテナと比較して警告 (モジュールの選択 / AWS_PROFILE / gpg の署名鍵。
  │                      選択はフラグ指定時のみ差が出る)
  ├─ docker compose -p <project> -f base -f workspace -f capabilities/gpg/compose.yml -f capabilities/ssh/compose.yml up -d --no-recreate
  ├─ docker compose exec --user root agent postCreate-root.sh agent    (未実行のときだけ)
  └─ docker compose exec --user agent agent postCreate.sh
```

設計上のポイント:

- **overlay は静的な生成物で commit する。** ホストに jsonnet は不要で、何がマウントされるかを
  ファイルとしてレビューできる。
- overlay 内のリポジトリ内パスは `${DCC_CONFIG_DIR}` 基準の**絶対パス**で書く（`dcc` が解決済みの値を
  export する。既定値 `~/.config/dcc` は compose 側に持つ）。compose の project
  directory（最初の `-f` の親）に依存しないので、devcontainer CLI から別の並びで `-f` に渡しても同じ
  場所を指す（[devcontainer.md](devcontainer.md)）。
- compose は multi-file の `volumes` を target キーで追記マージする。同じ target を 2 つの overlay に
  書くと後勝ちになるので target は重複させない。
- compose の環境変数補間に依存する値はモジュール側に置かない。ホスト側の前処理の結果はファイル
  （`capabilities/gpg/gnupg-host/*`）で渡し、sidecar と本体はそれを読む。devcontainer 経由では
  `initializeCommand` から compose に環境変数を渡せないため。
- `dcc build` は base と**全 overlay** を `-f` に渡し、`build` を持つ service（`agent` と
  モジュール専用 sidecar）をすべてビルドする。`stop` / `clear` は `-p` のラベル操作なので選択に依存しない。

## モジュールの追加

1. `template.jsonnet` の `credModules` にエントリを足す（base にマージされる compose 断片。
   通常は `services.agent.volumes` の追記だけだが、`aws` のようにモジュール専用の service を
   追加してもよい）。
2. `make generate` → `capabilities/<name>/compose.yml` が生成される。`dcc` はこのファイル名一覧から
   モジュール名を得るので、`dcc` 側の変更は不要。
3. ホスト側の前処理や bind ソースの事前チェックが必要なら `lifecycle_hooks/initialize.sh` の `case` に
   足す（`gpg` の export が例）。結果は compose の環境変数ではなく**ファイル**で渡す（devcontainer 経由
   でも動くように）。
4. コンテナ側の後処理が必要なら `postCreate.sh`（コンテナユーザー）か `postCreate-root.sh`（root。system gitconfig など）で
   マウントの存在を見て gate する（`setup_gnupg` と `gpg.program` の登録が例）。本体に sudo は無く root にも capability が
   無いので、`chown` のような処理は書けない（所有者はイメージ側で用意する）。
5. ホスト側のパスやポートなど利用者ごとに変わりうる値は `${DCC_X:-<既定値>}` で書き、`.env.example` と
   [customization.md](customization.md) の表に 1 行足す。
6. `docs/<name>.md` を [README.md](README.md) の「各ページの構成」に沿って書き、同ページの表、
   [boundaries.md](boundaries.md) の要約とマウント一覧、リポジトリ直下の `README.md` の表に足す。

## 制約・今後

- 選択が残るのはコンテナのラベルだけ。`dcc clear` でコンテナを消すと選択も消えるので、次に作るときは
  `--creds` か `DCC_CREDS` で指定し直す（ワークスペースごとの保存、対話チェックリスト、名前付きプロファイルは
  将来の拡張余地）。
- 選択の変更は作り直しでしか反映できない（マウントと sidecar はコンテナ作成時に決まる）。
- `~/.gitconfig` は常時マウントで外せない（[git.md](git.md)）。`claude` モジュールは `~/.claude` を丸ごと共有するか
  しないかの二択で、設定だけ・token だけを渡すといった細分化はしない（理由は [claude-code.md](claude-code.md)）。
