# dcc — run Claude Code / Codex confined in a container

> Run Claude Code or OpenAI Codex CLI inside a Docker Compose sandbox. The host's secrets (AWS, GPG, SSH,
> GitHub, `~/.claude`, `~/.codex`) are opt-in per module, Docker is provided by a rootless sidecar instead of
> the host socket, and signing / AWS / GitHub credentials are brokered by sidecars so that long-lived keys never enter
> the container.

`dcc` is a docker compose configuration, plus a thin wrapper CLI around it, for launching [Claude Code](https://claude.com/claude-code)
or [Codex CLI](https://github.com/openai/codex) in any directory **inside a container isolated from the host**.

```bash
cd ~/src/my-project
dcc                     # create the container (or reuse an existing one) and start claude in it
dcc --agent codex       # start codex in the same container
dcc --creds gpg,ssh     # start with only signing and SSH to GitHub passed in
```

## Why

Coding agents can run arbitrary commands. Instructions planted in a web page or document they read may also make them
try to exfiltrate credentials or tamper with the host. This repository assumes that **the agent container may be compromised**,
and uses the compose configuration to decide not "what to allow" but "what the container cannot reach".

- **Pass only the secrets you choose.** `aws` / `gpg` / `ssh` / `gh` / `claude` / `codex` are modules, and
  nothing is mounted unless you name it explicitly with `--creds`
- **Never bring long-lived keys into the container.** GPG signing, AWS, and GitHub (`gh`) are handled by sidecars; the agent container
  receives only signatures and expiring temporary credentials / access tokens. SSH gets a key created just for the container
- **Do not pass the host's Docker.** `docker` inside the container talks to a rootless dind sidecar.
  Even `docker run --privileged -v /:/host` only reaches the inside of the sidecar
- **Never put privileges and secrets together.** Only the Docker sidecar, which holds no secrets at all, gets `privileged`
- **Generated files are static.** The compose files are generated from Jsonnet and committed, so what gets mounted can be
  reviewed as files. `dcc` just lines up `-f` options and calls `docker compose`

```
 host                         compose project (one per workspace)
 ────                         ┌────────────────────────────────────────────────────────────┐
  dcc ─ docker compose ─────► │  agent (unprivileged)              docker (sidecar)        │
                              │   runs claude / codex       TLS    rootless dockerd        │
  ~/src/my-project ◄─ bind ─► │   /workspaces/my-project  ──────► the only privileged one │
  ~/.gitconfig ─── ro ──────► │   ~/.gitconfig                     no secrets mounted      │
                              │          │ 127.0.0.1 (shared netns)                        │
  only if chosen by --creds:  │          ▼                                                 │
  ~/.gnupg signing key ─ ro ► │  gpg-signer (only signs commits / tags)                    │
  ~/.aws login ── ro ───────► │  aws-credentials (only issues temporary credentials)       │
  dcc gh-login ─► volume ───► │  gh-token (only issues access tokens that expire in hours) │
                              └────────────────────────────────────────────────────────────┘
```

## Requirements

- `docker` (with the compose plugin). Any of Docker Desktop / Rancher Desktop / OrbStack / native Linux
- bash, and `shasum` or `sha256sum`
- `~/.gitconfig` on the host (it is always mounted read-only; if missing, `touch ~/.gitconfig`)
- `gpg` on the host, only if you use the `gpg` module

The host is primarily assumed to be macOS. Linux works too, but if your uid is not 1000, set `DCC_UID` to match
([docs/customization.md](docs/customization.md)). The devcontainer CLI is not required.

## Quick start

```bash
# 1. Clone this repository into ~/.config/dcc
#    (to put it elsewhere, export DCC_CONFIG_DIR)

# 2. Put dcc somewhere on your PATH
ln -s ~/.config/dcc/dcc ~/.local/bin/dcc

# 3. Start it in the directory you want to work in
cd ~/src/my-project
dcc
```

The first run takes a few minutes to build the image. Once started, Claude Code comes up inside the container; run `/login` the first time only.
The host's authentication (the macOS Keychain) is not passed in. Authentication obtained in the container is kept in the volume `dcc-claude-home`
(the host's `~/.claude` when the `claude` module is enabled) and is reused across all workspaces, even after recreating.
Codex works the same way: log in inside the container the first time only (the browser flow cannot reach the container, so use `codex login --device-auth` or an API key;
[docs/codex.md](docs/codex.md)).

The container stays after claude exits. The next `dcc` connects to the same container. Stop it with `dcc stop`, remove it with `dcc clear`.

## Usage

```
dcc [command] [workspace] [options] [args...]
```

| Command | Behavior |
|---|---|
| `dcc` | Start the container (create it if missing) and run the agent |
| `dcc up` | Only start / create |
| `dcc exec [args]` | Run the agent. Everything after `--` and unknown options are passed to the agent (e.g. `dcc exec -- --resume`) |
| `dcc stop [--all]` | Stop (`--all` for all workspaces) |
| `dcc clear [--all] [--volumes]` | Remove. `--volumes` also removes the sidecar's named volumes (image cache, etc.) |
| `dcc recreate` | Remove and recreate. Use it to apply changes to compose or credentials |
| `dcc build [opts]` | Build the images (e.g. `dcc build --no-cache`). Apply with `dcc recreate` |
| `dcc creds` | Show the modules and the current selection for this workspace |
| `dcc gh-login [args]` | Prepare the token for the `gh` module (`gh auth login --expiring`; shared by all workspaces) |
| `dcc list` / `dcc inspect` | List / show details of the containers of all workspaces |

Choose the agent to run with `--agent claude|codex` (default `DCC_AGENT`, otherwise `claude`). Both live in the same
container, so you can switch per invocation without recreating the container.

The workspace is determined by the directory in the first argument → `DCC_WORKSPACE` → `$PWD`, in that order, and appears in the container as
`/workspaces/<directory name>`. Each workspace gets its own compose project
(`dcc-<name>-<hash of the path>`).

## Credential modules

If nothing is specified, the only things passed to the container are the workspace and `~/.gitconfig` (ro).

```bash
dcc --creds gpg,ssh          # create with only the chosen modules enabled
dcc                          # afterwards, no flag needed to connect to the same container (same selection)
dcc recreate --creds aws,gh  # recreate to change the selection
export DCC_CREDS=gpg,ssh     # default for newly created containers
```

| Module | What the container can do | How it is passed | Preparation | Details |
|---|---|---|---|---|
| `gpg` | Sign commits / tags | **Delegated**. Only the `gpg-signer` sidecar holds the private key | Set `user.signingkey` on the host | [docs/gpg.md](docs/gpg.md) |
| `aws` | Get temporary credentials for one profile logged in on the host | **Delegated**. Issued by the `aws-credentials` sidecar | `aws login` on the host | [docs/aws.md](docs/aws.md) |
| `ssh` | SSH to GitHub | A container-only key passed ro | Create the dedicated key in `capabilities/ssh/data/` | [docs/ssh.md](docs/ssh.md) |
| `gh` | GitHub API operations with `gh` and git over HTTPS | **Delegated**. Only the `gh-token` sidecar holds the refresh token; the agent container receives a short-lived access token each time | `dcc gh-login` on the host | [docs/github.md](docs/github.md) |
| `claude` | Runs with the same Claude Code settings, history, and plugins as the host | The host's `~/.claude` **shared rw** | None | [docs/claude-code.md](docs/claude-code.md) |
| `codex` | Runs with the same Codex settings, history, and **authentication** as the host | The host's `~/.codex` **shared rw** | None | [docs/codex.md](docs/codex.md) |

How the selection is resolved and how a mismatch with an existing container (drift) is handled: [docs/credentials.md](docs/credentials.md).

## Security model

The upper bound of what an attacker gets if the agent container is taken over:

| Boundary | Upper bound |
|---|---|
| `gpg` | Can get commits / tags signed. The key and passphrase do not leak |
| `aws` | Expiring temporary credentials. Long-lived keys and the login session do not leak |
| `ssh` | The container-only key leaks. Damage is limited to the permissions granted to it, and it can be revoked on GitHub |
| `gh` | An access token that expires in a few hours. The refresh token does not leak |
| `claude` | When enabled, **tampering with the host's Claude Code settings, and exfiltrating tokens and history** (the biggest hole; enable it only in workspaces that need it). When disabled, only the tokens and history in the volume |
| `codex` | When enabled, **exfiltrating the host's Codex token and tampering with its settings** (`auth.json` is a plaintext file, and rewriting `notify` or hooks runs commands on the host; heavier than `claude`). When disabled, only the tokens and history in the volume |
| Docker | The privileges of uid 1000 inside the sidecar. It cannot reach the host's Docker or files outside the workspace |

What this setup **does not protect**:

- **Outbound traffic is not restricted.** The workspace contents, and anything obtainable with the credentials passed to the container, can be sent out
- **The workspace is rw.** Operations inside the container are reflected directly in the host's files
- The agents' own permission settings (Claude Code permissions / hooks, Codex approval policy) are out of scope. The container
  sets "the upper bound of damage once breached" and is not a substitute for the agent-side settings
- **Codex's own sandbox is turned off by default.** It often does not work inside a container, and even when it does it cuts off traffic to the Docker sidecar,
  so the container is treated as the sandbox (changeable with `DCC_CODEX_ARGS`; [docs/codex.md](docs/codex.md))

The overview of the boundaries is in [docs/boundaries.md](docs/boundaries.md); the design rationale and known holes for each boundary are on its own page.

## Customization

Personal or organization-specific values are not written into the repository; they are given as `DCC_*` environment variables with defaults (in the shell, or in `.env`).
The list is in [`.env.example`](.env.example).

- Pass environment variables to the container: `DCC_CONTAINER_ENV_<NAME>=value`
- Add tools to the image: `local/Dockerfile` (`FROM dcc:base`)
- Add binds or environment variables: `local/compose.yml`

`local/` and `.env` are gitignored; just put them in place and `dcc` uses them. Details in [docs/customization.md](docs/customization.md).

## Using from the devcontainer CLI / VS Code

The same compose files can be referenced from `dockerComposeFile` in `devcontainer.json`, and credential modules work the same way
([docs/devcontainer.md](docs/devcontainer.md)).

## Documentation

| | |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Components, structure of the compose project, lifecycle, CLI specification |
| [docs/boundaries.md](docs/boundaries.md) | Overview of the boundaries with the host, design principles, mounts |
| [docs/credentials.md](docs/credentials.md) | Selecting credential modules and how they work, how to add a module |
| [docs/customization.md](docs/customization.md) | `DCC_*` environment variables, `local/`, host-side assumptions |
| [docs/testing.md](docs/testing.md) | Component and end-to-end tests, the fake host, CI |
| [docs/README.md](docs/README.md) | Index of all pages (including the per-boundary pages) and terminology |

## Development

```bash
make generate   # generate the compose files from template.jsonnet
make fmt        # jsonnetfmt
make check      # shellcheck + component tests (bats, Python) + Jsonnet evaluation
make e2e        # end-to-end tests: build the images and run dcc against a fake host on the local Docker
```

Both run in GitHub Actions on every pull request, with dummy credentials only. What each test covers, how the
credentials are faked, and how to run the end-to-end tests inside a `dcc` container: [docs/testing.md](docs/testing.md).

`docker-compose*.yml` and `capabilities/*/compose.yml` are generated files, so do not edit them directly; change `template.jsonnet` and
run `make generate`. The required tools are `jsonnet` (go-jsonnet), `shellcheck`, and `bats`
(macOS: `brew install go-jsonnet shellcheck bats-core`). The agent image includes `jsonnet` but not
`shellcheck` / `bats`, and there is no sudo in the container, so to run `make check` inside the container,
add them with `local/Dockerfile` ([docs/customization.md](docs/customization.md)).
Code structure and conventions: [CLAUDE.md](CLAUDE.md) and [docs/architecture.md](docs/architecture.md).

## License

[MIT](LICENSE)
