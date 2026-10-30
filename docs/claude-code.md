# Claude Code settings and state

**Module name: `claude`** — the host's `~/.claude` is shared only when `dcc --creds claude` is given ([credentials.md](credentials.md)).
Without it Claude Code still works, but in an empty environment unrelated to the host's settings, history, and authentication (see below).

## What it protects

| Asset | Location | Nature |
|---|---|---|
| `~/.claude/.credentials.json` | host (Linux) / container | OAuth tokens for Claude Code itself and MCP servers. A macOS host uses the Keychain, so this file is written by the container side |
| `~/.claude/settings.json` | host | permissions, hooks, env. **If rewritten, Claude Code's own permissions change** |
| `~/.claude/projects/` | host | Session history and memory (conversation contents) |
| `~/.claude/plugins/`, `skills/`, `commands/`, `agents/` | host | User definitions |
| `~/.claude.json` | host | Global state (onboarding, MCP server settings, project list; may include old-format credentials) |

## Boundary

| Axis | Module enabled (shared with the host) | Module disabled (empty volume) |
|---|---|---|
| What it can do | Claude Code in the container runs with the same settings, history, and plugins as the host, and **can rewrite them**. Only `~/.claude.json` is a container-local copy | Runs with Claude Code's default settings. Sees nothing of the host's and can change nothing |
| Reach | `~/.claude` is **shared rw** with the host. `~/.claude.json` is passed ro and copied by postCreate | Does not reach the host's `~/.claude` / `~/.claude.json`. `~/.claude` is a volume shared across all workspaces |
| How the key is passed | Authentication for Claude Code itself and MCP is done inside the container, and the result stays in the shared `.credentials.json` in **plaintext**. The host's Keychain is not passed | Likewise authenticated inside the container; the result stays in the volume. Nothing flows back to the host |

## What leaks on compromise

If the agent container is taken over:

- **Module enabled**: everything under `~/.claude` can be read and written. **This is the biggest hole in this setup**, and the following can happen:
  - Rewrite `settings.json` to loosen permissions or plant hooks (affects the host's Claude Code too)
  - Exfiltrate the tokens in `.credentials.json` (those obtained in the container)
  - Read session history (conversation contents)
- **Module disabled**: only the tokens in the volume (those obtained in the container) and the container-side history can be exfiltrated. Nothing of the host's is there
- In either case, the host's Keychain (the host Claude Code's token) is unreachable

## Why this design

- **Default to not sharing; sharing is chosen via the module**: consistent with other secrets, "not passed unless explicitly requested". Whether to share is a judgment of "is it acceptable for the container to change the host Claude Code's permissions", and it can differ per workspace
- **rw when shared**: to reuse credentials across `dcc recreate` and workspaces (the Keychain is not passed, so one `/login` inside the container persists in the shared `.credentials.json`). To keep settings, plugins, and skills the same as the host, and to keep the container-side session history in the host's `~/.claude` (though history is keyed by path, so the `--resume` lists differ between host and container; see "Constraints and known holes" below). Claude Code writes frequently under `~/.claude` at startup, so it does not work ro
- **Empty fixed-name volume when not shared**: no mechanism is built to bring settings in partially. Binding the host's `~/.claude` ro would also expose history and tokens, and exporting and injecting would bring secrets written in `env` of `settings.json` into the container. Bringing nothing in keeps the boundary simple; any settings the container needs can be created inside the container
- **The volume is a fixed-name external one**: if container-local, `dcc recreate` would erase the token and require logging in each time. compose volumes are prefixed with the project name, so a login would be needed per workspace. A fixed-name (`dcc-claude-home`) external volume means one login covers all workspaces, and `dcc clear --volumes` does not delete it
- **Do not carve out just the token**: single-file binding `.credentials.json` runs into the EXDEV problem, and copying it invalidates the host side when the refresh token rotates. The container holds its authentication independently
- **Do not single-file bind `~/.claude.json`**: Claude Code writes this file atomically (writes a temp file, then `rename`). A single-file bind is a mount point, so `rename` fails as cross-device (EXDEV) and the settings break. It is passed ro as `.host` and copied by postCreate
- **Do not pass the Keychain**: the container is Linux and has no Keychain, and Claude Code has no means to export from it. Keeping separate token lineages for host and container is the cleaner boundary, and the container side can be revoked independently ([mcp.md](mcp.md))
- **Mark the workspace as trusted**: trust approval is recorded in `~/.claude.json` (container-local), so it is lost on every `dcc recreate` and the prompt reappears. A workspace placed into the container is regarded as one the user has decided to open, and postCreate sets `projects["/workspaces/<basename>"].hasTrustDialogAccepted`
- **Resolve host absolute paths via a symlink**: `plugins/installed_plugins.json` etc. contain the host's absolute paths at install time (`/Users/<user>/...`), which cannot be resolved under the container's `$HOME`. postCreate creates a `HOST_HOME → $HOME` symlink. The only side effect is that `/Users/<user>` appears in the container

## How it works

### Module enabled (`capabilities/claude/compose.yml`)

| Host side | Container side | Mode | Contents |
|---|---|---|---|
| `~/.claude/` (`DCC_CLAUDE_DIR`) | `/home/agent/.claude/` | **rw** | Session history, settings, plugins, skills, credentials |
| `~/.claude.json` (`DCC_CLAUDE_JSON`) | `/home/agent/.claude.json.host` | ro | Copied to `~/.claude.json` by postCreate |

A bind overrides the base volume at the same target `/home/agent/.claude` (for the same target, the later compose file wins).

`~/.claude.json` is container-local and inherits the host's state at creation time (onboarding completed, MCP server settings, theme). Later updates on the host are not reflected in an existing container (`dcc recreate`). MCP servers added inside the container (user / local scope) do not flow back to the host ([mcp.md](mcp.md)).

### Module disabled (base)

| Host side | Container side | Mode | Contents |
|---|---|---|---|
| volume `dcc-claude-home` (`DCC_CLAUDE_HOME_VOLUME`; external, shared across all workspaces) | `/home/agent/.claude/` | rw | Starts empty. Credentials and history stay here |

`dcc up` creates the volume if missing (it is external, so compose does not create it; from devcontainer, `docker volume create dcc-claude-home`). Ownership is inherited from the image's `~/.claude` (owned by the container user) on first mount, and postCreate only checks it and runs `chmod 700`. `~/.claude.json` is also created by Claude Code on first run (onboarding appears).

### Where the `claude` binary is installed

The Dockerfile verifies `install.sh` against sha256 and then runs it as the container user (version is `CLAUDE_CODE_VERSION`; [architecture.md](architecture.md)), placing it at `~/.local/bin/claude`. Claude Code's auto-update and `claude doctor` treat this location as a "managed install", so placing it in `/usr/local/bin` as root produces a "missing or broken" warning.

Both the binary (`~/.local/share/claude/versions/<ver>`) and the `~/.local/bin/claude` symlink are authoritative as baked into the image, and are not volumes. The results of auto-update and postCreate's `claude update` remain in the container layer, and `dcc recreate` reverts to the baked-in version (postCreate then updates it again; the difference is just one download). Putting only the binary in a named volume is not adopted. A volume is seeded only the first time, so when the image is rebuilt with a newer bundled version, the symlink outside the volume points to something not in the volume, and `claude` can no longer run (`executable file not found in $PATH`). Not keeping the same thing in two places, image and volume, eliminates this mismatch.

### Environment variables for personal tools

`dcc` does not add its own environment variables when launching claude. To pass one into the container, use `DCC_CONTAINER_ENV_<NAME>=value`; to set one on the host-side `dcc` process, write a bare `NAME=value` in `.env` ([customization.md](customization.md)).

## Constraints and known holes

- **When the module is enabled, Claude Code in the container can write to the host Claude Code's authentication, settings, and history.** Modifications such as loosening permissions or planting hooks cannot be prevented. Disable it for workspaces where you want to prevent that
- When the module is disabled there are no personal skills, plugins, or `settings.json`, and onboarding and `/login` are needed the first time (once per volume). The host's history does not appear in `--resume`. To have container-specific settings, bind only the needed files with `local/compose.yml`
- Keys in `projects/` are the workspace's absolute path. On the host it is `/Users/<user>/src/foo`, in the container `/workspaces/foo`, so even when shared, history for the same workspace is stored under different keys (sessions from the other side do not appear in `--resume`)
- If paths in `settings.json` (hook command paths, etc.) are host-specific, they do not work in the container
- Running Claude Code on the host and in the container at the same time may cause write conflicts on `settings.json` etc. when shared
- The workspace always starts as trusted, so the repository's `.claude/settings.json` (hooks, permissions) and `.mcp.json` take effect without confirmation. When opening an unfamiliar repository, review its contents on the host first. When the module is enabled, those hooks can write to the `~/.claude` shared with the host
- `~/.claude.json` may also contain credentials (old-format `oauthAccount`, etc.). When shared, it is passed to the container, albeit ro
