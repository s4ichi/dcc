# devcontainer から使う

`dcc` はこのリポジトリの compose ファイルを `docker compose` で直接使う薄いラッパーで、
devcontainer CLI には依存しない。同じ compose ファイルは devcontainer CLI / VS Code Dev Containers
からも参照でき、credential モジュール（`aws` / `claude` / `gpg` / `ssh` / `gh`）も同じ挙動で使える。
このページはその使い方。

## 前提: devcontainer CLI が compose に渡さないもの

devcontainer CLI は `dockerComposeFile` の各要素を順番どおり `-f` に展開して `docker compose up` を
呼ぶが、次の 2 つは**渡さない**（CLI のソースで確認済み）。

- ワークスペースのパス。`${localWorkspaceFolder}` の置換は `devcontainer.json` の中だけで、compose
  ファイルには何の環境変数も渡らない
- ホストで行う前処理の結果（`gpg` の公開鍵 export など）

このため base の `docker-compose.yml` には**ワークスペースの bind を置いていない**。`dcc` は
`docker-compose.workspace.yml`（`dcc` が export する `LOCAL_WORKSPACE_FOLDER` で補間）を足し、
devcontainer からはワークスペース側の compose ファイルで同じ bind を与える。ホスト側の前処理は
`lifecycle_hooks/initialize.sh` に切り出してあり、`initializeCommand` から呼ぶ。

## 設定例

ワークスペースに 2 ファイル置く。`<repo>` はこのリポジトリ（デフォルト
`~/.config/dcc`）。

### `.devcontainer/compose.yml`

ワークスペースの bind。本体（`agent`）と Docker sidecar（`docker`）の**両方**に、同一パスで bind する
（`docker run -v /workspaces/<name>/x:/x` の bind を解決するのは sidecar の dockerd だから）。
`<name>` は `devcontainer.json` の `workspaceFolder` と揃える。

```yaml
services:
  agent:
    volumes:
      - type: bind
        source: ..
        target: /workspaces/<name>
        consistency: cached
  docker:
    volumes:
      - type: bind
        source: ..
        target: /workspaces/<name>
        consistency: cached
```

### `.devcontainer/devcontainer.json`

```json
{
  "name": "Claude Code",
  "dockerComposeFile": [
    "compose.yml",
    "${localEnv:HOME}/.config/dcc/docker-compose.yml",
    "${localEnv:HOME}/.config/dcc/capabilities/gpg/compose.yml",
    "${localEnv:HOME}/.config/dcc/capabilities/ssh/compose.yml"
  ],
  "service": "agent",
  "remoteUser": "agent",
  "workspaceFolder": "/workspaces/<name>",
  "shutdownAction": "stopCompose",
  "initializeCommand": "${localEnv:HOME}/.config/dcc/lifecycle_hooks/initialize.sh gpg ssh",
  "postCreateCommand": "bash /usr/local/lib/dcc/hooks/postCreate.sh"
}
```

- **`compose.yml` を先頭に置く。** compose の project directory は最初の `-f` の親になり、
  `compose.yml` の `source: ..` はそれを基準に解決される（= ワークスペース）。このリポジトリ側の
  compose ファイルはリポジトリ内のパスをすべて `${DCC_CONFIG_DIR}` 基準の絶対パスで書いているので、
  project directory がどこでも動く
- 使うモジュールは `capabilities/<name>/compose.yml` を `dockerComposeFile` に足すだけ。同じ名前を
  `initializeCommand` の引数にも書く（ホスト側の前処理と事前チェック）
- `${localEnv:HOME}` は devcontainer CLI が置換する。リポジトリを別の場所に clone した場合はパスを
  変え、compose が同じ場所を見るようにシェルで `DCC_CONFIG_DIR` を export する
  （compose ファイル内の既定値は `~/.config/dcc`）
- 利用者ごとの設定（`DCC_*`。[customization.md](customization.md)）は**シェルの環境変数**で渡す。
  `dcc` が読む `${DCC_CONFIG_DIR}/.env` は、project directory がワークスペース側になるため compose からも
  読まれない。`DCC_COMPOSE_FILES` 相当は `dockerComposeFile` に自分の overlay を並べればよい。
  `DCC_CONTAINER_ENV_<NAME>` は `dcc` が集めるので効かない。コンテナに渡す環境変数は dotenv 形式のファイルを
  書いて `DCC_CONTAINER_ENV_FILE` でそのパスを渡すか、自分の overlay の `environment` に書く
- `local/Dockerfile`（[customization.md](customization.md)）は `dcc` を通らないと自動検出されない。使うなら
  シェルで `DCC_BUILD_CONTEXT=<repo>/local` と `DCC_DOCKERFILE=<repo>/local/Dockerfile` を export し、
  `FROM` 先の base を先に作る（`dcc build` を一度実行するか、次を実行する）:
  `docker compose -f <repo>/docker-compose.yml -f <repo>/docker-compose.base-image.yml build agent`
- `postCreateCommand` は `dcc` が使うものと同じスクリプト。`~/.claude.json` のコピー、
  `safe.directory` の登録、`claude update`、`gpg` 有効時の検証用 keyring 構築を行う

起動は通常どおり `devcontainer up --workspace-folder .` / `devcontainer exec --workspace-folder . claude`、
または VS Code の "Reopen in Container"。

## モジュールごとの補足

| モジュール | devcontainer 側で必要なこと |
|---|---|
| `ssh` / `gh` | `dockerComposeFile` に overlay を足すだけ |
| `claude` | overlay を足すとホストの `~/.claude` を共有する。足さない場合は base が external volume `dcc-claude-home` を要求するので、先に `docker volume create dcc-claude-home` を一度実行する（`dcc` は自動で作る） |
| `aws` | 同上。`initializeCommand` に `aws` を書くと `~/.aws/config` / `~/.aws/login/cache` の存在を事前チェックする。`AWS_PROFILE` / `AWS_REGION` はシェルの環境変数から compose が拾う |
| `gpg` | `initializeCommand` に `gpg` を書く（**必須**。ホストの公開鍵 / 署名鍵情報を `capabilities/gpg/gnupg-host` へ export する。無いと sidecar は署名鍵を持たない）。up 後にターミナルから `<repo>/capabilities/gpg/warm.sh` を一度実行してパスフレーズを sidecar にキャッシュする（下記） |

### `gpg` のパスフレーズ warm

署名鍵のパスフレーズは `gpg-signer` sidecar 内の gpg-agent にキャッシュされ、sidecar の寿命いっぱい
残る（[gpg.md](gpg.md)）。入力は sidecar 内の pinentry で行うため対話ターミナルが要り、
`initializeCommand`（sidecar 起動前）や `postCreateCommand`（本体コンテナ内）からは行えない。
`dcc` は claude 起動直前に自動で行うが、devcontainer からは up 後にホストのターミナルで一度実行する:

```bash
cd <workspace>
~/.config/dcc/capabilities/gpg/warm.sh          # カレントのワークスペースから sidecar を探す
~/.config/dcc/capabilities/gpg/warm.sh -p <project>  # compose プロジェクト名で指定
```

未 warm のまま `git commit -S` すると、wrapper が sidecar の 503 を表示して失敗する（hang はしない）。
`dcc stop` 相当（`shutdownAction: stopCompose` で VS Code を閉じた場合など）で sidecar が止まると
キャッシュは消えるので、次の起動後に再度実行する。

## `dcc` との共存

- `dcc list` / `dcc inspect` / `dcc stop --all` / `dcc clear --all` は devcontainer CLI が付ける
  `devcontainer.local_folder` ラベルも見るので、devcontainer で作ったコンテナも一覧・停止・削除の
  対象になる
- 同じワークスペースを `dcc` と devcontainer の両方で開くと compose プロジェクトが 2 つできる
  （`dcc` は `dcc-<basename>-<hash>`、devcontainer CLI は `<basename>_devcontainer`）。named volume
  もプロジェクトごとに分かれる
- `dcc` の credential drift 検出と、フラグ無し `dcc` が既存コンテナの選択を引き継ぐ挙動（どちらも `dcc.credentials` ラベル）は `dcc` が作ったコンテナだけが対象
