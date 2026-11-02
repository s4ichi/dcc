#!/usr/bin/env bats
# Static checks of the compose configuration, without starting anything: generated files match template.jsonnet,
# every module overlay merges, and the invariants in CLAUDE.md / docs/boundaries.md hold in the merged result.
# Needs the docker CLI with the compose plugin (no daemon) and jq. Run with `make test`.

setup_file() {
  load helpers/common
  docker compose version >/dev/null 2>&1 || skip "docker compose not installed"
  command -v jq >/dev/null || skip "jq not installed"
}

setup() {
  load helpers/common
  unset DCC_CREDS DCC_AGENT $(compgen -e | grep '^DCC_' || true)
  # A fake host home and workspace; interpolation only, nothing is mounted
  export HOME=/fake/home DCC_CONFIG_DIR="$REPO"
  export LOCAL_WORKSPACE_FOLDER=/fake/src/proj LOCAL_WORKSPACE_BASENAME=proj
  MODULES=()
  local f
  for f in "$REPO"/capabilities/*/compose.yml; do
    f="${f%/compose.yml}"
    MODULES+=("${f##*/}")
  done
}

# config <module...>: merged configuration (base + workspace + overlays) as JSON. --env-file /dev/null keeps a
# developer's .env out of it
config() {
  local -a files=(-f "$REPO/docker-compose.yml" -f "$REPO/docker-compose.workspace.yml")
  local m
  for m in "$@"; do files+=(-f "$REPO/capabilities/$m/compose.yml"); done
  docker compose -p dcc-test --env-file /dev/null "${files[@]}" config --format json
}

# Every "<service> <volume target>" in a generated file (the generated YAML is regular: 2-space services, one key per line)
targets_of() {
  awk '/^services:/ { s = 1; next } /^[^ ]/ { s = 0 }
       s && /^  [^ ]/ { svc = $1; sub(":", "", svc) }
       s && /^ +(- )?target: / { t = $0; sub(/.*target: /, "", t); print svc, t }' "$1"
}

generated_files() {
  printf '%s\n' "$REPO/docker-compose.yml" "$REPO/docker-compose.workspace.yml" \
    "$REPO/docker-compose.base-image.yml" "$REPO"/capabilities/*/compose.yml
}

# --- Generation ---------------------------------------------------------------

@test "generated files are up to date with template.jsonnet" {
  command -v jsonnet >/dev/null || skip "jsonnet not installed"
  local out="$BATS_TEST_TMPDIR/gen" f
  mkdir -p "$out"
  jsonnet -S -e "std.join('\n', std.objectFields(import '$REPO/template.jsonnet'))" >"$BATS_TEST_TMPDIR/names"
  while IFS= read -r f; do mkdir -p "$out/$(dirname "$f")"; done <"$BATS_TEST_TMPDIR/names"
  jsonnet -S -m "$out" "$REPO/template.jsonnet" >/dev/null
  while IFS= read -r f; do
    diff -u "$REPO/$f" "$out/$f" || { echo "$f is stale: run 'make generate'" >&2; return 1; }
  done <"$BATS_TEST_TMPDIR/names"
  # ... and nothing generated is left over from a removed module
  [ "$(generated_files | wc -l)" -eq "$(grep -c . "$BATS_TEST_TMPDIR/names")" ]
}

@test "template.jsonnet is formatted (make fmt)" {
  command -v jsonnetfmt >/dev/null || skip "jsonnetfmt not installed"
  jsonnetfmt --test "$REPO/template.jsonnet"
}

# --- Merging ------------------------------------------------------------------

@test "every module overlay merges onto the base, alone and all together" {
  local m
  for m in "${MODULES[@]}"; do
    config "$m" >/dev/null || { echo "module $m does not merge" >&2; return 1; }
  done
  config "${MODULES[@]}" >/dev/null
}

@test "the base works without the workspace overlay (devcontainer CLI)" {
  ! grep -q LOCAL_WORKSPACE "$REPO/docker-compose.yml"
  unset LOCAL_WORKSPACE_FOLDER LOCAL_WORKSPACE_BASENAME
  docker compose -p dcc-test --env-file /dev/null -f "$REPO/docker-compose.yml" config >/dev/null
  # ... while the workspace overlay refuses to run without dcc
  run docker compose -p dcc-test --env-file /dev/null -f "$REPO/docker-compose.yml" \
    -f "$REPO/docker-compose.workspace.yml" config
  [ "$status" -ne 0 ]
  [[ "$output" == *"run via dcc"* ]]
}

# --- Invariants (CLAUDE.md "Invariants that must not break") ------------------

@test "only the docker sidecar is privileged" {
  run jq -r '.services | to_entries[] | select(.value.privileged == true) | .key' <<<"$(config "${MODULES[@]}")"
  [ "$output" = docker ]
}

@test "agent: no-new-privileges, cap_drop ALL, an init, and no user override" {
  local agent
  agent="$(config "${MODULES[@]}" | jq '.services.agent')"
  [ "$(jq -c .security_opt <<<"$agent")" = '["no-new-privileges:true"]' ]
  [ "$(jq -c .cap_drop <<<"$agent")" = '["ALL"]' ]
  [ "$(jq -r .init <<<"$agent")" = true ]
  [ "$(jq -r '.user // "image"' <<<"$agent")" = image ]
  [ "$(jq -r '.cap_add // [] | length' <<<"$agent")" = 0 ]
}

@test "every other service joins the docker sidecar's netns and nothing publishes ports" {
  local cfg
  cfg="$(config "${MODULES[@]}")"
  run jq -r '.services | to_entries[] | select(.key != "docker") | select(.value.network_mode != "service:docker") | .key' <<<"$cfg"
  [ -z "$output" ]
  run jq -r '.services | to_entries[] | select(.value.ports) | .key' <<<"$cfg"
  [ -z "$output" ]
}

@test "module sidecars keep the default loopback listen address" {
  run jq -r '.services | to_entries[] | select(.value.environment.BIND_ADDR) | .key' <<<"$(config "${MODULES[@]}")"
  [ -z "$output" ]
}

@test "nothing mounts the host's docker socket" {
  run jq -r '.services[].volumes[]?.source // empty | select(test("docker\\.sock"))' <<<"$(config "${MODULES[@]}")"
  [ -z "$output" ]
}

@test "the docker sidecar gets no host binds except the workspace" {
  run jq -r '.services.docker.volumes[] | select(.type == "bind") | .source' <<<"$(config "${MODULES[@]}")"
  [ "$output" = /fake/src/proj ]
}

@test "the workspace is bound at the same /workspaces/<basename> in agent and docker" {
  local cfg q
  cfg="$(config)"
  q='.volumes[] | select(.source == "/fake/src/proj") | .target'
  [ "$(jq -r ".services.agent | $q" <<<"$cfg")" = /workspaces/proj ]
  [ "$(jq -r ".services.docker | $q" <<<"$cfg")" = /workspaces/proj ]
}

@test "the agent container never gets ~/.aws, ~/.gnupg or the host's ~/.ssh" {
  local cfg
  cfg="$(config "${MODULES[@]}")"
  run jq -r '.services.agent.volumes[].source | select(test("^/fake/home/\\.(aws|gnupg|ssh)(/|$)"))' <<<"$cfg"
  [ -z "$output" ]
  # Not vacuous: the module sidecars do get them
  jq -e '.services["aws-credentials"].volumes[] | select(.source == "/fake/home/.aws/config")' <<<"$cfg" >/dev/null
  jq -e '.services["gpg-signer"].volumes[] | select(.source == "/fake/home/.gnupg/private-keys-v1.d")' <<<"$cfg" >/dev/null
}

@test "the claude / codex modules override the home volumes; no other volume target is duplicated" {
  local f dups
  dups="$(for f in $(generated_files); do targets_of "$f"; done | sort | uniq -d)"
  [ "$dups" = $'agent "/home/${DCC_USER:-agent}/.claude"\nagent "/home/${DCC_USER:-agent}/.codex"' ]
  # Merged, the module's bind wins over the base volume
  [ "$(config claude | jq -r '.services.agent.volumes[] | select(.target == "/home/agent/.claude") | .type')" = bind ]
  [ "$(config | jq -r '.services.agent.volumes[] | select(.target == "/home/agent/.claude") | .type')" = volume ]
}

@test "compose files reference repository files only through DCC_CONFIG_DIR (no relative paths)" {
  local volumes value bad=""
  # Named volumes (the keys of the top-level volumes:) are the only sources that are not paths. Volumes a module
  # overrides with a bind drop out of the merged result, so take the keys with and without the modules
  volumes=" $({ config; config "${MODULES[@]}"; } | jq -r '.volumes | keys | join(" ")' | paste -sd' ' -) "
  while IFS= read -r value; do
    case "$value" in '${'* | /*) continue ;; esac
    case "$volumes" in *" $value "*) continue ;; esac
    bad="$bad $value"
  done < <(generated_files | xargs grep -hE '^ +(- )?(source|context|path): ' | awk -F': ' '{ gsub(/"/, "", $2); print $2 }')
  [ -z "$bad" ] || { echo "relative paths:$bad" >&2; return 1; }
}

@test "the agent choice is not part of the container (no AGENT in compose)" {
  ! generated_files | xargs grep -nE 'AGENT'
}

@test "the docker sidecar maps every VOLUME its image declares (no anonymous volume per container)" {
  # docker:*-dind-rootless declares both; checked against the image itself in test/e2e
  local cfg target
  cfg="$(config)"
  for target in /home/rootless/.local/share/docker /var/lib/docker; do
    jq -e --arg t "$target" '.services.docker.volumes[] | select(.target == $t)' <<<"$cfg" >/dev/null \
      || { echo "nothing mounted at $target" >&2; return 1; }
  done
}

@test "the volume names the hooks report are the volumes compose mounts" {
  local cfg
  cfg="$(DCC_CLAUDE_HOME_VOLUME=my-claude DCC_CODEX_HOME_VOLUME=my-codex config)"
  [ "$(jq -r '.services.agent.environment.DCC_CLAUDE_HOME_VOLUME' <<<"$cfg")" = "$(jq -r '.volumes["claude-home"].name' <<<"$cfg")" ]
  [ "$(jq -r '.services.agent.environment.DCC_CODEX_HOME_VOLUME' <<<"$cfg")" = "$(jq -r '.volumes["codex-home"].name' <<<"$cfg")" ]
  [ "$(jq -r '.volumes["claude-home"].name' <<<"$cfg")" = my-claude ]
}

@test "the docker CLI in the agent points at the service named docker (in the TLS certificate's SAN)" {
  [ "$(config | jq -r '.services.agent.environment.DOCKER_HOST')" = tcp://docker:2376 ]
}

# --- Conventions (CLAUDE.md "Conventions for making changes") -------------------

# DCC_* that dcc itself exports for compose; not user settings
INTERNAL_VARS="DCC_BUILD_CONTEXT DCC_DOCKERFILE DCC_CONTAINER_ENV_FILE"

template_vars() {
  grep -ohE '\$\{DCC_[A-Z0-9_]+' "$REPO/template.jsonnet" | tr -d '${' | sort -u
}

@test "every DCC_* the template reads is in .env.example and docs/customization.md" {
  local v missing=""
  for v in $(template_vars); do
    case " $INTERNAL_VARS " in *" $v "*) continue ;; esac
    grep -qE "^#?$v=" "$REPO/.env.example" || missing="$missing $v(.env.example)"
    grep -qF "\`$v\`" "$REPO/docs/customization.md" || missing="$missing $v(docs/customization.md)"
  done
  [ -z "$missing" ] || { echo "undocumented:$missing" >&2; return 1; }
}

@test "literal defaults in .env.example match the compose files" {
  local v want got bad=""
  for v in $(template_vars); do
    # Only plain literal defaults: ${DCC_X:-value} with no nested ${...}
    want="$(generated_files | xargs grep -ohE "\\\$\\{$v:-[^\$\}]+\}" | head -n 1 | sed -E "s/^\\\$\\{$v:-//; s/\}$//")"
    [ -n "$want" ] || continue
    got="$(grep -E "^#?$v=" "$REPO/.env.example" | head -n 1 | sed -E "s/^#?$v=//")" || true
    [ -z "$got" ] || [ "$got" = "$want" ] || bad="$bad $v(template=$want .env.example=$got)"
  done
  [ -z "$bad" ] || { echo "mismatch:$bad" >&2; return 1; }
}

@test "Dockerfile's GO_VERSION default matches DCC_GO_VERSION" {
  local want
  want="$(grep -oE '\$\{DCC_GO_VERSION:-[^}]+' "$REPO/template.jsonnet" | sed 's/.*:-//')"
  grep -qxF "ARG GO_VERSION=$want" "$REPO/Dockerfile"
}

@test "every module has a docs page and a README entry" {
  local m page
  for m in "${MODULES[@]}"; do
    case "$m" in gh) page=github ;; claude) page=claude-code ;; *) page="$m" ;; esac
    [ -f "$REPO/docs/$page.md" ] || { echo "docs/$page.md missing for $m" >&2; return 1; }
    grep -qF "\`$m\`" "$REPO/README.md" || { echo "README.md does not mention \`$m\`" >&2; return 1; }
  done
}
