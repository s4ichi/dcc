# Architecture

Components, config generation flow, structure of the compose project, lifecycle, and CLI specification.
For terminology, see "Terminology" in [README.md](README.md).

## Purpose

Run coding agents (Claude Code / Codex CLI) in a container isolated from the host (the developer's machine). There are 3 requirements.

1. **Pass only the minimum necessary host secrets to the container, read-only wherever possible.**
2. **Docker is usable from inside the container** (`docker run` / `docker compose` / `docker build`), but
   the agent must not be able to escalate to the host's or the agent container's privileges via Docker.
3. It can be started with one command from any workspace (project directory).

## Components

| Path | Role |
|---|---|
| `template.jsonnet` | Single source of the configuration. Edit only this |
| `docker-compose.yml` | Generated file (base). Defines the 2 services `agent` (agent container) and `docker` (sidecar). Only always-on mounts. Does not include the workspace bind |
| `docker-compose.workspace.yml` | Generated file (overlay). The workspace bind for `dcc` (same path in the agent container and the sidecar) and the `dcc.workspace` label. Interpolated with `LOCAL_WORKSPACE_FOLDER` / `LOCAL_WORKSPACE_BASENAME` exported by `dcc`. When used from devcontainer, the workspace-side compose replaces it ([devcontainer.md](devcontainer.md)) |
| `capabilities/<name>/compose.yml` | Generated file (overlay). The compose fragment for each credential module (additions to `services.agent` and module-specific sidecars; [credentials.md](credentials.md)) |
| `docker-compose.base-image.yml` | Generated file (overlay). Overrides `agent`'s `image` / `build` to build the base image (this repository's `Dockerfile` → `DCC_BASE_IMAGE`) when `local/Dockerfile` exists. Used only by `dcc build` / `dcc up` ([customization.md](customization.md)) |
| `Dockerfile` | The agent image. Based on `debian:bookworm-slim`, without dockerd. Personal layers are added in `local/Dockerfile` with `FROM` |
| `local/` | Gitignored. Put a personal `Dockerfile` / `compose.yml` here and `dcc` uses them automatically (location changeable with `DCC_LOCAL_DIR`; [customization.md](customization.md)) |
| `Makefile` | `generate` / `fmt` / `check` (= `lint` + `test` + Jsonnet evaluation) / `clean` |
| `dcc` + `lib/*.sh` | Per-workspace lifecycle CLI (up / exec / stop / clear / recreate / build). A thin wrapper around `docker compose`, not dependent on the devcontainer CLI. `dcc` is the entry point and the implementation is in `lib/` ("Implementation of `dcc`" below) |
| `test/dcc.bats` | Function tests for `dcc` (`make test`). Does not touch docker |
| `lifecycle_hooks/initialize.sh` | Host-side pre-processing (export / pre-checks for each module name in the arguments). Called from `dcc up` and from devcontainer's `initializeCommand` |
| `lifecycle_hooks/postCreate-root.sh`, `postCreate.sh` | Post-creation hooks (run inside the container; the part done as root and the part done as the container user). `dcc` calls them itself right after creation; with devcontainer, write them in `postCreateCommand` |
| `capabilities/gpg/` | The `gpg` module's signing sidecar (`server.py` signs commits / tags) and host-side scripts (`export-host-keys.sh` / `warm.sh`). [gpg.md](gpg.md) |
| `capabilities/claude/` | The `claude` module's overlay (binds of the host's `~/.claude` / `~/.claude.json`). [claude-code.md](claude-code.md) |
| `capabilities/codex/` | The `codex` module's overlay (bind of the host's `~/.codex`). [codex.md](codex.md) |
| `capabilities/aws/` | Image of the `aws` module's credential sidecar ([aws.md](aws.md)) |
| `capabilities/gh/` | The `gh` module's token sidecar (`server.py` returns the result of `gh auth token`) and the agent-side client (`gh-token-client.sh`; both the `gh` wrapper and the git credential helper). [github.md](github.md) |
| `capabilities/ssh/data/`, `capabilities/gpg/gnupg-host/` | Gitignored. Host-side sources bound into containers ([boundaries.md](boundaries.md)). `capabilities/gh/data/` is the location used by the old scheme; only its gitignore entry is kept, to prevent accidental commits |

## Config generation flow

```
template.jsonnet ──(make generate = jsonnet -S -m .)──► docker-compose.yml               (base)
                                                          ├► docker-compose.workspace.yml     (workspace overlay for dcc)
                                                          ├► docker-compose.base-image.yml    (for building the base when local/Dockerfile is used)
                                                          └► capabilities/<name>/compose.yml  (overlay × number of modules)

dcc up --creds a,b ──► docker compose -p <project> -f base -f workspace -f capabilities/a/compose.yml -f capabilities/b/compose.yml up -d --no-recreate
```

- The top level is `{ '<output file name>': <string>, ... }`. `jsonnet -S -m .` writes each field to a file
  of the same name. All generated files are committed statically; at startup `dcc` only exports environment variables and
  does not generate or rewrite files.
- The `bind(source, target, readonly)` / `volume(...)` helpers return compose's long syntax.
- `${VAR}` in compose files is **interpolated by docker compose**. `${HOME}` comes from the shell;
  `${DCC_CONFIG_DIR}` (the location of this repository; the compose side holds the default `~/.config/dcc` for when
  it is unset) and `${DCC_CREDS}` are exported by `dcc`. `${LOCAL_WORKSPACE_FOLDER}` /
  `${LOCAL_WORKSPACE_BASENAME}` are used only by the workspace overlay, and fail with `:?run via dcc` if unset.
- Per-user values (user / uid, image, timezone, host-side paths, ports, etc.) are all `${DCC_*}` with
  defaults, and personal or organization-specific values are not baked into the repository. `dcc` reads `${DCC_CONFIG_DIR}/.env` and
  exports them. The list is in [`.env.example`](../.env.example) and [customization.md](customization.md).
- **Files inside the repository (`capabilities/…`, `lifecycle_hooks/`, build context) are all written as
  absolute paths based on `${DCC_CONFIG_DIR}`**. They do not depend on compose's project directory (the parent of the first `-f`),
  so they point to the same place regardless of the order of `-f` or the caller (`dcc` / devcontainer CLI).

## Structure of the compose project

```
 host                                compose project: dcc-<basename>-<sha256(path)[:8]>
 ────                                ┌─────────────────────────────────────────────────────────┐
  dcc ── export ──►                  │  agent (agent container)            docker (sidecar)     │
   COMPOSE_PROJECT_NAME              │   image: dcc:local                   image: docker:*-dind-rootless
   DCC_CONFIG_DIR                    │   user: agent (uid 1000)             privileged: true (only here)
   LOCAL_WORKSPACE_FOLDER            │   not privileged                     dockerd rootless (uid 1000)
   LOCAL_WORKSPACE_BASENAME          │   network_mode: service:docker ◄──── shared netns       │
   DCC_CREDS                         │   DOCKER_HOST=tcp://docker:2376 ───► tcp/2376 (TLS)     │
   ▼                                 │   /certs:ro ◄──── volume docker-certs ───► /certs       │
  docker compose -p … up -d          │   /workspaces/<name> ◄─ host ws ─► /workspaces/<name>   │
   -f base -f workspace -f <overlay>… │   ~/.gnupg-host ~/.ssh ~/.claude … (only those chosen with --creds)  │
  docker compose exec … postCreate.sh │                                     volume docker-data   │
                                     └─────────────────────────────────────────────────────────┘
```

### Project name

`COMPOSE_PROJECT_NAME = dcc-<basename lowercased with everything outside [a-z0-9_-] removed>-<first 8 hex digits of the sha256 of the workspace's absolute path>`

- `dcc` passes it with `-p` to every compose call. If unset, it becomes the name of the compose file's directory
  and all workspaces collide in the same project.
- The basename is reduced to only the characters allowed in a compose project name (`[a-z0-9_-]`).
- Thanks to the path hash, directories with the same name in different places do not collide.
- Named volumes (`docker-data` / `docker-certs`) are prefixed with this project name, so
  they are independent per workspace.
- When used from the devcontainer CLI, the project name is decided by the CLI (`<basename>_devcontainer`;
  [devcontainer.md](devcontainer.md)).

### The `agent` service (agent container)

- `image: dcc:local` is written together with `build:`, so all workspaces share one image tag
  (without `image`, it is built per workspace as `<project>-agent`).
- `command: ['sleep', 'infinity']` keeps the container alive, and `dcc` starts the agent (`claude` / `codex`) with `docker compose exec`.
  Which one to start is not an attribute of the container; it is chosen per invocation with `--agent`.
  `init: true` makes tini PID 1, so `stop`'s SIGTERM reaches `sleep` and it exits immediately
  (if `sleep` is PID 1, it ignores SIGTERM and gets killed after the 10-second grace period).
- `network_mode: service:docker` joins the sidecar's netns. As a side effect, `ports` / `hostname` /
  `dns` / `extra_hosts` cannot be written for this service.
- `security_opt: no-new-privileges:true` and `cap_drop: ALL`. There is no sudo in the image, and the agent's processes cannot
  become root. Post-creation processing that needs root is done by `dcc` running `postCreate-root.sh` with `exec --user root`
  ("Lifecycle hooks" below, [boundaries.md](boundaries.md)).
- `depends_on: docker: condition: service_started`. To join the netns it is enough that the sidecar has started first;
  it does not wait for dockerd to be ready (`docker` commands may fail for the first few seconds after startup; postCreate does not
  use docker).
- Environment variables: `DOCKER_HOST` / `DOCKER_TLS_VERIFY` / `DOCKER_CERT_PATH` ([docker.md](docker.md)),
  `HOST_HOME` (the host's `$HOME`; used for plugin path resolution in [claude-code.md](claude-code.md)),
  `DCC_CREDS` (enabled credential modules, comma-separated), `TZ`. The user's environment variables are read via `env_file` from a dotenv file
  that `dcc` assembles from `DCC_CONTAINER_ENV_<NAME>` ([customization.md](customization.md)).
- Volumes: `~/.gitconfig` (ro bind), `~/.claude` / `~/.codex` (external volumes with fixed names `dcc-claude-home` / `dcc-codex-home`;
  the `claude` / `codex` modules override the same target with a host bind), `/certs` (ro), `lifecycle_hooks/` (ro bind). The workspace is added by
  the workspace overlay, everything else by the credential overlays (list in [boundaries.md](boundaries.md)).
- Label `dcc.credentials`: the same value as `DCC_CREDS`. Used so that `dcc` without flags inherits the existing container's selection, and
  to detect mismatches (drift) ([credentials.md](credentials.md)). The workspace overlay adds `dcc.workspace`
  (the host-side workspace path), which cross-workspace operations (`dcc list`, etc.) use to enumerate agent containers.

### The `docker` service (sidecar)

Details in [docker.md](docker.md). Key points:

- `docker:<ver>-dind-rootless@sha256:<digest>` (pinned by digest; [docker.md](docker.md)). dockerd is rootless as uid 1000.
- `privileged: true` is given only to this service. No secrets are mounted at all.
- `sysctls: net.ipv4.ip_unprivileged_port_start=0` allows publishing ports below 1024.
- Volumes: the workspace (workspace overlay; same path as in the agent container), `docker-certs`, `docker-data`.

## Agent image (Dockerfile)

The following are stacked as layers on `debian:bookworm-slim`. devcontainer features are not used (to avoid
feature installation failures, everything is baked into the Dockerfile).

Versions of tools fetched from GitHub Releases and the like are pinned by the defaults of the `ARG`s right before each layer (`YQ_VERSION` / `DUCKDB_VERSION` /
`JSONNET_VERSION` / `AWSCLI_VERSION` / `UV_VERSION` / `CODEX_VERSION` / `VOLTA_VERSION` / `NODE_VERSION` /
`D2_VERSION` / `CLAUDE_CODE_VERSION`), never `latest` (the same Dockerfile yields the same versions on every build).
Downloads are verified with sha256: those whose distributor publishes a checksum file (Go / `yq` / `uv` / Codex) are
checked against it (same origin, so what it detects is corruption and replacement in transit); those without one (`duckdb` / AWS CLI / Volta /
`d2` / Claude Code's `install.sh`) carry the sha256 in an `ARG` (`*_SHA256_*`). To bump, rewrite the defaults of the version and the
sha256. Things installed with apt (Docker CLI / `gh` / Corretto / Debian packages) are left to apt's signature verification and not pinned.
Claude Code's image version is pinned with `CLAUDE_CODE_VERSION`, but `claude update` in postCreate updates it to the latest in the container layer.

| Layer | Contents |
|---|---|
| 1 | APT lean settings (excluding recommends/suggests/doc/man/locale), base packages, creation of the container user (default `agent`) (uid/gid 1000; no sudo). Creates `~/.claude` / `~/.codex` with ownership set (an empty external volume inherits the owner on first mount) |
| 2 | Docker CLI + buildx + compose plugin (no dockerd) |
| 3 | GitHub CLI (`gh`) |
| 4 | Go (`GO_VERSION` build arg, `GOROOT=/usr/local/go`, `GOPATH=/go`) |
| 5 | Claude Code CLI (`install.sh` is verified with sha256 and run as the container user with `CLAUDE_CODE_VERSION`, placing it at `~/.local/bin/claude`. Auto-update and doctor treat this location as a managed install) |
| 6 | `yq` |
| 7 | `duckdb` CLI |
| 8 | `jsonnet` / `jsonnetfmt` (go-jsonnet built with Go) |
| 9 | AWS CLI v2 |
| 10 | `uv` / `uvx` |
| 11 | Codex CLI (`codex-package-<target>.tar.gz` from GitHub Releases, verified with `codex-package_SHA256SUMS`, extracted into `/opt/codex` and symlinked to `/usr/local/bin/codex`. Bundles `bwrap` and `rg`. Node is not needed. Updated by rebuilding the image. [codex.md](codex.md)) |
| 12 | Volta and Node.js (the default `node` is the `NODE_VERSION` LTS). The release tarball is verified with sha256 and extracted into `~/.volta/bin` (`VOLTA_HOME`), and `~/.volta/bin` is added to `PATH`. Add or switch versions with `volta install node@<ver>`; a project's `volta.node` in `package.json` takes precedence if present. Additions made inside the container go into the container layer and disappear on recreate |
| 13 | Shared libraries and fonts (Liberation / Noto CJK / Noto Color Emoji) needed to run headless Chromium. The browser itself is not installed (Playwright and the like fetch a build matching the library versions into `~/.cache`) |
| 14 | Java (Amazon Corretto 21 LTS, from Corretto's apt repository) |
| 15 | `d2` (distributed binary) |

The base packages include git / git-lfs / gnupg / pinentry-curses / openssh-client / curl / jq / rsync /
strace / gcc / g++ / make / python3 / pip / venv, among others.

`PATH` is `~/.volta/bin:~/.local/bin:/usr/local/go/bin:/go/bin:$PATH`. `LANG=LC_ALL=C.UTF-8`.
The final `USER` is the container user (default `agent`), and `WORKDIR` is `/workspaces`.

User name / uid / gid / Go version are passed to `ARG`s from compose's `build.args` (`DCC_USER` / `DCC_UID` / `DCC_GID` /
`DCC_GO_VERSION`). To add personal tools, do not edit this Dockerfile; instead put a `local/Dockerfile`
that does `FROM dcc:base`. When `dcc` finds it, it first builds this repository's
Dockerfile as `DCC_BASE_IMAGE`, and uses the output of `local/Dockerfile` as `DCC_IMAGE` for
the agent container (it tells compose by exporting `DCC_BUILD_CONTEXT` / `DCC_DOCKERFILE`;
[customization.md](customization.md)).

## Lifecycle hooks

Hooks are placed in `lifecycle_hooks/<name>.sh` named after devcontainer's lifecycle names, and the same scripts are called from both `dcc` and
devcontainer.

**`initialize.sh <module>...` (host side)**: runs on the host before the container is created / started. For each module name in the arguments,
it does pre-processing and pre-checks of bind sources (`gpg`: export of public keys / signing key info,
`aws` / `ssh` / `claude` / `codex`: existence checks of the sources; `gh` has no pre-processing). `dcc up` calls it with the selected module names; with devcontainer,
write it in `initializeCommand`.

**`postCreate-root.sh <user>` / `postCreate.sh` (container side)**: all of `lifecycle_hooks/` is read-only bound at
`/usr/local/lib/dcc/hooks` and run from there. There is no sudo in the agent container, and the agent's processes cannot
become root (`no-new-privileges` / `cap_drop: ALL`; [boundaries.md](boundaries.md)), so the processing that needs root and the processing done as the
container user are split into 2 scripts. After creating the container, `dcc up` calls them once with `docker compose exec`,
root side first, then user side (whether they have run is determined by the container-local marker `~/.dcc-postcreate-done`;
if something fails midway there is no marker, so they are re-run on the next `up`). With devcontainer, write the user side in `postCreateCommand`,
and run the root side once from the host with `docker exec --user root` ([devcontainer.md](devcontainer.md)).
Both run with the workspace as cwd.

`postCreate-root.sh` (root; it has no capabilities, so `chown` and the like are not possible):

1. When `~/.claude` / `~/.codex` are volumes (module disabled), check that the owner is the container user (an empty volume inherits
   the owner of the image's directory on first mount; root-owned volumes created by an old image must be recreated)
2. Create the `$HOST_HOME` → `$HOME` symlink (to resolve absolute paths of plugins installed on the host; [claude-code.md](claude-code.md))
3. `git config --system --add safe.directory <workspace>` ([git.md](git.md))
4. Register gpg-sign-client as `gpg.program` (only when the wrapper is mounted = `gpg` enabled; [gpg.md](gpg.md))
5. Register the gh-token client as `credential.https://<host>.helper` (only when the client is mounted = `gh` enabled; [github.md](github.md))

`postCreate.sh` (container user):

1. `claude update` (updates the baked-in version to the latest in the container layer; recreate reverts to the baked-in version; failure is only a warning)
2. Initialize `~/.claude`. When `claude` is enabled, copy `~/.claude.json.host` → `~/.claude.json`; when disabled, only `chmod 700` the volume ([claude-code.md](claude-code.md)).
   Likewise for `~/.codex` ([codex.md](codex.md); Codex is not updated here)
3. Build the keyring for verification (only when `~/.gnupg-host` exists = `gpg` enabled; [gpg.md](gpg.md))

## CLI

### `dcc`

```
dcc [command] [workspace] [options] [args...]
```

- The workspace is determined by argument → `DCC_WORKSPACE` → `$PWD`, in that order.
  If the first non-option argument is a directory, it is treated as the workspace.
- The config directory is `DCC_CONFIG_DIR` (default `~/.config/dcc`). At startup it reads
  `${DCC_CONFIG_DIR}/.env` (changeable with `DCC_ENV_FILE`) as bash and exports `DCC_*`
  (shell environment variables take precedence).
- If `local/compose.yml` (`DCC_LOCAL_DIR`) exists it is appended to the end of the `-f` list, followed by the compose files in
  `DCC_COMPOSE_FILES` (colon-separated) (`up` / `build`).
- For the credential options `--creds` / `--all-creds` / `--no-creds` and `DCC_CREDS`, see
  [credentials.md](credentials.md).
- The agent to run is determined by `--agent claude|codex` → `DCC_AGENT` → `claude`, in that order (effective for `default` / `exec`).
  At launch, `dcc` prepends the arguments in `DCC_CLAUDE_ARGS` / `DCC_CODEX_ARGS` to the user's arguments. The default for codex turns off
  Codex's own sandbox ([codex.md](codex.md)).

| Command | Behavior |
|---|---|
| `dcc` (default) | `up` → gpg warm (when `gpg` is enabled) → exec the agent |
| `dcc up` | `initialize.sh <selected modules>` → drift check → (if needed, create volumes `dcc-claude-home` / `dcc-codex-home` / `dcc-gh-home` and build the base image) → `docker compose -f base -f workspace -f <overlay>… [-f local/compose.yml] [-f $DCC_COMPOSE_FILES] up -d --no-recreate` → if not yet run, `postCreate-root.sh` (root) → `postCreate.sh` (container user) |
| `dcc exec [args]` | `up` → gpg warm (`capabilities/gpg/warm.sh`) → `docker compose exec -u agent -w /workspaces/<name> agent <claude\|codex> [default args] [args]` |
| `dcc creds` | Show the module list, defaults, the resolution for this invocation, and the running container's selection |
| `dcc gh-login [args]` | Prepare the volume `dcc-gh-home` (and build `dcc-gh-token:local` if missing), then `docker run --rm -it -v dcc-gh-home:… dcc-gh-token:local auth login --hostname <DCC_GH_HOST> --expiring --git-protocol ssh --skip-ssh-key [args]` → `auth status`. Does not depend on the workspace's container ([github.md](github.md)) |
| `dcc stop [--all]` | `docker compose -p <project> stop` (`--all` for all projects of all workspaces) |
| `dcc clear [--all] [--volumes]` | `docker compose -p <project> down [--volumes]`. `--volumes` also removes the sidecar's named volumes, `--all` for all workspaces |
| `dcc recreate` | `clear` → `up` (named volumes are kept) |
| `dcc build [opts]` | `docker compose -f <base> -f <all overlays> build [opts]` (builds `agent` and all module-specific sidecars). If `local/Dockerfile` exists, first runs `build agent` with `-f docker-compose.base-image.yml` to create the base |
| `dcc list` / `ls` | List agent containers of all workspaces (ID / status / name / project / credentials / workspace) |
| `dcc inspect` | name / status / workspace / project / credentials / image of each agent container |

Cross-workspace operations (`list` / `inspect` / `--all`) enumerate agent containers by their workspace label (`dcc.workspace` added by `dcc`,
or `devcontainer.local_folder` added by the devcontainer CLI), identify
the project from the `com.docker.compose.project` label, and operate per compose project.
Containers without the compose label are skipped.

### Implementation of `dcc`

`dcc` resolves `DCC_CONFIG_DIR`, sources `lib/*.sh`, and in `main` just calls
`load_config → parse_args → resolve_workspace → resolve_creds → command` in order.

| File | Role |
|---|---|
| `lib/log.sh` | Output format (`step` / `warn` / `fail` / `done_step`), running external commands and dumping on failure (`run_step`), converting hook output (`relay`) |
| `lib/config.sh` | Reading `.env`, defaults, `DCC_CONTAINER_ENV_*`, detecting `local/Dockerfile` |
| `lib/cli.sh` | Arguments (`parse_args`), workspace and compose project name (`resolve_workspace`), header and usage |
| `lib/creds.sh` | Resolving credential modules (`resolve_creds`), the `-f` list (`compose_files`), drift check (`check_drift`) |
| `lib/docker.sh` | Functions that **only read** docker / compose state (`container_id` / `agent_label` / `project_services` …) |
| `lib/project.sh` | Functions that **change** compose projects (`up_container` / `build_image` / `stop_containers` / `clear_containers` …) |
| `lib/all.sh` | Across all workspaces (`list` / `inspect` / `for_each_project`) |

Conventions:

- A function either "reads docker state" (`docker.sh`) or "changes it" (`project.sh`), never both
- Only `load_config` / `parse_args` / `resolve_workspace` / `resolve_creds` write global variables; after that they are only read
- The only thing executed at top level is `main` at the end of `dcc`. Sourcing `dcc` only loads function definitions, so
  tests (`test/dcc.bats`) call functions directly and replace functions that call docker with stubs
- Logs go to stderr, one piece of information per line (`▸ <subject> <predicate>`). Output of compose and hooks is not shown on success; it is shown
  in full only on failure (`DCC_VERBOSE=1` always streams it). Hooks print lines of the form `<subject>: <predicate>` / `warn: <subject>: <predicate>`, and
  `dcc` converts them to its own line format

## Operational notes

- **Do not restart only the sidecar** (`docker compose restart docker`, etc.). The agent container's netns gets left behind in the old sandbox
  and can no longer reach Docker. Recover with `dcc recreate`. `dcc stop` → `dcc up` in that order is
  fine (the sidecar starts first, and the agent container joins the new netns).
- Changes to compose files are not applied to existing containers (`dcc up` uses `--no-recreate`).
  Run `dcc recreate`. The same goes for changing the credential selection; `dcc` warns about the mismatch (recreate with `dcc recreate`).
- Rebuild the images with `dcc build [--no-cache]`. Existing containers keep the old image after the build, so
  `dcc recreate` is needed.
- Rootless constraints: cgroup resource limits (`--memory` / `--cpus`) are ignored. An inner container's
  `--privileged` only grants privileges inside the userns. Inner containers cannot reach `127.0.0.1` of the parent netns.

