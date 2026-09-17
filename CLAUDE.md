# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

このリポジトリは Claude Code をホストから隔離して動かすためのコンテナ設定（docker compose）と、その薄いラッパー CLI `dcc` を管理する。ホストでは `~/.config/devcontainer/claude`（`DCC_CONFIG_DIR`）に clone して使う。`dcc` は選択した compose ファイルを `-f` で並べて `docker compose` を呼ぶだけで、ファイルの生成・書き換えは行わず、devcontainer CLI にも依存しない。同じ compose ファイルは devcontainer CLI / VS Code からも参照できる。

compose プロジェクトはワークスペースごとに 1 つで、`claude`（本体。Claude Code が動く非特権コンテナ）と `docker`（rootless dind の sidecar。`privileged` はここだけで、秘密情報は一切マウントしない）からなる。ホストの秘密情報は credential モジュール（`aws` / `claude` / `gpg` / `ssh` / `gh`）として `dcc --creds gpg,ssh` のように明示したときだけ渡る。`gpg` と `aws` は非特権のモジュール sidecar が代行し、本体は鍵を受け取らない。

設計の前提は「本体コンテナは侵害されうる」。変更するときは、本体から新たに何へ到達できるようになるかを必ず考える（`docs/boundaries.md`）。

仕様の正は `docs/`。ここには作業に必要な要点だけを書く。

| 知りたいこと | 読むもの |
|---|---|
| 使い方、コマンド、モジュールの概要 | `README.md` |
| 構成要素、compose の構造、ライフサイクル、`dcc` の仕様と実装の分担 | `docs/architecture.md` |
| 境界の総論、設計原則、マウント一覧 | `docs/boundaries.md` |
| モジュールの選択・drift・追加方法 | `docs/credentials.md` |
| `DCC_*` 環境変数、`local/` | `docs/customization.md`、`.env.example` |
| 境界ごとの設計理由と既知の穴 | `docs/{gpg,aws,ssh,github,git,claude-code,mcp,docker}.md` |
| devcontainer CLI / VS Code からの利用 | `docs/devcontainer.md` |

## Commands

```bash
make generate   # template.jsonnet → docker-compose*.yml + capabilities/*/compose.yml を生成
make fmt        # template.jsonnet をフォーマット（jsonnetfmt -i）
make check      # lint + test + Jsonnet の評価検証（ファイルは生成しない）
make lint       # shellcheck（dcc / lib / lifecycle_hooks / capabilities/gpg のスクリプト）
make test       # bats（test/*.bats。dcc を source して docker に触らない関数を検査する）
make clean      # 生成物を削除
```

`shellcheck` と `bats` が要る（macOS: `brew install shellcheck bats-core`、Debian: `apt install shellcheck bats`）。

`dcc` のコマンドとオプションは `dcc help` と `README.md`。動作確認でよく使うのは `dcc up` / `dcc recreate` / `dcc creds` / `dcc list`、出力を全部見るなら `DCC_VERBOSE=1`。

## 変更するときの規約

- **生成物を直接編集しない。** `docker-compose.yml` / `docker-compose.workspace.yml` / `docker-compose.base-image.yml` / `capabilities/*/compose.yml` は `template.jsonnet` から生成する。`template.jsonnet` を変えたら `make fmt && make generate` し、生成物も一緒にコミットする（ホストに jsonnet が無くても使えるようにするため）
- **`dcc` / `lib/*.sh` / フックを変えたら `make check` を通す。** 関数を足したら `test/dcc.bats` にテストを足す。`dcc` は source すると関数定義だけが読まれる（実行は末尾の `main` のみ）ので、テストは関数を直接呼び、docker を呼ぶ関数（`claude_label` / `container_id` など）はテスト内で stub に差し替える
- **`lib/` の書き方:** 関数は「docker の状態を読む」（`docker.sh`）か「変える」（`project.sh`）のどちらか一方。グローバル変数を書くのは `load_config` / `parse_args` / `resolve_workspace` / `resolve_creds` だけで、以降は読むだけ。トップレベルで実行するのは `dcc` 末尾の `main` だけ
- **ログは 1 行 1 情報**（`lib/log.sh` 冒頭の規約）。主語は `dcc` が触った対象で、関数名や compose のサブコマンド名は出さない。外部ツールの出力は成功時は隠し、失敗時に全部出す。フックは `<主語>: <述語>` / `warn: <主語>: <述語>` の行だけを出す
- **利用者ごとの値を焼き込まない。** 個人・組織固有の値は `template.jsonnet` に `${DCC_X:-<既定値>}` で書き、`.env.example` と `docs/customization.md` の表に 1 行足す。`dcc` / `initialize.sh` が同じ値を必要とする場合は同じ既定値で参照する
- **compose に相対パスを書かない。** リポジトリ内のファイルはすべて `${DCC_CONFIG_DIR:-${HOME}/.config/devcontainer/claude}` 基準の絶対パスで参照する（devcontainer CLI から別の `-f` の並びで渡されても同じ場所を指すように）
- **モジュールの追加**は `template.jsonnet` の `credModules` にエントリを足して `make generate`。`dcc` は `capabilities/*/compose.yml` のファイル名一覧からモジュール名を得るので変更不要。ホスト側の前処理は `lifecycle_hooks/initialize.sh` の `case`、コンテナ側はマウントの存在で gate して `postCreate.sh` に足す。手順の全体は `docs/credentials.md` の「モジュールの追加」
- **docs も一緒に直す。** 境界ごとのページは同じ見出し（守るもの / 境界 / 侵害時に漏れるもの / なぜこの構成か / 仕組み / 制約・既知の穴）で書く。マウントを変えたら `docs/boundaries.md` のマウント一覧、コマンドやオプションを変えたら `usage`（`lib/cli.sh`）・`README.md`・`docs/architecture.md` を更新する
- **コメントは「なぜ」を書く。** 設計理由の本文は docs に置き、コード側は 1〜2 行の要点と docs へのポインタに留める

## ファイルの役割

| ファイル | 役割 |
|---|---|
| `template.jsonnet` | 設定の単一ソース。credential モジュールは `credModules` に定義 |
| `docker-compose.yml` | 生成物（base）。`claude` と `docker` の定義、常時マウントのみ。ワークスペースの bind は含まない |
| `docker-compose.workspace.yml` | 生成物（overlay）。`dcc` 用のワークスペース bind と `dcc.workspace` ラベル |
| `docker-compose.base-image.yml` | 生成物（overlay）。`local/Dockerfile` があるときに base イメージを build するための上書き。`dcc build` / `dcc up` だけが使う |
| `capabilities/<name>/compose.yml` | 生成物（overlay）。credential モジュールごとの compose 断片 |
| `capabilities/gpg/`、`capabilities/aws/` | モジュール sidecar のイメージ（`server.py`）と、`gpg` のホスト側スクリプト（`export-host-keys.sh` / `warm.sh`）、本体側 wrapper（`gpg-sign-client.sh`） |
| `capabilities/ssh/config`、`known_hosts` | `ssh` モジュールが `/etc/ssh` に注入する GitHub 向け設定（追跡対象） |
| `Dockerfile` | 本体イメージ（`debian:bookworm-slim`、dockerd は含まない）。個人のレイヤは `local/Dockerfile` で足す |
| `dcc`、`lib/*.sh` | CLI の入口と実装（分担は `dcc` 冒頭のコメントと `docs/architecture.md`） |
| `lifecycle_hooks/initialize.sh` | ホスト側の前処理（モジュールごとの export / 事前チェック）。`dcc up` と devcontainer の `initializeCommand` から呼ぶ |
| `lifecycle_hooks/postCreate.sh` | コンテナ作成後にコンテナ内で一度だけ実行するフック。`dcc up` と devcontainer の `postCreateCommand` から呼ぶ |
| `test/dcc.bats` | `dcc` の関数テスト |
| `.env.example` | `DCC_*` の一覧と既定値（これが正） |
| `.env`、`local/`、`capabilities/{ssh,gh}/data/`、`capabilities/gpg/gnupg-host/` | gitignore 済み。利用者の設定と秘密情報。**読まない・コミットしない** |

## 壊してはいけない不変条件

理由はそれぞれ括弧内の docs にある。変える必要があるなら、理由を読んでから。

- 本体は非特権。`privileged: true` は `docker` sidecar だけで、そこには秘密情報を一切マウントしない。ホストの `/var/run/docker.sock` は渡さない（`docs/docker.md`）
- サービス名 `docker` は変えない。sidecar が生成する TLS 証明書の SAN に固定で含まれる（`docs/docker.md`）
- ワークスペースは本体と `docker` sidecar に**同一パス**（`/workspaces/<basename>`）で bind する。`docker run -v` の bind を解決するのは sidecar の dockerd（`docs/docker.md`）
- base の `docker-compose.yml` にワークスペースの bind を置かない。devcontainer CLI は compose にワークスペースのパスを渡せない（`docs/devcontainer.md`）
- ホスト側の前処理の結果は compose の環境変数ではなく**ファイル**で渡す。devcontainer の `initializeCommand` からは compose に環境変数を渡せない（`docs/credentials.md`）
- モジュール sidecar は `network_mode: service:docker` で netns を共有し、`127.0.0.1` だけで listen する。AWS SDK が loopback 以外の `http://` endpoint を拒否するためで、結果として endpoint は netns の外から届かない（`docs/aws.md`）
- 長期鍵を本体に持ち込まない。`~/.aws`、`~/.gnupg`、ホストの `~/.ssh`、Keychain は本体にマウントしない（`docs/boundaries.md`）
- コンテナ内で atomic write されるファイル（`~/.claude.json`）を single-file bind しない。ro で `.host` として渡し postCreate でコピーする（`docs/claude-code.md`）
- Claude Code の実体（`~/.local/share/claude`）を volume にしない。イメージの焼き込み版が正（`docs/claude-code.md`）
- compose は multi-file の `volumes` を target で追記マージし、同一 target は後勝ち。意図的な上書き（`claude` モジュールの `~/.claude`）以外で target を重複させない

## 運用上の注意

- compose ファイルやイメージの変更は既存コンテナに反映されない（`dcc up` は `--no-recreate`）。`dcc recreate` する
- `docker` sidecar だけを再起動しない。本体の netns が古い sandbox に取り残されて Docker に繋がらなくなる。復旧は `dcc recreate`
- このリポジトリ自体を `dcc` のコンテナ内で編集している場合、コンテナ内の `docker` は sidecar の dockerd で、ホストの `dcc` が作ったコンテナは見えない。`dcc up` などの動作確認はホスト側で行う
