# GPG（コミット署名）

**モジュール名: `gpg`** — `dcc --creds gpg` を指定したときだけ有効になる（[credentials.md](credentials.md)）。

## 守るもの

| 実体 | 所在 | 性質 |
|---|---|---|
| `~/.gnupg/private-keys-v1.d/*.key` | ホスト | 秘密鍵（パスフレーズで暗号化済み）。署名鍵以外も含む |
| 署名鍵のパスフレーズ | ホストには保存されない。人が入力する | これが無いと秘密鍵は使えない |
| gpg-agent のキャッシュ | ホスト / sidecar の agent | パスフレーズ入力なしで署名できる状態 |
| 公開鍵・ownertrust | ホスト | 秘密ではないが、名前とメールアドレスを含む |

## 境界

| 軸 | この設計 |
|---|---|
| できること | 本体は「commit / tag オブジェクトに、固定された 1 本の署名鍵で署名を依頼する」ことだけができる。任意データへの署名、鍵の選択、復号はできない |
| 届く範囲 | 本体には秘密鍵も gpg-agent も pinentry も無い。`~/.gnupg/private-keys-v1.d` は `gpg-signer` sidecar にだけ ro で渡し、sidecar はその中から署名鍵の keygrip ファイルだけをコンテナローカルへコピーする。本体にあるのは公開鍵（検証用）と wrapper だけ |
| 鍵の渡し方 | **代行実行**。本体の git は `gpg.program` に登録された wrapper 経由で sidecar の署名 API（`127.0.0.1:8081`）を呼ぶ。パスフレーズは sidecar 内の pinentry で人が入力し、sidecar 内の gpg-agent にキャッシュされる |

## 侵害時に漏れるもの

本体コンテナが乗っ取られた場合:

- 攻撃者が得られるのは「commit / tag オブジェクトに署名させる能力」まで。署名 API は payload が git オブジェクト（先頭行が `tree <sha>` / `object <sha>`）でなければ 403 を返す
- 秘密鍵の材料もパスフレーズも本体に無いので持ち出せない。sidecar のキャッシュにも本体からは触れない
- 署名の依頼には都度確認が無い。本体から不正なコミットに署名させることは防げない（委譲では守れない部分）
- sidecar は自前の `server.py` しか動かさない

## なぜこの構成か

- **ホストの `~/.gnupg` を本体に bind しない**: macOS の gpg-agent（pinentry-mac）の Unix socket は Docker VM の境界を越えない。ホストの gpg 2.4 / 2.5 は `keyboxd` を使い、コンテナの gpg 2.2（Debian bookworm）は公開鍵ストアを読めない。書き込めばホスト側を壊しうる
- **署名処理ごと sidecar に分離する**: 秘密鍵を本体に置くと、Claude が動く場所に鍵材料とパスフレーズキャッシュが同居する。sidecar なら本体から見えるのは HTTP の endpoint だけ
- **公開鍵は armor export で渡す**: keyboxd 非互換のため。ホスト側の前処理でファイルに書き出し、sidecar と本体が import する
- **署名鍵の情報は環境変数ではなくファイルで渡す**: devcontainer 経由では `initializeCommand` の結果を compose の環境変数に渡せない。ファイルなら `dcc` と devcontainer のどちらからでも同じ経路で届く（[devcontainer.md](devcontainer.md)）
- **git 側の契約に合わせる**: git は署名を `<gpg.program> --status-fd=2 -bsau <key>`（stdin にオブジェクト、stdout に armor detached 署名、fd2 に `[GNUPG:] SIG_CREATED`）で呼ぶ。wrapper は sidecar 内の gpg が出した status を捏造せず verbatim に fd2 へ中継する。検証（`--verify`）は本体の素の gpg に委譲する（公開鍵だけでできる）

## 仕組み

| ホスト側 | マウント先 | モード | 用途 |
|---|---|---|---|
| `~/.gnupg/private-keys-v1.d/`（`DCC_GNUPG_DIR`） | `gpg-signer` の `/host-keys/` | ro | 署名鍵の keygrip ファイルのコピー元（**本体にはマウントしない**） |
| `<repo>/capabilities/gpg/gnupg-host/`（`DCC_GPG_EXPORT_DIR`） | `gpg-signer` の `/gnupg-host/`、本体の `~/.gnupg-host/` | ro | ホスト側の前処理が export した `pubkeys.asc` / `ownertrust.txt` / `keygrips.txt` / `signing-key.txt` |
| `<repo>/capabilities/gpg/gpg-sign-client.sh` | 本体の `/usr/local/lib/dcc/gpg-sign-client.sh` | ro | `gpg.program` wrapper |
| （なし） | `gpg-signer` の `/root/.gnupg/` | ローカル | entrypoint が構築する keyring |
| （なし） | 本体の `~/.gnupg/` | ローカル | postCreate が構築する**検証専用** keyring |

### セットアップ

ホストで署名が通る状態（`gpg` があり、`~/.gitconfig` に `user.signingkey` と、必要なら `commit.gpgsign = true`）になっていれば、
追加の準備は要らない。`dcc --creds gpg` で起動すると、claude の起動直前に sidecar 内の pinentry がパスフレーズを一度だけ聞く。
署名鍵を `~/.gitconfig` 以外で指定するなら `DCC_GPG_SIGNING_KEY`（[customization.md](customization.md)）。
以下は内部の流れ。

### 1. ホスト側（`capabilities/gpg/export-host-keys.sh`）

`lifecycle_hooks/initialize.sh gpg` から呼ばれる（`dcc up` は `gpg` が有効なときだけ渡す。devcontainer では `initializeCommand` に書く）。`gnupg-host/` に書き出す:

- `pubkeys.asc` / `ownertrust.txt`: 秘密鍵を持つ全鍵の公開鍵（検証にも使うため全鍵）
- `keygrips.txt`: 署名鍵（`DCC_GPG_SIGNING_KEY`、無ければ `git config user.signingkey`。末尾 `!` は除去）の keygrip 一覧。sidecar はこれに列挙された鍵**だけ**をコピーする
- `signing-key.txt`: 署名鍵の primary fingerprint

gpg が無い / 秘密鍵が無い / 署名鍵未設定なら警告だけ出してスキップする（署名なしで使える）。

### 2. sidecar 側（`capabilities/gpg/entrypoint.sh`）

起動時にコンテナローカルの `/root/.gnupg` を構築する: `gpg-agent.conf`（`pinentry-curses`、cache TTL 400 日）→ 公開鍵と ownertrust の import → `keygrips.txt` の keygrip ファイルだけを `/host-keys` からコピー（600）→ `signing-key.txt` の値を `/run/signing-key` に固定して `server.py` を exec。

### 3. 本体側（postCreate）

`postCreate-root.sh`（root）が wrapper の mount があるときだけ `git config --system gpg.program <wrapper>` を登録し、`postCreate.sh`（コンテナユーザー）の `setup_gnupg` が `~/.gnupg-host/pubkeys.asc` があるときだけ公開鍵と ownertrust をコンテナローカル keyring へ import する。主経路は compose が gpg overlay で設定する環境変数 `GIT_CONFIG_COUNT=1` / `GIT_CONFIG_KEY_0=gpg.program` / `GIT_CONFIG_VALUE_0=<wrapper>`（git 設定の最優先レイヤ）で、ホストの `~/.gitconfig` が `gpg.program` を設定していても上から固定する。system 登録は env が剥がれた場合（`env -i` 経由のツール等）の保険。

### 4. パスフレーズの warm（`capabilities/gpg/warm.sh`）

ホストの対話ターミナルで実行し、`docker exec -it <gpg-signer> gpg-warm.sh` で sidecar 内の pinentry を通す。未キャッシュなら pinentry-curses が一度だけ出る。sidecar は `-p <project>` か、ワークスペースを持つ本体コンテナのラベル（`dcc.workspace` / `devcontainer.local_folder`）から探す。`dcc` / `dcc exec` は claude 起動直前、**`gpg` が有効で stdin/stdout が TTY のときだけ**自動で呼ぶ。devcontainer からは up 後に手動で一度実行する。

### 5. 署名時

```
git commit -S
 └─ gpg.program = gpg-sign-client.sh --status-fd=2 -bsau <key>   # <key> は使わない
     └─ POST http://127.0.0.1:8081/sign  (payload = コミットオブジェクト)
         └─ sidecar: 検証 (tree/object で始まるか) → gpg --pinentry-mode error -bsau $DCC_GPG_SIGNING_KEY
     ◄─ {"signature": <armor>, "status": <gpg の --status-fd 出力>}
 ◄─ stdout: signature / fd2: status (SIG_CREATED)
```

`--pinentry-mode error` により、パスフレーズ未キャッシュなら hang せず 503 を返し、wrapper がエラーを表示して `git commit` はきれいに失敗する。

署名鍵はホスト側の export 時に解決され、sidecar 起動時に固定される。鍵を変えたら `dcc recreate`（`dcc` は実行中 sidecar の `/run/signing-key` と export 結果を比較し、違えば警告する）。`commit.gpgsign = true` はホストの `~/.gitconfig*`（[git.md](git.md)）に従う。

## 制約・既知の穴

- 署名の依頼は本体から自由にできる。都度確認したいなら sidecar の gpg-agent の TTL を短くする（`entrypoint.sh`）か、pinentry 確認を挟む拡張が必要
- sidecar が再起動する（`dcc stop` / `recreate`）とパスフレーズキャッシュは消える。次の `dcc` が再度 warm する。TTY なしで `dcc` を実行した場合（CI 等）は warm がスキップされ、署名付きコミットは失敗する
- devcontainer 経由では warm は自動化されない（`initializeCommand` は sidecar 起動前、`postCreateCommand` は本体内で走る）。up 後にホストから `warm.sh` を実行する
- 本体には秘密鍵が無いので、git 以外の `gpg --sign` / `--decrypt` はコンテナ内では使えない（設計どおり）
- ホストで鍵を追加・変更した場合、export は `dcc up` で更新されるが sidecar の keyring は起動時構築なので `dcc recreate` が必要
- `gnupg-host/` は gitignore 済み。`pubkeys.asc` は公開鍵、`keygrips.txt` は鍵の識別子で、名前・メールアドレスを含む。gpg-agent の TTL（400 日）はポリシーによっては短くする
- 署名済み push（`push.gpgSign`）は未対応（payload の形式検証で弾く）
