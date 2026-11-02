#!/usr/bin/env bats
# End-to-end: per-user customization (docs/customization.md): local/Dockerfile (two-stage build on the base image),
# local/compose.yml, DCC_COMPOSE_FILES, DCC_CONTAINER_ENV_*, DCC_TZ. Run with `make e2e`; settings in helpers.bash.

setup_file() {
  load ../helpers/common
  load helpers
  e2e_setup_file custom
  # Own tags, so the personal image does not replace the plain one the other files use
  export DCC_IMAGE=dcc-e2e-personal:local DCC_BASE_IMAGE=dcc-e2e-personal:base
  mkdir -p "$DCC_LOCAL_DIR"
  cat >"$DCC_LOCAL_DIR/Dockerfile" <<EOF
FROM $DCC_BASE_IMAGE
USER root
RUN echo personal >/etc/dcc-e2e-personal
USER agent
EOF
  cat >"$DCC_LOCAL_DIR/compose.yml" <<'EOF'
services:
  agent:
    environment:
      E2E_LOCAL_OVERLAY: "from local/compose.yml"
EOF
  cat >"$E2E_ROOT/extra.yml" <<'EOF'
services:
  agent:
    environment:
      E2E_EXTRA_OVERLAY: "from DCC_COMPOSE_FILES"
EOF
  export DCC_COMPOSE_FILES="${DCC_COMPOSE_FILES:+$DCC_COMPOSE_FILES:}$E2E_ROOT/extra.yml"
  export DCC_CONTAINER_ENV_E2E_GREETING="it's \"quoted\" \$HOME and a * glob"
  export DCC_CONTAINER_ENV_E2E_PLAIN='a b'
  export DCC_TZ=Asia/Tokyo
  dcc build "$WS" >"$E2E_ROOT/build.log" 2>&1 || { cat "$E2E_ROOT/build.log" >&2; return 1; }
  dcc up "$WS" --no-creds >"$E2E_ROOT/up.log" 2>&1 || { cat "$E2E_ROOT/up.log" >&2; return 1; }
}

teardown_file() {
  e2e_teardown_file
  [ -n "${DCC_E2E_KEEP:-}" ] || docker image rm dcc-e2e-personal:local dcc-e2e-personal:base >/dev/null 2>&1 || true
}

setup() {
  load ../helpers/common
  load helpers
}

teardown() {
  e2e_teardown
}

@test "build: the repository Dockerfile becomes the base, local/Dockerfile is built on top" {
  grep -qF "▸ image          building dcc-e2e-personal:base  (Dockerfile)" "$E2E_ROOT/build.log"
  grep -qF "▸ image          building dcc-e2e-personal:local and sidecars  (" "$E2E_ROOT/build.log"
  [ "$(in_agent cat /etc/dcc-e2e-personal)" = personal ]
  [ "$(docker inspect --format '{{.Config.Image}}' "$(service_id agent)")" = dcc-e2e-personal:local ]
  dcc up "$WS" 2>&1 | grep -qF "image        dcc-e2e-personal:local  (base + "
}

@test "local/compose.yml and DCC_COMPOSE_FILES are merged after the base" {
  [ "$(in_agent printenv E2E_LOCAL_OVERLAY)" = "from local/compose.yml" ]
  [ "$(in_agent printenv E2E_EXTRA_OVERLAY)" = "from DCC_COMPOSE_FILES" ]
}

@test "DCC_CONTAINER_ENV_<NAME> reaches the container as NAME, verbatim" {
  [ "$(in_agent printenv E2E_GREETING)" = "it's \"quoted\" \$HOME and a * glob" ]
  [ "$(in_agent printenv E2E_PLAIN)" = "a b" ]
  # Only the named variables are passed
  ! in_agent printenv DCC_CONTAINER_ENV_E2E_PLAIN
  ! in_agent printenv DCC_TZ
}

@test "DCC_TZ sets the container's time zone" {
  [ "$(in_agent printenv TZ)" = Asia/Tokyo ]
}

@test "up builds a missing base image before the personal one" {
  dcc clear "$WS" >/dev/null 2>&1
  docker image rm dcc-e2e-personal:local dcc-e2e-personal:base >/dev/null
  run dcc up "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"▸ image          building dcc-e2e-personal:base  (Dockerfile)"* ]]
  [ "$(in_agent cat /etc/dcc-e2e-personal)" = personal ]
}

@test "DCC_COMPOSE_FILES naming a missing file is a usage error" {
  DCC_COMPOSE_FILES="$E2E_ROOT/missing.yml" run dcc up "$WS"
  [ "$status" -eq 2 ]
  [[ "$output" == *"DCC_COMPOSE_FILES: $E2E_ROOT/missing.yml not found"* ]]
}
