# SSH keys

**Module name: `ssh`** — enabled only when `dcc --creds ssh` is given ([credentials.md](credentials.md)).

## What it protects

| Asset | Location | Nature |
|---|---|---|
| Private keys in the host's `~/.ssh/` | host | Long-lived keys tied to all personal access (GitHub, servers, etc.) |
| The host's `ssh-agent` (Keychain integration) | host | A state in which the above keys work without entering a passphrase |
| Container-only private key `id_ed25519` | `<repo>/capabilities/ssh/data/` (gitignored) | A key registered on GitHub only for the repositories that need it |

## Boundary

| Axis | This design |
|---|---|
| What it can do | The agent container can only "connect to GitHub over SSH with the container-only key". The permissions granted to the key (deploy key / dedicated account) are the ceiling |
| Reach | The host's `~/.ssh` and `ssh-agent` are never passed. The container-only key directory is bound ro to `~/.ssh`, and connection settings and host keys are injected ro into `/etc/ssh` |
| How the key is passed | **The plaintext key is passed as is** (ro bind). Compensated by making the key container-only and restricting its permissions |

## What leaks on compromise

If the agent container is taken over:

- The container-only private key can be exfiltrated (readable even ro). Damage from a leak is limited to the permissions granted to that key, and deleting the key on GitHub stops it
- The host's keys and agent are unreachable
- Not visible from inner containers (this directory is not passed to the sidecar)

## Why this design

- **Do not bind the host's `~/.ssh`**: the host's private keys are tied to all personal access. Too much authority to hand to Claude Code in a container
- **Do not use agent forwarding**: the Unix socket of macOS's `ssh-agent` (Keychain integration) cannot cross the Docker VM boundary. It needs extra setup and has no guarantee of always working
- **Pass the key as is**: unlike signing (gpg) or AWS, SSH has no cheap form of "delegated execution". Instead, restrict the permissions of the key that is passed
- **Inject connection settings and host keys into `/etc/ssh`**: pinning GitHub's host keys (`GlobalKnownHostsFile` of the GitHub host) avoids the first-connection confirmation prompt and avoids writing to `~/.ssh/known_hosts`. A `git push` from Claude Code's Bash tool, which has no TTY, does not stall there. Since no writes are needed, `~/.ssh` can be ro

## How it works

| Host side | Container side | Mode | Tracked |
|---|---|---|---|
| `<repo>/capabilities/ssh/conf/` (`DCC_SSH_CONF_DIR`) | `/etc/ssh/dcc/` | ro | yes |
| `<repo>/capabilities/ssh/data/` (`DCC_SSH_DIR`) | `/home/agent/.ssh/` | ro | no (gitignored) |

- `conf/github.conf`: `User git` / `IdentityFile ~/.ssh/id_ed25519` / `IdentitiesOnly yes` / `GlobalKnownHostsFile /etc/ssh/dcc/known_hosts` for `Host github.com`. The image has `/etc/ssh/ssh_config.d/dcc.conf` = `Include /etc/ssh/dcc/*.conf` (Debian's `/etc/ssh/ssh_config` includes `ssh_config.d/*.conf`); without the module the directory is absent and the include matches nothing
- `conf/known_hosts`: GitHub's host keys (`ssh_keys` from `https://api.github.com/meta`)
- `conf/` is bound as a directory, not file by file: a single-file bind keeps the inode it was given, so after `git pull` (or an editor's save) replaces a file the container would keep the old one ([boundaries.md](boundaries.md)). To use other settings, point `DCC_SSH_CONF_DIR` at a directory with the same two files
- `data/`: only the private key `id_ed25519` (and `.pub`). If you place a `~/.ssh/config`, it takes precedence over the system config as personal settings (ssh uses the first value found)

### Setup

Do this on the host with this repository (`<repo>`) as the current directory.

1. Create a container-only key (with an empty passphrase; see "Constraints and known holes" below):
   ```bash
   mkdir -p capabilities/ssh/data
   ssh-keygen -t ed25519 -N '' -f capabilities/ssh/data/id_ed25519 -C "dcc"
   chmod 700 capabilities/ssh/data; chmod 600 capabilities/ssh/data/id_ed25519   # the host-side permissions are visible at the bind target too
   ```
2. Register the public key (`id_ed25519.pub`) on GitHub **as a deploy key or as a key of a dedicated account**. Limit write access to only the repositories that need it
3. Start with `dcc --creds ssh` (`dcc recreate --creds ssh` if a container already exists) and confirm that `ssh -T git@github.com` works inside the container

If you rename the key, update `IdentityFile` in `conf/github.conf` to match. `initialize.sh ssh` warns in advance if `data/` is missing.

### Updating host keys

If GitHub rotates its host keys, regenerate `known_hosts` and commit it:

```bash
curl -sS https://api.github.com/meta | jq -r '.ssh_keys[] | "github.com \(.)"' > capabilities/ssh/conf/known_hosts
ssh-keygen -lf capabilities/ssh/conf/known_hosts   # compare the fingerprints with GitHub's published ones
```

## Constraints and known holes

- The private key is readable by every process in the agent container. The design limits damage through the key's permissions; the key itself cannot be protected
- Passphrase-protected keys cannot be used. There is no automatic `ssh-agent` startup in the container, and pinentry cannot be shown from the TTY-less Bash tool. Either use a key without a passphrase or add a mechanism equivalent to gpg's warming (not implemented)
- SSH signing (`gpg.format = ssh`) is possible by setting this key as `user.signingkey`, but the warming mechanism assumes GPG
- If an inner container needs SSH, the only way is to pass it explicitly via the workspace
- `capabilities/ssh/data/` is gitignored; do not commit it. `conf/` is tracked but contains only GitHub's public information
