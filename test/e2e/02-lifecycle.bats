#!/usr/bin/env bats
# End-to-end: the container lifecycle through dcc with no credential modules (up / exec / stop / recreate / clear /
# list / inspect / creds). Tests run in file order. Run with `make e2e`; settings in helpers.bash, docs/testing.md.

setup_file() {
  load ../helpers/common
  load helpers
  e2e_setup_file lifecycle
  dcc up "$WS" --no-creds >"$E2E_ROOT/up.log" 2>&1 || { cat "$E2E_ROOT/up.log" >&2; return 1; }
  export FIRST_ID="$(service_id agent)"
}

teardown_file() {
  e2e_teardown_file
}

setup() {
  load ../helpers/common
  load helpers
}

teardown() {
  e2e_teardown
}

# The agent gets a terminal, as from an interactive shell (script(1) provides one). Prints its output without CRs
on_tty() {
  local cmd
  printf -v cmd '%q ' "$@"
  timeout 120 script -qec "$cmd" /dev/null | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

@test "up --no-creds: only agent and docker, no module settings in the container" {
  run docker ps --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Label "com.docker.compose.service"}}'
  [ "$(sort <<<"$output" | paste -sd' ' -)" = "agent docker" ]
  run in_agent bash -c 'env | grep -E "^(DCC_GPG_SIGN_URI|DCC_GH_TOKEN_URI|AWS_CONTAINER_CREDENTIALS_FULL_URI|GIT_CONFIG_)" || true'
  [ -z "$output" ]
  [ "$(docker inspect --format '{{index .Config.Labels "dcc.credentials"}}' "$FIRST_ID")" = "" ]
}

@test "up --no-creds: ~/.claude and ~/.codex are the shared external volumes, owned by the container user" {
  grep -qF "▸ volume         creating dcc-e2e-claude-home for ~/.claude  (claude module off)" "$E2E_ROOT/up.log"
  grep -qF "▸ ~/.claude      on volume dcc-e2e-claude-home (claude module off)" "$E2E_ROOT/up.log"
  grep -qF "▸ ~/.codex       on volume dcc-e2e-codex-home (codex module off)" "$E2E_ROOT/up.log"
  docker volume inspect dcc-e2e-claude-home dcc-e2e-codex-home >/dev/null
  [ "$(mounts_of "$FIRST_ID" | awk '$3 == "/home/agent/.claude" { print $1 }')" = volume ]
  [ "$(in_agent stat -c '%U %a' /home/agent/.claude /home/agent/.codex | paste -sd' ' -)" = "agent 700 agent 700" ]
}

@test "exec: runs claude in the workspace with the user's arguments" {
  run on_tty "$REPO/dcc" exec "$WS" -- --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"(Claude Code)"* ]]
  [[ "$output" == *"✓ ready"* ]]
}

@test "exec --agent codex: the same container runs codex" {
  run on_tty "$REPO/dcc" exec "$WS" --agent codex -- --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex-cli"* ]]
  [ "$(service_id agent)" = "$FIRST_ID" ]
}

@test "exec: the agent's exit code is dcc's" {
  run on_tty "$REPO/dcc" exec "$WS" -- --no-such-option-e2e
  [ "$status" -ne 0 ]
}

@test "up on a running container: nothing is recreated and postCreate does not run again" {
  run dcc up "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"▸ containers     running docker, agent"* ]]
  [[ "$output" != *"trusted"* ]]
  [ "$(service_id agent)" = "$FIRST_ID" ]
}

@test "stop, then up: the same container starts again" {
  run dcc stop "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"▸ containers     stopping "* ]]
  [ -z "$(service_id agent)" ]
  [ "$(docker inspect --format '{{.State.Status}}' "$FIRST_ID")" = exited ]
  run dcc up "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"▸ containers     starting docker, agent"* ]]
  [[ "$output" != *"trusted"* ]]
  [ "$(service_id agent)" = "$FIRST_ID" ]
  # Docker is reachable again after the restart
  if [ "${DCC_E2E_DOCKER:-}" != stub ]; then in_agent docker version >/dev/null; fi
}

@test "list / inspect: the workspace appears across workspaces" {
  run dcc list
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROJECT"* ]]
  [[ "$output" == *"$WS"* ]]
  run dcc inspect
  [[ "$output" == *"workspace=$WS"* ]]
  [[ "$output" == *"project=$PROJECT"* ]]
  [[ "$output" == *"image=dcc-e2e:local"* ]]
}

@test "creds: the running selection is none; flags only change the request" {
  run dcc creds "$WS"
  [[ "$output" == *"running:   (none)   # $PROJECT"* ]]
  run dcc creds "$WS" --creds ssh
  [[ "$output" == *"selected:  ssh   # from flags"* ]]
}

anonymous_volumes() {
  docker volume ls -q --filter label=com.docker.volume.anonymous | sort
}

@test "recreate --creds ssh: a new container with the new selection, postCreate runs again" {
  mkdir -p "$DCC_SSH_DIR"
  anonymous_volumes >"$BATS_TEST_TMPDIR/before"
  run dcc recreate "$WS" --creds ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *"▸ containers     removing agent, docker"* ]]
  [[ "$output" == *"trusted"* ]]
  [ "$(service_id agent)" != "$FIRST_ID" ]
  [ "$(docker inspect --format '{{index .Config.Labels "dcc.credentials"}}' "$(service_id agent)")" = ssh ]
  # Removing the old containers (down without --volumes) leaves no anonymous volume behind
  [ -z "$(comm -13 "$BATS_TEST_TMPDIR/before" <(anonymous_volumes))" ]
  # Without flags, later runs keep the container's selection
  run dcc up "$WS"
  [[ "$output" == *"credentials  ssh"*"(existing container)"* ]]
  [[ "$output" != *"! credentials"* ]]
}

@test "clear --volumes: containers and project volumes go; the shared home volumes stay" {
  run dcc clear "$WS" --volumes
  [ "$status" -eq 0 ]
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ]
  [ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")" ]
  docker volume inspect dcc-e2e-claude-home >/dev/null
  run dcc clear "$WS"
  [[ "$output" == *"none to remove"* ]]
}

@test "usage errors exit 2 without touching docker" {
  run dcc up "$WS" --creds nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown credential module 'nope'"* ]]
  run dcc frobnicate
  [ "$status" -eq 2 ]
  [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ]
}
