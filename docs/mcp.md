# MCP servers (Claude Code)

This page is about Claude Code's MCP. For Codex CLI's MCP (`[mcp_servers]` in `config.toml`, `codex mcp login --no-browser`), see [codex.md](codex.md).

It works regardless of module selection, but it rests on `~/.claude` / `~/.claude.json` ([claude-code.md](claude-code.md)) and the workspace, so whether the `claude` module is enabled changes "whether the host's settings are visible" and "where tokens stay". Below, "shared" means the `claude` module is enabled (the host's `~/.claude` is shared rw), and "not shared" means it is disabled (the volume `dcc-claude-home`, shared across all workspaces).

MCP servers keep "which servers to connect to (settings)" and "credentials for those servers (OAuth tokens)" in separate places, and they reach the container differently.

## What it protects

| Asset | Location | Nature |
|---|---|---|
| The host Claude Code's OAuth tokens (Claude Code's own `claudeAiOauth` and MCP's `mcpOAuth`) | macOS Keychain (item `Claude Code-credentials`) | All tokens are in a single blob |
| OAuth tokens obtained in the container | `~/.claude/.credentials.json` (mode 600) | Plaintext. Placed on the host's disk when shared, in the volume when not shared |
| MCP server settings | `~/.claude.json` (user / local scope), `<workspace>/.mcp.json` (project scope) | Become secrets if API keys are written directly in `headers` or `env` |

## Boundary

| Axis | This design |
|---|---|
| What it can do | Claude Code in the container can use the workspace's `.mcp.json` (project scope) and, when shared, the servers configured on the host (user scope). Authentication for remote servers is done inside the container. stdio servers work only if their command exists in the container |
| Reach | Settings are passed by copy (user; only when shared) / bind (project). The host's Keychain is not passed. stdio servers can touch only what is inside the container and what credential modules pass |
| How the key is passed | **Authenticate and obtain inside the container**. The host's tokens are not bridged; the container holds a separate lineage of tokens. Obtained tokens stay in `~/.claude/.credentials.json` and are reused across recreate and workspaces |

## What leaks on compromise

If the agent container is taken over:

- MCP tokens obtained in the container (and Claude Code's own token) can be exfiltrated from `~/.claude/.credentials.json`. Stop them with `claude mcp logout <name>` / revocation on each IdP
- The tokens in the host's Keychain are unreachable
- API keys written directly in `.mcp.json` can be read (use `${VAR}` instead)

## Why this design

- **Do not pass the Keychain**: the container is Linux and has no Keychain, and Claude Code has neither a means to export the Keychain contents nor a setting on macOS to switch to file storage. Bridging would require custom processing that extracts the host's blob with the `security` command and writes it into the container, which would hand over all of the host's tokens at once (including Claude Code's own login). Keeping separate token lineages for host and container is the cleaner boundary, and the container side can be revoked independently
- **Authentication happens once**: `~/.claude` is a host bind when shared and a fixed-name external volume when not, so either way tokens obtained in the container survive `dcc recreate` / `clear` and are shared across all workspaces
- **Do not publish the callback port**: publishing it would let authentication complete in the browser alone, but the `agent` service (agent container) cannot have `ports` because of the shared netns, and publishing on the sidecar would open a port on the host. The "do not publish to the host" policy ([docker.md](docker.md)) takes priority, and pasting the redirect URL is good enough

## How it works

| Item | Host-side asset | Container side | How it gets there |
|---|---|---|---|
| user scope settings | `mcpServers` in `~/.claude.json` | `~/.claude.json` (local copy) | Only when shared. Snapshot at creation time |
| local scope settings | `projects.<host absolute path>.mcpServers` in `~/.claude.json` | same as above | Copied but **not referenced** (the key is the host path) |
| project scope settings | `<workspace>/.mcp.json` | `/workspaces/<name>/.mcp.json` | As is, via the workspace bind |
| Approval state of `.mcp.json` | `<workspace>/.claude/settings.local.json` | same as above | same as above |
| OAuth tokens (host) | macOS Keychain | none | **Not passed** |
| OAuth tokens (container) | `mcpOAuth` in `~/.claude/.credentials.json` | the same file | Authenticated and obtained inside the container |

Even if authenticated on the host, **it is normal for servers to appear unauthenticated to Claude Code in the container**, and `/mcp` shows `needs authentication`. Claude Code's own login (`claudeAiOauth`) is treated the same way: run `/login` inside the container the first time only.

### Authenticating remote servers (`http` / `sse`)

The container has no browser and its `localhost` ports are not published to the host, so the OAuth callback is **allowed to fail in the browser, and the redirect URL is pasted by hand**.

1. Start with `dcc`, then `/mcp` → the target server → `Authenticate`. Or `claude mcp login <name>` (`--no-browser` only shows the URL)
2. Claude Code listens on `http://localhost:<port>/callback` and shows the authorization URL
3. Open that URL in **the host's browser** and log in to the IdP
4. The IdP redirects to `http://localhost:<port>/callback?code=...&state=...`. Nothing listens on the host's `localhost`, so **you get a connection error. This is expected**
5. Copy the URL from the address bar (the whole thing, including `?code=...&state=...`) and paste it at Claude Code's `Or paste the redirect URL here:`

After that it is refreshed automatically with the refresh token. If it fails, `/mcp` shows `needs authentication`; re-authenticate with the same steps. To delete the token, run `claude mcp logout <name>`. The callback port can be pinned with `MCP_OAUTH_CALLBACK_PORT` (when the redirect URI must be registered with the IdP).

If API keys are passed to `headers` via `${VAR}`, provide that environment variable **inside the container** (`DCC_CONTAINER_ENV_<NAME>`, `services.agent.environment` in `local/compose.yml`, or `env` in `~/.claude/settings.json`; the last also affects the host when shared; [customization.md](customization.md)).

### Handling per scope

- **user scope**: when shared, servers configured on the host are visible as is (when not shared, `~/.claude.json` is not passed, so they are not visible; add them inside the container). A later `claude mcp add --scope user` on the host is not reflected in an existing container (`dcc recreate`). Servers added inside the container do not flow back to the host and disappear on recreate
- **local scope**: the key is the workspace's host-side absolute path (`/Users/<user>/src/foo`), while in the container it is `/workspaces/foo`, so they do not match and servers added on the host are not visible. The `HOST_HOME → $HOME` symlink is for resolving paths directly under the home directory and cannot rescue workspace paths. Servers added inside the container with `claude mcp add` (default = local) also disappear on recreate. Use project scope to persist them
- **project scope**: the workspace is the same bind, so host and container see the same file. `claude mcp add --scope project` inside the container is reflected on the host too. Approval at first use (`enabledMcpjsonServers`, etc.) is written to `<workspace>/.claude/settings.local.json`, which is also shared. Redo with `claude mcp reset-project-choices`. In `command` / `args` / `env` / `url` / `headers` of `.mcp.json`, `${VAR}` / `${VAR:-default}` are expanded
- **Temporary specification**: `dcc exec -- --mcp-config <file>` (`--strict-mcp-config` ignores the others)

### stdio servers

- The command must exist **inside the container**. The image has `uvx` / `python3` / `node` / `npx` / `docker` / `go`. Servers that need other runtimes show `failed` in `/mcp`. To use them, add them with `local/Dockerfile` ([customization.md](customization.md))
- `docker run -i ...` style servers run on the sidecar's rootless dockerd ([docker.md](docker.md)). Only paths under the workspace can be bound with `-v`. Inner containers cannot reach the parent netns's `127.0.0.1`. cgroup resource limits are ignored
- Servers that depend on host files or sockets (`~/.aws`, `/var/run/docker.sock`, etc.) do not work. Only what credential modules pass is available

### Effects on the host

| Operation in the container | Reflected on the host |
|---|---|
| OAuth authentication of a remote server / `claude mcp logout` | When shared, written to / removed from `~/.claude/.credentials.json` (the host Claude Code on macOS does not read it). Not reflected when not shared |
| `claude mcp add --scope user` / local | Not reflected (`~/.claude.json` is container-local) |
| `claude mcp add --scope project`, approval of `.mcp.json` | **Reflected** (on the workspace) |

## Constraints and known holes

- Tokens obtained in the container stay in plaintext (in the host's `~/.claude/.credentials.json` when shared, in the volume `dcc-claude-home` when not). When no longer needed, run `claude mcp logout <name>` in the container
- Keychain bridging will not be supported going forward either (intentional)
- Settings added to user / local scope inside the container disappear on recreate (because `~/.claude.json` is container-local). Work around it with project scope
- Traffic to remote servers leaves through the netns shared with the sidecar. Reachability that depends on the host's proxy or VPN depends on the Docker runtime
- If you commit `.mcp.json` to the workspace, do not write tokens or internal hostnames directly in `url` / `headers`
