# Docker（rootless sidecar）

常時マウント（モジュール選択に関係なく渡る）。本体コンテナに dockerd は無く、compose の `docker` サービス（`docker:dind-rootless`）が dockerd を提供する。

## 守るもの

| 実体 | 所在 | 性質 |
|---|---|---|
| ホストの Docker デーモン（`/var/run/docker.sock`） | ホスト | これを渡すと `docker run -v /:/host` でホストの root 相当になる |
| 本体コンテナにマウントした認証情報（`~/.claude`、各モジュール） | 本体 | inner container から見えてはいけない |
| ホストのファイル全般 | ホスト | inner container が bind できる範囲を限定したい |

## 境界

| 軸 | この設計 |
|---|---|
| できること | 本体は「sidecar の dockerd に対して任意の Docker 操作」ができる。`--privileged` や `-v /:/host` も通るが、その `/` は sidecar のルートで、権限は sidecar 内の uid 1000 止まり |
| 届く範囲 | inner container から見えるホストのファイルは**ワークスペースだけ**（sidecar に bind しているのがそれだけ）。本体の `~/.claude` や各モジュールのマウントは sidecar に無い。inner container から親 netns の `127.0.0.1` には届かない |
| 鍵の渡し方 | この境界では鍵を渡さない。TLS クライアント証明書は sidecar が生成し、本体に ro で渡す（dockerd への接続のためだけ） |

## 侵害時に漏れるもの

本体コンテナが乗っ取られた場合:

- sidecar の dockerd を自由に使える。イメージの pull、コンテナの実行、sidecar の `docker-data` volume の読み書きができる
- ワークスペースは inner container からも読み書きできる（本体からできることと同じ）
- ホストの Docker、ホストのファイル（ワークスペース以外）、本体にマウントした認証情報には到達できない
- sidecar は `privileged: true` だが秘密情報を一切マウントしていないので、sidecar を乗っ取っても漏らすものが無い

## なぜこの構成か

- **ホストの docker.sock を渡さない**: 渡した時点でホストの root 相当になる
- **rootless dind を sidecar に分離する**: dockerd を本体に同居させると本体に `privileged` が要り、Claude が動く場所に特権と認証情報が同居する。sidecar なら特権を持つコンテナには秘密情報が無く、秘密情報を持つコンテナには特権が無い
- **sidecar に `privileged: true` が必要な理由**: `docker:dind-rootless` イメージでも seccomp / AppArmor / `/proc`・`/sys` の mount mask を外すため。rootless であることと特権が必要なことは別
- **ワークスペースを同一パスで両方に bind する**: `docker run -v /workspaces/<name>/sub:/x` の bind を解決するのは sidecar の dockerd。本体と同じパスに無いと inner container にワークスペースを渡せない。ワークスペース外のホストパスは sidecar に無いので、inner container にマウントしようとすると空ディレクトリが作られるだけ
- **netns を共有する**: sidecar 上で `-p 3000:80` したポートに本体から `localhost:3000` で届く。ホストには公開しない
- **healthcheck を置かない**: netns を join するには sidecar が起動していれば十分で、dockerd の準備完了を待つ必要は無い。常時 `docker info` を回すコストの方が大きい

## 仕組み

```
 agent (本体, 非特権)                         docker (sidecar, privileged)
 ──────────────────────                       ────────────────────────────
 DOCKER_HOST=tcp://docker:2376  ───TLS───►    dockerd --host tcp://0.0.0.0:2376 (rootless, uid 1000)
 DOCKER_TLS_VERIFY=1                          DOCKER_TLS_CERTDIR=/certs
 DOCKER_CERT_PATH=/certs/client               /certs/{ca,server,client}/ を entrypoint が生成
 /certs (volume docker-certs, ro)  ◄────────  /certs (volume docker-certs, rw)
 /workspaces/<name> (bind)                    /workspaces/<name> (bind, 同一パス)
                                              /home/rootless/.local/share/docker (volume docker-data)
 network_mode: service:docker ◄────────────── netns の持ち主
```

| | 本体 | sidecar | inner container |
|---|---|---|---|
| `privileged` | なし | **あり** | 指定可能だが userns 内 |
| 実行 uid | 1000 (`agent`) | 1000 (`rootless`, dockerd) | userns 内 root = 外側の uid 1000+ |
| ホストの秘密情報 | あり | **なし** | なし |
| ホストのファイル | ワークスペース + 各種 bind | ワークスペースのみ | ワークスペース（`-v` で明示した範囲） |

- **TLS 証明書**: `docker:dind` 系の entrypoint は `DOCKER_TLS_CERTDIR` が設定されていると初回起動時に CA・サーバー・クライアント証明書を `/certs` に生成する。サーバー証明書の SAN には `docker`（サービス名）、`localhost`、`127.0.0.1` が含まれるので**サービス名 `docker` は変更しない**。`/certs/client/key.pem` は 0644 で生成され、本体のコンテナユーザー（`agent`）からも読める。証明書は volume に永続化され `dcc clear --volumes` まで残る
- **起動順**: 本体は `depends_on: docker: condition: service_started`。起動直後の数秒は `docker` コマンドが失敗しうる（postCreate は docker を使わない）
- **ネットワーク**: 本体側に `ports` / `hostname` / `dns` / `extra_hosts` は書けない。`sysctls: net.ipv4.ip_unprivileged_port_start=0` により uid 1000 の port driver が 1024 未満のポートも bind できる。inner container からは親 netns の `127.0.0.1` に届かない（rootlesskit `--disable-host-loopback`）
- **永続化**: `<project>_docker-certs`（`/certs`）と `<project>_docker-data`（イメージ・コンテナ・volume・buildkit キャッシュ）。プロジェクト名でプレフィックスされ、ワークスペースごとに独立する。ホストの Docker のイメージとは共有されない

## 制約・既知の穴

- **sidecar だけを再起動しない。** 本体の netns は sidecar の sandbox に紐づいており、sidecar が再作成されると本体が消えた netns に取り残される。`dcc recreate` で復旧する。`dcc stop` → `dcc up` は安全
- rootless の制約: systemd が無いため cgroup v2 の delegation ができず、`--memory` / `--cpus` / `--pids-limit` は無視される（警告のみ）。inner container の `--privileged` / `--cap-add SYS_ADMIN` は userns 内の CAP でしかなく、デバイス・カーネルパラメータには触れない。overlay2 は fuse-overlayfs または userns 対応の kernel overlay で動き、パフォーマンスはホストの Docker より落ちる
- inner container → 本体のサービスへ `host.docker.internal` 相当では繋げない。Docker network 経由で本体と同じ netns の IP を使うか、本体側で `0.0.0.0` を listen して sidecar の IP で繋ぐ
- `docker:dind-rootless` のバージョン固定は `DCC_DIND_IMAGE`（[customization.md](customization.md)）。変更後は `dcc recreate`
