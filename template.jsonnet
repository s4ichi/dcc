// Single source of the configuration. `make generate` produces:
//   docker-compose.yml               base (agent = agent container + docker sidecar)
//   docker-compose.workspace.yml     workspace bind for dcc
//   docker-compose.base-image.yml    override that builds the base image when local/Dockerfile is used
//   capabilities/<name>/compose.yml  overlay per credential module
//
// Generated files are committed (usable without jsonnet on the host, and what gets mounted can be reviewed).
// After changing this file, run `make fmt && make generate`.
//
// ${VAR} is interpolated by docker compose. ${DCC_*} are per-user settings, all with defaults
// (.env.example). Paths in the repo are written as absolute paths based on ${DCC_CONFIG_DIR}, so they do not
// depend on the compose project directory (they point to the same place even when the devcontainer CLI passes a different -f order).
// The structure is described in docs/architecture.md, the boundary model in docs/boundaries.md.

local home = '${HOME}';
local configDir = '${DCC_CONFIG_DIR:-${HOME}/.config/dcc}';

// User inside the container. Must match the build arg in the Dockerfile
local remoteUser = '${DCC_USER:-agent}';
local remoteUid = '${DCC_UID:-1000}';
local remoteGid = '${DCC_GID:-${DCC_UID:-1000}}';
local remoteHome = '/home/' + remoteUser;

// Exported by dcc. Only the workspace overlay uses it; using it without dcc fails with :?
local workspaceSource = '${LOCAL_WORKSPACE_FOLDER:?run via dcc}';
local workspaceTarget = '/workspaces/${LOCAL_WORKSPACE_BASENAME:?run via dcc}';

// When the claude module (rw sharing of the host's ~/.claude) is not selected, an empty fixed-name volume is
// shared across all workspaces (auth and history stay inside the containers)
local claudeDir = '${DCC_CLAUDE_DIR:-${HOME}/.claude}';
local claudeJson = '${DCC_CLAUDE_JSON:-${HOME}/.claude.json}';
local claudeHomeVolume = '${DCC_CLAUDE_HOME_VOLUME:-dcc-claude-home}';
// The codex module has the same shape (~/.codex). config.toml is written via rename, so always pass the whole directory
local codexDir = '${DCC_CODEX_DIR:-${HOME}/.codex}';
local codexHomeVolume = '${DCC_CODEX_HOME_VOLUME:-dcc-codex-home}';
local gitconfig = '${DCC_GITCONFIG:-${HOME}/.gitconfig}';

// Agent image. When local/Dockerfile exists it is built in 2 stages, base (this repo's Dockerfile) -> final, and
// dcc exports DCC_BUILD_CONTEXT / DCC_DOCKERFILE to swap the build source of final
local agentImage = '${DCC_IMAGE:-dcc:local}';
local baseImage = '${DCC_BASE_IMAGE:-dcc:base}';
local buildContext = '${DCC_BUILD_CONTEXT:-' + configDir + '}';
local dockerfile = '${DCC_DOCKERFILE:-Dockerfile}';
// The only privileged container, so pin it by digest (the tag is for readability; pull is decided by the digest).
// Renovate bumps the tag and the index digest here and in .env.example together (renovate.json), then runs
// `make generate`. Keep the `DCC_DIND_IMAGE:-docker:<tag>@sha256:<digest>` shape it matches. docs/docker.md
local dindImage = '${DCC_DIND_IMAGE:-docker:29.9.3-dind-rootless@sha256:87e10120f2f9dd99ff78f30ff1e27a86b96ed1371e9bb50be7e96bfb00fd69b4}';
local goVersion = '${DCC_GO_VERSION:-1.27.3}';

local buildArgs = {
  BASE_IMAGE: baseImage,
  USERNAME: remoteUser,
  USER_UID: remoteUid,
  USER_GID: remoteGid,
  GO_VERSION: goVersion,
};

// Docker sidecar. The service name 'docker' is fixed because it is included in the SAN of the TLS certificate
local certsDir = '/certs';
local sharedNetns = 'service:docker';
local dindDataDir = '/home/rootless/.local/share/docker';

// Returns the compose long syntax (type / source / target / read_only).
// Multi-file volumes are merged by appending with target as the key; for the same target the last one wins
local bind(source, target, readonly=false) = {
  type: 'bind',
  source: source,
  target: target,
  [if readonly then 'read_only']: true,
};

local volume(source, target, readonly=false) = {
  type: 'volume',
  source: source,
  target: target,
  [if readonly then 'read_only']: true,
};

// Bind target of lifecycle_hooks/. postCreate runs from here (same value as REMOTE_HOOKS_DIR in dcc)
local hooksDir = '/usr/local/lib/dcc/hooks';

// Files of this repository are bound as directories that hold only what the agent container may see
// (capabilities/<module>/agent, capabilities/ssh/conf). A single-file bind pins the file's inode, so git pull / checkout
// or an editor's save, which replace the file, would leave the container on the old (or vanished) file. docs/boundaries.md
local moduleLibDir(name) = '/usr/local/lib/dcc/' + name;

// Bound at the same path into the agent container and the sidecar. The sidecar's dockerd resolves `docker run -v /workspaces/...`
local workspaceMount = bind(workspaceSource, workspaceTarget) { consistency: 'cached' };

// Module sidecars listen on 127.0.0.1 in the shared netns (the SDK credential providers only allow
// loopback). The port can collide with -p of inner containers, so it is configurable
local awsCredentialsPort = '${DCC_AWS_CREDENTIALS_PORT:-8080}';
local awsDir = '${DCC_AWS_DIR:-${HOME}/.aws}';
local awsRegion = '${DCC_AWS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}';
local awsProfile = '${DCC_AWS_PROFILE:-${AWS_PROFILE:-default}}';

local gpgSignerPort = '${DCC_GPG_SIGNER_PORT:-8081}';
local gnupgDir = '${DCC_GNUPG_DIR:-${GNUPGHOME:-${HOME}/.gnupg}}';
local gpgExportDir = '${DCC_GPG_EXPORT_DIR:-' + configDir + '/capabilities/gpg/gnupg-host}';
local gpgSignClient = moduleLibDir('gpg') + '/gpg-sign-client.sh';

local sshDir = '${DCC_SSH_DIR:-' + configDir + '/capabilities/ssh/data}';
// github.conf + known_hosts. The image includes /etc/ssh/dcc/*.conf from ssh_config.d
local sshConfDir = '${DCC_SSH_CONF_DIR:-' + configDir + '/capabilities/ssh/conf}';
// gh state (refresh token) lives in a fixed-name external volume shared by the gh-token sidecars of all workspaces
// (so the flock on refresh.lock reliably takes effect; dcc creates it). The agent container only gets access tokens
local ghTokenPort = '${DCC_GH_TOKEN_PORT:-8082}';
local ghHost = '${DCC_GH_HOST:-github.com}';
local ghHomeVolume = '${DCC_GH_HOME_VOLUME:-dcc-gh-home}';

// Credential modules. Only those selected with `dcc --creds <name>,...` are passed as overlays.
// The key becomes the directory name capabilities/<name>/. docs/credentials.md
local credModules = {
  // ~/.aws is not passed to the agent container. The sidecar issues temporary credentials from the login session. docs/aws.md
  aws: {
    services: {
      agent: {
        environment: {
          AWS_CONTAINER_CREDENTIALS_FULL_URI: 'http://127.0.0.1:' + awsCredentialsPort + '/credentials',
          AWS_REGION: awsRegion,
        },
        depends_on: { 'aws-credentials': { condition: 'service_started' } },
        // For drift detection in dcc
        labels: { 'dcc.aws-profile': awsProfile },
      },
      'aws-credentials': {
        image: 'dcc-aws-credentials:local',
        build: { context: configDir + '/capabilities/aws' },
        network_mode: sharedNetns,
        environment: {
          AWS_PROFILE: awsProfile,
          AWS_REGION: awsRegion,
          BIND_PORT: awsCredentialsPort,
        },
        volumes: [
          bind(awsDir + '/config', '/root/.aws/config', readonly=true),
          bind(awsDir + '/login/cache', '/root/.aws/login/cache', readonly=true),
        ],
      },
    },
  },

  // Share the host's ~/.claude (settings, history, credentials) rw. docs/claude-code.md
  // Without it the base volume (claude-home) is used, and auth is held independently on the container side
  claude: {
    services: {
      agent: {
        volumes: [
          bind(claudeDir, remoteHome + '/.claude'),
          // A single-file bind makes Claude Code's atomic write (rename) fail with EXDEV, so
          // pass it ro and postCreate copies it to a container-local file
          bind(claudeJson, remoteHome + '/.claude.json.host', readonly=true),
        ],
      },
    },
  },

  // Share the host's ~/.codex (settings, history, credentials in auth.json) rw. docs/codex.md
  // Without it the base volume (codex-home) is used, and auth is held independently on the container side
  codex: {
    services: {
      agent: {
        volumes: [
          bind(codexDir, remoteHome + '/.codex'),
        ],
      },
    },
  },

  // Signing is delegated to the gpg-signer sidecar. The private key and passphrase exist only in the sidecar, and
  // the agent container calls the signing API through the gpg.program wrapper. docs/gpg.md
  gpg: {
    services: {
      agent: {
        environment: {
          DCC_GPG_SIGN_URI: 'http://127.0.0.1:' + gpgSignerPort + '/sign',
          // Pin to the wrapper in the highest-priority git config layer (overrides gpg.program in the host's ~/.gitconfig)
          GIT_CONFIG_COUNT: '1',
          GIT_CONFIG_KEY_0: 'gpg.program',
          GIT_CONFIG_VALUE_0: gpgSignClient,
        },
        depends_on: { 'gpg-signer': { condition: 'service_started' } },
        volumes: [
          bind(gpgExportDir, remoteHome + '/.gnupg-host', readonly=true),
          bind(configDir + '/capabilities/gpg/agent', moduleLibDir('gpg'), readonly=true),
        ],
      },
      'gpg-signer': {
        image: 'dcc-gpg-signer:local',
        build: { context: configDir + '/capabilities/gpg' },
        network_mode: sharedNetns,
        environment: { BIND_PORT: gpgSignerPort },
        volumes: [
          bind(gnupgDir + '/private-keys-v1.d', '/host-keys', readonly=true),
          bind(gpgExportDir, '/gnupg-host', readonly=true),
        ],
      },
    },
  },

  // For connecting to GitHub. Connection settings and host keys go ro to /etc/ssh, the container-only private key ro to ~/.ssh. docs/ssh.md
  ssh: {
    services: {
      agent: {
        volumes: [
          bind(sshDir, remoteHome + '/.ssh', readonly=true),
          bind(sshConfDir, '/etc/ssh/dcc', readonly=true),
        ],
      },
    },
  },

  // The refresh token exists only in the gh-token sidecar; the agent container receives a short-lived access token
  // every time through the gh wrapper and the git credential helper. docs/github.md
  gh: {
    services: {
      agent: {
        environment: {
          DCC_GH_TOKEN_URI: 'http://127.0.0.1:' + ghTokenPort + '/token',
          DCC_GH_HOST: ghHost,
        },
        depends_on: { 'gh-token': { condition: 'service_started' } },
        volumes: [
          // The image puts this directory first on PATH, so its gh (a symlink to gh-token-client.sh) is found
          // before /usr/bin/gh. Without the module the directory does not exist and plain gh runs
          bind(configDir + '/capabilities/gh/agent', moduleLibDir('gh'), readonly=true),
        ],
      },
      'gh-token': {
        image: 'dcc-gh-token:local',
        build: { context: configDir + '/capabilities/gh' },
        network_mode: sharedNetns,
        environment: {
          BIND_PORT: ghTokenPort,
          GH_HOST: ghHost,
        },
        volumes: [
          volume('gh-home', '/home/gh/.config/gh'),
        ],
      },
    },
    volumes: {
      'gh-home': { name: ghHomeVolume, external: true },
    },
  },
};

local compose = {
  services: {
    agent: {
      image: agentImage,
      build: {
        context: buildContext,
        dockerfile: dockerfile,
        args: buildArgs,
      },
      // sleep as PID 1 ignores SIGTERM and stop waits for the grace period (10s), so put an init (tini) in front
      command: ['sleep', 'infinity'],
      init: true,
      // Share the netns with the sidecar (ports / hostname / dns / extra_hosts cannot be set here)
      network_mode: sharedNetns,
      // Cut off paths from the agent's processes up to root (disable setuid / file capabilities, and give no
      // capabilities even to things running as root). postCreate steps that need root are called by dcc with exec --user root
      // (postCreate-root.sh). docs/boundaries.md
      security_opt: ['no-new-privileges:true'],
      cap_drop: ['ALL'],
      depends_on: { docker: { condition: 'service_started' } },
      environment: {
        DOCKER_HOST: 'tcp://docker:2376',
        DOCKER_TLS_VERIFY: '1',
        DOCKER_CERT_PATH: certsDir + '/client',
        TZ: '${DCC_TZ:-${TZ:-UTC}}',
        HOST_HOME: home,
        DCC_CREDS: '${DCC_CREDS-}',
        // Only for the postCreate hooks' messages (which volume ~/.claude / ~/.codex is, to remove it)
        DCC_CLAUDE_HOME_VOLUME: claudeHomeVolume,
        DCC_CODEX_HOME_VOLUME: codexHomeVolume,
      },
      // The user's environment variables. dcc collects DCC_CONTAINER_ENV_<NAME>=value into a temp file and
      // passes its path in DCC_CONTAINER_ENV_FILE (empty if none)
      env_file: [{ path: '${DCC_CONTAINER_ENV_FILE:-/dev/null}', required: false }],
      // For drift detection in dcc
      labels: {
        'dcc.credentials': '${DCC_CREDS-}',
      },
      volumes: [
        // Personal files referenced by include are not bound (git ignores includes that do not exist)
        bind(gitconfig, remoteHome + '/.gitconfig', readonly=true),
        // The claude module overrides the same target with a bind of the host's ~/.claude
        volume('claude-home', remoteHome + '/.claude'),
        // Likewise the codex module overrides it with a bind of the host's ~/.codex
        volume('codex-home', remoteHome + '/.codex'),
        // The Claude Code binary (~/.local/share/claude) is not a volume. The baked-in version in the image is authoritative;
        // auto-updates stay in the container layer and recreate reverts to the baked-in version (postCreate updates it).
        // As a volume it would diverge from the ~/.local/bin/claude symlink (outside the volume) and break after a rebuild
        volume('docker-certs', certsDir, readonly=true),
        bind(configDir + '/lifecycle_hooks', hooksDir, readonly=true),
      ],
    },

    // No credentials are mounted at all. privileged is set only on this service
    docker: {
      image: dindImage,
      privileged: true,
      environment: { DOCKER_TLS_CERTDIR: certsDir },
      // So rootlesskit can publish ports below 1024
      sysctls: { 'net.ipv4.ip_unprivileged_port_start': 0 },
      volumes: [
        volume('docker-certs', certsDir),
        volume('docker-data', dindDataDir),
        // The image also declares VOLUME /var/lib/docker, which rootless dockerd does not use. Unmapped, every
        // container creation leaves an empty anonymous volume behind (down without --volumes keeps it). docs/docker.md
        { type: 'tmpfs', target: '/var/lib/docker' },
      ],
    },
  },

  // Prefixed with the project name, so independent per workspace.
  // Only claude-home / codex-home are fixed-name external volumes (created by dcc; not removed even by down --volumes)
  volumes: {
    'claude-home': { name: claudeHomeVolume, external: true },
    'codex-home': { name: codexHomeVolume, external: true },
    'docker-certs': {},
    'docker-data': {},
  },
};

// When used from devcontainer, give the same bind in the workspace-side compose (docs/devcontainer.md)
local workspaceOverlay = {
  services: {
    agent: {
      labels: { 'dcc.workspace': workspaceSource },
      volumes: [workspaceMount],
    },
    docker: {
      volumes: [workspaceMount],
    },
  },
};

// When local/Dockerfile exists, override to build its FROM target (base) from this repo's Dockerfile.
// dcc build / dcc up add it to -f only when running `build agent`
local baseImageOverlay = {
  services: {
    agent: {
      image: baseImage,
      build: {
        context: configDir,
        dockerfile: 'Dockerfile',
      },
    },
  },
};

// Output: file name -> YAML string. `jsonnet -S -m .` writes each field to a file of the same name
local yaml(obj) = std.manifestYamlDoc(obj, indent_array_in_object=true, quote_keys=false) + '\n';

{
  'docker-compose.yml': yaml(compose),
  'docker-compose.workspace.yml': yaml(workspaceOverlay),
  'docker-compose.base-image.yml': yaml(baseImageOverlay),
} + {
  ['capabilities/' + name + '/compose.yml']: yaml(credModules[name])
  for name in std.objectFields(credModules)
}
