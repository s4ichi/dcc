# AGENTS.md

このリポジトリで作業するエージェント向けの入口。作業規約・ファイルの役割・壊してはいけない不変条件は
[CLAUDE.md](CLAUDE.md) にまとめてあり、Claude Code 以外のエージェントも同じ規約に従う。作業の前に読むこと。

- 仕様の正は `docs/`（索引は [docs/README.md](docs/README.md)）
- `docker-compose*.yml` と `capabilities/*/compose.yml` は生成物。`template.jsonnet` を変えて `make fmt && make generate` する
- `dcc` / `lib/*.sh` / フックを変えたら `make check` を通す
- `.env`、`local/`、`capabilities/{ssh,gh}/data/`、`capabilities/gpg/gnupg-host/` は利用者の設定と秘密情報。読まない・コミットしない
