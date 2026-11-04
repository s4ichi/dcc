# Codex CLI settings and state

**Module name: `codex`** — the host's `~/.codex` is shared only when `dcc --creds codex` is given ([credentials.md](credentials.md)).
The Codex CLI itself is always in the agent image and runs with `dcc --agent codex` even without the module. In that case it is an empty environment
unrelated to the host's settings, history, and authentication (see below). The same topic for Claude Code is in [claude-code.md](claude-code.md).

Statements about Codex's behavior on this page are based on the official documentation and source as of Codex CLI 0.154.0.
**Points not yet confirmed on a real machine are collected under "Unverified assumptions".**

## What it protects

| Asset | Location | Nature |
|---|---|---|
| `~/.codex/auth.json` | host / container | ChatGPT login token (including a refresh token) or API key. **Plaintext**. The default store is this file regardless of OS; even on macOS it is not the Keychain (`cli_auth_credentials_store = "file"` is the default) |
| `~/.codex/config.toml` | host | Model, sandbox / approval settings, MCP servers, `notify`. **If rewritten, the commands executed when Codex runs on the host change** |
| `~/.codex/hooks.json`, `rules/` | host | Lifecycle hooks, and rules for commands allowed to run outside the sandbox |
| `~/.codex/.credentials.json` | host / container | OAuth tokens for MCP servers (the store used when no keyring is available; the container has no keyring) |
| `~/.codex/sessions/`, `history.jsonl` | host | Session history (conversation contents) |
| `~/.codex/AGENTS.md` | host | Instructions common to all projects |

## Boundary

| Axis | Module enabled (shared with the host) | Module disabled (empty volume) |
|---|---|---|
| What it can do | Codex in the container runs with the same settings, history, and authentication as the host, and **can rewrite them** | Runs with Codex's default settings. Sees nothing of the host's and can change nothing |
| Reach | `~/.codex` is **shared rw** with the host (as a directory) | Does not reach the host's `~/.codex`. `~/.codex` is a volume shared across all workspaces |
| How the key is passed | **The host's token is shared as is** (`auth.json` is a plaintext file). No login is needed inside the container | Authenticated inside the container; the result stays in the volume. Nothing flows back to the host |

## What leaks on compromise

If the agent container is taken over:

- **Module enabled**: everything under `~/.codex` can be read and written. The same kind of hole as the `claude` module in [claude-code.md](claude-code.md), but **one step worse**:
  - **The host Codex's token can be exfiltrated.** Claude Code's token (macOS) lives in the Keychain and is not passed to the container, but Codex's `auth.json` is
    a plaintext file by default, so sharing it hands the host's login itself to the container
  - `notify` in `config.toml`, `hooks.json`, and `command` in `[mcp_servers.*]` can be rewritten. All of these are settings with which Codex launches external commands, so
    **the next time Codex starts on the host, the attacker's command runs on the host** (a path out of the container to the host)
  - Sandbox / approval settings (`sandbox_mode`, `approval_policy`, `rules/`) can be loosened. This affects the host's Codex too
  - Session history (conversation contents) can be read
- **Module disabled**: only the tokens in the volume (those obtained in the container) and the container-side history can be exfiltrated. Nothing of the host's is there, and the host's settings cannot be changed
- In either case, Codex's own sandbox is disabled by default (see below), so commands Codex runs execute with the agent container's privileges as is.
  The upper bound of damage is set by the container's outer frame ([boundaries.md](boundaries.md))

## Why this design

- **Symmetric with `~/.claude`**: default to not sharing; sharing is chosen via the module. Whether to share is a judgment of "is it acceptable for the container to
  read and write the host Codex's authentication and settings", and it can differ per workspace. As shown above, the cost of sharing is higher than with the `claude` module, so enable it only in workspaces that need it
- **Pass as a directory, not as files**: Codex rewrites `config.toml` via a temp file + `rename` (this happens routinely: project trust decisions, `/model`,
  `codex mcp add`, etc.). A single-file bind is a mount point, so `rename` fails. No finer-grained splitting such as passing only `auth.json` or passing only `config.toml` ro
- **Empty fixed-name volume when not shared**: if container-local, `dcc recreate` would erase the token and require logging in each time. compose volumes are
  prefixed with the project name, so a login would be needed per workspace. A fixed-name (`dcc-codex-home`) external volume means one login covers all workspaces,
  and `dcc clear --volumes` does not delete it
- **Disable Codex's own sandbox by default**: Codex's Linux sandbox is bubblewrap, which requires creating an unprivileged user namespace. Inside an unprivileged container this
  is often not allowed. In addition, the default `workspace-write` isolates the network of executed commands, so they can reach neither the Docker sidecar over TCP
  (`DOCKER_HOST=tcp://docker:2376`) nor the `aws` / `gpg` module sidecars (`127.0.0.1`). This repository
  **treats the container as the sandbox**, and `dcc` passes `-c sandbox_mode=danger-full-access`. With this setting Codex does not use bubblewrap
- **Do not touch the approval policy**: when to ask for confirmation is the user's preference, to be decided in `config.toml` or by arguments. `dcc` only disables "things that
  do not work inside the container, or that would make the sidecars unusable if they did"
- **Pass via `-c`, not `--sandbox`**: `-c key=value` overrides `config.toml` and has lower priority than the dedicated argument. Even if the user stacks
  something like `dcc exec --agent codex -- --sandbox workspace-write`, the same argument is not duplicated
- **Bake it into the image instead of using the official install.sh**: install.sh rewrites the shell profile and puts the binary under `~/.codex/packages/`. `~/.codex`
  becomes a volume / host bind, so placing the binary there would diverge from the image (the same reason Claude Code's binary is not put in a volume in [claude-code.md](claude-code.md)).
  `codex-package-<target>.tar.gz` (bundling `bwrap` and `rg` in addition to `codex`) from GitHub Releases (tag `CODEX_VERSION`) is extracted to `/opt/codex` and verified with the same release's
  `codex-package_SHA256SUMS`. Node.js is not needed
- **Disable the update check at startup**: the binary lives in root-owned `/opt/codex`, and self-update from inside the container is not intended. Updates are done by rebuilding the image

## How it works

### Module enabled (`capabilities/codex/compose.yml`)

| Host side | Container side | Mode | Contents |
|---|---|---|---|
| `~/.codex/` (`DCC_CODEX_DIR`) | `/home/agent/.codex/` | **rw** | Settings, credentials, session history, MCP tokens |

A bind overrides the base volume at the same target `/home/agent/.codex` (for the same target, the later compose file wins). `initialize.sh codex` warns in advance if the host-side
directory is missing.

### Module disabled (base)

| Host side | Container side | Mode | Contents |
|---|---|---|---|
| volume `dcc-codex-home` (`DCC_CODEX_HOME_VOLUME`; external, shared across all workspaces) | `/home/agent/.codex/` | rw | Starts empty. Credentials and history stay here |

`dcc up` creates the volume if missing (it is external, so compose does not create it; from devcontainer, `docker volume create dcc-codex-home`).
Since the base compose references it, **this volume is created even if you do not use Codex** (it stays empty). Ownership is inherited from the image's `~/.codex` (owned by the container user) on first mount, and postCreate only checks it and runs `chmod 700`.

### Launch and default arguments

```bash
dcc --agent codex                       # up + launch codex
dcc exec --agent codex -- resume --all  # everything after `--` goes to codex
export DCC_AGENT=codex                  # make codex the default agent
```

`claude` and `codex` live in the same container, and which one to launch is chosen per invocation. At launch, `dcc` prepends the following to the user's arguments.

| Variable | Default | Contents |
|---|---|---|
| `DCC_CODEX_ARGS` | `-c sandbox_mode=danger-full-access -c check_for_update_on_startup=false` | Leading arguments for `codex` |
| `DCC_CLAUDE_ARGS` | empty | Leading arguments for `claude` |

Values are only split on whitespace; quoting is not interpreted. **Setting an empty string adds nothing** (`DCC_CODEX_ARGS=`). To use Codex's sandbox,
set it empty, then confirm that bubblewrap works in the container and that sidecars are unreachable unless `[sandbox_workspace_write] network_access = true` is set.

### Login (when the module is disabled)

For browser login, Codex waits for the callback on `127.0.0.1:1455` **inside the container**. The agent container does not publish ports to the host
([docker.md](docker.md)), so the host's browser cannot reach it. Use one of the following.

- **device code**: run `codex login --device-auth` in the container. Open the displayed URL in the host's browser and enter the code. This is a beta feature, and
  device code login must be enabled on the ChatGPT side (security settings for individuals, admin permission settings for workspaces)
- **API key**: run `printenv OPENAI_API_KEY | codex login --with-api-key` in the container (the key is read from stdin)

Either way the result stays in `~/.codex/auth.json` (the volume) and is reused across `dcc recreate` and all workspaces. Check with `codex login status`; remove with `codex logout`.

When the module is enabled, the host's `auth.json` is used as is, so no login is needed. Token renewal (Codex refreshes when expiry is near and writes back to `auth.json`)
operates on the same file for host and container. Since it is not a copy, there is no "an update on one side invalidates the other" problem, but
running Codex on the host and in the container at the same time may cause write conflicts.

### MCP servers

Configure with `[mcp_servers.<name>]` in `config.toml`, or `codex mcp add`. For OAuth of remote servers use `codex mcp login <name> --no-browser`
(it shows the authorization URL, and after authorizing in the browser you paste the redirected URL; the callback port does not need to be published to the host).
In a container without a keyring, the token stays in `~/.codex/.credentials.json` in plaintext. The requirement that a stdio server's command exist **inside the container** is
the same as in "stdio servers" in [mcp.md](mcp.md).

### Environment variables

By default Codex passes all of the parent process's environment variables to the commands it runs (`shell_environment_policy.inherit = "all"`; excluding variables whose names contain `KEY` / `SECRET` /
`TOKEN` is disabled by default). Therefore `DOCKER_HOST` / `DOCKER_CERT_PATH` / `DOCKER_TLS_VERIFY` set by compose on the agent container,
`GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` from the `gpg` module, and `AWS_CONTAINER_CREDENTIALS_FULL_URI` from the `aws` module are
visible as is to the `docker` / `git` / `aws` that Codex runs. Setting `inherit = "core"` or `ignore_default_excludes = false` in `config.toml`
drops them (with the latter, `GIT_CONFIG_KEY_0` matches `*KEY*`), so take care if your shared `config.toml` does that.

## Unverified assumptions

The following are inferences from the official documentation and source and **have not actually been run and confirmed on this repository's image.** Confirm them on the host after `dcc build`.

| Assumption | How to check | If it turns out wrong |
|---|---|---|
| `codex` accepts `-c key=value` (`--config`), and `-c sandbox_mode=danger-full-access` disables the sandbox | `docker run --rm dcc:local codex --help` lists `-c, --config`. Launch with `dcc --agent codex` and `/status` shows the sandbox as `danger-full-access` | Set `DCC_CODEX_ARGS="--sandbox danger-full-access"` (the existence of `--sandbox` is confirmed in the source; if the user stacks `--sandbox`, arguments may be duplicated) |
| In an unprivileged container bubblewrap cannot create a user namespace (one rationale for the default of disabling the sandbox) | `docker run --rm dcc:local /opt/codex/codex-resources/bwrap --unshare-user true; echo $?` is non-zero and prints something like `No permissions to create new namespace` | In an environment where it works, Codex's sandbox can be used alongside. However, `workspace-write` still cuts the network, so this is no reason to change the default |
| `codex-package-<target>.tar.gz` contains `bin/codex` / `codex-resources/` / `codex-path/`, and `codex-package_SHA256SUMS` is in `sha256sum -c` format | The Codex layer of `dcc build` succeeds (if the format differs, the build fails there) | Adjust Layer 11 of the `Dockerfile` to the actual layout |

## Constraints and known holes

- **When the module is enabled, the host Codex's token is passed to the container in plaintext, and the settings for commands executed on the host (`notify` / hooks / MCP) can be
  written from inside the container.** Disable it for workspaces where you want to prevent that
- Codex's own sandbox is disabled by default. The only things stopping commands Codex runs are the approval policy (the user's setting) and the container's outer frame
- Global skills (`~/.agents/skills`) are outside `~/.codex`, so they are not passed even with the module enabled. Bind them with `local/compose.yml` if needed
  ([customization.md](customization.md))
- `codex resume` / `codex fork` by default target only sessions with the same working directory. On the host it is `/Users/<user>/src/foo`, in the container
  `/workspaces/foo`, so even when shared, sessions from the other side do not appear in the default list (they do with `--all`)
- Whether a project is trusted is also recorded by path in `config.toml`. The container path differs from the host's, so the container side asks again
- The version is pinned by `CODEX_VERSION` (a release tag) in the `Dockerfile`. Renovate opens the bump PR ([architecture.md](architecture.md#dependency-updates)); after it is merged, `dcc build` → `dcc recreate`.
  The update notification at startup is turned off by the default arguments
- `/opt/codex` is about 260 MB and is included in the image even if you do not use Codex
- Running multiple `dcc exec --agent codex` in the same container at once shares Codex's shared background server. To isolate them, use `--no-daemon`
- Codex sends usage metrics by default. To stop it, set `[analytics] enabled = false` in `config.toml`
