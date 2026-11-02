# AWS credentials

**Module name: `aws`** — enabled only when `dcc --creds aws` is given ([credentials.md](credentials.md)).

## What it protects

| Asset | Location | Nature |
|---|---|---|
| `~/.aws/login/cache/` | host | The `aws login` session. Temporary credentials can be issued from it |
| `~/.aws/credentials` | host | Static access keys. Long-lived keys |
| `~/.aws/config` | host | Profile definitions. Not secret, but reveals which accounts hold what |
| `~/.aws/sso/cache/`, `~/.aws/cli/cache/` | host | SSO / CLI token caches |

## Boundary

| Axis | This design |
|---|---|
| What it can do | The agent container can only "obtain temporary credentials as one profile already logged in on the host". It cannot switch profiles (fixed at container creation) |
| Reach | Nothing under `~/.aws` is mounted into the agent container. `config` and `login/cache` are passed ro only to the unprivileged `aws-credentials` sidecar. `credentials` (long-lived keys) and the SSO / CLI caches are passed nowhere |
| How the key is passed | **Delegated execution**. The sidecar runs `aws configure export-credentials`, and the agent container receives only expiring temporary credentials through the SDK's Container Credential Provider (`AWS_CONTAINER_CREDENTIALS_FULL_URI`). The sidecar fetches the credentials; the agent container only receives the result |

## What leaks on compromise

If the agent container (where Claude may run arbitrary code) is taken over:

- The attacker gains at most "the ability to obtain temporary credentials for that profile while the login session is valid". The temporary credentials themselves can be exfiltrated, but they expire at `Expiration`
- The long-lived keys (`~/.aws/credentials`) and the login session token are not in the agent container, so they cannot be exfiltrated
- The endpoint exists only on `127.0.0.1` in the shared netns, so it is unreachable from inner containers, the host, and other compose projects
- Once you `aws logout` on the host or the login session expires, further issuance stops

The sidecar runs nothing but its own `server.py`, and its access log contains only method / path / status, never credentials.

## Why this design

- **Do not bind `~/.aws` into the agent container**: even ro, every profile in `config` / `credentials` would be readable. The principle is not to bring long-lived keys into the container
- **Shared netns + `127.0.0.1`**: the AWS SDK's Container Credential Provider allows `http://` endpoints only on loopback (127.0.0.1 / localhost / ::1) and the ECS/EKS link-local addresses. `http://aws-credentials:8080` over a dedicated network is a different netns and IP, so botocore rejects it with `Unsupported host`. Therefore the sidecar also joins the Docker sidecar's netns with `network_mode: service:docker`. As a consequence the endpoint is reachable only from inside the netns (`ports` cannot even be written)
- **No caching in the sidecar**: the SDK caches on its own until `Expiration`, and login session management is left to the CLI. The sidecar only converts
- **`depends_on` is agent → aws-credentials**: both merely join the `docker` netns and do not depend on each other, so there is no cycle

## How it works

```
 agent (agent container)                      aws-credentials (sidecar, unprivileged)
  AWS_CONTAINER_CREDENTIALS_FULL_URI          python3 /server.py listens on 127.0.0.1:8080
   = http://127.0.0.1:8080/credentials   ──►   GET /credentials
  AWS_REGION                                    └─ aws configure export-credentials
                                                    --profile $AWS_PROFILE --format process
                                              mount: ~/.aws/config (ro)
                                                     ~/.aws/login/cache (ro)
        └───────── shared netns (both network_mode: service:docker) ─────────┘
```

| Item | Destination | Mode |
|---|---|---|
| `~/.aws/config` (configurable with `DCC_AWS_DIR`) | sidecar `/root/.aws/config` | ro |
| `~/.aws/login/cache` | sidecar `/root/.aws/login/cache` | ro |
| Temporary credentials (AccessKeyId / SecretAccessKey / Token / Expiration) | agent container (HTTP) | — |

### Setup

Run `aws login` on the host (with the profile you will use), set `AWS_PROFILE` (or `DCC_AWS_PROFILE`), and run `dcc --creds aws`.
Inside the container, check with `aws sts get-caller-identity`.

### Details

- The sidecar image is `public.ecr.aws/aws-cli/aws-cli` (`capabilities/aws/`). For each `GET /credentials` it runs `export-credentials`, converts the result to the Container Credential Provider format, and returns it. A result without `SessionToken` / `Expiration` (long-lived keys) is refused. On failure it returns 503 (body contains only `Code` / `Message`); anything other than `/credentials` is 404
- compose interpolates profile / region from the host's environment variables at `dcc` run time (profile: `DCC_AWS_PROFILE` → `AWS_PROFILE` → `default`; region: `DCC_AWS_REGION` → `AWS_REGION` → `AWS_DEFAULT_REGION` → `us-east-1`; [customization.md](customization.md)). `AWS_REGION` is also passed to the sidecar itself (if the profile has no region, `export-credentials` fails with `NoRegion`)
- `dcc` warns about a change of `AWS_PROFILE` as drift (label `dcc.aws-profile`; apply with `dcc recreate`)
- The agent container's AWS CLI v2 / SDKs (Go v2, boto3, Terraform, etc.) pick up `AWS_CONTAINER_CREDENTIALS_FULL_URI` automatically. Inside the container the concept of a profile is unavailable (`--profile` yields `ProfileNotFound`)
- `initialize.sh aws` warns in advance if `config` / `login/cache` are missing (otherwise `up` fails or an empty directory is created at that location; see "When a bind source is missing" in [customization.md](customization.md))

## Constraints and known holes

- Assumes `aws login` has been done on the host. If expired, the endpoint returns 503. Logging in again on the host recovers from the next request without restarting the sidecar
- Temporary credentials are readable by every process in the agent container. Once exfiltrated, they are usable until they expire
- Only temporary credentials are served. If the profile resolves to a static access key (`aws_access_key_id` in `~/.aws/config`,
  etc.; no `SessionToken` / `Expiration`), the endpoint returns 503 instead of handing a long-lived key to the agent container.
  Such a profile cannot be used with this module; use `aws login`, SSO or a role (the SDKs' container provider requires
  `Token` / `Expiration` anyway)
- Because `~/.aws/login/cache` is ro, flows where the CLI must write back a refresh token may fail (unverified; if it becomes a problem, the trade-off is to make only `login/cache` rw)
- SSO profiles (`aws sso login`) and profiles that call an external command via `credential_process` do not work, since those files are not passed to the sidecar / the command is absent. Add them with `local/compose.yml` if needed
- Inner containers cannot see the endpoint (they cannot reach the parent netns's `127.0.0.1`). The only way to give an inner container AWS permissions is to pass them explicitly, e.g. via environment variables
