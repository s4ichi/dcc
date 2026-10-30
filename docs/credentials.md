# Selective granting of credential modules

## Overview

Host secrets are split into **modules**, and only the ones selected with `--creds` when `dcc` starts are
mounted into the agent container. If nothing is specified, not a single secret module is passed.

| Module | What it passes | Mode | Side processing | Details |
|---|---|---|---|---|
| `aws` | temporary credentials (`~/.aws` is not mounted into the agent container) | HTTP | the `aws-credentials` sidecar issues them from `~/.aws/config` / `~/.aws/login/cache` (ro) | [aws.md](aws.md) |
| `gpg` | a signing API (the private key is only in the `gpg-signer` sidecar; the agent container gets only the public key and a `gpg.program` wrapper) | HTTP | `initialize.sh gpg` exports the public key, keygrip, and signing key on the host; after start, `capabilities/gpg/warm.sh` runs pinentry inside the sidecar (automatic with `dcc`) | [gpg.md](gpg.md) |
| `ssh` | `./capabilities/ssh/data` → `~/.ssh`, `./capabilities/ssh/{config,known_hosts}` → `/etc/ssh` | ro | none | [ssh.md](ssh.md) |
| `gh` | a short-lived access token (the refresh token is only in the `gh-token` sidecar; the agent container gets only a `gh` wrapper and a git credential helper) | HTTP | run `dcc gh-login` once on the host (state lives in the volume `dcc-gh-home`, shared by all workspaces; created by `dcc up` / `gh-login`) | [github.md](github.md) |
| `claude` | host `~/.claude` → `~/.claude`, `~/.claude.json` → `~/.claude.json.host` | rw / ro | when omitted, `~/.claude` becomes the empty volume `dcc-claude-home`, shared by all workspaces (created by `dcc up`) | [claude-code.md](claude-code.md) |
| `codex` | host `~/.codex` → `~/.codex` (`auth.json` = includes the host Codex token) | rw | when omitted, `~/.codex` becomes the empty volume `dcc-codex-home`, shared by all workspaces (created by `dcc up`) | [codex.md](codex.md) |

The `claude` / `codex` modules do not "make that agent usable". Both agents are in the agent image,
and which one starts is chosen with `--agent` ([architecture.md](architecture.md)). A module decides only whether the host's settings and authentication are shared.

Always mounted (not modularized): the workspace, `~/.gitconfig` ([git.md](git.md)),
lifecycle hooks, Docker TLS certificates, and the volumes used when the `claude` / `codex` modules are disabled.

## Selecting modules (`dcc`)

```
dcc [command] [workspace] [options] [args...]

Credential options (default / up / exec / recreate):
  --creds <a,b,...>  Enable credential modules (comma separated, repeatable)
  --all-creds        Enable every module
  --no-creds         Enable none
  Without any of these, an existing container keeps its own selection (modules only
  apply at creation); a new container gets $DCC_CREDS, or none if unset

Environment:
  DCC_CREDS               Default for --creds (e.g. DCC_CREDS=gpg,ssh)

Commands:
  creds              Show available credential modules and the running container's selection
  gh-login [args]    Log in to GitHub for the gh module (gh auth login --expiring in the gh-token
                     sidecar image; shared by every workspace). Args are passed to gh auth login
```

Examples:

```bash
dcc --creds gpg,ssh                 # start claude with only signing and SSH
dcc up ~/src/foo --creds=gh         # start another workspace with only gh
DCC_CREDS=aws,gpg dcc               # default via environment variable
dcc exec --creds gpg -- --resume    # everything after `--` goes to claude
dcc creds                           # check status
dcc recreate --all-creds            # recreate with everything passed
```

`dcc` interprets only the options above. Any other `--xxx` and everything after `--` are treated as positional arguments,
and with `exec` they pass through to `claude`. If the first non-option argument is a directory, it is treated as the workspace.

When no flag is given, the selection is resolved in this order:

1. If an existing container (including a stopped one) exists, use the selection in its `dcc.credentials` label as is.
   Modules can only be applied at creation, so a container created with `dcc --creds gpg,ssh` can afterwards be reached with plain `dcc`.
   `dcc recreate` without flags also recreates with the same selection
2. Otherwise `DCC_CREDS`
3. Otherwise the minimal setup

You can check it in the `credentials` line of the header printed to stderr at startup (`(existing container)` is appended when the existing container's selection was adopted).

## Mismatch with a running container (drift)

The selection is recorded in the container label `dcc.credentials` and the environment variable `DCC_CREDS` (comma separated).
When `--creds` / `--all-creds` / `--no-creds` is given explicitly, the label of the existing container (including a stopped one) is compared with this run's request.

| Situation | Behavior |
|---|---|
| No flag | adopt the existing selection as is and connect (no comparison) |
| Match | connect as is |
| Mismatch | warn and **connect to the existing container** (mounts do not change). To apply, `dcc recreate --creds …` |
| Same selection but a different `AWS_PROFILE` for `aws` | warn likewise (compared with the `dcc.aws-profile` label; compared even without flags) |
| Same selection but a different `gpg` signing key | warn likewise (compares the key the running `gpg-signer` pinned at startup with the `signing-key.txt` the host just exported; not compared while the sidecar is stopped; compared even without flags) |

```
! credentials    container has gpg ssh; requested aws (+aws -gpg -ssh)
                 run 'dcc recreate --creds aws' to apply
```

## How it works

```
template.jsonnet ──make generate──►  docker-compose.yml               (base: always-mounted + sidecar)
                                          docker-compose.workspace.yml     (workspace bind for dcc)
                                          capabilities/<name>/compose.yml  (additions to services.agent + module-specific sidecar)

dcc up --creds gpg,ssh
  ├─ resolve_creds     : choose by flag > existing container's label > DCC_CREDS, validate names and normalize
  │                      → export CREDS="gpg ssh", DCC_CREDS="gpg,ssh"
  ├─ initialize.sh gpg ssh : host-side preprocessing (gpg export) and pre-checks of bind sources
  ├─ check_drift       : compare with the existing container and warn (module selection / AWS_PROFILE / gpg signing key;
  │                      the selection can only differ when flags are given)
  ├─ docker compose -p <project> -f base -f workspace -f capabilities/gpg/compose.yml -f capabilities/ssh/compose.yml up -d --no-recreate
  ├─ docker compose exec --user root agent postCreate-root.sh agent    (only if not yet run)
  └─ docker compose exec --user agent agent postCreate.sh
```

Design points:

- **Overlays are static generated files and are committed.** The host needs no jsonnet, and what gets mounted
  can be reviewed as files.
- Paths inside the repository in overlays are written as **absolute paths** based on `${DCC_CONFIG_DIR}` (`dcc` exports the
  resolved value; the default `~/.config/dcc` lives on the compose side). They do not depend on the compose project
  directory (the parent of the first `-f`), so they point to the same place even when the devcontainer CLI passes the `-f`
  files in a different order ([devcontainer.md](devcontainer.md)).
- compose merges multi-file `volumes` by appending, keyed on target. If the same target is written in two overlays
  the later one wins, so do not duplicate targets.
- Do not put values that rely on compose environment variable interpolation in modules. Results of host-side preprocessing
  are passed as files (`capabilities/gpg/gnupg-host/*`), which the sidecar and the agent container read. This is because
  via devcontainer, `initializeCommand` cannot pass environment variables to compose.
- `dcc build` passes the base and **all overlays** to `-f` and builds every service that has `build` (`agent` and the
  module-specific sidecars). `stop` / `clear` operate on the `-p` label and so do not depend on the selection.

## Adding a module

1. Add an entry to `credModules` in `template.jsonnet` (a compose fragment merged into the base.
   Usually it only appends to `services.agent.volumes`, but like `aws` it may also add a module-specific
   service).
2. `make generate` → `capabilities/<name>/compose.yml` is generated. `dcc` gets module names from this list of file
   names, so no change is needed on the `dcc` side.
3. If host-side preprocessing or pre-checks of bind sources are needed, add them to the `case` in `lifecycle_hooks/initialize.sh`
   (the `gpg` export is an example). Pass results as **files**, not compose environment variables (so it also works via
   devcontainer).
4. If container-side post-processing is needed, gate it on the presence of the mount in `postCreate.sh` (container user) or
   `postCreate-root.sh` (root; system gitconfig etc.) (`setup_gnupg` and registering `gpg.program` are examples). The agent container has no sudo and
   root has no capabilities either, so things like `chown` cannot be done (prepare ownership on the image side).
5. Write values that may vary per user, such as host-side paths and ports, as `${DCC_X:-<default>}`, and add one row to
   `.env.example` and the table in [customization.md](customization.md).
6. Write `docs/<name>.md` following "Page structure" in [README.md](README.md), and add it to that page's table,
   the summary and mount lists in [boundaries.md](boundaries.md), and the table in the top-level `README.md`.

## Constraints and future work

- The selection is kept only in the container label. Deleting the container with `dcc clear` also deletes the selection, so the next time
  specify it again with `--creds` or `DCC_CREDS` (per-workspace persistence, an interactive checklist, and named profiles are
  room for future extension).
- Changing the selection only takes effect by recreating (mounts and sidecars are decided at container creation). Drift only warns;
  running `dcc --no-creds` or `--creds ssh` against an existing `--all-creds` container warns and then connects to that
  container. A request for "fewer privileges this time" has no effect unless the container is recreated.
- `~/.gitconfig` is always mounted and cannot be removed ([git.md](git.md)). The `claude` module is a binary choice of sharing
  `~/.claude` wholesale or not; it is not split up into passing only settings or only the token (reason in [claude-code.md](claude-code.md)).
