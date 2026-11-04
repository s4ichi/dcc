# Customization

Personal and organization-specific values (user / uid, image tags, time zone, host-side paths, ports, etc.) are not baked
into the repository. Users adapt it to their environment with the following two. Both are gitignored, and the repository's
tracked files do not need to be edited.

- **`DCC_*` environment variables** (shell, or `.env`): change values
- **`local/`**: add layers to the image, add binds or environment variables to compose

## Environment variables (`DCC_*`)

**All are optional; unset means the default is used.** The list and defaults in [`.env.example`](../.env.example) are authoritative. There are two ways to set them:

- `export DCC_...=...` in the shell (works for both `dcc` and devcontainer)
- `${DCC_CONFIG_DIR}/.env` (copy `.env.example` and edit). `dcc` reads it as bash at startup
  and exports it. Shell environment variables take precedence. compose itself also reads the same file, but via devcontainer
  the project directory changes so it is not read ([devcontainer.md](devcontainer.md))

| Variable | Default | Description |
|---|---|---|
| `DCC_CONFIG_DIR` | `~/.config/dcc` | Location of this repository. Decided before `.env` is read, so it cannot be set in `.env` |
| `DCC_ENV_FILE` | `$DCC_CONFIG_DIR/.env` | env file to read |
| `DCC_WORKSPACE` | `$PWD` | Default workspace (can be overridden by an argument) |
| `DCC_CREDS` | empty | Default for `--creds` ([credentials.md](credentials.md)) |
| `DCC_AGENT` | `claude` | Default for `--agent`. `claude` or `codex` |
| `DCC_CLAUDE_ARGS` / `DCC_CODEX_ARGS` | empty / `-c sandbox_mode=danger-full-access -c check_for_update_on_startup=false` | Arguments `dcc` puts before the user's arguments when starting the agent. Whitespace separated; quotes are not interpreted. Setting an empty string adds nothing. Reason for the codex default in [codex.md](codex.md) |
| `DCC_VERBOSE` | empty | `1` always streams compose / hook output (by default everything is shown only on failure) |
| `DCC_LOCAL_DIR` | `$DCC_CONFIG_DIR/local` | Where personal settings live. `Dockerfile` / `compose.yml` are used automatically if present (below) |
| `DCC_COMPOSE_FILES` | empty | Further compose overlays added on top of `local/compose.yml` (colon-separated absolute paths) |
| `DCC_USER` / `DCC_UID` / `DCC_GID` | `agent` / `1000` / `$DCC_UID` | User inside the container. Passed as Dockerfile build args. Match them on a Linux host when uid ≠ 1000 |
| `DCC_IMAGE` | `dcc:local` | Tag of the agent image (shared by all workspaces; use a different tag if you change the user / uid) |
| `DCC_BASE_IMAGE` | `dcc:base` | Tag of the base image (this repository's Dockerfile) when `local/Dockerfile` is used. If changed, match `FROM` too |
| `DCC_DIND_IMAGE` | `docker:<ver>-dind-rootless@sha256:…` ([`.env.example`](../.env.example) is authoritative) | Image of the Docker sidecar. Pinned by digest because it is the only privileged container ([docker.md](docker.md)) |
| `DCC_GO_VERSION` | Dockerfile default | Go version in the agent image (build arg) |
| `DCC_TZ` | `$TZ`, otherwise `UTC` | Time zone of the agent container |
| `DCC_CONTAINER_ENV_<NAME>` | none | Passed as environment variable `NAME` inside the container (e.g. `DCC_CONTAINER_ENV_GOPRIVATE`). Fixed at container creation (below) |
| `DCC_GITCONFIG` | `~/.gitconfig` | Host-side path that is always mounted |
| `DCC_CLAUDE_DIR` / `DCC_CLAUDE_JSON` | `~/.claude` / `~/.claude.json` | Host-side paths shared by the `claude` module |
| `DCC_CLAUDE_HOME_VOLUME` | `dcc-claude-home` | Name of the empty external volume that becomes `~/.claude` when the `claude` module is disabled (shared by all workspaces) |
| `DCC_CODEX_DIR` | `~/.codex` | Host-side path shared by the `codex` module |
| `DCC_CODEX_HOME_VOLUME` | `dcc-codex-home` | Name of the empty external volume that becomes `~/.codex` when the `codex` module is disabled (shared by all workspaces) |
| `DCC_AWS_DIR` | `~/.aws` | Parent of `config` / `login/cache` that the `aws` module passes to the sidecar |
| `DCC_AWS_REGION` / `DCC_AWS_PROFILE` | `AWS_REGION` → `AWS_DEFAULT_REGION` → `us-east-1` / `AWS_PROFILE` → `default` | Region / profile of the `aws` sidecar |
| `DCC_AWS_CREDENTIALS_PORT` | `8080` | Port of the credential endpoint (change it if it collides with an inner container's `-p` in the shared netns) |
| `DCC_GNUPG_DIR` | `$GNUPGHOME`, otherwise `~/.gnupg` | Host GnuPG home (`private-keys-v1.d` is ro-bound into the sidecar; `GNUPGHOME` during export) |
| `DCC_GPG_SIGNING_KEY` | `git config user.signingkey` | Signing key (fingerprint / keyid / email) |
| `DCC_GPG_EXPORT_DIR` | `$DCC_CONFIG_DIR/capabilities/gpg/gnupg-host` | Output directory of the host-side export |
| `DCC_GPG_SIGNER_PORT` | `8081` | Port of the signing API |
| `DCC_SSH_DIR` / `DCC_SSH_CONF_DIR` | `$DCC_CONFIG_DIR/capabilities/ssh/{data,conf}` | Private key location / directory with the connection settings (`github.conf`) and host keys (`known_hosts`) of the `ssh` module |
| `DCC_GH_HOST` | `github.com` | Host the `gh` module issues tokens for (for GitHub Enterprise, its host name) |
| `DCC_GH_HOME_VOLUME` | `dcc-gh-home` | Name of the external volume holding the `gh-token` sidecar's state (refresh token) (shared by all workspaces; created by `dcc up` / `dcc gh-login`) |
| `DCC_GH_TOKEN_PORT` | `8082` | Port of the access token endpoint |

`DCC_BUILD_CONTEXT` / `DCC_DOCKERFILE` / `DCC_CONTAINER_ENV_FILE` and `LOCAL_WORKSPACE_FOLDER` /
`LOCAL_WORKSPACE_BASENAME` / `COMPOSE_PROJECT_NAME` are internal variables `dcc` uses to talk to compose; users do not set them
(except when using devcontainer; [devcontainer.md](devcontainer.md)).

### Passing environment variables to the container

Host environment variables are not passed to the container. Specify only the ones you want to pass with `DCC_CONTAINER_ENV_<NAME>=value`.

```bash
# .env
DCC_CONTAINER_ENV_GOPRIVATE='github.com/<org>/*'
DCC_CONTAINER_ENV_EDITOR=vim
```

`dcc` collects them into a temporary dotenv-format file and has compose read it via `env_file` (compose cannot interpolate
dynamic variable names). Values are fixed at container creation, so changes need `dcc recreate`. If you only want to set
an environment variable for the host-side `dcc` process itself, write a plain `NAME=value` in `.env`.

## `local/`: where personal settings live

Put files with fixed names in `${DCC_CONFIG_DIR}/local/` (changeable with `DCC_LOCAL_DIR`) and
`dcc` uses them automatically. No environment variables are needed. If you manage it with dotfiles, make `local/` a symlink or
point `DCC_LOCAL_DIR` at a directory inside your dotfiles.

```
<repo>/
├── .env                 # DCC_* settings (optional)
└── local/
    ├── Dockerfile       # if present, adds layers to the agent image
    └── compose.yml      # if present, added as a compose overlay
```

### `local/compose.yml`: compose overlay

The base compose binds only what always exists on the host. Files that exist only in your personal environment (such as
`~/.gitconfig.local` included by `~/.gitconfig`; git ignores the include if it is missing) and settings for personal tools
go here. It is merged after the credential overlays. To add yet more files, use `DCC_COMPOSE_FILES`.

```yaml
services:
  agent:
    environment:
      MY_TOOL_MARKER: "1"
    volumes:
      - type: bind
        source: ${HOME}/.gitconfig.local
        target: /home/agent/.gitconfig.local
        read_only: true
```

Binds added here widen the boundary. When passing host files, check what would leak if the agent container were compromised,
using the approach in [boundaries.md](boundaries.md).

### `local/Dockerfile`: adding layers to the image

Use an image with your personal tools added as the agent image, without changing this repository's `Dockerfile`.
Just put an ordinary Dockerfile that starts with `FROM dcc:base`.

```dockerfile
FROM dcc:base

USER root
RUN apt-get update && apt-get install -y ripgrep fd-find && rm -rf /var/lib/apt/lists/*
COPY --chown=agent:agent bin/ /home/agent/.local/bin/

USER agent
RUN curl -fsSL https://example.com/install.sh | sh
```

Internally this becomes a two-stage build:

```
<repo>/Dockerfile ──build──► dcc:base   (DCC_BASE_IMAGE)
                                  │ FROM
local/Dockerfile  ──build──► dcc:local  (DCC_IMAGE) ← used by the agent container
```

- `dcc build` builds both, base first, then personal (`--no-cache` applies to both). `dcc` / `dcc up` build
  the base first if it is missing, and compose builds the agent image automatically if it is missing
- The source of `COPY` (build context) is `local/`
- The base's `ENV` (`PATH` etc.) and `WORKDIR` are inherited. Do work that needs root under `USER root`, and
  switch back to `USER agent` at the end. If you changed the user name with `DCC_USER`, declaring `ARG USERNAME` lets you
  receive the same build args as the base (`USERNAME` / `USER_UID` / `USER_GID` / `GO_VERSION` / `BASE_IMAGE`)
- Changing `DCC_USER` / `DCC_UID` also changes the base, so give both `DCC_BASE_IMAGE` and `DCC_IMAGE`
  different tags, and match `FROM` too
- It is not auto-detected via devcontainer (which does not go through `dcc`). Run `dcc build` first, or
  build the base following [devcontainer.md](devcontainer.md) and export `DCC_BUILD_CONTEXT` / `DCC_DOCKERFILE`

### Slimming down the base image

This repository's `Dockerfile` includes, besides Claude Code and Codex CLI, Go / AWS CLI / `gh` / `yq` / `duckdb` / `uv` / `jsonnet` / Node.js / Java (Corretto) / `d2` and more
("Agent image (Dockerfile)" in [architecture.md](architecture.md)). Adding is covered by `local/Dockerfile`, but there is no mechanism to remove things.
If there are layers you do not need, fork and edit the `Dockerfile`. Do not remove the Docker CLI (connects to the sidecar), or git / gnupg / curl / jq
(used by the `gpg` module's wrapper). Do not add sudo (even if added, it does not work because of compose's `no-new-privileges`; [boundaries.md](boundaries.md)).

## Host-side assumptions

| Path / command | Purpose | If missing |
|---|---|---|
| `docker` (including the compose plugin) | running containers | `dcc` does not work |
| `shasum` or `sha256sum` | hash for the compose project name | one of them is required |
| `~/.gitconfig` (`DCC_GITCONFIG`) | git settings (always mounted) | see "When a bind source is missing" below. Create it; empty is fine (`touch ~/.gitconfig`) |
| `~/.claude/`, `~/.claude.json` (`DCC_CLAUDE_DIR` / `DCC_CLAUDE_JSON`) | only with the `claude` module | exist if you have started Claude Code on the host even once. `initialize.sh claude` warns in advance |
| `~/.codex/` (`DCC_CODEX_DIR`) | only with the `codex` module | exists if you have started Codex on the host even once. `initialize.sh codex` warns in advance |
| `~/.aws/config`, `~/.aws/login/cache` (`DCC_AWS_DIR`) | only with the `aws` module | `initialize.sh aws` warns in advance. Run `aws login` on the host |
| `~/.gnupg/private-keys-v1.d/` (`DCC_GNUPG_DIR`), `gpg` command | only with the `gpg` module | `initialize.sh gpg` warns. If only the `gpg` command is missing, it works without signing |
| `devcontainer` CLI / VS Code Dev Containers | only when referencing the compose files from devcontainer ([devcontainer.md](devcontainer.md)) | not needed for `dcc` |

### Directories that must be prepared

These are gitignored directories under the repository; users prepare **only those for the modules they use**.

| Directory | Contents | Preparation |
|---|---|---|
| `capabilities/ssh/data/` (`DCC_SSH_DIR`) | container-only SSH private key `id_ed25519`. Connection settings and host keys are tracked and need no preparation | Setup in [ssh.md](ssh.md) |
| `capabilities/gpg/gnupg-host/` (`DCC_GPG_EXPORT_DIR`) | export of the host's public key and signing key information | none (`initialize.sh gpg` generates it every time) |
| `.env`, `local/` | above | optional. Without them it runs with the defaults and the base image / compose only |

### When a bind source is missing

When a bind source does not exist on the host, the behavior depends on the docker compose version and the Docker runtime:
either `up` fails with an error, or **an empty directory is created automatically** (owned by root on some runtimes).
In the latter case a directory appears at a path where a file is expected (`~/.gitconfig`, `~/.claude.json`, `~/.aws/config`),
which causes trouble later if left unnoticed. `lifecycle_hooks/initialize.sh` checks the sources of the selected modules in advance
and warns, so if you see a warning, create the real file first.

## Host OS dependencies

| Location | Dependency | Notes |
|---|---|---|
| `sha256_prefix` in `dcc` | `shasum` on macOS / `sha256sum` on Linux | both supported |
| Design rationale in [gpg.md](gpg.md) / [ssh.md](ssh.md) | macOS gpg-agent / ssh-agent sockets do not cross the VM; host gpg uses keyboxd | works with the same design on Linux hosts, but part of the rationale is macOS-specific |
| Keychain in [claude-code.md](claude-code.md) / [mcp.md](mcp.md) | Claude Code on macOS stores the token in the Keychain | on Linux hosts it is in `~/.claude/.credentials.json` and is shared with the container when the `claude` module is enabled |
| `HOST_HOME` symlink in [claude-code.md](claude-code.md) | the host home is `/Users/<user>` (macOS) or `/home/<user>` (Linux) | taken from `$HOME`, so OS-independent |
| uid mismatch ([git.md](git.md)) | on macOS the VM's file sharing maps uids | on a Linux host with uid ≠ 1000, writes to bound files can fail. Match `DCC_UID` / `DCC_GID` (and use a different tag for `DCC_IMAGE`) |

## Before publishing a fork

`.env`, `local/`, `capabilities/{ssh,gh}/data/`, `capabilities/gpg/gnupg-host/`, and `.claude/` are gitignored, but
if you publish a fork, confirm that no secrets are in the tracked files or the history.

```bash
# Directories containing secrets are not tracked (output is empty)
git ls-files capabilities/ssh/data capabilities/gh/data capabilities/gpg/gnupg-host .claude local .env

# They were not accidentally added in past commits (output is empty)
git log --all --diff-filter=A --name-only --format= | sort -u \
  | grep -E '^(\.env$|local/|\.claude/|capabilities/(ssh|gh)/data/|capabilities/gpg/gnupg-host/)'
```

If they were in the history, the safe course is to revoke those keys / tokens and then squash into a new repository.
