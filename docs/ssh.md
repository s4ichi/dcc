# SSH 鍵

**モジュール名: `ssh`** — `dcc --creds ssh` を指定したときだけ有効になる（[credentials.md](credentials.md)）。

## 守るもの

| 実体 | 所在 | 性質 |
|---|---|---|
| ホストの `~/.ssh/` の秘密鍵 | ホスト | 個人の全アクセス（GitHub、サーバー等）に紐づく長期鍵 |
| ホストの `ssh-agent`（Keychain 連携） | ホスト | パスフレーズ入力なしで上記の鍵を使える状態 |
| コンテナ専用の秘密鍵 `id_ed25519` | `<repo>/capabilities/ssh/data/`（gitignore） | GitHub の必要なリポジトリだけに登録した鍵 |

## 境界

| 軸 | この設計 |
|---|---|
| できること | 本体は「コンテナ専用鍵で GitHub に SSH 接続する」ことだけができる。鍵に与えた権限（デプロイキー / 専用アカウント）の範囲が上限 |
| 届く範囲 | ホストの `~/.ssh` と `ssh-agent` は一切渡さない。コンテナ専用鍵の置き場を `~/.ssh` に ro で bind し、接続設定とホスト鍵は `/etc/ssh` に ro で注入する |
| 鍵の渡し方 | **平文の鍵をそのまま渡す**（ro bind）。渡す鍵をコンテナ専用にし、権限を絞ることで補う |

## 侵害時に漏れるもの

本体コンテナが乗っ取られた場合:

- コンテナ専用の秘密鍵は持ち出せる（ro でも読める）。漏れた場合の被害はその鍵に与えた権限の範囲で、GitHub 側で鍵を削除すれば止まる
- ホストの鍵と agent には到達できない
- inner container からは見えない（sidecar にこのディレクトリを渡していない）

## なぜこの構成か

- **ホストの `~/.ssh` を bind しない**: ホストの秘密鍵は個人の全アクセスに紐づく。コンテナ内の Claude Code に渡すには権限が大きすぎる
- **agent forwarding を使わない**: macOS の `ssh-agent`（Keychain 連携）の Unix socket は Docker VM の境界を越えられない。追加のセットアップが要り、常時動作の保証が無い
- **鍵はそのまま渡す**: 署名（gpg）や AWS と違い、SSH には「代行実行」の安価な形が無い。代わりに渡す鍵の権限を絞る
- **接続設定とホスト鍵は `/etc/ssh` に注入する**: GitHub のホスト鍵を `/etc/ssh/ssh_known_hosts` に固定すると初回接続の確認プロンプトが出ず、`~/.ssh/known_hosts` への書き込みも発生しない。TTY の無い Claude Code の Bash ツールから `git push` してもここで止まらない。書き込みが要らないので `~/.ssh` は ro でよい

## 仕組み

| ホスト側 | コンテナ側 | モード | 追跡 |
|---|---|---|---|
| `<repo>/capabilities/ssh/config`（`DCC_SSH_CONFIG`） | `/etc/ssh/ssh_config.d/github.conf` | ro | あり |
| `<repo>/capabilities/ssh/known_hosts`（`DCC_SSH_KNOWN_HOSTS`） | `/etc/ssh/ssh_known_hosts` | ro | あり |
| `<repo>/capabilities/ssh/data/`（`DCC_SSH_DIR`） | `/home/claude/.ssh/` | ro | なし（gitignore） |

- `config`: `Host github.com` に `User git` / `IdentityFile ~/.ssh/id_ed25519` / `IdentitiesOnly yes`。Debian の `/etc/ssh/ssh_config` が `Include /etc/ssh/ssh_config.d/*.conf` するので追加設定なしで効く
- `known_hosts`: GitHub のホスト鍵（`https://api.github.com/meta` の `ssh_keys`）
- `data/`: 秘密鍵 `id_ed25519`（と `.pub`）のみ。`~/.ssh/config` を置けば個人設定として system config より優先される（ssh は先に見つかった値を使う）

### セットアップ

ホスト上で、このリポジトリ（`<repo>`）をカレントにして行う。

1. コンテナ専用の鍵を作る（パスフレーズは空にする。下記「制約」）:
   ```bash
   mkdir -p capabilities/ssh/data
   ssh-keygen -t ed25519 -N '' -f capabilities/ssh/data/id_ed25519 -C "claude-devcontainer"
   chmod 700 capabilities/ssh/data; chmod 600 capabilities/ssh/data/id_ed25519   # bind 先でもホスト側のパーミッションが見える
   ```
2. GitHub に**デプロイキーまたは専用アカウントの鍵**として公開鍵（`id_ed25519.pub`）を登録する。書き込み権限は必要なリポジトリだけに絞る
3. `dcc --creds ssh`（既存コンテナがあれば `dcc recreate --creds ssh`）で起動し、コンテナ内で `ssh -T git@github.com` が通ることを確認する

鍵の名前を変える場合は `config` の `IdentityFile` を合わせる。`initialize.sh ssh` が `data/` の存在を事前に警告する。

### ホスト鍵の更新

GitHub がホスト鍵をローテーションした場合は `known_hosts` を再生成してコミットする:

```bash
curl -sS https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com \(.)"' > capabilities/ssh/known_hosts
ssh-keygen -lf capabilities/ssh/known_hosts   # 指紋を GitHub の公開情報と照合する
```

## 制約・既知の穴

- 秘密鍵は本体内の全プロセスから読める。鍵の権限で被害を限定する設計であり、鍵そのものは守れない
- パスフレーズ付き鍵は使えない。コンテナ内に `ssh-agent` の自動起動が無く、TTY の無い Bash ツールからは pinentry を出せない。パスフレーズ無しの鍵にするか、gpg の warm 相当の仕組みを足す必要がある（未実装）
- SSH 署名（`gpg.format = ssh`）は `user.signingkey` にこの鍵を指定すれば可能だが、warm の仕組みは GPG 前提
- inner container で SSH が必要な場合はワークスペース経由で明示的に渡すしかない
- `capabilities/ssh/data/` は gitignore 済みで、commit しない。`config` と `known_hosts` は追跡対象だが GitHub の公開情報しか含まない
