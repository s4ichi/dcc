# Claude Code の設定・状態

**モジュール名: `claude`** — `dcc --creds claude` を指定したときだけホストの `~/.claude` を共有する（[credentials.md](credentials.md)）。
外した場合も Claude Code は動くが、ホストの設定・履歴・認証とは無関係な空の環境になる（下記）。

## 守るもの

| 実体 | 所在 | 性質 |
|---|---|---|
| `~/.claude/.credentials.json` | ホスト（Linux）/ コンテナ | Claude Code 本体と MCP サーバーの OAuth token。macOS のホストは Keychain を使うため、このファイルはコンテナ側が書く |
| `~/.claude/settings.json` | ホスト | permissions、hooks、env。**書き換えられると Claude Code 自身の権限が変わる** |
| `~/.claude/projects/` | ホスト | セッション履歴・メモリ（会話内容） |
| `~/.claude/plugins/`、`skills/`、`commands/`、`agents/` | ホスト | ユーザー定義 |
| `~/.claude.json` | ホスト | グローバル状態（onboarding、MCP サーバー設定、プロジェクト一覧、旧形式の認証情報を含むことがある） |

## 境界

| 軸 | モジュール有効（ホストと共有） | モジュール無効（空の volume） |
|---|---|---|
| できること | コンテナ内の Claude Code はホストと同じ設定・履歴・プラグインで動き、それらを**書き換えられる**。`~/.claude.json` だけはコンテナローカルのコピー | Claude Code の既定設定で動く。ホストのものは何も見えず、何も変えられない |
| 届く範囲 | `~/.claude` はホストと **rw で共有**。`~/.claude.json` は ro で渡し、postCreate がコピーする | ホストの `~/.claude` / `~/.claude.json` には到達しない。`~/.claude` は全ワークスペース共有の volume |
| 鍵の渡し方 | Claude Code 本体と MCP の認証はコンテナ内で行い、結果は共有された `.credentials.json` に**平文**で残る。ホストの Keychain は渡さない | 同じくコンテナ内で認証し、結果は volume に残る。ホストには一切戻らない |

## 侵害時に漏れるもの

本体コンテナが乗っ取られた場合:

- **モジュール有効**: `~/.claude` 配下はすべて読み書きできる。**この設定で最も大きな穴**で、次が起きうる:
  - `settings.json` を書き換えて permissions を緩める、hooks を仕込む（ホストの Claude Code にも効く）
  - `.credentials.json` の token（コンテナで取得したもの）を持ち出す
  - セッション履歴（会話内容）を読む
- **モジュール無効**: 持ち出せるのは volume 内の token（コンテナで取得したもの）とコンテナ側の履歴だけ。ホストには何も無い
- どちらでも、ホストの Keychain（ホストの Claude Code の token）には到達できない

## なぜこの構成か

- **既定は共有しない側に倒し、共有はモジュールで選ぶ**: 他の秘密情報と同じく「明示しない限り渡さない」に揃える。共有するかどうかは「ホストの Claude Code の権限をコンテナから変えられてよいか」の判断で、ワークスペースごとに変えられる
- **共有するときは rw**: 認証情報を `dcc recreate` やワークスペースをまたいで使い回すため（Keychain を渡さないので、コンテナ内で 1 回 `/login` すれば以後は共有された `.credentials.json` に残る）。設定・プラグイン・skills をホストと同じものにし、コンテナ側のセッション履歴もホストの `~/.claude` に残すため（ただし履歴のキーはパスなので、ホストとコンテナで `--resume` の一覧は別になる。下記「制約」）。Claude Code は起動時に `~/.claude` 配下へ頻繁に書くため ro では動かない
- **共有しないときは空の固定名 volume**: 設定を部分的に持ち込む仕組みは作らない。ホストの `~/.claude` を ro で bind すれば履歴と token も読めてしまうし、export して流し込むと `settings.json` の `env` に書いた秘密がコンテナに入る。何も持ち込まなければ境界が単純で、コンテナ側で必要な設定はコンテナ内で作ればよい
- **volume は固定名の external**: コンテナローカルだと `dcc recreate` で token が消えて毎回ログインになる。compose の volume はプロジェクト名でプレフィックスされるのでワークスペースごとにログインが要る。固定名（`dcc-claude-home`）の external volume にすると全ワークスペースで 1 回のログインで済み、`dcc clear --volumes` でも消えない
- **token だけ切り出さない**: `.credentials.json` を single-file bind すると EXDEV 問題を踏み、コピーだと refresh token の回転でホスト側が無効になる。認証はコンテナ側で独立に持つ
- **`~/.claude.json` は single-file bind しない**: Claude Code はこのファイルを atomic write（一時ファイルに書いて `rename`）する。single-file bind はマウントポイントなので `rename` が cross-device（EXDEV）で失敗し、設定が壊れる。ro で `.host` として渡し、postCreate がコピーする
- **Keychain を渡さない**: コンテナは Linux で Keychain が無く、Claude Code にも export する手段が無い。ホストとコンテナで token を別系統にする方が境界として素直で、コンテナ側は独立に失効できる（[mcp.md](mcp.md)）
- **ホストの絶対パスを symlink で解決する**: `plugins/installed_plugins.json` 等にはインストール時のホストの絶対パス（`/Users/<user>/...`）が書かれており、コンテナの `$HOME` では解決できない。postCreate が `HOST_HOME → $HOME` の symlink を作る。副作用はコンテナ内に `/Users/<user>` が現れることだけ

## 仕組み

### モジュール有効（`capabilities/claude/compose.yml`）

| ホスト側 | コンテナ側 | モード | 内容 |
|---|---|---|---|
| `~/.claude/`（`DCC_CLAUDE_DIR`） | `/home/agent/.claude/` | **rw** | セッション履歴、設定、プラグイン、skills、認証情報 |
| `~/.claude.json`（`DCC_CLAUDE_JSON`） | `/home/agent/.claude.json.host` | ro | postCreate が `~/.claude.json` へコピー |

base の volume と同じ target `/home/agent/.claude` を bind で上書きする（compose の同一 target は後勝ち）。

`~/.claude.json` はコンテナローカルで、作成時点のホストの状態（onboarding 完了、MCP サーバー設定、theme）を引き継ぐ。ホスト側を後から更新しても既存コンテナには反映されない（`dcc recreate`）。コンテナ内で追加した MCP サーバー（user / local スコープ）はホストに戻らない（[mcp.md](mcp.md)）。

### モジュール無効（base）

| ホスト側 | コンテナ側 | モード | 内容 |
|---|---|---|---|
| volume `dcc-claude-home`（`DCC_CLAUDE_HOME_VOLUME`。external、全ワークスペース共有） | `/home/agent/.claude/` | rw | 空で始まる。認証情報と履歴はここに残る |

`dcc up` が volume を無ければ作る（external なので compose は作らない。devcontainer からは `docker volume create dcc-claude-home`）。postCreate は volume の所有者を直すだけで、`~/.claude.json` も Claude Code が初回に作る（onboarding が出る）。

### `claude` 本体のインストール場所

Dockerfile でコンテナユーザーとして `install.sh` を実行し `~/.local/bin/claude` に置く。Claude Code の自動更新・`claude doctor` はこの場所を「管理インストール」として扱うため、root で `/usr/local/bin` に置くと "missing or broken" 警告が出る。

実体（`~/.local/share/claude/versions/<ver>`）と `~/.local/bin/claude` の symlink はどちらもイメージの焼き込み版が正で、volume にはしない。自動更新と postCreate の `claude update` の結果はコンテナ層に残り、`dcc recreate` で焼き込み版に戻る（そのとき postCreate がまた最新化する。差分は 1 回分のダウンロードだけ）。実体だけを named volume に置く構成は採らない。volume は初回しかシードされないため、イメージを rebuild して同梱版が上がると volume 外の symlink の指し先が volume に無くなり、`claude` が実行できなくなる（`executable file not found in $PATH`）。同じものをイメージと volume の 2 か所に持たないことでこの食い違いを無くしている。

### 個人ツール向けの環境変数

`dcc` は claude の起動時に固有の環境変数を足さない。コンテナ内に渡すなら `DCC_CONTAINER_ENV_<NAME>=value`、ホスト側の `dcc` プロセスに付けるなら `.env` に素の `NAME=value` を書く（[customization.md](customization.md)）。

## 制約・既知の穴

- **モジュール有効時は、ホストの Claude Code の認証・設定・履歴にコンテナ内の Claude Code が書き込める。** permissions を緩める、hooks を仕込む、といった改変は防げない。防ぎたいワークスペースでは無効にする
- モジュール無効時は個人のスキル・プラグイン・`settings.json` が無く、初回は onboarding と `/login` が要る（volume ごとに 1 回）。ホストの履歴は `--resume` に出ない。コンテナ用の設定を持ちたければ `local/compose.yml` で必要なファイルだけ bind する
- `projects/` のキーはワークスペースの絶対パス。ホストでは `/Users/<user>/src/foo`、コンテナでは `/workspaces/foo` になるため、共有していても同じワークスペースの履歴は別のキーに保存される（`--resume` で互いのセッションは一覧に出ない）
- `settings.json` 内のパス（hooks のコマンドパスなど）がホスト固有だとコンテナで動かない
- 同時にホストとコンテナで Claude Code を動かすと、共有時は `settings.json` 等の書き込みが競合しうる
- `~/.claude.json` にも認証情報（旧形式の `oauthAccount` 等）が含まれることがある。共有時は ro とはいえコンテナに渡っている
