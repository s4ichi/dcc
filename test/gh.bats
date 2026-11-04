#!/usr/bin/env bats
# Tests for the gh module on the test host: the agent-side wrapper / git credential helper (gh-token-client.sh) against
# the real token server (server.py), whose `gh` is a stub that hands out a dummy token. Run with `make test`.

bats_require_minimum_version 1.5.0

setup_file() {
  load helpers/common
  # The server's gh: behaviour switched by $GH_MODE_FILE (token | fail | empty); records whether a token env var leaked in
  export GH_BIN="$BATS_FILE_TMPDIR/bin" GH_MODE_FILE="$BATS_FILE_TMPDIR/mode" GH_ENV_LOG="$BATS_FILE_TMPDIR/env"
  mkdir -p "$GH_BIN"
  cat >"$GH_BIN/gh" <<'EOF'
#!/usr/bin/env bash
env | grep -E '^(GH_TOKEN|GITHUB_TOKEN|GH_PROMPT_DISABLED)=' >"$GH_ENV_LOG" || true
echo "$*" >>"$GH_ENV_LOG.args"
case "$(cat "$GH_MODE_FILE")" in
  token) printf 'gho_dummy_token\n' ;;
  empty) ;;
  fail) echo "not logged in to github.com" >&2; exit 1 ;;
esac
EOF
  chmod +x "$GH_BIN/gh"
  echo token >"$GH_MODE_FILE"
  GH_PORT="$(free_port)"
  GH_PID="$(start_server "$BATS_FILE_TMPDIR/server.log" "$GH_PORT" "$REPO/capabilities/gh/server.py" \
    PATH="$GH_BIN:$PATH" GH_TOKEN=leaked-from-agent GITHUB_TOKEN=leaked-too)"
  export GH_PORT GH_PID
}

teardown_file() {
  kill "${GH_PID:-}" 2>/dev/null || true
}

setup() {
  load helpers/common
  common_setup
  echo token >"$GH_MODE_FILE"
  unset DCC_GH_HOST GH_TOKEN
  # Inside a dcc container with the gh module, the system config has the real helper; keep git to the test's config
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  export DCC_GH_TOKEN_URI="http://127.0.0.1:$GH_PORT/token"
  CLIENT="$REPO/capabilities/gh/agent/gh-token-client.sh"
  # What the agent runs as gh (a symlink to the client, first on PATH in the image)
  WRAPPER="$REPO/capabilities/gh/agent/gh"
}

credential() {
  printf '%s\n' "$@" ""
}

# --- git credential helper ----------------------------------------------------

@test "credential: https on the gh host gets the sidecar's token as x-access-token" {
  run --separate-stderr "$CLIENT" git-credential get < <(credential protocol=https host=github.com path=org/repo.git)
  [ "$status" -eq 0 ]
  [ "$output" = $'username=x-access-token\npassword=gho_dummy_token' ]
}

@test "credential: other hosts and plain http get nothing (left to the next helper)" {
  run --separate-stderr "$CLIENT" git-credential get < <(credential protocol=https host=gitlab.com)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run --separate-stderr "$CLIENT" git-credential get < <(credential protocol=http host=github.com)
  [ -z "$output" ]
}

@test "credential: DCC_GH_HOST selects the host (GitHub Enterprise)" {
  DCC_GH_HOST=ghe.example.com run "$CLIENT" git-credential get < <(credential protocol=https host=ghe.example.com)
  [[ "$output" == *"password=gho_dummy_token"* ]]
  DCC_GH_HOST=ghe.example.com run "$CLIENT" git-credential get < <(credential protocol=https host=github.com)
  [ -z "$output" ]
}

@test "credential: store / erase do nothing and do not call the sidecar" {
  : >"$GH_ENV_LOG.args"
  run "$CLIENT" git-credential store < <(credential protocol=https host=github.com password=x)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$CLIENT" git-credential erase < <(credential protocol=https host=github.com)
  [ "$status" -eq 0 ]
  [ ! -s "$GH_ENV_LOG.args" ]
}

@test "credential: sidecar without a login → no password, reason on stderr, exit 0" {
  echo fail >"$GH_MODE_FILE"
  run --separate-stderr "$CLIENT" git-credential get < <(credential protocol=https host=github.com)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no usable token for github.com; run 'dcc gh-login' on the host"* ]]
  # gh's own diagnostics stay in the sidecar log
  [[ "$stderr" != *"not logged in"* ]]
  grep -q "not logged in" "$BATS_FILE_TMPDIR/server.log"
}

@test "credential: sidecar unreachable → no password, exit 0" {
  DCC_GH_TOKEN_URI="http://127.0.0.1:$(free_port)/token" \
    run --separate-stderr "$CLIENT" git-credential get < <(credential protocol=https host=github.com)
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"cannot reach the gh-token sidecar"* ]]
}

@test "credential: git itself picks the token up through the helper" {
  local repo="$BATS_TEST_TMPDIR/repo"
  git init -q "$repo"
  git -C "$repo" config credential.https://github.com.helper "!$CLIENT git-credential"
  run git -C "$repo" credential fill < <(credential protocol=https host=github.com)
  [ "$status" -eq 0 ]
  [[ "$output" == *"username=x-access-token"* ]]
  [[ "$output" == *"password=gho_dummy_token"* ]]
}

# --- gh wrapper ---------------------------------------------------------------

@test "wrapper: gh in agent/ is the client, so the directory alone carries both roles" {
  [ "$(readlink "$WRAPPER")" = gh-token-client.sh ]
  [ -x "$WRAPPER" ]
  # Nothing else for the agent container in the bound directory
  [ "$(ls -A "$REPO/capabilities/gh/agent" | sort | paste -sd' ' -)" = "gh gh-token-client.sh" ]
}

@test "wrapper: changing the login from the agent container is refused" {
  local cmd
  for cmd in login logout refresh switch setup-git; do
    run "$WRAPPER" auth "$cmd"
    [ "$status" -eq 1 ]
    [[ "$output" == *"gh credentials are managed by the gh-token sidecar; run 'dcc gh-login' on the host"* ]]
  done
}

@test "wrapper: runs the real gh with the fetched token in GH_TOKEN" {
  [ -x /usr/bin/gh ] || skip "/usr/bin/gh not installed"
  run --separate-stderr "$WRAPPER" auth token
  [ "$status" -eq 0 ]
  [ "$output" = gho_dummy_token ]
}

@test "wrapper: still runs gh when the sidecar has no token" {
  [ -x /usr/bin/gh ] || skip "/usr/bin/gh not installed"
  echo fail >"$GH_MODE_FILE"
  run --separate-stderr "$WRAPPER" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "gh version "* ]]
  [[ "$stderr" == *"no usable token"* ]]
}

# --- server.py (as the client sees it) ----------------------------------------

@test "server: token env vars from its own environment never reach gh; prompts are disabled" {
  run curl -sf "http://127.0.0.1:$GH_PORT/token"
  [ "$output" = gho_dummy_token ]
  [ "$(cat "$GH_ENV_LOG")" = "GH_PROMPT_DISABLED=1" ]
  [ "$(tail -n 1 "$GH_ENV_LOG.args")" = "auth token --hostname github.com" ]
}

@test "server: an empty token is an error, not an empty 200" {
  echo empty >"$GH_MODE_FILE"
  run curl -s -w ' %{http_code}' "http://127.0.0.1:$GH_PORT/token"
  [ "$output" = $'gh auth token returned nothing\n 503' ]
}

@test "server: the access log has no token and no query string" {
  curl -s -o /dev/null "http://127.0.0.1:$GH_PORT/token?secret=abc"
  ! grep -q "gho_dummy_token\|secret=abc" "$BATS_FILE_TMPDIR/server.log"
  grep -q "^GET /token 404" "$BATS_FILE_TMPDIR/server.log"
}
