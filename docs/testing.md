# Testing

Two layers, both run by GitHub Actions ([`.github/workflows/test.yml`](../.github/workflows/test.yml)) on every
pull request and push to `master`:

| Layer | Command | What runs | Needs | Time |
|---|---|---|---|---|
| Component | `make check` | shellcheck, bats (`test/*.bats`), Python unittest (`test/python/`), Jsonnet evaluation. Each script, hook and sidecar server on its own, with stubs where it would touch docker or a container-only path | `bats`, `shellcheck`, `jsonnet`, `python3`, `gpg`, `jq`, the docker CLI with the compose plugin (no daemon) | ~1 min |
| End-to-end | `make e2e` | `test/e2e/*.bats`: the real `dcc` builds the images and brings up workspaces with every credential module against a fake host on a real Docker daemon, then checks the boundary and each module from inside the containers | a Docker daemon that can run a privileged container, `bats`, `gpg`, `ssh-keygen`, `script`, `jq` | 10–20 min (most of it the first image build) |

No real credential is used anywhere. Every module gets a dummy that exercises the same path as the real thing
("Fake host" below), so the workflow needs no secrets.

## Component tests

| File | Covers | Replaced |
|---|---|---|
| `test/dcc.bats` | `dcc` / `lib/*.sh` functions that do not touch docker: arguments, workspace, module resolution, drift, logging, `.env` | Functions that read docker state (`agent_label`, `container_id`, ...) and `compose` / `docker` are redefined per test |
| `test/hooks.bats` | `lifecycle_hooks/initialize.sh` (per-module pre-checks, gpg export), `postCreate-root.sh` (safe.directory, `HOST_HOME` link, volume owner check), `postCreate.sh` (`~/.claude.json` copy and trust, volume permissions, gpg public key import). Output follows the hook line format | `claude`, `git` (for `--system`), `getent`, `stat` are stubs; `HOME` is a temp directory |
| `test/gpg.bats` | `export-host-keys.sh` (key selection by `DCC_GPG_SIGNING_KEY` / `user.signingkey`, nothing secret exported), `git commit -S` / `git tag -s` through `gpg-sign-client.sh` against the real `server.py` and verification, refusal of non-git payloads, the not-warmed failure, `warm.sh`'s lookup of the sidecar | Throwaway GnuPG keyrings; `docker` is a stub for `warm.sh` |
| `test/gh.bats` | `gh-token-client.sh` as git credential helper (host / protocol matching, failure leaves no password) and as the `gh` wrapper (login changes refused, `GH_TOKEN` passed), against the real `server.py` | The server's `gh` is a stub handing out a dummy token |
| `test/compose.bats` | Generated files match `template.jsonnet` and are formatted; every module overlay merges; the invariants of [CLAUDE.md](../CLAUDE.md) on the merged configuration (only `docker` privileged, `cap_drop` / `no-new-privileges`, shared netns and no ports, no docker socket, no host binds in `docker` but the workspace, same workspace path, no `~/.aws` / `~/.gnupg` / `~/.ssh` in `agent`, no duplicated volume targets, no relative paths, no `AGENT`); conventions (every `DCC_*` in `.env.example` and [customization.md](customization.md) with the same default, a docs page per module) | Nothing is started (`docker compose config` only), `HOME` is a fake path |
| `test/python/test_*_server.py` | The three sidecar servers' HTTP contract: response format, status codes, timeouts, what is logged, what reaches the CLI they wrap (e.g. no `GH_TOKEN` into `gh`), payload validation of the signer | Fake `aws` / `gh` on `PATH`; real `gpg` with a throwaway key |

Shared helpers (`stub`, `start_server`, `new_gpg_key`, ...) are in `test/helpers/common.bash` and
`test/python/support.py`.

`make check` also works inside a `dcc` container (add `bats` / `shellcheck` with `local/Dockerfile`). The tests unset
the module settings the container itself has (`DCC_GPG_SIGN_URI`, the system git credential helper, ...), so they
never reach the real sidecars.

## End-to-end tests

| File | Covers |
|---|---|
| `00-build.bats` | `dcc build` builds the agent image and every sidecar image; the image contract (container user and uid, `~/.claude` / `~/.codex` owned by it, no `sudo` / `dockerd`, the documented tools, binaries outside the home volumes); sidecar images (gh new enough for expiring tokens, runs as `gh`) |
| `01-modules.bats` | `dcc up --all-creds`. Boundary on the running containers: no capabilities even for root, `no_new_privs`, only `docker` privileged, no host binds in `docker` but the workspace, no long-lived keys in `agent`, module endpoints on loopback only, no published ports, no anonymous volumes. Docker sidecar over TLS and the same-path workspace bind. postCreate results. Each module from inside the agent: `~/.claude` / `~/.codex` shared, signed commits (fails fast before warming with the reason visible through git, `warm.sh` by project and by workspace, verifies, private key only in the signer), AWS SDK container credentials, `gh` / git credential token, ssh files read-only. `dcc creds`, drift of the selection, AWS profile and signing key |
| `02-lifecycle.bats` | `dcc up --no-creds` (shared home volumes named as configured, owner), `dcc exec` for claude and codex on a terminal, exit code, `up` on running / stopped containers (no recreate, postCreate once), `stop`, `list`, `inspect`, `recreate --creds` (leaves no anonymous volume behind), `clear --volumes`, usage errors |
| `03-customization.bats` | `local/Dockerfile` (two-stage build, and `up` building a missing base), `local/compose.yml`, `DCC_COMPOSE_FILES`, `DCC_CONTAINER_ENV_*` (quoting), `DCC_TZ` |
| `04-all-workspaces.bats` | `stop --all` / `clear --all`. Only with `DCC_E2E_ALL=1`, since they act on every dcc workspace the daemon has |

Files run in order and later ones reuse the images from `00-build.bats`; each can also run alone
(`bats test/e2e/02-lifecycle.bats`; images are built by `dcc up` if missing). Within a file, tests share one
workspace and run in order.

### Fake host

Each file makes a temp directory and points `HOME` at a fake home in it, so `dcc`'s defaults (`~/.claude`,
`~/.aws`, ...) resolve there and nothing of the developer's is read. `DCC_ENV_FILE=/dev/null` and
`COMPOSE_DISABLE_ENV_FILE=1` keep the repository's `.env` out, every `DCC_*` / `AWS_*` / `GH_*` from the environment is
unset, and images and fixed-name volumes get e2e-only names (`dcc-e2e:local`, `dcc-e2e-claude-home`, ...).
`DCC_GPG_EXPORT_DIR`, `DCC_SSH_DIR` and `DCC_LOCAL_DIR` point into the temp directory, so `capabilities/gpg/gnupg-host`,
`capabilities/ssh/data` and `local/` of the checkout are not touched.

| Module | Dummy | Served through the real path |
|---|---|---|
| `claude` / `codex` | `~/.claude/`, `~/.claude.json`, `~/.codex/config.toml` with marker contents | Binds and the postCreate copy; writes from the container must appear on the host |
| `gpg` | A passphrase-protected ed25519 key (selected by `user.signingkey` in the fake `~/.gitconfig`) and a second key | `export-host-keys.sh` → `gpg-signer`. Warming is done by giving the passphrase to the signer's gpg-agent with `--pinentry-mode loopback` (what typing it into pinentry does), then `warm.sh` must succeed without a prompt |
| `aws` | A profile whose `credential_process` prints temporary credentials (with `SessionToken` / `Expiration`) from a file in the mounted `~/.aws/login/cache` | `aws configure export-credentials` in `aws-credentials` → `AWS_CONTAINER_CREDENTIALS_FULL_URI` → the AWS CLI in the agent. Works offline |
| `gh` | A `hosts.yml` with a non-expiring dummy token written into the gh state volume, as `dcc gh-login` would leave it | `gh auth token` in `gh-token` → the `gh` wrapper and the git credential helper in the agent |
| `ssh` | A fresh ed25519 key in `DCC_SSH_DIR` | Read-only binds and the GitHub `ssh_config` / `known_hosts` |

On Linux the container user's uid is set to the current uid (`DCC_UID`, as [customization.md](customization.md)
recommends for Linux hosts), so the container can write the workspace and read the bound files.

### Settings

| Variable | Default | Meaning |
|---|---|---|
| `DCC_E2E_TMPDIR` | `$TMPDIR` or `/tmp` | Where the fake hosts are made. The Docker daemon must be able to bind paths under it at the same path |
| `DCC_E2E_DOCKER` | (real) | `stub` replaces the Docker sidecar with an idle container of the same image, for daemons that cannot run nested dind. The tests that need the inner dockerd are skipped |
| `DCC_E2E_UID` | `id -u` | uid of the container user |
| `DCC_E2E_ALL` | (unset) | `1` runs `04-all-workspaces.bats`. It stops and removes **every** dcc workspace on the daemon; CI only |
| `DCC_E2E_KEEP` | (unset) | `1` leaves containers, volumes and the fake host after each file, for debugging (the path is printed) |

### Running locally

On a host with Docker (Docker Desktop or Linux):

```bash
make e2e
```

Inside a `dcc` container (editing this repository with an agent), the `docker` there is the rootless sidecar, which
cannot run another dind. Use the stub and a temp directory inside the workspace, which the sidecar can bind:

```bash
DCC_E2E_DOCKER=stub DCC_E2E_TMPDIR="$PWD/.e2e" make e2e   # .e2e/ is gitignored
```

Everything except the two inner-Docker tests runs this way. In this mode `HOST_HOME` is moved out of `/workspaces`
(the fake host lives there, and `postCreate-root.sh` cannot create directories in `/workspaces` without capabilities).

A failing test prints the state and the last log lines of the project's containers. Each file removes its
containers, project volumes, e2e home volumes and fake host at the end (`DCC_E2E_KEEP=1` to keep them). The images
(`dcc-e2e:local` and the sidecar images) are kept for the next run; remove them with `docker image rm`.

## CI

| Job | Runner | Steps |
|---|---|---|
| `component` | `ubuntu-24.04` | apt `bats` / `shellcheck`, go-jsonnet at the agent image's version (so generated files compare byte for byte), `make check` |
| `e2e` | `ubuntu-24.04` (+ `ubuntu-24.04-arm` when started by hand with `arm64`) | Allows unprivileged user namespaces (Ubuntu 23.10+ restricts them through AppArmor, and rootlesskit in the Docker sidecar needs them), then `make e2e` with `DCC_E2E_ALL=1` |

Actions are pinned by commit SHA (the tag is in the comment); bump them together with the comment. The e2e job
builds the agent image from scratch each time. When a download in the `Dockerfile` changes upstream (for example
Claude Code's `install.sh`, whose sha256 is pinned), this job is where it shows first.

## Not covered

| What | Why / where instead |
|---|---|
| Real AWS, GitHub and Anthropic endpoints, an actual `ssh` connection to GitHub | Needs real credentials; the e2e tests stop at the credential reaching the agent's CLI |
| Typing a passphrase into pinentry-curses, `dcc gh-login`'s interactive login, gh refreshing an expiring token | Interactive or needs a real account. Replaced by loopback warming and a pre-seeded `hosts.yml` |
| macOS host specifics (Docker Desktop file sharing and uid mapping, the host's gpg-agent, Keychain) | GitHub's macOS runners have no Docker. The design reasons are in the per-boundary pages |
| The devcontainer CLI / VS Code path ([devcontainer.md](devcontainer.md)) | Only the compose side is checked (`compose.bats`: the base works without the workspace overlay) |
| `claude update` in postCreate | Depends on the network; the hook only warns when it fails, and the tests accept either |

## Adding tests

| You changed | Add to |
|---|---|
| A function in `dcc` / `lib/*.sh` | `test/dcc.bats` (CLAUDE.md requires it) |
| A hook in `lifecycle_hooks/` | `test/hooks.bats` |
| A module's scripts or `server.py` | `test/<module>.bats` / `test/python/test_<module>_server.py`, and the module's part of `test/e2e/01-modules.bats` |
| A new module | A dummy in `fake_host` (`test/e2e/helpers.bash`), its checks in `01-modules.bats`; `compose.bats` and `hooks.bats` pick up the module list by themselves |
| `template.jsonnet` (mounts, services) | An invariant in `test/compose.bats` if it is one, and the boundary check in `01-modules.bats` |
| A `dcc` command or option | `02-lifecycle.bats` or `03-customization.bats` |
