#!/usr/bin/env bats
# End-to-end: `stop --all` / `clear --all` across workspaces. These act on every dcc workspace the Docker daemon has,
# not only the test's, so they run only with DCC_E2E_ALL=1 (CI). Settings in helpers.bash, docs/testing.md.

setup_file() {
  load ../helpers/common
  load helpers
  [ "${DCC_E2E_ALL:-}" = 1 ] || skip "stops and removes every dcc workspace; set DCC_E2E_ALL=1 to run"
  e2e_setup_file all-a
  export WS_A="$WS" PROJECT_A="$PROJECT"
  export WS_B="$E2E_ROOT/all-b"
  mkdir -p "$WS_B"
  dcc up "$WS_A" --no-creds >"$E2E_ROOT/up-a.log" 2>&1 || { cat "$E2E_ROOT/up-a.log" >&2; return 1; }
  dcc up "$WS_B" --no-creds >"$E2E_ROOT/up-b.log" 2>&1 || { cat "$E2E_ROOT/up-b.log" >&2; return 1; }
  PROJECT_B="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' \
    "$(docker ps -q --filter "label=dcc.workspace=$WS_B")")"
  export PROJECT_B
}

teardown_file() {
  [ -z "${WS_B:-}" ] || [ -n "${DCC_E2E_KEEP:-}" ] || dcc clear "$WS_B" --volumes >/dev/null 2>&1 || true
  e2e_teardown_file
}

setup() {
  load ../helpers/common
  load helpers
}

running_in() {
  docker ps -q --filter "label=com.docker.compose.project=$1" | wc -l | tr -d ' '
}

@test "stop --all: every workspace's containers stop" {
  [ "$(running_in "$PROJECT_A")" -gt 0 ]
  [ "$(running_in "$PROJECT_B")" -gt 0 ]
  run dcc stop --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"($PROJECT_A)"* ]]
  [[ "$output" == *"($PROJECT_B)"* ]]
  [ "$(running_in "$PROJECT_A")" -eq 0 ]
  [ "$(running_in "$PROJECT_B")" -eq 0 ]
}

@test "clear --all: stopped workspaces are removed too" {
  run dcc clear --all
  [ "$status" -eq 0 ]
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_A")" ]
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_B")" ]
  run dcc list
  [ "$output" = "No containers found." ]
}
