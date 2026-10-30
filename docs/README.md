# docs

The specification of the container setup for Claude Code / Codex CLI, and how credentials and settings are handed between
host and container (how the boundaries are handled). For getting started, see [README.md](../README.md) at the repository root.

Suggested reading order: to learn how it works, [architecture.md](architecture.md); to learn what is and is not protected,
[boundaries.md](boundaries.md) → the pages of the modules you use.

## Overview

| File | Contents |
|---|---|
| [architecture.md](architecture.md) | Components, generation flow, structure of the compose project, lifecycle, CLI |
| [boundaries.md](boundaries.md) | Overview of the boundaries with the host. The 3 axes, design principles, summary by boundary, mounts |
| [credentials.md](credentials.md) | Selective granting of credential modules. How to specify `--creds`, drift behavior, how overlays work, adding a module |
| [customization.md](customization.md) | Per-user customization with `DCC_*` environment variables and `local/`, host-side assumptions |
| [devcontainer.md](devcontainer.md) | How to use the compose files from the devcontainer CLI / VS Code without `dcc` |

## Per-boundary pages

| File | Subject | Module | Host side | Container side |
|---|---|---|---|---|
| [gpg.md](gpg.md) | GPG signing key, public keys, passphrase | `gpg` | `~/.gnupg/private-keys-v1.d` + exported public keys | `gpg-signer` sidecar (the agent container delegates to the signing API) |
| [aws.md](aws.md) | AWS credentials | `aws` | `~/.aws/config` + `~/.aws/login/cache` (ro to the sidecar) | Temporary credentials fetched via `AWS_CONTAINER_CREDENTIALS_FULL_URI` |
| [ssh.md](ssh.md) | SSH key, known_hosts | `ssh` | `<repo>/capabilities/ssh/data/` (gitignored) | `~/.ssh` (ro) |
| [github.md](github.md) | Authentication for GitHub CLI (`gh`) and HTTPS git (expiring token) | `gh` | volume `dcc-gh-home` (written by `dcc gh-login`; rw to the `gh-token` sidecar) | Short-lived access token fetched on each use by the `gh` wrapper / git credential helper |
| [git.md](git.md) | gitconfig, safe.directory, signing settings | always | `~/.gitconfig` | `~/.gitconfig` (ro) + system gitconfig |
| [claude-code.md](claude-code.md) | Claude Code settings, sessions, plugins | `claude` | `~/.claude`, `~/.claude.json` | When enabled, `~/.claude` (rw). When disabled, an empty volume shared by all workspaces |
| [codex.md](codex.md) | Codex CLI settings, authentication, sessions, and handling of Codex's own sandbox | `codex` | `~/.codex` (`auth.json` = contains the token) | When enabled, `~/.codex` (rw). When disabled, an empty volume shared by all workspaces |
| [mcp.md](mcp.md) | Claude Code MCP server settings and OAuth tokens | always (depends on `claude`) | Settings in `~/.claude.json` / `.mcp.json`. Tokens in the macOS Keychain (**not passed**) | Authenticated inside the container and stored in `~/.claude/.credentials.json` |
| [docker.md](docker.md) | Docker (rootless sidecar) and TLS certificates | always | None (the host's Docker is not used) | `DOCKER_HOST=tcp://docker:2376` + `/certs` (ro) |

A module is passed to the container only when its name in the "Module" column is given with `dcc --creds <name>`. "always" is mounted regardless of the selection.

### Page structure

Per-boundary pages use the same headings. The agent container is where an agent (Claude Code / Codex) may run arbitrary code,
so boundaries are explained **assuming it may be compromised** ([boundaries.md](boundaries.md)).

| Section | What to write |
|---|---|
| What it protects | The things that must not leak, where they live, and their nature |
| Boundary | One line for each of the 3 axes. What it can do (allowed operations) / what it can reach (reachable files and resources) / how the key is passed (one of delegated execution, via a store, plaintext, direct read) |
| What leaks on compromise | The upper bound of capabilities an attacker gets if the agent container is taken over |
| Why this design | Alternatives and why they were not chosen |
| How it works | Mount table, processing flow, setup steps |
| Constraints and known holes | Risks deliberately accepted and unaddressed items |

## Terminology

| Term | Meaning |
|---|---|
| host | The developer's machine that runs `dcc` |
| workspace | The project directory passed to the container. `/workspaces/<basename>` inside the container |
| agent container | The compose `agent` service. The unprivileged container where the agent runs |
| agent | The CLI run in the agent container. `claude` (Claude Code) or `codex` (Codex CLI). Both are in the same image, chosen with `--agent` on each launch |
| Docker sidecar | The compose `docker` service. Provides a rootless dockerd. The only `privileged` one |
| module sidecar | An unprivileged sidecar added by a credential module (`gpg-signer` / `aws-credentials`) |
| inner container | A container started with `docker run` from the agent container, running inside the Docker sidecar |
| credential module | The unit chosen with `--creds`. Concretely, the compose overlay `capabilities/<name>/compose.yml` |
| base / overlay | base is the always-used `docker-compose.yml`. An overlay is a compose fragment stacked after it with `-f` |
| drift | A mismatch between the selection baked into an existing container and the current request |
| warm | Having the gpg-agent in `gpg-signer` cache the signing key's passphrase |
| `<repo>` | Where this repository is cloned (`DCC_CONFIG_DIR`; default `~/.config/dcc`) |

## Assumptions

- The host is primarily assumed to be macOS (constraints of macOS's gpg-agent / ssh-agent / Keychain are part of the design rationale).
  The same design also works on Linux hosts ("Host OS dependencies" in [customization.md](customization.md))
- `docker` (with the compose plugin) is installed on the host. The `devcontainer` CLI is not needed for `dcc` (only when using it from devcontainer; [devcontainer.md](devcontainer.md))
- The user of the agent container is `agent` (uid 1000). The design assumes it does not match the host's uid (see safe.directory in [git.md](git.md))
