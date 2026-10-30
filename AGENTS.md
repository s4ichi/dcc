# AGENTS.md

Entry point for agents working in this repository. The working conventions, file roles, and invariants that must not break are
collected in [CLAUDE.md](CLAUDE.md), and agents other than Claude Code follow the same conventions. Read it before starting work.

- The source of truth for the specification is `docs/` (index: [docs/README.md](docs/README.md))
- `docker-compose*.yml` and `capabilities/*/compose.yml` are generated files. Change `template.jsonnet` and run `make fmt && make generate`
- If you change `dcc` / `lib/*.sh` / the hooks, make `make check` pass
- `.env`, `local/`, `capabilities/{ssh,gh}/data/`, and `capabilities/gpg/gnupg-host/` are the user's settings and secrets. Do not read them, do not commit them
