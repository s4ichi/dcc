# MCP サーバー

モジュール選択に関係なく使えるが、`~/.claude` / `~/.claude.json`（[claude-code.md](claude-code.md)）とワークスペースの上に成り立つので、`claude` モジュールの有無で「ホストの設定が見えるか」「token がどこに残るか」が変わる。以下で「共有時」は `claude` モジュール有効（ホストの `~/.claude` を rw 共有）、「非共有時」は無効（全ワークスペース共有の volume `dcc-claude-home`）を指す。

MCP サーバーは「どのサーバーに繋ぐか（設定）」と「そのサーバーへの認証情報（OAuth token）」を別の場所に持ち、コンテナへの渡り方が違う。

## 守るもの

| 実体 | 所在 | 性質 |
|---|---|---|
| ホストの Claude Code の OAuth token（本体 `claudeAiOauth` と MCP `mcpOAuth`） | macOS Keychain（item `Claude Code-credentials`） | 1 つの blob にすべての token が入っている |
| コンテナで取得した OAuth token | `~/.claude/.credentials.json`（mode 600） | 平文。共有時はホストのディスクに、非共有時は volume に置かれる |
| MCP サーバーの設定 | `~/.claude.json`（user / local scope）、`<workspace>/.mcp.json`（project scope） | `headers` や `env` に API key を直書きすると秘密になる |

## 境界

| 軸 | この設計 |
|---|---|
| できること | コンテナ内の Claude Code は、ワークスペースの `.mcp.json`（project scope）と、共有時はホストで設定済み（user scope）のサーバーを使える。remote サーバーの認証はコンテナ内で行う。stdio サーバーはコンテナ内に実行コマンドがあるものだけ |
| 届く範囲 | 設定はコピー（user。共有時のみ）/ bind（project）で渡る。ホストの Keychain は渡さない。stdio サーバーが触れるのはコンテナ内と credential モジュールで渡したものだけ |
| 鍵の渡し方 | **コンテナ内で認証して取得する**。ホストの token を橋渡しせず、コンテナ用に別系統の token を持つ。取得した token は `~/.claude/.credentials.json` に残り、recreate とワークスペースを跨いで再利用される |

## 侵害時に漏れるもの

本体コンテナが乗っ取られた場合:

- コンテナで取得した MCP の token（と Claude Code 本体の token）は `~/.claude/.credentials.json` から持ち出せる。`claude mcp logout <name>` / 各 IdP 側の失効で止める
- ホストの Keychain の token には到達できない
- `.mcp.json` に直書きした API key は読める（`${VAR}` 経由にする）

## なぜこの構成か

- **Keychain を渡さない**: コンテナは Linux で Keychain が無く、Claude Code にも Keychain の中身を export する手段や macOS 側でファイル保存へ切り替える設定が無い。橋渡しするには `security` コマンドでホストの blob を取り出してコンテナへ書き込む独自処理が要り、ホストの全 token（本体のログインを含む）をまとめて渡すことになる。ホストとコンテナで token を別系統にする方が境界として素直で、コンテナ側は独立に失効できる
- **認証は 1 回で済む**: `~/.claude` は共有時はホストの bind、非共有時は固定名の external volume なので、どちらでもコンテナで取った token は `dcc recreate` / `clear` を跨いで残り、全ワークスペースで共有される
- **callback ポートを公開しない**: 公開すればブラウザだけで認証が完了するが、`claude` サービスは netns 共有のため `ports` を書けず、sidecar 側で公開するとホストにポートが開く。「ホストへ公開しない」方針（[docker.md](docker.md)）を優先し、リダイレクト URL の貼り付けで済ませる

## 仕組み

| 対象 | ホスト側の実体 | コンテナ側 | 渡り方 |
|---|---|---|---|
| user scope の設定 | `~/.claude.json` の `mcpServers` | `~/.claude.json`（ローカルコピー） | 共有時のみ。作成時点のスナップショット |
| local scope の設定 | `~/.claude.json` の `projects.<ホストの絶対パス>.mcpServers` | 同上 | コピーはされるが**参照されない**（キーがホストのパス） |
| project scope の設定 | `<workspace>/.mcp.json` | `/workspaces/<name>/.mcp.json` | ワークスペース bind でそのまま |
| `.mcp.json` の承認状態 | `<workspace>/.claude/settings.local.json` | 同上 | 同上 |
| OAuth token（ホスト） | macOS Keychain | なし | **渡さない** |
| OAuth token（コンテナ） | `~/.claude/.credentials.json` の `mcpOAuth` | 同じファイル | コンテナ内で認証して取得 |

ホストで認証済みでも**コンテナの Claude Code からは未認証に見えるのが正常**で、`/mcp` に `needs authentication` と出る。Claude Code 本体のログイン（`claudeAiOauth`）も同じ扱いで、初回だけコンテナ内で `/login` する。

### remote サーバー（`http` / `sse`）の認証手順

コンテナにはブラウザが無く、`localhost` のポートはホストに公開されていないので、OAuth の callback は**ブラウザ側で失敗させて、リダイレクト URL を手で貼り付ける**。

1. `dcc` で起動し、`/mcp` → 対象サーバー → `Authenticate`。または `claude mcp login <name>`（`--no-browser` で URL 表示のみ）
2. Claude Code が `http://localhost:<port>/callback` を listen し、認可 URL を表示する
3. その URL を**ホストのブラウザ**で開き、IdP にログインする
4. IdP が `http://localhost:<port>/callback?code=...&state=...` にリダイレクトする。ホストの `localhost` では誰も listen していないので**接続エラーになる。これは想定どおり**
5. アドレスバーの URL（`?code=...&state=...` を含む全体）をコピーし、Claude Code の `Or paste the redirect URL here:` に貼る

以降は refresh token で自動更新される。失敗したら `/mcp` に `needs authentication` と出るので同じ手順で再認証する。token を消すには `claude mcp logout <name>`。callback のポートは `MCP_OAUTH_CALLBACK_PORT` で固定できる（IdP に redirect URI を登録する必要がある場合）。

`headers` に `${VAR}` で API key を渡す構成なら、その環境変数を**コンテナ内**に用意する（`DCC_CONTAINER_ENV_<NAME>`、`local/compose.yml` の `services.claude.environment`、または `~/.claude/settings.json` の `env`。最後のものは共有時はホストにも効く。[customization.md](customization.md)）。

### スコープごとの扱い

- **user scope**: 共有時は、ホストで設定済みのサーバーがそのまま見える（非共有時は `~/.claude.json` を渡さないので見えない。コンテナ内で追加する）。ホスト側で後から `claude mcp add --scope user` しても既存コンテナには反映されない（`dcc recreate`）。コンテナ内で追加したものはホストに戻らず、recreate で消える
- **local scope**: キーがワークスペースのホスト側絶対パス（`/Users/<user>/src/foo`）で、コンテナ内は `/workspaces/foo` なので一致せず、ホストで追加したサーバーは見えない。`HOST_HOME → $HOME` の symlink はホーム直下の解決用で、ワークスペースのパスは救えない。コンテナ内で `claude mcp add`（既定 = local）したものも recreate で消える。永続化したいなら project scope
- **project scope**: ワークスペースは同一 bind なのでホストとコンテナで同じファイル。コンテナ内で `claude mcp add --scope project` すればホストにも反映される。初回利用時の承認（`enabledMcpjsonServers` 等）は `<workspace>/.claude/settings.local.json` に書かれ、これも共有される。やり直しは `claude mcp reset-project-choices`。`.mcp.json` の `command` / `args` / `env` / `url` / `headers` では `${VAR}` / `${VAR:-default}` が展開される
- **一時的な指定**: `dcc exec -- --mcp-config <file>`（`--strict-mcp-config` で他を無視）

### stdio サーバー

- 実行コマンドが**コンテナ内**に必要。イメージには `uvx` / `python3` / `docker` / `go` はあるが、**`node` / `npx` は入っていない**。`npx -y @xxx/mcp-server` 型は `/mcp` に `failed` と出る。使うなら `local/Dockerfile` で Node.js を足す（[customization.md](customization.md)）
- `docker run -i ...` 型は sidecar の rootless dockerd で動く（[docker.md](docker.md)）。`-v` で bind できるのはワークスペース配下だけ。inner container から親 netns の `127.0.0.1` には届かない。cgroup のリソース制限は無視される
- ホストのファイルやソケット（`~/.aws`、`/var/run/docker.sock` 等）に依存するサーバーは動かない。credential モジュールで渡しているものだけが使える

### ホストへの影響

| コンテナ内の操作 | ホストへの反映 |
|---|---|
| remote サーバーの OAuth 認証 / `claude mcp logout` | 共有時は `~/.claude/.credentials.json` に書かれる / 消える（macOS のホストの Claude Code は参照しない）。非共有時はされない |
| `claude mcp add --scope user` / local | されない（`~/.claude.json` はコンテナローカル） |
| `claude mcp add --scope project`、`.mcp.json` の承認 | **される**（ワークスペース上） |

## 制約・既知の穴

- コンテナで取った token が平文で残る（共有時はホストの `~/.claude/.credentials.json`、非共有時は volume `dcc-claude-home`）。不要になったらコンテナ内で `claude mcp logout <name>` する
- Keychain の橋渡しは今後も対応しない（意図的）
- コンテナ内で user / local scope に追加した設定は recreate で消える（`~/.claude.json` がコンテナローカルのため）。project scope で回避する
- remote サーバーへの通信は sidecar と共有する netns から外に出る。ホストのプロキシや VPN 依存の到達性は Docker ランタイム次第
- `node` が無いのは意図的（イメージを小さく保つ）
- `.mcp.json` をワークスペースに commit する場合、`url` / `headers` に token や内部ホスト名を直書きしない
