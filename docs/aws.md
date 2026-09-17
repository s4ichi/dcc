# AWS 認証情報

**モジュール名: `aws`** — `dcc --creds aws` を指定したときだけ有効になる（[credentials.md](credentials.md)）。

## 守るもの

| 実体 | 所在 | 性質 |
|---|---|---|
| `~/.aws/login/cache/` | ホスト | `aws login` のセッション。ここから一時 credential を発行できる |
| `~/.aws/credentials` | ホスト | 静的なアクセスキー。長期鍵 |
| `~/.aws/config` | ホスト | profile 定義。秘密ではないが、どのアカウントに何があるかが分かる |
| `~/.aws/sso/cache/`、`~/.aws/cli/cache/` | ホスト | SSO / CLI の token キャッシュ |

## 境界

| 軸 | この設計 |
|---|---|
| できること | 本体は「ホストで login 済みの 1 profile として、一時 credential を取得する」ことだけができる。profile の切り替えはできない（コンテナ作成時に固定） |
| 届く範囲 | 本体には `~/.aws` を一切マウントしない。`config` と `login/cache` は非特権の `aws-credentials` sidecar にだけ ro で渡す。`credentials`（長期鍵）と SSO / CLI キャッシュはどこにも渡さない |
| 鍵の渡し方 | **代行実行**。sidecar が `aws configure export-credentials` を実行し、本体は SDK の Container Credential Provider 経由（`AWS_CONTAINER_CREDENTIALS_FULL_URI`）で有効期限付きの一時 credential だけを受け取る。credential を取りに行くのは sidecar で、本体は結果を受け取るだけ |

## 侵害時に漏れるもの

本体コンテナ（Claude が任意コードを実行しうる場所）が乗っ取られた場合:

- 攻撃者が得られるのは「login セッションが有効な間、その profile の一時 credential を取得する能力」まで。一時 credential 自体は持ち出せるが、`Expiration` で失効する
- 長期鍵（`~/.aws/credentials`）と login セッションの token は本体に無いので持ち出せない
- endpoint は共有 netns の `127.0.0.1` にしかないため、inner container・ホスト・他の compose project からは到達できない
- ホストで `aws logout` するか login セッションが切れれば、それ以降の発行は止まる

sidecar は自前の `server.py` しか動かさず、access log は method / path / status のみで credential を含めない。

## なぜこの構成か

- **`~/.aws` を本体に bind しない**: ro でも `config` / `credentials` の全 profile が読める。長期鍵をコンテナに持ち込まないのが原則
- **netns 共有 + `127.0.0.1`**: AWS SDK の Container Credential Provider は `http://` の endpoint を loopback（127.0.0.1 / localhost / ::1）と ECS/EKS の link-local にしか許可しない。専用 network 越しの `http://aws-credentials:8080` は別 netns・別 IP なので botocore に `Unsupported host` で拒否される。そのため sidecar も `network_mode: service:docker` で Docker sidecar の netns に join する。帰結として endpoint は netns の内側からしか届かない（`ports` はそもそも書けない）
- **sidecar 側でキャッシュしない**: SDK が `Expiration` まで自前でキャッシュし、login セッションの管理は CLI に任せる。sidecar は変換するだけ
- **`depends_on` は agent → aws-credentials**: 両者とも `docker` の netns に join するだけで互いには依存しないため循環しない

## 仕組み

```
 agent (本体)                                 aws-credentials (sidecar, 非特権)
  AWS_CONTAINER_CREDENTIALS_FULL_URI          python3 /server.py が 127.0.0.1:8080 で listen
   = http://127.0.0.1:8080/credentials   ──►   GET /credentials
  AWS_REGION                                    └─ aws configure export-credentials
                                                    --profile $AWS_PROFILE --format process
                                              mount: ~/.aws/config (ro)
                                                     ~/.aws/login/cache (ro)
        └───────── netns 共有（両者とも network_mode: service:docker）─────────┘
```

| 対象 | 行き先 | モード |
|---|---|---|
| `~/.aws/config`（`DCC_AWS_DIR` で変更可） | sidecar `/root/.aws/config` | ro |
| `~/.aws/login/cache` | sidecar `/root/.aws/login/cache` | ro |
| 一時 credential（AccessKeyId / SecretAccessKey / Token / Expiration） | 本体（HTTP） | — |

### セットアップ

ホストで `aws login`（使う profile で）を済ませ、`AWS_PROFILE`（または `DCC_AWS_PROFILE`）を設定した状態で `dcc --creds aws` を実行する。
コンテナ内では `aws sts get-caller-identity` で確認できる。

### 詳細

- sidecar のイメージは `public.ecr.aws/aws-cli/aws-cli`（`capabilities/aws/`）。`GET /credentials` ごとに `export-credentials` を実行し、Container Credential Provider の形式に変換して返す。失敗時は 503（本文は `Code` / `Message` のみ）、`/credentials` 以外は 404
- profile / region は `dcc` 実行時のホストの環境変数を compose が補間する（profile: `DCC_AWS_PROFILE` → `AWS_PROFILE` → `default`、region: `DCC_AWS_REGION` → `AWS_REGION` → `AWS_DEFAULT_REGION` → `us-east-1`。[customization.md](customization.md)）。sidecar 自身にも `AWS_REGION` を渡す（profile に region が無いと `export-credentials` が `NoRegion` で失敗する）
- `AWS_PROFILE` の変更は `dcc` が drift として警告する（ラベル `dcc.aws-profile`。適用は `dcc recreate`）
- 本体の AWS CLI v2 / SDK（Go v2、boto3、Terraform など）は `AWS_CONTAINER_CREDENTIALS_FULL_URI` を自動で拾う。コンテナ内では profile という概念は使えない（`--profile` は `ProfileNotFound`）
- `initialize.sh aws` が `config` / `login/cache` の存在を事前に警告する（無いと `up` が失敗するか、その場所に空ディレクトリが作られる。[customization.md](customization.md) の「bind のソースが無いとき」）

## 制約・既知の穴

- ホストで `aws login` 済みであることが前提。期限切れなら endpoint は 503 を返す。ホストで再ログインすれば sidecar の再起動なしに次のリクエストから復旧する
- 一時 credential は本体内の全プロセスから読める。持ち出されれば失効まで使える
- `~/.aws/login/cache` が ro のため、CLI が refresh token を書き戻す必要のあるフローで失敗する可能性がある（未検証。問題になれば `login/cache` だけ rw にするトレードオフ）
- SSO profile（`aws sso login`）と `credential_process` で外部コマンドを呼ぶ profile は、sidecar に渡していない / コマンドが無いため動かない。必要なら `local/compose.yml` で足す
- inner container からは endpoint が見えない（親 netns の `127.0.0.1` に届かない）。inner container に AWS 権限を渡すには明示的に環境変数等で渡すしかない
