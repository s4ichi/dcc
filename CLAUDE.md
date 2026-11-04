# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository manages the container setup (docker compose) for running coding agents (Claude Code / Codex CLI) isolated from the host, plus a thin wrapper CLI `dcc` around it. On the host it is cloned into `~/.config/dcc` (`DCC_CONFIG_DIR`). `dcc` just lines up the selected compose files with `-f` and calls `docker compose`; it does not generate or rewrite files, and does not depend on the devcontainer CLI. The same compose files can also be referenced from the devcontainer CLI / VS Code.

There is one compose project per workspace, made of `agent` (the agent container: the unprivileged container where the agent runs. Both `claude` and `codex` are installed, chosen with `dcc --agent` on each launch) and `docker` (a rootless dind sidecar. The only `privileged` one, and no secrets are mounted into it at all). The host's secrets are passed only when explicitly named as credential modules (`aws` / `claude` / `codex` / `gpg` / `ssh` / `gh`), as in `dcc --creds gpg,ssh`. For `gpg` / `aws` / `gh`, an unprivileged module sidecar does the work on the agent container's behalf, and the agent container never receives the key (for `gh`, the refresh token).

The design assumes "the agent container may be compromised". When making changes, always consider what the agent container can newly reach as a result (`docs/boundaries.md`).

The source of truth for the specification is `docs/`. Only the essentials needed for working are written here.

| What you want to know | What to read |
|---|---|
| Usage, commands, module overview | `README.md` |
| Components, compose structure, lifecycle, `dcc` specification and how the implementation is split | `docs/architecture.md` |
| Overview of boundaries, design principles, mounts | `docs/boundaries.md` |
| Selecting modules, drift, how to add one | `docs/credentials.md` |
| `DCC_*` environment variables, `local/` | `docs/customization.md`, `.env.example` |
| Design rationale and known holes per boundary | `docs/{gpg,aws,ssh,github,git,claude-code,codex,mcp,docker}.md` |
| Using it from the devcontainer CLI / VS Code | `docs/devcontainer.md` |
| Component / end-to-end tests, fake credentials, CI | `docs/testing.md` |

## Commands

```bash
make generate   # generate docker-compose*.yml + capabilities/*/compose.yml from template.jsonnet
make fmt        # format template.jsonnet (jsonnetfmt -i)
make check      # lint + test + validate Jsonnet evaluation (does not generate files)
make lint       # shellcheck (scripts in dcc / lib / lifecycle_hooks / capabilities/{gpg,gh} / test helpers)
make test       # component tests: bats (test/*.bats) + Python unittest (test/python/); starts no containers
make e2e        # end-to-end tests (test/e2e/*.bats): builds the images and runs dcc against a fake host on the local Docker
make clean      # remove generated files
```

`shellcheck` and `bats` are required (macOS: `brew install shellcheck bats-core`, Debian: `apt install shellcheck bats`).
GitHub Actions runs `make check` and `make e2e` on every pull request (`.github/workflows/test.yml`). Inside a `dcc`
container the Docker sidecar cannot run another dind, so run the end-to-end tests there with
`DCC_E2E_DOCKER=stub DCC_E2E_TMPDIR="$PWD/.e2e" make e2e` (`docs/testing.md`).

`dcc`'s commands and options are in `dcc help` and `README.md`. Commonly used for checking behavior: `dcc up` / `dcc recreate` / `dcc creds` / `dcc list`; to see all output, `DCC_VERBOSE=1`.

## Conventions for making changes

- **Do not edit generated files directly.** `docker-compose.yml` / `docker-compose.workspace.yml` / `docker-compose.base-image.yml` / `capabilities/*/compose.yml` are generated from `template.jsonnet`. After changing `template.jsonnet`, run `make fmt && make generate` and commit the generated files too (so it works without jsonnet on the host)
- **If you change `dcc` / `lib/*.sh` / the hooks, make `make check` pass.** When you add a function, add a test to `test/dcc.bats`. Sourcing `dcc` only loads function definitions (only `main` at the end is executed), so tests call functions directly, and functions that call docker (`agent_label` / `container_id`, etc.) are replaced with stubs inside the test
- **Tests follow the change** (where each kind of change gets its test: "Adding tests" in `docs/testing.md`). Hooks → `test/hooks.bats`; module scripts and `server.py` → `test/<module>.bats` / `test/python/`; a new invariant of the compose configuration → `test/compose.bats`; anything visible from inside the running containers → `test/e2e/`. Tests never use real credentials: the end-to-end tests make a fake host with dummies (`test/e2e/helpers.bash`)
- **How to write `lib/`:** a function either "reads docker state" (`docker.sh`) or "changes it" (`project.sh`), never both. Only `load_config` / `parse_args` / `resolve_workspace` / `resolve_creds` write global variables; after that they are only read. The only thing executed at top level is `main` at the end of `dcc`
- **Logs are one piece of information per line** (the convention at the top of `lib/log.sh`). The subject is the thing `dcc` touched; do not print function names or compose subcommand names. Hide external tools' output on success and print all of it on failure. Hooks print only lines of the form `<subject>: <predicate>` / `warn: <subject>: <predicate>`
- **Do not bake in per-user values.** Write personal or organization-specific values in `template.jsonnet` as `${DCC_X:-<default>}`, and add one line to `.env.example` and to the table in `docs/customization.md`. If `dcc` / `initialize.sh` need the same value, reference it with the same default
- **Do not write relative paths in compose.** Every file in the repository is referenced by an absolute path based on `${DCC_CONFIG_DIR:-${HOME}/.config/dcc}` (so it points to the same place even when the devcontainer CLI passes a different order of `-f`)
- **To add a module**, add an entry to `credModules` in `template.jsonnet` and run `make generate`. `dcc` gets the module names from the file names of `capabilities/*/compose.yml`, so it needs no changes. Host-side pre-processing goes in the `case` of `lifecycle_hooks/initialize.sh`; container-side work is gated on the presence of the mount and added to `postCreate.sh` (container user) or `postCreate-root.sh` (things that need root). The full procedure is in "Adding a module" in `docs/credentials.md`
- **Fix the docs too.** Per-boundary pages use the same headings (What it protects / Boundary / What leaks on compromise / Why this design / How it works / Constraints and known holes). If you change mounts, update the mount tables in `docs/boundaries.md`; if you change commands or options, update `usage` (`lib/cli.sh`), `README.md`, and `docs/architecture.md`
- **Comments explain "why".** The body of the design rationale goes in docs; the code side keeps only a 1-2 line gist and a pointer to the docs

## File roles

| File | Role |
|---|---|
| `template.jsonnet` | Single source of the configuration. Credential modules are defined in `credModules` |
| `docker-compose.yml` | Generated file (base). Definitions of `agent` and `docker`, always-on mounts only. Does not include the workspace bind |
| `docker-compose.workspace.yml` | Generated file (overlay). The workspace bind for `dcc` and the `dcc.workspace` label |
| `docker-compose.base-image.yml` | Generated file (overlay). Override for building the base image when `local/Dockerfile` exists. Used only by `dcc build` / `dcc up` |
| `capabilities/<name>/compose.yml` | Generated file (overlay). The compose fragment for each credential module |
| `capabilities/gpg/`, `capabilities/aws/`, `capabilities/gh/` | Module sidecar images (`server.py`), the host-side scripts for `gpg` (`export-host-keys.sh` / `warm.sh`), and agent-side wrappers in `agent/` (`gpg-sign-client.sh` / `gh-token-client.sh`; each `agent/` is bound to the agent container as a directory) |
| `capabilities/ssh/conf/` | GitHub-specific settings (`github.conf`, `known_hosts`) that the `ssh` module binds to `/etc/ssh/dcc` (tracked in git) |
| `Dockerfile` | The agent image (`debian:bookworm-slim`, without dockerd). Personal layers are added in `local/Dockerfile` |
| `dcc`, `lib/*.sh` | Entry point and implementation of the CLI (the split is described in the comment at the top of `dcc` and in `docs/architecture.md`) |
| `lifecycle_hooks/initialize.sh` | Host-side pre-processing (per-module export / pre-checks). Called from `dcc up` and devcontainer's `initializeCommand` |
| `lifecycle_hooks/postCreate-root.sh` | Hook run once as root inside the container after creation (system gitconfig, the `HOST_HOME` symlink). There is no sudo in the agent container, so `dcc up` calls it with `compose exec --user root`. Even root has no capabilities (no `chown`) |
| `lifecycle_hooks/postCreate.sh` | Hook run once as the container user after creation. Called from `dcc up` (after the root side) and devcontainer's `postCreateCommand` |
| `test/dcc.bats` | Function tests for `dcc` |
| `test/{hooks,gpg,gh,compose}.bats`, `test/python/` | Component tests for the hooks, the module scripts and sidecar servers, and the static compose invariants. Shared helpers in `test/helpers/` |
| `test/e2e/` | End-to-end tests against a fake host (`helpers.bash` makes it and holds the `DCC_E2E_*` settings) |
| `.github/workflows/test.yml` | CI: `make check`, then `make e2e` |
| `AGENTS.md` | Entry point for Codex and other agents. The conventions live in this file (`CLAUDE.md`); `AGENTS.md` only points here. To change the conventions, edit this file |
| `.env.example` | List of `DCC_*` and their defaults (this is the source of truth) |
| `.env`, `local/`, `capabilities/{ssh,gh}/data/`, `capabilities/gpg/gnupg-host/` | Gitignored. The user's settings and secrets. **Do not read them, do not commit them** |

## Invariants that must not break

The reason for each is in the docs in parentheses. If you need to change one, read the reason first.

- The agent container is unprivileged. `privileged: true` is only on the `docker` sidecar, and no secrets at all are mounted there. The host's `/var/run/docker.sock` is not passed (`docs/docker.md`)
- Do not put sudo in the agent container. Do not remove `security_opt: no-new-privileges` and `cap_drop: ALL`. Post-creation processing that needs root goes in `postCreate-root.sh`, which `dcc` calls with `compose exec --user root`. Even root has no capabilities, so `chown` cannot be written; volume ownership is prepared via directories on the image side (`docs/boundaries.md`)
- Do not change the service name `docker`. It is hard-coded in the SAN of the TLS certificate the sidecar generates (`docs/docker.md`)
- Bind the workspace at the **same path** (`/workspaces/<basename>`) in the agent container and the `docker` sidecar. It is the sidecar's dockerd that resolves binds of `docker run -v` (`docs/docker.md`)
- Do not put the workspace bind in the base `docker-compose.yml`. The devcontainer CLI cannot pass the workspace path to compose (`docs/devcontainer.md`)
- Pass the results of host-side pre-processing as **files**, not as compose environment variables. devcontainer's `initializeCommand` cannot pass environment variables to compose (`docs/credentials.md`)
- Module sidecars share the netns with `network_mode: service:docker` and listen only on `127.0.0.1`. This is because the AWS SDK rejects `http://` endpoints other than loopback; as a result, the endpoints are unreachable from outside the netns (`docs/aws.md`)
- Never bring long-lived keys into the agent container. `~/.aws`, `~/.gnupg`, the host's `~/.ssh`, and the Keychain are not mounted into the agent container (`docs/boundaries.md`)
- Do not single-file bind files that are atomically written inside the container (`~/.claude.json`). Pass them ro as `.host` and copy them in postCreate (`docs/claude-code.md`). `~/.codex` is also written via rename for `config.toml`, so always pass it as a whole directory (`docs/codex.md`)
- Do not single-file bind files of this repository either: `git pull` / checkout and editors replace them, and the container keeps the old (deleted) inode until recreate. Put what the agent container needs in a directory of its own (`capabilities/<module>/agent/`, `capabilities/ssh/conf/`) and bind that (`docs/boundaries.md`; `test/compose.bats` checks it)
- Do not make the agent choice (`--agent`) an attribute of the container. Both agents live together in the same container; do not bring `AGENT` into labels or compose interpolation (doing so would make switching require `dcc recreate`)
- Do not make the Claude Code binary (`~/.local/share/claude`) a volume. The version baked into the image is authoritative (`docs/claude-code.md`). The Codex binary also lives in `/opt/codex` (the image), not under `~/.codex`
- Compose merges multi-file `volumes` by appending per target, and the same target is last-wins. Do not duplicate targets except for the intentional override (`~/.claude` by the `claude` module)

## Operational notes

- Changes to compose files or images are not applied to existing containers (`dcc up` uses `--no-recreate`). Run `dcc recreate`
- Do not restart only the `docker` sidecar. The agent container's netns gets left behind in the old sandbox and can no longer reach Docker. Recover with `dcc recreate`
- If you are editing this repository itself inside a `dcc` container, `docker` inside the container is the sidecar's dockerd, and containers created by `dcc` on the host are not visible. Check behavior such as `dcc up` on the host
- Using this repository as the workspace removes the boundary (`dcc` / `lib` / `.env` / hooks / sidecar sources run on the host and in the sidecars). If you open it, use `--no-creds`, and check `git diff` on the host before running the next `dcc` ("What this design does not protect" in `docs/boundaries.md`)
