#!/usr/bin/env bats
# dcc の純粋な関数 (docker に触らないもの) のテスト。`make test` で実行する。
# dcc を source すると関数定義だけが読まれる。docker を呼ぶ関数はテスト内で stub に差し替える。

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export DCC_CONFIG_DIR="$REPO"
  export DCC_ENV_FILE=/dev/null
  export NO_COLOR=1
  unset DCC_CREDS DCC_WORKSPACE DCC_VERBOSE DCC_AGENT DCC_CLAUDE_ARGS DCC_CODEX_ARGS
  # shellcheck disable=SC1091
  source "$REPO/dcc"
  load_config
}

# --- 引数 ---------------------------------------------------------------------

@test "parse_args: no args → default command" {
  parse_args
  [ "$COMMAND" = default ]
  [ "${#ARGS[@]}" -eq 0 ]
  [ "$CREDS_EXPLICIT" -eq 0 ]
}

@test "parse_args: --creds is a union across repeats and both syntaxes" {
  parse_args --creds gpg,ssh --creds=aws exec
  [ "$CREDS_EXPLICIT" -eq 1 ]
  [ "$CREDS_REQUEST" = "gpg,ssh,aws" ]
  [ "$COMMAND" = exec ]
}

@test "parse_args: --no-creds and --all-creds are explicit too" {
  parse_args --no-creds
  [ "$CREDS_EXPLICIT" -eq 1 ]
  [ -z "$CREDS_REQUEST" ]
  parse_args --all-creds
  [ "$CREDS_REQUEST" = "aws,claude,codex,gh,gpg,ssh" ]
}

@test "parse_args: --creds without value dies" {
  run parse_args --creds
  [ "$status" -eq 2 ]
  [[ "$output" == *"--creds requires an argument"* ]]
}

@test "parse_args: everything after -- goes to ARGS untouched" {
  parse_args exec -- --creds x --all
  [ "$COMMAND" = exec ]
  [ "${ARGS[*]}" = "--creds x --all" ]
  [ "$ALL" -eq 0 ]
}

@test "parse_args: unknown --flags are passed through as ARGS" {
  parse_args exec --resume
  [ "${ARGS[*]}" = "--resume" ]
}

# --- エージェント -----------------------------------------------------------------

@test "parse_args: agent defaults to claude" {
  parse_args
  [ "$AGENT" = claude ]
}

@test "parse_args: --agent in both syntaxes, and it is not left in ARGS" {
  parse_args --agent codex exec --resume
  [ "$AGENT" = codex ]
  [ "$COMMAND" = exec ]
  [ "${ARGS[*]}" = "--resume" ]
  parse_args exec --agent=codex
  [ "$AGENT" = codex ]
  [ "${#ARGS[@]}" -eq 0 ]
}

@test "parse_args: DCC_AGENT is the default, --agent wins over it" {
  DCC_AGENT=codex load_config
  parse_args
  [ "$AGENT" = codex ]
  parse_args --agent claude
  [ "$AGENT" = claude ]
}

@test "parse_args: unknown agent and missing value die" {
  run parse_args --agent gemini
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown agent 'gemini'"* ]]
  run parse_args --agent
  [ "$status" -eq 2 ]
  [[ "$output" == *"--agent requires an argument"* ]]
}

@test "parse_args: --agent after -- belongs to the agent, not to dcc" {
  parse_args exec -- --agent codex
  [ "$AGENT" = claude ]
  [ "${ARGS[*]}" = "--agent codex" ]
}

@test "agent_args: codex turns off its own sandbox by default, claude gets nothing" {
  AGENT=claude
  [ -z "$(agent_args)" ]
  AGENT=codex
  [ "$(agent_args)" = "-c sandbox_mode=danger-full-access -c check_for_update_on_startup=false" ]
}

@test "agent_args: DCC_*_ARGS replace the default, empty disables it" {
  DCC_CODEX_ARGS="" DCC_CLAUDE_ARGS="--model opus" load_config
  AGENT=codex
  [ -z "$(agent_args)" ]
  AGENT=claude
  [ "$(agent_args)" = "--model opus" ]
}

@test "exec_agent: preset args come first, user args are passed one by one" {
  compose() { printf '%s\n' "$@"; }
  done_step() { :; }
  REMOTE_WORKSPACE=/workspaces/x AGENT=codex
  run exec_agent resume "a b"
  [ "$status" -eq 0 ]
  [ "${lines[5]}" = agent ]
  [ "${lines[6]}" = codex ]
  [ "${lines[7]}" = "-c" ]
  [ "${lines[8]}" = "sandbox_mode=danger-full-access" ]
  [ "${lines[11]}" = resume ]
  [ "${lines[12]}" = "a b" ]
}

@test "exec_agent: no preset args leaves no empty argument behind" {
  compose() { printf '[%s]\n' "$@"; }
  done_step() { :; }
  REMOTE_WORKSPACE=/workspaces/x AGENT=claude
  run exec_agent --resume
  [ "${lines[6]}" = "[claude]" ]
  [ "${lines[7]}" = "[--resume]" ]
  [ "${#lines[@]}" -eq 8 ]
}

# --- ワークスペース ---------------------------------------------------------------

@test "resolve_workspace: first directory argument is consumed as the workspace" {
  parse_args exec "$REPO/docs" --resume
  resolve_workspace
  [ "$WORKSPACE" = "$REPO/docs" ]
  [ "${ARGS[*]}" = "--resume" ]
  [ "$LOCAL_WORKSPACE_BASENAME" = docs ]
  [ "$REMOTE_WORKSPACE" = /workspaces/docs ]
}

@test "resolve_workspace: DCC_WORKSPACE is the default" {
  DCC_WORKSPACE="$REPO/docs" parse_args
  DCC_WORKSPACE="$REPO/docs" resolve_workspace
  [ "$WORKSPACE" = "$REPO/docs" ]
}

@test "project_name: lowercased basename + 8 hex chars of the path hash" {
  WORKSPACE=/Users/me/src/My.Project LOCAL_WORKSPACE_BASENAME=My.Project
  name="$(project_name)"
  [[ "$name" =~ ^dcc-myproject-[0-9a-f]{8}$ ]]
  # 同じパスなら同じ名前
  [ "$name" = "$(project_name)" ]
  WORKSPACE=/elsewhere/My.Project
  [ "$name" != "$(project_name)" ]
}

# --- credential モジュール --------------------------------------------------------

@test "resolve_creds: flags → normalized order, DCC_CREDS exported" {
  CREDS_EXPLICIT=1 CREDS_REQUEST="ssh, aws"
  resolve_creds
  [ "$CREDS" = "aws ssh" ]
  [ "$DCC_CREDS" = "aws,ssh" ]
  [ "$CREDS_SOURCE" = flags ]
  [ "$ALL_CREDS" = "aws claude codex gh gpg ssh" ]
}

@test "resolve_creds: flags win over DCC_CREDS, --no-creds gives none" {
  CREDS_DEFAULT=aws
  CREDS_EXPLICIT=1 CREDS_REQUEST=gpg
  resolve_creds
  [ "$CREDS" = gpg ]
  CREDS_EXPLICIT=1 CREDS_REQUEST=""
  resolve_creds
  [ -z "$CREDS" ]
  [ -z "$DCC_CREDS" ]
  [ "$CREDS_SOURCE" = flags ]
}

@test "resolve_creds: no flags → DCC_CREDS, else none" {
  CREDS_EXPLICIT=0 CREDS_REQUEST=""
  CREDS_DEFAULT=gpg,ssh resolve_creds
  [ "$CREDS" = "gpg ssh" ]
  [ "$CREDS_SOURCE" = DCC_CREDS ]
  CREDS_DEFAULT="" resolve_creds
  [ -z "$CREDS" ]
  [ "$CREDS_SOURCE" = none ]
}

@test "resolve_creds: unknown module dies" {
  CREDS_EXPLICIT=1 CREDS_REQUEST="gpg,nope"
  run resolve_creds
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown credential module 'nope'"* ]]
}

@test "resolve_creds --adopt: takes the existing container's label when no flag was given" {
  agent_label() { printf 'gpg,ssh'; }
  CREDS_DEFAULT=aws
  CREDS_EXPLICIT=0 CREDS_REQUEST=""
  resolve_creds --adopt
  [ "$CREDS" = "gpg ssh" ]
  [ "$CREDS_SOURCE" = container ]
}

@test "resolve_creds --adopt: explicit flags win over the running container" {
  agent_label() { printf 'gpg,ssh'; }
  CREDS_EXPLICIT=1 CREDS_REQUEST=aws
  resolve_creds --adopt
  [ "$CREDS" = aws ]
  [ "$CREDS_SOURCE" = flags ]
}

@test "resolve_creds --adopt: no container → falls back to DCC_CREDS" {
  agent_label() { return 1; }
  CREDS_EXPLICIT=0 CREDS_REQUEST=""
  CREDS_DEFAULT=aws resolve_creds --adopt
  [ "$CREDS" = aws ]
  [ "$CREDS_SOURCE" = DCC_CREDS ]
}

@test "gh_login: requests expiring credentials on the volume, user args last" {
  docker() {
    case "$1 $2" in
      "volume inspect" | "image inspect") return 0 ;;
    esac
    printf '%s\n' "$@" >> "$BATS_TEST_TMPDIR/docker"
  }
  DCC_GH_HOST=ghe.example.com DCC_GH_HOME_VOLUME=gh-vol load_config
  run gh_login --scopes read:packages
  [ "$status" -eq 0 ]
  args="$(paste -sd' ' "$BATS_TEST_TMPDIR/docker")"
  [[ "$args" == "run --rm -i -v gh-vol:/home/gh/.config/gh --entrypoint gh dcc-gh-token:local auth login --hostname ghe.example.com --expiring "*"--scopes read:packages run "* ]]
  [[ "$args" == *" auth status --hostname ghe.example.com" ]]
  [[ "$args" != *"build"* ]]
}

@test "gh_login: creates the volume and builds the image when missing, fails on login error" {
  docker() {
    case "$1 $2" in
      "volume inspect" | "image inspect") return 1 ;;
      "run --rm") return 1 ;;
    esac
    printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/docker"
  }
  run gh_login
  [ "$status" -eq 1 ]
  grep -qx "volume create dcc-gh-home" "$BATS_TEST_TMPDIR/docker"
  grep -qx "build -t dcc-gh-token:local $REPO/capabilities/gh" "$BATS_TEST_TMPDIR/docker"
  [[ "$output" == *"login failed"* ]]
}

@test "check_creds_drift: warns with +added/-removed and a recreate hint" {
  agent_label() { printf 'aws,gpg'; }
  CREDS_EXPLICIT=1 CREDS_REQUEST="gpg,ssh"
  resolve_creds
  run check_creds_drift
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "! credentials    container has aws gpg; requested gpg ssh (+ssh -aws)" ]
  [[ "${lines[1]}" == *"run 'dcc recreate --creds gpg,ssh' to apply" ]]
}

@test "check_creds_drift: silent when the selection matches" {
  agent_label() { printf 'gpg,ssh'; }
  CREDS_EXPLICIT=1 CREDS_REQUEST="gpg,ssh"
  resolve_creds
  run check_creds_drift
  [ -z "$output" ]
}

@test "check_aws_profile_drift: only with the aws module, only when the label differs" {
  agent_label() { [ "$1" = dcc.aws-profile ] && printf 'prod'; }
  CREDS_EXPLICIT=1 CREDS_REQUEST=aws
  resolve_creds
  DCC_AWS_PROFILE=dev run check_aws_profile_drift
  [ "${lines[0]}" = "! aws            container was created with AWS_PROFILE=prod; requested dev" ]
  [[ "${lines[1]}" == *"run 'AWS_PROFILE=dev dcc recreate --creds aws' to apply" ]]
  DCC_AWS_PROFILE=prod run check_aws_profile_drift
  [ -z "$output" ]
  CREDS_EXPLICIT=1 CREDS_REQUEST=gpg
  resolve_creds
  DCC_AWS_PROFILE=dev run check_aws_profile_drift
  [ -z "$output" ]
}

@test "check_gpg_key_drift: compares the signer's key with the host export" {
  signer_signing_key() { printf 'AAAA1111222233334444555566667777888899990000'; }
  host_signing_key() { printf 'BBBB1111222233334444555566667777888899990000'; }
  CREDS_EXPLICIT=1 CREDS_REQUEST=gpg
  resolve_creds
  run check_gpg_key_drift
  [ "${lines[0]}" = "! gpg            gpg-signer was started with signing key AAAA…0000; host now exports BBBB…0000" ]
  host_signing_key() { printf 'AAAA1111222233334444555566667777888899990000'; }
  run check_gpg_key_drift
  [ -z "$output" ]
  host_signing_key() { :; }   # ホストに鍵が無いときは比較しない
  run check_gpg_key_drift
  [ -z "$output" ]
}

# --- ワークスペース横断 --------------------------------------------------------------

@test "for_each_project: calls the function once per compose project, in a subshell" {
  workspace_container_ids() { printf 'c1\nc2\nc3\nc4\n'; }
  label_of() {
    case "$1" in c1|c2) printf 'dcc-a-1'; ;; c3) printf 'dcc-b-2' ;; c4) printf '' ;; esac
  }
  seen_projects() { echo "$COMPOSE_PROJECT_NAME $*"; }
  COMPOSE_PROJECT_NAME=outer
  run for_each_project -a seen_projects arg
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "dcc-a-1 arg" ]
  [ "${lines[1]}" = "dcc-b-2 arg" ]
  [[ "${lines[2]}" == *"skipping non-compose container c4" ]]
  [ "$COMPOSE_PROJECT_NAME" = outer ]
}

@test "for_each_project: keeps going after a failure and fails at the end" {
  workspace_container_ids() { printf 'c1\nc2\n'; }
  label_of() { case "$1" in c1) printf 'p1' ;; c2) printf 'p2' ;; esac; }
  flaky() { echo "$COMPOSE_PROJECT_NAME"; [ "$COMPOSE_PROJECT_NAME" != p1 ]; }
  run for_each_project flaky
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = p1 ]
  [ "${lines[1]}" = p2 ]
}

@test "for_each_project: nothing found → one line, success" {
  workspace_container_ids() { :; }
  run for_each_project -a false
  [ "$status" -eq 0 ]
  [ "$output" = "▸ containers     none found" ]
}

# --- 設定 ----------------------------------------------------------------------

@test "load_config: DCC_CREDS from the environment becomes CREDS_DEFAULT" {
  DCC_CREDS=gpg load_config
  [ "$CREDS_DEFAULT" = gpg ]
}

@test "load_env_file: shell environment wins over .env" {
  f="$BATS_TEST_TMPDIR/env"
  printf 'DCC_TZ=Asia/Tokyo\nexport DCC_USER=fromfile\nDCC_GID=$DCC_UID\n' > "$f"
  DCC_USER=fromshell DCC_UID=1234
  load_env_file "$f"
  [ "$DCC_TZ" = Asia/Tokyo ]
  [ "$DCC_USER" = fromshell ]
  [ "$DCC_GID" = 1234 ]
}

@test "dotenv_quote: single quotes unless the value contains one" {
  [ "$(dotenv_quote 'a b$c')" = "'a b\$c'" ]
  [ "$(dotenv_quote "it's \"q\" \$x")" = '"it'"'"'s \"q\" \$x"' ]
}

@test "export_container_env: DCC_CONTAINER_ENV_<NAME> becomes NAME in a dotenv file" {
  # 関数が EXIT trap を張るので subshell で実行する
  (
    export DCC_CONTAINER_ENV_GOPRIVATE='github.com/org/*' DCC_CONTAINER_ENV_EDITOR=vim
    export_container_env
    [ -f "$DCC_CONTAINER_ENV_FILE" ]
    grep -qxF "GOPRIVATE='github.com/org/*'" "$DCC_CONTAINER_ENV_FILE"
    grep -qxF "EDITOR='vim'" "$DCC_CONTAINER_ENV_FILE"
    ! grep -q DCC_CONTAINER_ENV "$DCC_CONTAINER_ENV_FILE"
  )
}

# --- ログ ----------------------------------------------------------------------

@test "step / warn / done_step: subject column and optional note" {
  run step containers "creating agent, docker" "note"
  [ "$output" = "▸ containers     creating agent, docker  (note)" ]
  run warn gpg "not cached" "run warm.sh"
  [ "${lines[0]}" = "! gpg            not cached" ]
  [ "${lines[1]}" = "                 run warm.sh" ]
  run done_step ready 3s
  [ "$output" = "✓ ready          3s" ]
}

@test "relay: hook lines become ▸ / ! rows, others are indented" {
  run relay <<'IN'
claude: updated to 2.1.0
warn: claude: update failed; using 2.0.0
stray output
IN
  [ "${lines[0]}" = "▸ claude         updated to 2.1.0" ]
  [ "${lines[1]}" = "! claude         update failed; using 2.0.0" ]
  [ "${lines[2]}" = "  stray output" ]
}

@test "run: silent on success, dumps everything on failure" {
  run run_step containers bash -c 'echo noise; true'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run run_step containers bash -c 'echo Creating x; echo boom >&2; exit 3'
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "! containers     failed" ]
  [ "${lines[1]}" = "  Creating x" ]
  [ "${lines[2]}" = "  boom" ]
}

@test "run_step -t: passes the terminal through untouched, still reports failure" {
  run run_step -t image bash -c 'echo raw; echo err >&2'
  [ "$status" -eq 0 ]
  [ "$output" = $'raw\nerr' ]
  run run_step -t image bash -c 'echo raw; exit 5'
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "raw" ]
  [ "${lines[1]}" = "! image          failed" ]
}

@test "run: DCC_VERBOSE streams output" {
  DCC_VERBOSE=1 run run_step containers bash -c 'echo live'
  [ "$output" = "  live" ]
}

@test "indent: compose logrus lines are reduced to level and message" {
  run indent <<'IN'
time="2026-01-01T00:00:00Z" level=warning msg="Warning: no services to build"
plain
IN
  [ "${lines[0]}" = "  warning: no services to build" ]
  [ "${lines[1]}" = "  plain" ]
}

@test "short_key: abbreviates long fingerprints only" {
  [ "$(short_key EE666DC8C853CD5B8102DDE208428D5AB6690320)" = "EE66…0320" ]
  [ "$(short_key ABCD1234)" = ABCD1234 ]
}
