# GitHub CLI (`gh`) と HTTPS git の認証

**モジュール名: `gh`** — `dcc --creds gh` を指定したときだけ有効になる（[credentials.md](credentials.md)）。

## 守るもの

| 実体 | 所在 | 性質 |
|---|---|---|
| ホストの `gh` の token | macOS Keychain | 個人アカウントの OAuth token。scope は広いことが多い |
| コンテナ用の refresh token | volume `dcc-gh-home`（`DCC_GH_HOME_VOLUME`）の `hosts.yml` | `dcc gh-login` で得る。access token を発行し直せる。1 回使うたびに新しいものに入れ替わる。**平文** |
| access token | gh-token sidecar が都度発行 → 本体（HTTP） | 数時間で失効する（expiring credentials のとき） |

## 境界

| 軸 | この設計 |
|---|---|
| できること | 本体は「sidecar が動いている間、`dcc gh-login` したアカウントの access token を取得する」ことだけができる。token の scope が上限 |
| 届く範囲 | 本体には `~/.config/gh` を bind しない。refresh token を含む gh の状態は非特権の `gh-token` sidecar にだけ volume で渡す。ホストの Keychain と `~/.config/gh` はどこにも渡さない |
| 鍵の渡し方 | **代行実行**。sidecar が `gh auth token` を実行し（必要なら gh が refresh する）、本体は access token だけを受け取る。本体の `gh` は wrapper が、git は credential helper が実行のたびに取り直し、本体には保存しない |

## 侵害時に漏れるもの

本体コンテナが乗っ取られた場合:

- 攻撃者が得られるのは「sidecar が動いている間、access token を取得する能力」まで。持ち出した access token は数時間で失効する
- refresh token は本体に無いので持ち出せない。ホストの token にも到達できない
- endpoint は共有 netns の `127.0.0.1` にしかないため、inner container・ホスト・他の compose project からは届かない
- 止めるには `dcc stop`、または GitHub の Settings → Applications で GitHub CLI の認可を revoke する

sidecar は自前の `server.py` しか動かさず、access log は method / path / status のみで token を含めない。

## なぜこの構成か

- **gh の expiring credentials（v2.103.0〜）を使う**: `gh auth login --expiring` は、数時間で失効する access token と、1 回使うたびに入れ替わる refresh token の組を発行する。access token が漏れても被害は失効までで止まる
- **本体で `--expiring` しない**: refresh token は access token を発行し直せるので、本体に置くと持ち出されたときに無期限 token と変わらない。aws / gpg と同じく sidecar が代行し、本体には失効する token だけを渡す
- **本体へは `GH_TOKEN` で渡し、毎回取り直す**: gh は `GH_TOKEN` / `GITHUB_TOKEN` を refresh しない。wrapper は実行のたびに sidecar から取得するので、失効の影響は 1 回の実行の中に収まる（gh 自身も「`gh auth token` の結果をキャッシュせず毎回呼べ」としている）
- **git は自前の credential helper**: `gh auth git-credential` は refresh token を持つ gh でしか動かない。本体の helper は sidecar から取った token を返すだけで、`store` は何もしない。キャッシュ helper を挟まないので、gh が推奨する git 2.46 の ephemeral 指定（本体の git は 2.39）が無くても古い token が残らない
- **状態は固定名の named volume で全ワークスペース共有**: refresh token は単回使用で、2 つのプロセスが同じものを使うと token 一式が revoke されうる。gh は `~/.config/gh/refresh.lock` の flock + reload で直列化するので、全 sidecar が同じファイルシステム上の同じ lock を見る必要がある。VM 内のローカル volume なら flock が確実に効く（macOS のホスト bind 越しのコンテナ間 flock は保証されない）。ホストのリポジトリ配下に平文の token も残らない
- **ログインはワークスペースから独立**: `dcc gh-login` は sidecar のイメージを `docker run` して volume に書くだけで、ワークスペースのコンテナにも Docker sidecar にも依存しない

## 仕組み

```
 agent (本体)                                       gh-token (sidecar, 非特権)
  /usr/local/bin/gh = gh-token-client.sh             python3 /server.py が 127.0.0.1:8082 で listen
   GH_TOKEN=<GET /token> exec /usr/bin/gh     ──►     GET /token
  git: credential.https://github.com.helper            └─ gh auth token --hostname $GH_HOST
   = gh-token-client.sh git-credential        ──►        （失効が近ければ refresh。refresh.lock で直列化）
                                                     volume dcc-gh-home → /home/gh/.config/gh (rw)
        └───────── netns 共有（両者とも network_mode: service:docker）─────────┘
```

| 対象 | 行き先 | モード |
|---|---|---|
| volume `dcc-gh-home`（`DCC_GH_HOME_VOLUME`） | sidecar `/home/gh/.config/gh` | rw |
| `<repo>/capabilities/gh/gh-token-client.sh` | 本体 `/usr/local/lib/dcc/gh-token-client.sh`、`/usr/local/bin/gh` | ro |
| access token | 本体（HTTP。環境変数 / ファイルには残さない） | — |

### セットアップ

ホストで一度だけ:

```bash
dcc gh-login                          # gh auth login --expiring を sidecar のイメージで実行
dcc gh-login --scopes read:packages   # 追加の scope が要るとき（引数は gh auth login にそのまま渡る）
```

device flow で表示された URL をホストのブラウザで開き、one-time code を入力する。最後に `gh auth status` が出るので、token が expiring になっているか（失効時刻が表示されるか）を確認する。
その後 `dcc --creds gh`（既存コンテナなら `dcc recreate --creds gh`）で起動する。コンテナ内では `gh auth status` / `gh api user`、`git ls-remote https://github.com/<repo>` で確認できる。

- 既定の scope は gh の OAuth app のもの（`repo` / `read:org` / `gist`）。classic scope なので fine-grained PAT より広い
- 組織が OAuth app を制限している場合は、GitHub CLI の利用を組織で承認する必要がある
- GitHub Enterprise は `DCC_GH_HOST` で指定する。GHES 3.23 未満は expiring に対応せず、無期限 token にフォールバックする（`gh auth status` で分かる）
- ログインし直すときも `dcc gh-login`。動いている sidecar は次のリクエストから新しい token を返す

### 詳細

- `GET /token` は `gh auth token --hostname $GH_HOST` の出力を `text/plain` で返す。失敗（未ログイン、refresh token の失効など）は 503 で、本文は対処（`dcc gh-login`）だけ。gh の stderr は sidecar のログにだけ出す。`/token` 以外は 404
- sidecar の gh は `GH_TOKEN` / `GH_DEBUG` などを落とした環境で動かす（`GH_TOKEN` があると gh は refresh しない。`GH_DEBUG` は使わない）
- 本体の wrapper は `gh auth login|logout|refresh|switch|setup-git` を拒否し、`dcc gh-login` を案内する。sidecar に届かないときは警告して token 無しで `/usr/bin/gh` を実行する
- credential helper は postCreate が `git config --system credential.https://<host>.helper` に登録する（`~/.gitconfig` は ro）。ホストの `~/.gitconfig` 由来の helper（`osxkeychain` 等）より先に問い合わせられ、token を返したところで git は次の helper に進まない
- sidecar の gh は `GH_VERSION`（`capabilities/gh/Dockerfile` の ARG）で版を固定する。expiring には 2.103.0 以上が要る
- 旧方式（`capabilities/gh/data/` を本体に rw bind）の `hosts.yml` は使われなくなった。中の token は GitHub 側で revoke し、ディレクトリを消す

## 制約・既知の穴

- access token は本体内の全プロセスから読める。失効までは持ち出して使える
- 1 回の `gh` の実行が access token の失効をまたぐ（長い `gh run watch` など）と、途中で認証に失敗する
- refresh token の寿命は GitHub が公表していない。切れたら endpoint が 503 を返すので `dcc gh-login` し直す
- volume の `hosts.yml` に PAT（`gh-login` で token を貼り付けた場合を含む）や無期限 token が入っていれば、sidecar はそれをそのまま配る。短命にはならないが、本体に保存されない点は同じ
- `GH_HOST` は 1 つ。複数ホストを使い分けるなら `local/compose.yml` で sidecar を足す
- inner container からは endpoint が見えない。inner container に token を渡すには明示的に環境変数等で渡すしかない
- `dcc clear --volumes` でも `dcc-gh-home` は消えない（外部 volume）。消すときは `docker volume rm dcc-gh-home`
