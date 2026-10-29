# git 設定

常時マウント（モジュール選択に関係なく渡る）。

## 守るもの

| 実体 | 所在 | 性質 |
|---|---|---|
| `~/.gitconfig`（と include 先） | ホスト | identity（`user.name` / `user.email`）、署名設定、alias。書き換えられるとホスト側の git の挙動が変わる |
| ホストの credential helper（`osxkeychain` 等） | ホスト | Keychain の HTTPS 認証情報 |

## 境界

| 軸 | この設計 |
|---|---|
| できること | 本体の git はホストの identity と設定で動く。global 設定の変更はできない（ro）。コンテナ固有の設定は system（`/etc/gitconfig`）にだけ書ける |
| 届く範囲 | `~/.gitconfig` を ro で bind する。include 先の個人ファイルは base では渡さない。credential helper はホスト依存のまま（コンテナには無い） |
| 鍵の渡し方 | この境界では鍵を渡さない。署名は [gpg.md](gpg.md)、push の認証は [ssh.md](ssh.md) / [github.md](github.md) に委ねる |

## 侵害時に漏れるもの

本体コンテナが乗っ取られた場合:

- `~/.gitconfig` の内容（identity、alias、include のパス）は読める。秘密情報は通常含まれない
- ホストの gitconfig を書き換えることはできない（ro）。`git config --global` はコンテナ内で失敗する
- 署名や push の権限は各モジュールの境界に従う

## なぜこの構成か

- **ro で bind**: 本体の git がホストと同じ identity で動くのが目的で、書き戻す必要は無い。rw だと Claude が alias や hook のパスを書き換えてホストに影響しうる
- **include 先を base で渡さない**: `~/.gitconfig.local` のような分割は個人環境依存で、無いと bind が失敗する。git は存在しない include を無視するので、渡さなくても壊れない。必要なら `local/compose.yml` で bind する（[customization.md](customization.md)）
- **コンテナ固有の設定は system に書く**: `~/.gitconfig` が ro なので、`safe.directory` や `gpg.program` の保険は `/etc/gitconfig`（コンテナローカル、ホストには戻らない）に書く。global は `safe.directory` を定義しない前提なので競合しない

## 仕組み

| ホスト側 | コンテナ側 | モード |
|---|---|---|
| `~/.gitconfig`（`DCC_GITCONFIG`） | `/home/agent/.gitconfig` | ro |

- **`safe.directory`**: bind されたワークスペースはホスト uid のまま見えるため、コンテナユーザーと一致しないと git が `dubious ownership` で全操作を拒否する。postCreate（root 側の `postCreate-root.sh`）が `git config --system --add safe.directory "$(pwd)"` を実行する（cwd はワークスペース。本体に sudo は無いので `dcc` が root で呼ぶ）
- **署名**: `user.signingkey` / `commit.gpgsign` はホストの `~/.gitconfig*` に従う。`gpg.program` だけは `gpg` モジュール有効時に compose の `GIT_CONFIG_*` 環境変数（最優先レイヤ）が sidecar への wrapper に固定するため、ホストの `~/.gitconfig` に何が書かれていても影響しない（[gpg.md](gpg.md)）
- **`GOPRIVATE`**: 必要なら `DCC_CONTAINER_ENV_GOPRIVATE` でコンテナに渡す（[customization.md](customization.md)）。private module の取得は git（SSH または HTTPS + token）で行う

## 制約・既知の穴

- ワークスペース配下の別リポジトリ（サブモジュール、monorepo 内の別 `.git`）は `safe.directory` に登録されない。コンテナ内では root に上がれないので system gitconfig は書けない。`git -c safe.directory=<path> …` で都度渡すか、ホストから `docker compose -p <project> exec --user root agent git config --system --add safe.directory '*'` で登録する（`<project>` は `dcc list`）
- ホストの `~/.gitconfig` に `credential.helper = osxkeychain` があると、コンテナ内で helper が見つからず警告が出る（致命的ではない）。HTTPS で push するなら `gh` モジュールを有効にする（postCreate が gh-token sidecar の短命 token を返す credential helper を system に登録し、こちらが先に問い合わせられる。[github.md](github.md)）
- SSH 署名（`gpg.format = ssh`）で `user.signingkey` がホストの `~/.ssh/...` を指している場合、コンテナには無い。[ssh.md](ssh.md) の鍵を指すよう system gitconfig で上書きする
- コンテナ専用の identity を使いたい場合は system gitconfig またはワークスペースの `.git/config` で上書きする
