# GitHub CLI (`gh`) and HTTPS git authentication

**Module name: `gh`** — enabled only when `dcc --creds gh` is given ([credentials.md](credentials.md)).

## What it protects

| Asset | Location | Nature |
|---|---|---|
| The host's `gh` token | macOS Keychain | OAuth token of the personal account. Often has broad scopes |
| Refresh token for the container | `hosts.yml` in volume `dcc-gh-home` (`DCC_GH_HOME_VOLUME`) | Obtained with `dcc gh-login`. Can re-issue access tokens. Replaced with a new one on every use. **Plaintext** |
| Access token | Issued on each request by the gh-token sidecar → agent container (HTTP) | Expires in a few hours (with expiring credentials) |

## Boundary

| Axis | This design |
|---|---|
| What it can do | The agent container can only "obtain an access token for the account logged in with `dcc gh-login`, while the sidecar is running". The token's scope is the ceiling |
| Reach | `~/.config/gh` is not bound into the agent container. gh's state, including the refresh token, is passed as a volume only to the unprivileged `gh-token` sidecar. The host's Keychain and `~/.config/gh` are passed nowhere |
| How the key is passed | **Delegated execution**. The sidecar runs `gh auth token` (gh refreshes if needed), and the agent container receives only the access token. In the agent container, `gh` (via a wrapper) and git (via a credential helper) fetch it anew on every run, and nothing is stored in the agent container |

## What leaks on compromise

If the agent container is taken over:

- The attacker gains at most "the ability to obtain access tokens while the sidecar is running". An exfiltrated access token expires in a few hours
- The refresh token is not in the agent container, so it cannot be exfiltrated. The host's token is also unreachable
- The endpoint exists only on `127.0.0.1` in the shared netns, so it is unreachable from inner containers, the host, and other compose projects
- To stop it, run `dcc stop`, or revoke the GitHub CLI authorization in GitHub's Settings → Applications

The sidecar runs nothing but its own `server.py`, and its access log contains only method / path / status, never tokens.

## Why this design

- **Use gh's expiring credentials (v2.103.0+)**: `gh auth login --expiring` issues a pair of an access token that expires in a few hours and a refresh token that is rotated on every use. If the access token leaks, the damage stops at its expiry
- **Do not use `--expiring` in the agent container**: a refresh token can re-issue access tokens, so if it sat in the agent container and were exfiltrated it would be no different from a non-expiring token. As with aws / gpg, the sidecar acts on the agent's behalf and the agent container receives only expiring tokens
- **Pass it to the agent container as `GH_TOKEN` and fetch it every time**: gh does not refresh `GH_TOKEN` / `GITHUB_TOKEN`. The wrapper fetches from the sidecar on every run, so the effect of expiry is confined to a single run (gh itself also says "do not cache the result of `gh auth token`; call it every time")
- **A custom credential helper for git**: `gh auth git-credential` works only with a gh that holds the refresh token. The agent container's helper just returns the token fetched from the sidecar, and `store` does nothing. Since no caching helper is involved, stale tokens do not linger even without git 2.46's ephemeral option that gh recommends (the agent container's git is 2.39)
- **State lives in a fixed-name named volume shared across all workspaces**: the refresh token is single-use, and if two processes use the same one, the whole token set may be revoked. gh serializes with flock + reload on `~/.config/gh/refresh.lock`, so all sidecars must see the same lock on the same filesystem. A local volume inside the VM makes flock work reliably (flock across containers over a macOS host bind is not guaranteed). It also leaves no plaintext token under the host's repository
- **Login is independent of workspaces**: `dcc gh-login` just runs the sidecar image with `docker run` and writes into the volume; it depends neither on a workspace's containers nor on the Docker sidecar

## How it works

```
 agent (agent container)                            gh-token (sidecar, unprivileged)
  /usr/local/bin/gh = gh-token-client.sh             python3 /server.py listens on 127.0.0.1:8082
   GH_TOKEN=<GET /token> exec /usr/bin/gh     ──►     GET /token
  git: credential.https://github.com.helper            └─ gh auth token --hostname $GH_HOST
   = gh-token-client.sh git-credential        ──►        (refresh if near expiry; serialized by refresh.lock)
                                                     volume dcc-gh-home → /home/gh/.config/gh (rw)
        └───────── shared netns (both network_mode: service:docker) ─────────┘
```

| Item | Destination | Mode |
|---|---|---|
| volume `dcc-gh-home` (`DCC_GH_HOME_VOLUME`) | sidecar `/home/gh/.config/gh` | rw |
| `<repo>/capabilities/gh/gh-token-client.sh` | agent container `/usr/local/lib/dcc/gh-token-client.sh`, `/usr/local/bin/gh` | ro |
| access token | agent container (HTTP; not left in environment variables / files) | — |

### Setup

Once, on the host:

```bash
dcc gh-login                          # runs gh auth login --expiring with the sidecar image
dcc gh-login --scopes read:packages   # when extra scopes are needed (arguments go straight to gh auth login)
```

Open the URL shown by the device flow in the host's browser and enter the one-time code. At the end `gh auth status` is printed; check that the token is expiring (that an expiry time is shown).
Then start with `dcc --creds gh` (`dcc recreate --creds gh` for an existing container). Inside the container, check with `gh auth status` / `gh api user` and `git ls-remote https://github.com/<repo>`.

- The default scopes are those of gh's OAuth app (`repo` / `read:org` / `gist`). These are classic scopes, so broader than a fine-grained PAT
- If the organization restricts OAuth apps, the organization must approve use of GitHub CLI
- Specify GitHub Enterprise with `DCC_GH_HOST`. GHES older than 3.23 does not support expiring tokens and falls back to a non-expiring token (visible in `gh auth status`)
- To log in again, also use `dcc gh-login`. A running sidecar returns the new token from the next request

### Details

- `GET /token` returns the output of `gh auth token --hostname $GH_HOST` as `text/plain`. Failures (not logged in, refresh token expired, etc.) are 503, with a body containing only the remedy (`dcc gh-login`). gh's stderr goes only to the sidecar's log. Anything other than `/token` is 404
- The sidecar's gh runs in an environment with `GH_TOKEN` / `GH_DEBUG` etc. removed (with `GH_TOKEN` set, gh does not refresh; `GH_DEBUG` is not used)
- The agent container's wrapper rejects `gh auth login|logout|refresh|switch|setup-git` and points to `dcc gh-login`. If the sidecar is unreachable, it warns and runs `/usr/bin/gh` without a token
- postCreate (the root-side `postCreate-root.sh`) registers the credential helper with `git config --system credential.https://<host>.helper` (`~/.gitconfig` is ro). It is queried before helpers from the host's `~/.gitconfig` (`osxkeychain`, etc.), and once it returns a token git does not proceed to the next helper
- The sidecar's gh version is pinned with `GH_VERSION` (an ARG in `capabilities/gh/Dockerfile`). Expiring tokens need 2.103.0 or later
- The `hosts.yml` of the old scheme (`capabilities/gh/data/` rw-bound into the agent container) is no longer used. Revoke the token in it on GitHub and delete the directory

## Constraints and known holes

- The access token is readable by every process in the agent container. Until it expires, it can be exfiltrated and used
- If a single `gh` run spans the expiry of the access token (a long `gh run watch`, etc.), authentication fails partway
- GitHub does not publish the lifetime of refresh tokens. When it expires the endpoint returns 503, so run `dcc gh-login` again
- If the volume's `hosts.yml` holds a PAT (including when a token was pasted in `gh-login`) or a non-expiring token, the sidecar hands it out as is. It is not short-lived, but it is still not stored in the agent container
- Only one `GH_HOST`. To use multiple hosts, add sidecars with `local/compose.yml`
- Inner containers cannot see the endpoint. The only way to give an inner container a token is to pass it explicitly, e.g. via environment variables
- `dcc clear --volumes` does not remove `dcc-gh-home` (external volume). To delete it, run `docker volume rm dcc-gh-home`
