# Boundaries with the host

An overview of what is shared between the host (the developer's machine) and the containers, in which direction, and with what permissions.
For individual boundaries, see each page ([github.md](github.md), etc.). Each page has the same structure
(What it protects / Boundary / What leaks on compromise / Why this design / How it works / Constraints and known holes) ([README.md](README.md)).

## Assumptions

The agent container is where the agent (Claude Code / Codex CLI) may run arbitrary code, so boundaries are drawn **assuming it may be compromised**.
Instructions planted in a web page or document it read may make it try to exfiltrate credentials.
So rather than deciding "what to allow", we decide "what the agent container cannot reach".

Boundaries are considered along 3 axes:

| Axis | Question | How this design handles it |
|---|---|---|
| **What it can do** | Which operations are allowed | Mainly the domain of the agent's own settings (permissions / hooks in Claude Code's `settings.json`, Codex's approval policy), not handled by this repository. With delegated execution (gpg / aws / gh), achieved by narrowing the operations the sidecar accepts |
| **What it can reach** | Which files and resources it can reach | Bind only what was chosen into the agent container, ro wherever possible. Do not put privileges (Docker sidecar) and secrets in the same container. Show inner containers only the workspace |
| **How the key is passed** | How credentials are passed | Delegated execution where possible (the agent container never receives the key). Otherwise create a container-only key with narrowed permissions and pass it in plaintext. Never bring long-lived keys into the container |

## Design principles

1. **Pass only the secrets you choose.** `aws` / `gpg` / `ssh` / `gh` / `claude` / `codex` are modules and are not mounted unless named explicitly with `dcc --creds` ([credentials.md](credentials.md))
2. **Never put privileges and secrets together.** No secrets at all are passed to the Docker sidecar, which has `privileged: true`. Secrets go only to the agent container or to unprivileged module sidecars such as `aws-credentials` / `gpg-signer` / `gh-token`. The agent container is unprivileged (user `agent` uid 1000; no sudo, `no-new-privileges`, `cap_drop: ALL`)
3. **The sidecar, not the agent container, fetches the key.** Signing (gpg), AWS, and GitHub (gh) use delegated execution; the agent container receives only signatures and expiring temporary credentials / access tokens
4. **Never bring long-lived keys into the container.** The host's `~/.ssh`, `~/.aws/credentials`, the private keys in `~/.gnupg`, and tokens in the Keychain are not passed. What is passed is a key created just for the container (`ssh`) or a refresh token held only by the sidecar (`gh`), with narrowed permissions. **The exception is the `codex` module**: when enabled, the host's `~/.codex/auth.json` (Codex's token; a plaintext file) is passed to the container as is. By default it is not passed and you log in separately inside the container ([codex.md](codex.md))
5. **Read-only by default.** Only things that need writes (`~/.claude`, `~/.codex`, the workspace, the `gh-token` sidecar's state volume) are rw
6. **Avoid single-file bind mounts.** A single-file bind pins the file's inode, which breaks two ways. Inside the container, an atomic write (tmp → rename) fails with EXDEV: such files are passed ro as `.host` and copied in postCreate (`~/.claude.json`), or passed as the whole parent directory (`~/.codex/config.toml`). On the host, anything that replaces the file (`git pull` / `git checkout`, an editor's save, `git config --global`) leaves the container on the old, now deleted file (on Docker Desktop it simply vanishes: "No such file or directory") until `dcc recreate`: files of this repository are therefore bound as directories that hold only what the agent container may see (`capabilities/<module>/agent/`, `capabilities/ssh/conf/`). The remaining single-file bind is `~/.gitconfig` ([git.md](git.md))
7. **Do not pass the host's Docker.** `/var/run/docker.sock` is not passed to the container. Docker is provided by a rootless sidecar ([docker.md](docker.md))
8. **Do not pass the macOS Keychain.** Authentication for Claude Code itself and for MCP servers is done inside the container, and the result is kept in `~/.claude/.credentials.json` ([mcp.md](mcp.md))

## Summary by boundary

"How the key is passed", from safest: **delegated execution > injection via a store > plaintext environment variable / file > direct read**.

| Boundary | What it protects | How the key is passed | Upper bound if the agent container is compromised | Details |
|---|---|---|---|---|
| `gpg` | Signing key, passphrase | Delegated execution (the sidecar signs) | Can get commits / tags signed. The key does not leak | [gpg.md](gpg.md) |
| `aws` | Login session, long-lived keys | Delegated execution (the sidecar issues temporary credentials) | Expiring temporary credentials. Long-lived keys do not leak | [aws.md](aws.md) |
| `ssh` | The host's private keys, agent | Plaintext (container-only key bound ro) | The dedicated key leaks. Damage is limited to the key's permissions | [ssh.md](ssh.md) |
| `gh` | The host's token (Keychain), refresh token | Delegated execution (the sidecar issues short-lived access tokens) | An access token that expires in a few hours. The refresh token does not leak | [github.md](github.md) |
| git | gitconfig | Not passed (ro) | Settings can be read. Cannot be rewritten | [git.md](git.md) |
| `claude` | Settings, history, tokens | Authenticated inside the container (kept in plaintext in `~/.claude`) | When enabled: **tampering with the host's settings, exfiltrating tokens and history**. The biggest hole. When disabled: only the tokens and history in the volume | [claude-code.md](claude-code.md) |
| `codex` | Settings, history, token (`auth.json`) | When enabled: **the host's token shared in plaintext as is**. When disabled: authenticated inside the container (kept in the volume) | When enabled: **exfiltrating the host's token, tampering with settings for commands run on the host (`notify` / hooks / MCP)**. Heavier than `claude`. When disabled: only the tokens and history in the volume | [codex.md](codex.md) |
| MCP | Server settings, tokens | Authenticated inside the container (Keychain not passed) | Tokens obtained in the container leak | [mcp.md](mcp.md) |
| Docker | The host's Docker, the host's files | Not passed (provided by the sidecar) | The privileges of uid 1000 inside the sidecar. Nothing outside the workspace is visible | [docker.md](docker.md) |

## Mounts (agent container)

Entries whose "Module" is `always` are in the base compose (`docker-compose.yml`); the rest are added as overlays in
`capabilities/<name>/compose.yml` only when chosen with `dcc --creds <name>`.

| Module | Host side | Container side | Mode | Type | Details |
|---|---|---|---|---|---|
| always | `$LOCAL_WORKSPACE_FOLDER` | `/workspaces/$LOCAL_WORKSPACE_BASENAME` | rw | bind (cached) | The workspace. Bound at the same path in the agent container and the sidecar by `docker-compose.workspace.yml`. Via devcontainer, the workspace-side compose provides it ([devcontainer.md](devcontainer.md)) |
| always | `~/.gitconfig` (`DCC_GITCONFIG`) | `~/.gitconfig` | ro | bind | [git.md](git.md). Personal files it includes are not bound (use `local/compose.yml` if needed) |
| always | volume `dcc-claude-home` (`DCC_CLAUDE_HOME_VOLUME`, external, shared by all workspaces, starts empty) | `~/.claude` | rw | volume | [claude-code.md](claude-code.md). The `claude` module overrides the same target with a bind |
| `claude` | `~/.claude` (`DCC_CLAUDE_DIR`) | `~/.claude` | **rw** | bind | [claude-code.md](claude-code.md) |
| `claude` | `~/.claude.json` (`DCC_CLAUDE_JSON`) | `~/.claude.json.host` | ro | bind | [claude-code.md](claude-code.md). Copied locally in postCreate |
| always | volume `dcc-codex-home` (`DCC_CODEX_HOME_VOLUME`, external, shared by all workspaces, starts empty) | `~/.codex` | rw | volume | [codex.md](codex.md). The `codex` module overrides the same target with a bind |
| `codex` | `~/.codex` (`DCC_CODEX_DIR`) | `~/.codex` | **rw** | bind | [codex.md](codex.md). Contains `auth.json` (token). Passed as a whole directory |
| always | `<repo>/lifecycle_hooks/` | `/usr/local/lib/dcc/hooks` | ro | bind | [architecture.md](architecture.md) |
| always | volume `docker-certs` | `/certs` | ro | volume | [docker.md](docker.md). TLS certificates generated by the sidecar |
| `aws` | None (the `aws-credentials` sidecar issues temporary credentials on `127.0.0.1:8080`) | Only the environment variable `AWS_CONTAINER_CREDENTIALS_FULL_URI` | — | — | [aws.md](aws.md) |
| `gpg` | None (the `gpg-signer` sidecar provides the signing API on `127.0.0.1:8081`) | Only the environment variable `DCC_GPG_SIGN_URI` and the wrapper | — | — | [gpg.md](gpg.md) |
| `gpg` | `<repo>/capabilities/gpg/gnupg-host` | `~/.gnupg-host` | ro | bind | [gpg.md](gpg.md). Exported public keys and ownertrust (for verification) |
| `gpg` | `<repo>/capabilities/gpg/agent/` | `/usr/local/lib/dcc/gpg/` | ro | bind | [gpg.md](gpg.md). The `gpg.program` wrapper only |
| `ssh` | `<repo>/capabilities/ssh/data` | `~/.ssh` | ro | bind | [ssh.md](ssh.md). Only the container-only private key |
| `ssh` | `<repo>/capabilities/ssh/conf/` (`DCC_SSH_CONF_DIR`) | `/etc/ssh/dcc/` | ro | bind | [ssh.md](ssh.md). `github.conf` + `known_hosts`, tracked in git. Included from the image's `ssh_config.d` |
| `gh` | None (the `gh-token` sidecar issues access tokens on `127.0.0.1:8082`) | Only the environment variables `DCC_GH_TOKEN_URI` / `DCC_GH_HOST` | — | — | [github.md](github.md) |
| `gh` | `<repo>/capabilities/gh/agent/` | `/usr/local/lib/dcc/gh/` (first on the image's `PATH`) | ro | bind | [github.md](github.md). `gh-token-client.sh` (git credential helper) and `gh`, a symlink to it (the `gh` wrapper) |

`<repo>` is this repository. In compose files it is written as absolute paths based on `${DCC_CONFIG_DIR}`, and host-side paths can be changed with `DCC_*` environment variables ([customization.md](customization.md)).

## Mounts (sidecars)

Nothing under the host's `$HOME` is passed to the Docker sidecar (`privileged`). The only host files visible from inner containers are **the workspace**.

| Host side | Container side | Mode | Type |
|---|---|---|---|
| `$LOCAL_WORKSPACE_FOLDER` | `/workspaces/$LOCAL_WORKSPACE_BASENAME` | rw | bind |
| volume `docker-certs` | `/certs` | rw | volume |
| volume `docker-data` | `/home/rootless/.local/share/docker` | rw | volume |
| (none) | `/var/lib/docker` | rw | tmpfs. Unused by rootless dockerd; mapped only so the image's `VOLUME` does not leave an anonymous volume ([docker.md](docker.md)) |

Module sidecars (unprivileged):

| sidecar | Host side | Container side | Mode |
|---|---|---|---|
| `aws-credentials` | `~/.aws/config`, `~/.aws/login/cache` | `/root/.aws/config`, `/root/.aws/login/cache` | ro |
| `gpg-signer` | `~/.gnupg/private-keys-v1.d`, `<repo>/capabilities/gpg/gnupg-host` | `/host-keys`, `/gnupg-host` | ro |
| `gh-token` | volume `dcc-gh-home` (`DCC_GH_HOME_VOLUME`, external, shared by all workspaces; written by `dcc gh-login`) | `/home/gh/.config/gh` | rw |

## Direction: what flows back to the host and what does not

| Target | Are changes inside the container reflected on the host? |
|---|---|
| Workspace | **Yes** (same bind) |
| `~/.claude` (session history, plugins, settings, OAuth tokens obtained in the container) | **Yes** when `claude` is enabled (the token is not referenced by the host's Claude Code). No when disabled (contained in the volume) |
| `~/.claude.json` | No (a container-local copy) |
| `~/.codex` (settings, authentication, session history) | **Yes** when `codex` is enabled (both setting changes and token refreshes take effect directly in the host's Codex). No when disabled (contained in the volume) |
| `~/.ssh` | No (container-only; separate from the host's) |
| gh authentication state | No (contained in the `dcc-gh-home` volume; separate from the host's gh) |
| `~/.gnupg`, `~/.gitconfig*`, `~/.aws` | No (ro, or not present in the agent container) |
| git's `safe.directory` | No (the system gitconfig inside the container) |
| Docker images and containers | **Do not appear** in the host's Docker. Contained in the sidecar's `docker-data` volume |

## Handling of uids

- The user of the agent container is `agent` (uid 1000; changeable with `DCC_USER` / `DCC_UID`). On macOS hosts, access goes through the VM of Docker Desktop / Rancher Desktop or similar, so files on bind mounts are basically readable and writable from the container
- git rejects owner uid mismatches as `dubious ownership`, so postCreate (root side) registers the workspace in `safe.directory` ([git.md](git.md))
- The sidecar's dockerd also runs as uid 1000. root inside an inner container is root inside the userns, and files on the workspace are written as uid 1000

## Network boundary

- The agent container and the sidecar share a netns. A port published in the sidecar with `-p 3000:80` is reachable at `localhost:3000` in the agent container. It is not reachable from the host (no `ports` in compose)
- Reachability from the agent container to the host (`host.docker.internal`, etc.) depends on the Docker runtime. The configuration does not treat it specially
- Inner containers cannot reach `127.0.0.1` of the parent netns (rootlesskit's `--disable-host-loopback`)
- Module sidecar endpoints (`127.0.0.1:8080` / `8081` / `8082`) are reachable only inside the shared netns. They are not reachable from the host, inner containers, or other compose projects
- **Outbound traffic is not restricted** (below)

## What this design does not protect

The container sets "the upper bound of damage when the agent container is compromised"; it does not prevent the compromise itself. The following are out of scope.

- **Outbound traffic.** Traffic from the agent container and inner containers to the internet is not restricted. The workspace contents, and anything
  obtainable with the credentials passed to the agent container (temporary credentials, repositories readable with the dedicated token, etc.), can be sent out.
  If you want to restrict it, do so in the Docker runtime or the host-side network
- **The workspace.** It is an rw bind, so operations inside the container are reflected directly in the host's files. Secrets inside the workspace
  (`.env`, etc.) are readable from the agent container. Note also that files executed on the host (git hooks, build scripts, editor settings) can be
  rewritten. Writes are done as the container user (uid `DCC_UID`, default 1000), and on Linux hosts
  the files end up owned by that uid (it cannot write as root; see "Privileges inside the agent container" below)
- **When this repository itself (`DCC_CONFIG_DIR`) is used as the workspace.** `dcc` / `lib/*.sh` / `.env` (sourced as bash) /
  `lifecycle_hooks/initialize.sh` / `capabilities/gpg/*.sh` run on the host, and `capabilities/*/Dockerfile` and `server.py` become
  the images of sidecars holding secrets. While these are visible to the container as an rw workspace, changes written by the agent container
  run on the host and inside the sidecars on the next `dcc` run. In other words, there is no boundary. If you edit this repository inside `dcc`,
  use `--no-creds`, and look at `git diff` on the host before running `dcc`. Do not open it with modules enabled
- **Use of the credentials passed to the agent container.** Even with delegated execution, the agent container is free to "get things signed" and "get temporary credentials".
  The dedicated key (`ssh`) and unexpired access tokens (`gh`) can be read. The upper bound of damage is as stated in "What leaks on compromise" on each page
- **Privileges inside the agent container.** The container user (`agent`) cannot become root (no sudo, `no-new-privileges` disables setuid / file
  capabilities, and `cap_drop: ALL` leaves even root without capabilities). Post-creation processing that needs root is run by `dcc` as
  `postCreate-root.sh` via `compose exec --user root`. Even so, the boundary is drawn at the container's outer frame (unprivileged, no host Docker socket, only the chosen mounts),
  and files inside the container (`/etc`, the image contents) are protected only to the extent of the agent's user privileges
- **The agents' permission settings.** Claude Code's permissions / hooks / sandbox and Codex's approval policy are the user's settings and are not handled by this repository.
  The only exception: **`dcc` turns off Codex's own sandbox by default** (it often does not work inside a container, and even when it does it cuts off traffic to the sidecar; [codex.md](codex.md))
