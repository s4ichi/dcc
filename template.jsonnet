// 設定の単一ソース。`make generate` で次を生成する:
//   docker-compose.yml               base (agent = 本体 + docker sidecar)
//   docker-compose.workspace.yml     dcc 用のワークスペース bind
//   docker-compose.base-image.yml    local/Dockerfile 使用時に base イメージを build する上書き
//   capabilities/<name>/compose.yml  credential モジュールごとの overlay
//
// 生成物はコミットする (ホストに jsonnet が無くても使え、何がマウントされるかをレビューできる)。
// 変更したら `make fmt && make generate`。
//
// ${VAR} は docker compose が補間する。${DCC_*} は利用者ごとの設定で、すべて既定値付き
// (.env.example)。リポジトリ内のパスは ${DCC_CONFIG_DIR} 基準の絶対パスで書き、compose の
// project directory に依存させない (devcontainer CLI から別の -f の並びで渡されても同じ場所を指す)。
// 構成の説明は docs/architecture.md、境界の考え方は docs/boundaries.md。

local home = '${HOME}';
local configDir = '${DCC_CONFIG_DIR:-${HOME}/.config/dcc}';

// コンテナ内ユーザー。Dockerfile の build arg と一致させる
local remoteUser = '${DCC_USER:-agent}';
local remoteUid = '${DCC_UID:-1000}';
local remoteGid = '${DCC_GID:-${DCC_UID:-1000}}';
local remoteHome = '/home/' + remoteUser;

// dcc が export する。workspace overlay だけが使い、dcc を通さずに使うと :? で失敗する
local workspaceSource = '${LOCAL_WORKSPACE_FOLDER:?run via dcc}';
local workspaceTarget = '/workspaces/${LOCAL_WORKSPACE_BASENAME:?run via dcc}';

// claude モジュール (ホストの ~/.claude を rw 共有) を外したときは、空の固定名 volume を
// 全ワークスペースで共有する (認証と履歴はコンテナ側に閉じる)
local claudeDir = '${DCC_CLAUDE_DIR:-${HOME}/.claude}';
local claudeJson = '${DCC_CLAUDE_JSON:-${HOME}/.claude.json}';
local claudeHomeVolume = '${DCC_CLAUDE_HOME_VOLUME:-dcc-claude-home}';
// codex モジュールも同じ形 (~/.codex)。config.toml は rename で書かれるので、必ずディレクトリ単位で渡す
local codexDir = '${DCC_CODEX_DIR:-${HOME}/.codex}';
local codexHomeVolume = '${DCC_CODEX_HOME_VOLUME:-dcc-codex-home}';
local gitconfig = '${DCC_GITCONFIG:-${HOME}/.gitconfig}';

// 本体イメージ。local/Dockerfile があるときは base (このリポジトリの Dockerfile) → final の 2 段で、
// dcc が DCC_BUILD_CONTEXT / DCC_DOCKERFILE を export して final の build 元を差し替える
local agentImage = '${DCC_IMAGE:-dcc:local}';
local baseImage = '${DCC_BASE_IMAGE:-dcc:base}';
local buildContext = '${DCC_BUILD_CONTEXT:-' + configDir + '}';
local dockerfile = '${DCC_DOCKERFILE:-Dockerfile}';
local dindImage = '${DCC_DIND_IMAGE:-docker:dind-rootless}';
local goVersion = '${DCC_GO_VERSION:-1.26.3}';

local buildArgs = {
  BASE_IMAGE: baseImage,
  USERNAME: remoteUser,
  USER_UID: remoteUid,
  USER_GID: remoteGid,
  GO_VERSION: goVersion,
};

// Docker sidecar。サービス名 'docker' は TLS 証明書の SAN に含まれるため固定
local certsDir = '/certs';
local sharedNetns = 'service:docker';
local dindDataDir = '/home/rootless/.local/share/docker';

// compose の long syntax (type / source / target / read_only) を返す。
// multi-file の volumes は target をキーに追記マージされ、同一 target は後勝ち
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

// lifecycle_hooks/ の bind 先。postCreate はここから実行する (dcc の REMOTE_HOOKS_DIR と同じ値)
local hooksDir = '/usr/local/lib/dcc/hooks';

// 本体と sidecar に同一パスで bind する。`docker run -v /workspaces/...` を解決するのは sidecar の dockerd
local workspaceMount = bind(workspaceSource, workspaceTarget) { consistency: 'cached' };

// モジュール sidecar は共有 netns の 127.0.0.1 で listen する (SDK の credential provider は
// loopback しか許可しない)。ポートは inner container の -p と衝突しうるので変更可
local awsCredentialsPort = '${DCC_AWS_CREDENTIALS_PORT:-8080}';
local awsDir = '${DCC_AWS_DIR:-${HOME}/.aws}';
local awsRegion = '${DCC_AWS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}';
local awsProfile = '${DCC_AWS_PROFILE:-${AWS_PROFILE:-default}}';

local gpgSignerPort = '${DCC_GPG_SIGNER_PORT:-8081}';
local gnupgDir = '${DCC_GNUPG_DIR:-${GNUPGHOME:-${HOME}/.gnupg}}';
local gpgExportDir = '${DCC_GPG_EXPORT_DIR:-' + configDir + '/capabilities/gpg/gnupg-host}';
local gpgSignClient = '/usr/local/lib/dcc/gpg-sign-client.sh';

local sshDir = '${DCC_SSH_DIR:-' + configDir + '/capabilities/ssh/data}';
local sshConfig = '${DCC_SSH_CONFIG:-' + configDir + '/capabilities/ssh/config}';
local sshKnownHosts = '${DCC_SSH_KNOWN_HOSTS:-' + configDir + '/capabilities/ssh/known_hosts}';
// gh の状態 (refresh token) は全ワークスペースの gh-token sidecar で共有する固定名の外部 volume に置く
// (refresh.lock の flock を確実に効かせるため。dcc が作る)。本体には access token だけを渡す
local ghTokenPort = '${DCC_GH_TOKEN_PORT:-8082}';
local ghHost = '${DCC_GH_HOST:-github.com}';
local ghHomeVolume = '${DCC_GH_HOME_VOLUME:-dcc-gh-home}';
local ghClient = '/usr/local/lib/dcc/gh-token-client.sh';

// credential モジュール。`dcc --creds <name>,...` で選んだものだけ overlay として渡る。
// キーが capabilities/<name>/ のディレクトリ名になる。docs/credentials.md
local credModules = {
  // ~/.aws は本体に渡さない。sidecar が login セッションから一時 credential を発行する。docs/aws.md
  aws: {
    services: {
      agent: {
        environment: {
          AWS_CONTAINER_CREDENTIALS_FULL_URI: 'http://127.0.0.1:' + awsCredentialsPort + '/credentials',
          AWS_REGION: awsRegion,
        },
        depends_on: { 'aws-credentials': { condition: 'service_started' } },
        // dcc の drift 検出用
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

  // ホストの ~/.claude (設定・履歴・認証情報) を rw で共有する。docs/claude-code.md
  // 外すと base の volume (claude-home) が使われ、認証はコンテナ側で独立に持つ
  claude: {
    services: {
      agent: {
        volumes: [
          bind(claudeDir, remoteHome + '/.claude'),
          // single-file bind だと Claude Code の atomic write (rename) が EXDEV で失敗するため、
          // ro で渡して postCreate がコンテナローカルへコピーする
          bind(claudeJson, remoteHome + '/.claude.json.host', readonly=true),
        ],
      },
    },
  },

  // ホストの ~/.codex (設定・履歴・認証情報 auth.json) を rw で共有する。docs/codex.md
  // 外すと base の volume (codex-home) が使われ、認証はコンテナ側で独立に持つ
  codex: {
    services: {
      agent: {
        volumes: [
          bind(codexDir, remoteHome + '/.codex'),
        ],
      },
    },
  },

  // 署名は gpg-signer sidecar に委譲する。秘密鍵とパスフレーズは sidecar にだけ存在し、
  // 本体は gpg.program の wrapper 経由で署名 API を呼ぶ。docs/gpg.md
  gpg: {
    services: {
      agent: {
        environment: {
          DCC_GPG_SIGN_URI: 'http://127.0.0.1:' + gpgSignerPort + '/sign',
          // git config の最優先レイヤで wrapper に固定する (ホストの ~/.gitconfig の gpg.program より優先)
          GIT_CONFIG_COUNT: '1',
          GIT_CONFIG_KEY_0: 'gpg.program',
          GIT_CONFIG_VALUE_0: gpgSignClient,
        },
        depends_on: { 'gpg-signer': { condition: 'service_started' } },
        volumes: [
          bind(gpgExportDir, remoteHome + '/.gnupg-host', readonly=true),
          bind(configDir + '/capabilities/gpg/gpg-sign-client.sh', gpgSignClient, readonly=true),
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

  // GitHub 接続用。接続設定とホスト鍵は /etc/ssh に、コンテナ専用の秘密鍵は ~/.ssh に ro で渡す。docs/ssh.md
  ssh: {
    services: {
      agent: {
        volumes: [
          bind(sshDir, remoteHome + '/.ssh', readonly=true),
          bind(sshConfig, '/etc/ssh/ssh_config.d/github.conf', readonly=true),
          bind(sshKnownHosts, '/etc/ssh/ssh_known_hosts', readonly=true),
        ],
      },
    },
  },

  // refresh token は gh-token sidecar にだけ存在し、本体は gh の wrapper と git の credential helper
  // 経由で短命の access token を毎回受け取る。docs/github.md
  gh: {
    services: {
      agent: {
        environment: {
          DCC_GH_TOKEN_URI: 'http://127.0.0.1:' + ghTokenPort + '/token',
          DCC_GH_HOST: ghHost,
        },
        depends_on: { 'gh-token': { condition: 'service_started' } },
        volumes: [
          bind(configDir + '/capabilities/gh/gh-token-client.sh', ghClient, readonly=true),
          // PATH 上で /usr/bin/gh より先に見つかる位置に wrapper として置く
          bind(configDir + '/capabilities/gh/gh-token-client.sh', '/usr/local/bin/gh', readonly=true),
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
      // PID 1 の sleep は SIGTERM を無視して stop が grace period (10s) まで待つため、init (tini) を挟む
      command: ['sleep', 'infinity'],
      init: true,
      // sidecar と netns を共有する (ports / hostname / dns / extra_hosts はここに書けない)
      network_mode: sharedNetns,
      // エージェントのプロセスから root へ上がる経路を断つ (setuid / file capability を無効化し、root で
      // 動くものにも capability を与えない)。root が要る postCreate の処理は dcc が exec --user root で
      // 呼ぶ (postCreate-root.sh)。docs/boundaries.md
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
      },
      // 利用者の環境変数。dcc が DCC_CONTAINER_ENV_<NAME>=value を集めて一時ファイルに書き、
      // そのパスを DCC_CONTAINER_ENV_FILE で渡す (無ければ空)
      env_file: [{ path: '${DCC_CONTAINER_ENV_FILE:-/dev/null}', required: false }],
      // dcc の drift 検出用
      labels: {
        'dcc.credentials': '${DCC_CREDS-}',
      },
      volumes: [
        // include 先の個人ファイルは bind しない (git は存在しない include を無視する)
        bind(gitconfig, remoteHome + '/.gitconfig', readonly=true),
        // claude モジュールが同じ target をホストの ~/.claude の bind で上書きする
        volume('claude-home', remoteHome + '/.claude'),
        // 同じく codex モジュールがホストの ~/.codex の bind で上書きする
        volume('codex-home', remoteHome + '/.codex'),
        // Claude Code の実体 (~/.local/share/claude) は volume にしない。イメージの焼き込み版が正で、
        // 自動更新はコンテナ層に残り recreate で焼き込み版に戻る (postCreate が最新化する)。
        // volume にすると ~/.local/bin/claude の symlink (volume 外) と食い違い、rebuild 後に壊れる
        volume('docker-certs', certsDir, readonly=true),
        bind(configDir + '/lifecycle_hooks', hooksDir, readonly=true),
      ],
    },

    // 認証情報は一切マウントしない。privileged はこのサービスだけ
    docker: {
      image: dindImage,
      privileged: true,
      environment: { DOCKER_TLS_CERTDIR: certsDir },
      // rootlesskit が 1024 未満のポートを公開できるように
      sysctls: { 'net.ipv4.ip_unprivileged_port_start': 0 },
      volumes: [
        volume('docker-certs', certsDir),
        volume('docker-data', dindDataDir),
      ],
    },
  },

  // プロジェクト名でプレフィックスされ、ワークスペースごとに独立する。
  // claude-home / codex-home だけは固定名の外部 volume (dcc が作る。down --volumes でも消えない)
  volumes: {
    'claude-home': { name: claudeHomeVolume, external: true },
    'codex-home': { name: codexHomeVolume, external: true },
    'docker-certs': {},
    'docker-data': {},
  },
};

// devcontainer から使う場合はワークスペース側の compose で同じ bind を与える (docs/devcontainer.md)
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

// local/Dockerfile があるとき、その FROM 先 (base) をこのリポジトリの Dockerfile から build するための上書き。
// dcc build / dcc up が `build agent` のときだけ -f に足す
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

// 出力: ファイル名 → YAML 文字列。`jsonnet -S -m .` が各フィールドを同名のファイルに書き出す
local yaml(obj) = std.manifestYamlDoc(obj, indent_array_in_object=true, quote_keys=false) + '\n';

{
  'docker-compose.yml': yaml(compose),
  'docker-compose.workspace.yml': yaml(workspaceOverlay),
  'docker-compose.base-image.yml': yaml(baseImageOverlay),
} + {
  ['capabilities/' + name + '/compose.yml']: yaml(credModules[name])
  for name in std.objectFields(credModules)
}
