#!/usr/bin/env bats
# End-to-end: `dcc build` and what the images promise (docs/architecture.md "Agent image"). The later files reuse
# the images built here. Run with `make e2e`; settings in helpers.bash, docs/testing.md.

setup_file() {
  load ../helpers/common
  load helpers
  e2e_setup_file build
}

teardown_file() {
  e2e_teardown_file
}

setup() {
  load ../helpers/common
  load helpers
}

@test "build: the agent image and every module sidecar image" {
  run dcc build "$WS"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -n 40; return 1; }
  [[ "$output" == *"▸ image          building dcc-e2e:local and sidecars  (Dockerfile)"* ]]
  [[ "$output" == *"✓ built"* ]]
  local image
  for image in dcc-e2e:local dcc-aws-credentials:local dcc-gpg-signer:local dcc-gh-token:local; do
    docker image inspect "$image" >/dev/null || { echo "$image missing" >&2; return 1; }
  done
}

@test "docker sidecar: the pinned index has both linux/amd64 and linux/arm64" {
  # Official images publish one architecture at a time; a digest taken mid-way pins an index missing one of them.
  # CI runs on amd64 only, so an index without arm64 would pass everything else and break arm64 hosts
  local ref
  ref="$(grep -oE 'docker:[^@}]+@sha256:[0-9a-f]{64}' "$REPO/template.jsonnet")"
  run docker buildx imagetools inspect --raw "$ref"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  run jq -r '[.manifests[].platform | "\(.os)/\(.architecture)"] | join(" ")' <<<"$output"
  [[ " $output " == *" linux/amd64 "* ]] || { echo "$ref: no linux/amd64 in [$output]" >&2; return 1; }
  [[ " $output " == *" linux/arm64 "* ]] || { echo "$ref: no linux/arm64 in [$output]" >&2; return 1; }
}

@test "agent image: the container user, owning its home volumes' mount points; no sudo, no dockerd" {
  run docker run --rm --entrypoint bash dcc-e2e:local -c '
    id -un; id -u
    stat -c "%U %a" ~/.claude ~/.codex
    command -v sudo dockerd || true'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = agent ]
  [ "${lines[1]}" = "$DCC_UID" ]
  # An empty named volume inherits these on first mount (postCreate cannot chown; docs/boundaries.md)
  [ "${lines[2]}" = "agent 700" ]
  [ "${lines[3]}" = "agent 700" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "agent image: both agents and the documented tools run" {
  run docker run --rm --entrypoint bash dcc-e2e:local -c '
    set -e
    claude --version; codex --version
    git --version; gh --version; docker --version; docker compose version; docker buildx version
    go version; node --version; npm --version; python3 --version; uv --version; java -version 2>&1
    jq --version; yq --version; duckdb --version; jsonnet --version; aws --version; d2 --version
    gpg --version; ssh -V 2>&1; curl --version'
  [ "$status" -eq 0 ]
  [[ "$output" == *"(Claude Code)"* ]]
  [[ "$output" == *"codex-cli"* ]]
}

@test "agent image: the Claude Code binary lives in the image, not under ~/.claude" {
  run docker run --rm --entrypoint bash dcc-e2e:local -c 'readlink -f "$(command -v claude)"; readlink -f "$(command -v codex)"'
  [[ "${lines[0]}" == /home/agent/.local/share/claude/* ]]
  [[ "${lines[1]}" == /opt/codex/* ]]
}

@test "gpg-signer image: gpg and pinentry, the entrypoint and the warm helper" {
  run docker run --rm --entrypoint sh dcc-gpg-signer:local -c \
    'gpg --version | head -n 1; command -v pinentry-curses python3; test -x /usr/local/bin/gpg-warm.sh && echo warm'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/bin/pinentry-curses"* ]]
  [[ "$output" == *"warm"* ]]
}

@test "gh-token image: runs as gh, state directory private, gh new enough for expiring tokens" {
  run docker run --rm --entrypoint sh dcc-gh-token:local -c 'id -un; stat -c "%U %a" /home/gh/.config/gh; gh --version | head -n 1'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = gh ]
  [ "${lines[1]}" = "gh 700" ]
  local version
  version="$(awk '{print $3}' <<<"${lines[2]}")"
  [ "$(printf '%s\n' 2.103.0 "$version" | sort -V | head -n 1)" = 2.103.0 ]
}

@test "aws-credentials image: the AWS CLI and python3 for the server" {
  run docker run --rm --entrypoint sh dcc-aws-credentials:local -c 'aws --version; python3 --version'
  [ "$status" -eq 0 ]
  [[ "$output" == *"aws-cli/2."* ]]
}
