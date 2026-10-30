# git configuration

Always mounted (passed regardless of module selection).

## What it protects

| Asset | Location | Nature |
|---|---|---|
| `~/.gitconfig` (and its include targets) | host | Identity (`user.name` / `user.email`), signing settings, aliases. If rewritten, the behavior of git on the host changes |
| The host's credential helper (`osxkeychain`, etc.) | host | HTTPS credentials in the Keychain |

## Boundary

| Axis | This design |
|---|---|
| What it can do | The agent container's git runs with the host's identity and settings. Global settings cannot be changed (ro). Container-specific settings can only be written to system (`/etc/gitconfig`) |
| Reach | `~/.gitconfig` is bound ro. Personal include-target files are not passed in base. The credential helper stays host-dependent (absent in the container) |
| How the key is passed | No key is passed at this boundary. Signing is left to [gpg.md](gpg.md), push authentication to [ssh.md](ssh.md) / [github.md](github.md) |

## What leaks on compromise

If the agent container is taken over:

- The contents of `~/.gitconfig` (identity, aliases, include paths) are readable. They normally contain no secrets
- The host's gitconfig cannot be rewritten (ro). `git config --global` fails inside the container
- Signing and push permissions follow each module's boundary

## Why this design

- **Bind ro**: the goal is for the agent container's git to run with the same identity as the host; there is no need to write back. With rw, Claude could rewrite aliases or hook paths and affect the host
- **Do not pass include targets in base**: splits like `~/.gitconfig.local` depend on the personal environment, and if absent the bind fails. git ignores nonexistent includes, so nothing breaks if they are not passed. Bind them with `local/compose.yml` if needed ([customization.md](customization.md))
- **Write container-specific settings to system**: since `~/.gitconfig` is ro, `safe.directory` and the `gpg.program` fallback are written to `/etc/gitconfig` (container-local, never flows back to the host). This assumes the global config does not define `safe.directory`, so there is no conflict

## How it works

| Host side | Container side | Mode |
|---|---|---|
| `~/.gitconfig` (`DCC_GITCONFIG`) | `/home/agent/.gitconfig` | ro |

- **`safe.directory`**: the bound workspace appears with the host uid, and if it does not match the container user, git refuses every operation with `dubious ownership`. postCreate (the root-side `postCreate-root.sh`) runs `git config --system --add safe.directory "$(pwd)"` (cwd is the workspace; the agent container has no sudo, so `dcc` calls it as root)
- **Signing**: `user.signingkey` / `commit.gpgsign` follow the host's `~/.gitconfig*`. Only `gpg.program` is pinned to the wrapper for the sidecar by compose's `GIT_CONFIG_*` environment variables (highest-priority layer) when the `gpg` module is enabled, so whatever the host's `~/.gitconfig` says has no effect ([gpg.md](gpg.md))
- **`GOPRIVATE`**: pass it to the container with `DCC_CONTAINER_ENV_GOPRIVATE` if needed ([customization.md](customization.md)). Private modules are fetched with git (SSH, or HTTPS + token)

## Constraints and known holes

- Other repositories under the workspace (submodules, separate `.git` in a monorepo) are not registered in `safe.directory`. Inside the container you cannot become root, so the system gitconfig cannot be written. Pass it each time with `git -c safe.directory=<path> …`, or register it from the host with `docker compose -p <project> exec --user root agent git config --system --add safe.directory '*'` (`<project>` from `dcc list`)
- If the host's `~/.gitconfig` has `credential.helper = osxkeychain`, the helper is not found inside the container and a warning is printed (not fatal). To push over HTTPS, enable the `gh` module (postCreate registers in system a credential helper that returns the gh-token sidecar's short-lived token, and it is queried first; [github.md](github.md))
- With SSH signing (`gpg.format = ssh`), if `user.signingkey` points to the host's `~/.ssh/...`, that file does not exist in the container. Override it in the system gitconfig to point to the key from [ssh.md](ssh.md)
- To use a container-specific identity, override it in the system gitconfig or in the workspace's `.git/config`
