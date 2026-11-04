# GPG (commit signing)

**Module name: `gpg`** — enabled only when `dcc --creds gpg` is given ([credentials.md](credentials.md)).

## What it protects

| Asset | Location | Nature |
|---|---|---|
| `~/.gnupg/private-keys-v1.d/*.key` | host | Private keys (encrypted with a passphrase). Includes keys other than the signing key |
| Passphrase of the signing key | Not stored on the host. A human types it | Without it the private key is unusable |
| gpg-agent cache | agent on the host / sidecar | A state in which signing works without entering the passphrase |
| Public keys and ownertrust | host | Not secret, but contain names and email addresses |

## Boundary

| Axis | This design |
|---|---|
| What it can do | The agent container can only "ask for a commit / tag object to be signed with one fixed signing key". It cannot sign arbitrary data, choose a key, or decrypt |
| Reach | The agent container has no private key, no gpg-agent, and no pinentry. `~/.gnupg/private-keys-v1.d` is passed ro only to the `gpg-signer` sidecar, which copies just the signing key's keygrip files from it to container-local storage. The agent container only has the public keys (for verification) and a wrapper |
| How the key is passed | **Delegated execution**. The agent container's git calls the sidecar's signing API (`127.0.0.1:8081`) through the wrapper registered as `gpg.program`. A human enters the passphrase in the sidecar's pinentry, and it is cached in the sidecar's gpg-agent |

## What leaks on compromise

If the agent container is taken over:

- The attacker gains at most "the ability to have commit / tag objects signed". The signing API returns 403 unless the payload is a git object (first line `tree <sha>` / `object <sha>`)
- Neither the private key material nor the passphrase is in the agent container, so they cannot be exfiltrated. The sidecar's cache is also out of reach from the agent container
- There is no per-request confirmation for signing. Having a malicious commit signed from the agent container cannot be prevented (the part delegation cannot protect)
- The sidecar runs nothing but its own `server.py`

## Why this design

- **Do not bind the host's `~/.gnupg` into the agent container**: the Unix socket of macOS's gpg-agent (pinentry-mac) does not cross the Docker VM boundary. The host's gpg 2.4 / 2.5 uses `keyboxd`, and the container's gpg 2.2 (Debian bookworm) cannot read that public keyring. Writing to it could break the host side
- **Isolate the whole signing process in a sidecar**: putting the private key in the agent container would co-locate key material and the passphrase cache where Claude runs. With a sidecar, the agent container only sees an HTTP endpoint
- **Pass public keys as an armor export**: because of the keyboxd incompatibility. The host-side preprocessing writes them to a file, and the sidecar and the agent container import it
- **Pass signing key info via files, not environment variables**: via devcontainer, the result of `initializeCommand` cannot be passed into compose environment variables. A file reaches both `dcc` and devcontainer by the same path ([devcontainer.md](devcontainer.md))
- **Match git's contract**: git calls signing as `<gpg.program> --status-fd=2 -bsau <key>` (object on stdin, armored detached signature on stdout, `[GNUPG:] SIG_CREATED` on fd2). The wrapper does not fabricate the status; it relays verbatim to fd2 what the gpg inside the sidecar emitted. Verification (`--verify`) is delegated to the plain gpg in the agent container (public keys suffice)

## How it works

| Host side | Mount target | Mode | Purpose |
|---|---|---|---|
| `~/.gnupg/private-keys-v1.d/` (`DCC_GNUPG_DIR`) | `/host-keys/` in `gpg-signer` | ro | Source for copying the signing key's keygrip files (**not mounted into the agent container**) |
| `<repo>/capabilities/gpg/gnupg-host/` (`DCC_GPG_EXPORT_DIR`) | `/gnupg-host/` in `gpg-signer`, `~/.gnupg-host/` in the agent container | ro | `pubkeys.asc` / `ownertrust.txt` / `keygrips.txt` / `signing-key.txt` exported by the host-side preprocessing |
| `<repo>/capabilities/gpg/agent/` (`gpg-sign-client.sh`) | `/usr/local/lib/dcc/gpg/` in the agent container | ro | `gpg.program` wrapper. Bound as a directory so updates of the file reach the container ([boundaries.md](boundaries.md)) |
| (none) | `/root/.gnupg/` in `gpg-signer` | local | Keyring built by the entrypoint |
| (none) | `~/.gnupg/` in the agent container | local | **Verification-only** keyring built by postCreate |

### Setup

If signing already works on the host (`gpg` is installed, and `~/.gitconfig` has `user.signingkey` and, if needed, `commit.gpgsign = true`),
no extra preparation is needed. When started with `dcc --creds gpg`, the sidecar's pinentry asks for the passphrase once, right before claude starts.
To specify the signing key somewhere other than `~/.gitconfig`, use `DCC_GPG_SIGNING_KEY` ([customization.md](customization.md)).
The rest describes the internal flow.

### 1. Host side (`capabilities/gpg/export-host-keys.sh`)

Called from `lifecycle_hooks/initialize.sh gpg` (`dcc up` passes it only when `gpg` is enabled; with devcontainer, write it in `initializeCommand`). Writes to `gnupg-host/`:

- `pubkeys.asc` / `ownertrust.txt`: public keys of every key that has a private key (all keys, since they are also used for verification)
- `keygrips.txt`: the keygrips of the signing key (`DCC_GPG_SIGNING_KEY`, otherwise `git config user.signingkey`; a trailing `!` is stripped). The sidecar copies **only** the keys listed here
- `signing-key.txt`: the primary fingerprint of the signing key

If gpg is missing, there is no private key, or no signing key is configured, it only prints a warning and skips (usable without signing).

### 2. Sidecar side (`capabilities/gpg/entrypoint.sh`)

At startup it builds a container-local `/root/.gnupg`: `gpg-agent.conf` (`pinentry-curses`, cache TTL 400 days) → import public keys and ownertrust → copy only the keygrip files listed in `keygrips.txt` from `/host-keys` (600) → pin the value of `signing-key.txt` into `/run/signing-key` and exec `server.py`.

### 3. Agent container side (postCreate)

`postCreate-root.sh` (root) registers `git config --system gpg.program <wrapper>` only when the wrapper mount exists, and `setup_gnupg` in `postCreate.sh` (container user) imports public keys and ownertrust into the container-local keyring only when `~/.gnupg-host/pubkeys.asc` exists. The primary path is the environment variables `GIT_CONFIG_COUNT=1` / `GIT_CONFIG_KEY_0=gpg.program` / `GIT_CONFIG_VALUE_0=<wrapper>` that compose sets in the gpg overlay (the highest-priority layer of git config), which pins it on top even if the host's `~/.gitconfig` sets `gpg.program`. The system registration is a fallback for when the env is stripped (tools that go through `env -i`, etc.).

### 4. Warming the passphrase (`capabilities/gpg/warm.sh`)

Run in an interactive terminal on the host; it goes through the sidecar's pinentry via `docker exec -it <gpg-signer> gpg-warm.sh`. If not cached yet, pinentry-curses appears once. The sidecar is located with `-p <project>` or from the label of an agent container that has a workspace (`dcc.workspace` / `devcontainer.local_folder`). `dcc` / `dcc exec` call it automatically right before starting claude, **only when `gpg` is enabled and stdin/stdout are TTYs**. With devcontainer, run it manually once after up.

### 5. At signing time

```
git commit -S
 └─ gpg.program = gpg-sign-client.sh --status-fd=2 -bsau <key>   # <key> is not used
     └─ POST http://127.0.0.1:8081/sign  (payload = commit object)
         └─ sidecar: validate (starts with tree/object?) → gpg --pinentry-mode error -bsau $DCC_GPG_SIGNING_KEY
     ◄─ {"signature": <armor>, "status": <gpg --status-fd output>}
 ◄─ stdout: signature / fd2: status (SIG_CREATED)
```

Thanks to `--pinentry-mode error`, if the passphrase is not cached it returns 503 instead of hanging, the wrapper prints an error, and `git commit` fails cleanly.
The image's git (2.39, Debian bookworm) keeps gpg.program's stderr to itself and prints only `gpg failed to sign the data`,
so when git is the caller the wrapper also appends the reason (`gpg-sign-client: signing failed (HTTP 503): ... run
capabilities/gpg/warm.sh ...`) to git's own stderr (`/proc/<git>/fd/2`). That is what the agent sees.

The signing key is resolved at host-side export time and pinned when the sidecar starts. If you change the key, run `dcc recreate` (`dcc` compares the running sidecar's `/run/signing-key` with the export result and warns if they differ). `commit.gpgsign = true` follows the host's `~/.gitconfig*` ([git.md](git.md)).

## Constraints and known holes

- The agent container can request signatures freely. For per-request confirmation, shorten the TTL of the sidecar's gpg-agent (`entrypoint.sh`) or add an extension that inserts a pinentry confirmation
- When the sidecar restarts (`dcc stop` / `recreate`), the passphrase cache is lost. The next `dcc` warms it again. If `dcc` runs without a TTY (CI, etc.), warming is skipped and signed commits fail
- Via devcontainer, warming is not automated (`initializeCommand` runs before the sidecar starts, `postCreateCommand` runs inside the agent container). Run `warm.sh` from the host after up
- Since the agent container has no private key, `gpg --sign` / `--decrypt` outside git cannot be used in the container (by design)
- If you add or change keys on the host, the export is refreshed by `dcc up`, but the sidecar's keyring is built at startup, so `dcc recreate` is required
- `gnupg-host/` is gitignored. `pubkeys.asc` holds public keys and `keygrips.txt` key identifiers, including names and email addresses. Depending on policy, shorten the gpg-agent TTL (400 days)
- Signed pushes (`push.gpgSign`) are not supported (rejected by the payload format check)
- The sidecar sees the whole `private-keys-v1.d` ro (only the signing key's keygrip is loaded into the keyring). If the sidecar itself
  (`server.py`, running as root) is compromised, what it can read is not just the one signing key but all of the host's private keys (encrypted with passphrases).
  The agent container cannot reach the sidecar's filesystem, so compromise of the agent container alone does not extend to this scope
