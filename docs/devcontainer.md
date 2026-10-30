# Using from devcontainer

`dcc` is a thin wrapper that uses this repository's compose files directly with `docker compose`, and it
does not depend on the devcontainer CLI. The same compose files can also be referenced from the devcontainer CLI / VS Code Dev Containers,
and the credential modules (`aws` / `claude` / `codex` / `gpg` / `ssh` / `gh`) behave the same way there.
This page describes how.

## Assumption: what the devcontainer CLI does not pass to compose

The devcontainer CLI expands each element of `dockerComposeFile` into `-f` in order and calls `docker compose up`,
but it **does not pass** the following two (confirmed in the CLI source).

- The workspace path. `${localWorkspaceFolder}` substitution happens only inside `devcontainer.json`; no environment
  variables at all are passed to the compose files
- Results of preprocessing done on the host (such as the `gpg` public key export)

For this reason the base `docker-compose.yml` **does not contain the workspace bind**. `dcc` adds
`docker-compose.workspace.yml` (interpolated with `LOCAL_WORKSPACE_FOLDER`, which `dcc` exports), and
from devcontainer a compose file on the workspace side provides the same bind. Host-side preprocessing is
split out into `lifecycle_hooks/initialize.sh`, which is called from `initializeCommand`.

## Example configuration

Put two files in the workspace. `<repo>` is this repository (default
`~/.config/dcc`).

### `.devcontainer/compose.yml`

The workspace bind. Bind it at the same path into **both** the agent container (`agent`) and the Docker sidecar (`docker`)
(because the bind in `docker run -v /workspaces/<name>/x:/x` is resolved by the sidecar's dockerd).
Make `<name>` match `workspaceFolder` in `devcontainer.json`.

```yaml
services:
  agent:
    volumes:
      - type: bind
        source: ..
        target: /workspaces/<name>
        consistency: cached
  docker:
    volumes:
      - type: bind
        source: ..
        target: /workspaces/<name>
        consistency: cached
```

### `.devcontainer/devcontainer.json`

```json
{
  "name": "Claude Code",
  "dockerComposeFile": [
    "compose.yml",
    "${localEnv:HOME}/.config/dcc/docker-compose.yml",
    "${localEnv:HOME}/.config/dcc/capabilities/gpg/compose.yml",
    "${localEnv:HOME}/.config/dcc/capabilities/ssh/compose.yml"
  ],
  "service": "agent",
  "remoteUser": "agent",
  "workspaceFolder": "/workspaces/<name>",
  "shutdownAction": "stopCompose",
  "initializeCommand": "${localEnv:HOME}/.config/dcc/lifecycle_hooks/initialize.sh gpg ssh",
  "postCreateCommand": "bash /usr/local/lib/dcc/hooks/postCreate.sh"
}
```

- **Put `compose.yml` first.** The compose project directory becomes the parent of the first `-f`, and
  `source: ..` in `compose.yml` is resolved relative to it (= the workspace). This repository's compose files
  write every in-repository path as an absolute path based on `${DCC_CONFIG_DIR}`, so they work
  wherever the project directory is
- To use a module, just add `capabilities/<name>/compose.yml` to `dockerComposeFile`. Write the same name
  in the arguments of `initializeCommand` too (host-side preprocessing and pre-checks)
- `${localEnv:HOME}` is substituted by the devcontainer CLI. If you cloned the repository elsewhere, change the paths
  and export `DCC_CONFIG_DIR` in the shell so that compose looks at the same place
  (the default inside the compose files is `~/.config/dcc`)
- Pass per-user settings (`DCC_*`; [customization.md](customization.md)) as **shell environment variables**.
  The `${DCC_CONFIG_DIR}/.env` that `dcc` reads is not read by compose either, because the project directory is on the
  workspace side. The equivalent of `DCC_COMPOSE_FILES` is listing your own overlays in `dockerComposeFile`.
  `DCC_CONTAINER_ENV_<NAME>` has no effect because `dcc` is what collects it. For environment variables to pass to the container, write a
  dotenv-format file and pass its path via `DCC_CONTAINER_ENV_FILE`, or write them in `environment` in your own overlay
- `local/Dockerfile` ([customization.md](customization.md)) is not auto-detected unless you go through `dcc`. To use it,
  export `DCC_BUILD_CONTEXT=<repo>/local` and `DCC_DOCKERFILE=<repo>/local/Dockerfile` in the shell, and
  build the base that `FROM` refers to first (run `dcc build` once, or run the following):
  `docker compose -f <repo>/docker-compose.yml -f <repo>/docker-compose.base-image.yml build agent`
- `postCreateCommand` is the same script `dcc` uses (container-user side). It copies `~/.claude.json`,
  runs `claude update`, and builds the verification keyring when `gpg` is enabled. The parts that need root (registering `safe.directory`, registering in the
  system gitconfig when `gpg` / `gh` is enabled, the `HOST_HOME` symlink) are in `postCreate-root.sh`, and because the agent container has no sudo
  they cannot be called from `postCreateCommand` (which runs as `remoteUser`). Run it once from the host after the first up:

  ```bash
  docker compose -p <name>_devcontainer exec --user root --workdir /workspaces/<name> agent \
    bash /usr/local/lib/dcc/hooks/postCreate-root.sh agent
  ```

  (`<name>_devcontainer` is the project name the devcontainer CLI assigns. You can also check it with `dcc list`)

Start as usual with `devcontainer up --workspace-folder .` / `devcontainer exec --workspace-folder . claude`,
or "Reopen in Container" in VS Code.

## Notes per module

| Module | What is needed on the devcontainer side |
|---|---|
| `ssh` | just add the overlay to `dockerComposeFile` |
| `gh` | add the overlay and run `dcc gh-login` once on the host (creates the external volume `dcc-gh-home` and prepares the token; it does not depend on the workspace, so it can be run outside devcontainer). If you have not run `dcc build`, the sidecar image is built at up |
| `claude` | adding the overlay shares the host's `~/.claude`. If not added, the base requires the external volume `dcc-claude-home`, so run `docker volume create dcc-claude-home` once beforehand (`dcc` creates it automatically) |
| `codex` | same as `claude`. Adding the overlay shares the host's `~/.codex`. If not added, run `docker volume create dcc-codex-home` once. **The base references both volumes, so `dcc-codex-home` is needed even if you do not use Codex** (likewise `dcc-claude-home` if you do not use Claude Code). When starting `codex` from devcontainer, `dcc`'s default arguments are not added, so pass them yourself as in `codex -c sandbox_mode=danger-full-access` or write them in `~/.codex/config.toml` ([codex.md](codex.md)) |
| `aws` | just add the overlay to `dockerComposeFile`. Writing `aws` in `initializeCommand` pre-checks that `~/.aws/config` / `~/.aws/login/cache` exist. compose picks up `AWS_PROFILE` / `AWS_REGION` from shell environment variables |
| `gpg` | write `gpg` in `initializeCommand` (**required**; exports the host's public key / signing key information to `capabilities/gpg/gnupg-host`. Without it the sidecar has no signing key). After up, run `<repo>/capabilities/gpg/warm.sh` once from a terminal to cache the passphrase in the sidecar (below) |

### Warming the `gpg` passphrase

The signing key's passphrase is cached in the gpg-agent inside the `gpg-signer` sidecar and stays for the sidecar's
whole lifetime ([gpg.md](gpg.md)). It is entered through pinentry inside the sidecar, so an interactive terminal is needed, and
it cannot be done from `initializeCommand` (before the sidecar starts) or `postCreateCommand` (inside the agent container).
`dcc` does it automatically right before starting claude, but from devcontainer run it once in a host terminal after up:

```bash
cd <workspace>
~/.config/dcc/capabilities/gpg/warm.sh          # find the sidecar from the current workspace
~/.config/dcc/capabilities/gpg/warm.sh -p <project>  # specify by compose project name
```

If you run `git commit -S` without warming, the wrapper shows the sidecar's 503 and fails (it does not hang).
When the sidecar stops through the equivalent of `dcc stop` (e.g. closing VS Code with `shutdownAction: stopCompose`),
the cache is lost, so run it again after the next start.

## Coexisting with `dcc`

- `dcc list` / `dcc inspect` / `dcc stop --all` / `dcc clear --all` also look at the `devcontainer.local_folder`
  label the devcontainer CLI assigns, so containers created by devcontainer are also listed, stopped, and deleted
- Opening the same workspace with both `dcc` and devcontainer creates two compose projects
  (`dcc-<basename>-<hash>` for `dcc`, `<basename>_devcontainer` for the devcontainer CLI). Named volumes
  are also separate per project
- `dcc`'s credential drift detection and flagless `dcc` inheriting the existing container's selection (both use the `dcc.credentials` label) apply only to containers created by `dcc`
