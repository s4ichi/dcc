# docs

Claude Code / Codex CLI 用コンテナ設定の仕様と、ホスト ⇔ コンテナ間で認証情報や設定をどう受け渡しているか
（境界の扱い）をまとめたもの。使い始め方はリポジトリ直下の [README.md](../README.md)。

読む順の目安: 仕組みを知りたいなら [architecture.md](architecture.md)、何が守られて何が守られないかを
知りたいなら [boundaries.md](boundaries.md) → 使うモジュールのページ。

## 全体

| ファイル | 内容 |
|---|---|
| [architecture.md](architecture.md) | 構成要素、生成フロー、compose プロジェクトの構造、ライフサイクル、CLI |
| [boundaries.md](boundaries.md) | ホストとの境界の総論。3 つの軸、設計原則、境界ごとの要約、マウント一覧 |
| [credentials.md](credentials.md) | credential モジュールの選択的付与。`--creds` の指定方法、drift の挙動、overlay の仕組み、モジュールの追加 |
| [customization.md](customization.md) | `DCC_*` 環境変数と `local/` による利用者ごとのカスタマイズ、ホスト側の前提 |
| [devcontainer.md](devcontainer.md) | `dcc` を使わず devcontainer CLI / VS Code から compose ファイルを参照して使う方法 |

## 境界ごとのページ

| ファイル | 対象 | モジュール | ホスト側の実体 | コンテナ側 |
|---|---|---|---|---|
| [gpg.md](gpg.md) | GPG 署名鍵・公開鍵・パスフレーズ | `gpg` | `~/.gnupg/private-keys-v1.d` + export した公開鍵 | `gpg-signer` sidecar（本体は署名 API に委譲） |
| [aws.md](aws.md) | AWS 認証情報 | `aws` | `~/.aws/config` + `~/.aws/login/cache`（sidecar に ro） | 一時 credential を `AWS_CONTAINER_CREDENTIALS_FULL_URI` で取得 |
| [ssh.md](ssh.md) | SSH 鍵・known_hosts | `ssh` | `<repo>/capabilities/ssh/data/`（gitignore） | `~/.ssh` (ro) |
| [github.md](github.md) | GitHub CLI (`gh`) の認証 | `gh` | `<repo>/capabilities/gh/data/`（gitignore） | `~/.config/gh` (rw) |
| [git.md](git.md) | gitconfig、safe.directory、署名設定 | 常時 | `~/.gitconfig` | `~/.gitconfig` (ro) + system gitconfig |
| [claude-code.md](claude-code.md) | Claude Code の設定・セッション・プラグイン | `claude` | `~/.claude`、`~/.claude.json` | 有効時 `~/.claude` (rw)。無効時は全ワークスペース共有の空の volume |
| [codex.md](codex.md) | Codex CLI の設定・認証・セッション、Codex 自身の sandbox の扱い | `codex` | `~/.codex`（`auth.json` = token を含む） | 有効時 `~/.codex` (rw)。無効時は全ワークスペース共有の空の volume |
| [mcp.md](mcp.md) | Claude Code の MCP サーバーの設定と OAuth token | 常時（`claude` に依存） | 設定は `~/.claude.json` / `.mcp.json`。token は macOS Keychain（**渡さない**） | コンテナ内で認証して `~/.claude/.credentials.json` に保存 |
| [docker.md](docker.md) | Docker（rootless sidecar）と TLS 証明書 | 常時 | なし（ホストの Docker は使わない） | `DOCKER_HOST=tcp://docker:2376` + `/certs` (ro) |

「モジュール」列の名前を `dcc --creds <name>` で指定したときだけコンテナに渡る。「常時」は選択に関係なくマウントされる。

### 各ページの構成

境界ごとのページは同じ見出しで書く。本体コンテナはエージェント（Claude Code / Codex）が任意コードを実行しうる場所として、
**侵害されうる前提**で境界を説明する（[boundaries.md](boundaries.md)）。

| 節 | 書くこと |
|---|---|
| 守るもの | 漏れると困る実体と、その所在・性質 |
| 境界 | 3 つの軸で 1 行ずつ。できること（許す操作）/ 届く範囲（到達できるファイル・リソース）/ 鍵の渡し方（代行実行、ストア経由、平文、直読みのどれか） |
| 侵害時に漏れるもの | 本体コンテナが乗っ取られた場合に、攻撃者が得られる能力の上限 |
| なぜこの構成か | 代替案と、選ばなかった理由 |
| 仕組み | マウント表、処理の流れ、セットアップ手順 |
| 制約・既知の穴 | 意図的に許容しているリスクと未対応事項 |

## 用語

| 用語 | 意味 |
|---|---|
| ホスト | `dcc` を実行する開発者のマシン |
| ワークスペース | コンテナに渡すプロジェクトディレクトリ。コンテナ内では `/workspaces/<basename>` |
| 本体（本体コンテナ） | compose の `agent` サービス。エージェントが動く非特権のコンテナ |
| エージェント | 本体で動かす CLI。`claude`（Claude Code）か `codex`（Codex CLI）。両方とも同じイメージに入っており、`--agent` で起動のたびに選ぶ |
| Docker sidecar | compose の `docker` サービス。rootless の dockerd を提供する。`privileged` はここだけ |
| モジュール sidecar | credential モジュールが追加する非特権の sidecar（`gpg-signer` / `aws-credentials`） |
| inner container | 本体から `docker run` して Docker sidecar の中で動くコンテナ |
| credential モジュール | `--creds` で選ぶ単位。実体は compose overlay `capabilities/<name>/compose.yml` |
| base / overlay | base は常に使う `docker-compose.yml`。overlay は `-f` で後ろに重ねる compose 断片 |
| drift | 既存コンテナに焼き込まれた選択と、今回の要求との不一致 |
| warm | 署名鍵のパスフレーズを `gpg-signer` 内の gpg-agent にキャッシュさせること |
| `<repo>` | このリポジトリの clone 先（`DCC_CONFIG_DIR`。既定は `~/.config/dcc`） |

## 前提

- ホストは macOS を主に想定している（macOS の gpg-agent / ssh-agent / Keychain の制約が設計理由の一部になっている）。
  Linux ホストでも同じ設計で動く（[customization.md](customization.md) の「ホスト OS 依存」）
- ホストに `docker`（compose plugin 込み）がインストールされていること。`devcontainer` CLI は `dcc` には不要（devcontainer から使う場合のみ。[devcontainer.md](devcontainer.md)）
- 本体コンテナのユーザーは `agent`（uid 1000）。ホストの uid とは一致しない前提で設計している（[git.md](git.md) の safe.directory を参照）
