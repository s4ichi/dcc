# GitHub CLI (`gh`) の認証

**モジュール名: `gh`** — `dcc --creds gh` を指定したときだけ有効になる（[credentials.md](credentials.md)）。

## 守るもの

| 実体 | 所在 | 性質 |
|---|---|---|
| ホストの `gh` の token | macOS Keychain | 個人アカウントの OAuth token。scope は広いことが多い |
| ホストの `~/.config/gh/` | ホスト | `gh` の設定。macOS では token を含まないことが多い |
| コンテナ専用の token | `<repo>/capabilities/gh/data/hosts.yml`（gitignore） | scope を絞った PAT または `gh auth login` の token。**平文** |

## 境界

| 軸 | この設計 |
|---|---|
| できること | 本体は「コンテナ専用 token の scope の範囲で GitHub API を叩く」ことができる。token の scope が上限 |
| 届く範囲 | ホストの Keychain と `~/.config/gh` は渡さない。コンテナ専用の `data/` を `~/.config/gh` に rw で bind する |
| 鍵の渡し方 | **平文の token をそのまま渡す**（rw bind）。渡す token をコンテナ専用にし、scope を絞ることで補う |

## 侵害時に漏れるもの

本体コンテナが乗っ取られた場合:

- コンテナ専用の token は持ち出せる（`hosts.yml` に平文）。被害は token の scope の範囲で、GitHub 側で revoke すれば止まる
- ホストの token には到達できない
- inner container からは見えない

## なぜこの構成か

- **ホストの `~/.config/gh` を bind しない**: macOS の `gh` は token を Keychain に保存しており、`hosts.yml` に token が無いことが多い。bind しても認証情報が渡らない。rw で共有するとコンテナ内の `gh auth login` / `refresh` がホストの設定を書き換え、ro にすると `gh` が状態を更新できない
- **コンテナ専用の token**: scope を絞れる。不要になったら GitHub 側で revoke するだけでよく、ホストには影響しない
- **平文で渡す**: `gh` は OS のキーリングが無ければ `hosts.yml` に平文で書く。コンテナにキーリングは無いので、それを前提にリポジトリ配下（gitignore）に置く。`gh` 自身が refresh 等で書き込むため rw

## 仕組み

| ホスト側 | コンテナ側 | モード |
|---|---|---|
| `<repo>/capabilities/gh/data/`（`DCC_GH_DIR`） | `/home/claude/.config/gh/` | rw |

| ファイル | 内容 | 秘密情報 |
|---|---|---|
| `data/hosts.yml` | ホスト（`github.com` 等）ごとの `user` / `oauth_token` / `git_protocol` | **あり** |
| `data/config.yml` | `gh` の一般設定（editor、aliases、prompt など） | なし |

### セットアップ

先にホスト上で置き場を作る（`<repo>` をカレントにして `mkdir -p capabilities/gh/data`）。`dcc --creds gh` で起動し、
コンテナ用の token を用意する。どちらでもよい:

- コンテナ内で `gh auth login` を実行する（対話。ブラウザはホストで開き、表示された one-time code を入力する。結果は `data/hosts.yml` に書かれる）
- Personal Access Token（fine-grained 推奨）を作り、`data/hosts.yml` を手で書く:
  ```yaml
  github.com:
    user: <login>
    oauth_token: <token>
    git_protocol: https
  ```

`data/config.yml` は無くても `gh` が生成する。`initialize.sh gh` が `data/` の存在を事前に警告する。

scope の目安:

| 用途 | 必要な scope |
|---|---|
| PR 作成・レビュー・issue 操作 | `repo`（classic）または fine-grained の Contents / Pull requests / Issues |
| `gh api` で org 情報 | `read:org` |
| GitHub Packages / private module の取得 | `read:packages` |

### git との連携

`git_protocol: https` の場合、`gh auth setup-git` は `~/.gitconfig`（ro）に書こうとして失敗する。代替:

- push / pull は SSH（[ssh.md](ssh.md)）を使う
- `GH_TOKEN` / `GITHUB_TOKEN` 環境変数を使う（`gh` はこれらを優先する）
- `git config --system credential.helper '!gh auth git-credential'` を postCreate に足す（未実装）

## 制約・既知の穴

- token は本体内の全プロセスから読める。scope で被害を限定する設計であり、token そのものは守れない
- `data/` はホストの `gh` から参照されない。revoke は GitHub 側で行い、`hosts.yml` から消す
- `capabilities/gh/data/` は gitignore 済みで、commit しない
