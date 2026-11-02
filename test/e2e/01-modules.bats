#!/usr/bin/env bats
# End-to-end: one workspace with every credential module, against a fake host with dummy credentials.
# Checks the boundary (docs/boundaries.md) on the running containers and that each module actually hands its
# capability to the agent container. Tests run in file order (the gpg ones warm the signer midway; drift runs last).
# Run with `make e2e`; settings in helpers.bash, docs/testing.md.

bats_require_minimum_version 1.5.0

setup_file() {
  load ../helpers/common
  load helpers
  e2e_setup_file modules
  fake_host
  seed_gh_volume gho_e2e_dummy_token
  dcc up "$WS" --all-creds >"$E2E_ROOT/up.log" 2>&1 || { cat "$E2E_ROOT/up.log" >&2; return 1; }
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

# --- dcc up -------------------------------------------------------------------

@test "up: one line per fact, postCreate ran for every module, ready" {
  local log
  log="$(cat "$E2E_ROOT/up.log")"
  [[ "$log" == *"credentials  aws claude codex gh gpg ssh"* ]]
  [[ "$log" == *"▸ gpg            exported host keys  (signing key ${GPG_FPR:0:4}…${GPG_FPR: -4})"* ]]
  [[ "$log" == *"▸ containers     creating "* ]]
  [[ "$log" == *"▸ gpg            signing delegated to gpg-signer"* ]]
  [[ "$log" == *"▸ gh             token served by gh-token sidecar (gh and git over https://github.com)"* ]]
  [[ "$log" == *"▸ ~/.claude      shared with host"* ]]
  [[ "$log" == *"▸ claude         $REMOTE_WS trusted"* ]]
  [[ "$log" == *"▸ ~/.codex       shared with host"* ]]
  [[ "$log" == *"▸ gpg            public keys imported for verification"* ]]
  [[ "$log" == *"✓ ready"* ]]
  # Hidden on success: no raw compose output
  [[ "$log" != *"Container "* ]]
}

@test "up: the agent container carries its selection and the workspace as labels" {
  local id
  id="$(service_id agent)"
  [ "$(docker inspect --format '{{index .Config.Labels "dcc.credentials"}}' "$id")" = "aws,claude,codex,gh,gpg,ssh" ]
  [ "$(docker inspect --format '{{index .Config.Labels "dcc.workspace"}}' "$id")" = "$WS" ]
  [ "$(docker inspect --format '{{index .Config.Labels "dcc.aws-profile"}}' "$id")" = default ]
}

# --- Boundary -----------------------------------------------------------------

@test "agent: the container user, no capabilities, no_new_privs, no sudo" {
  run in_agent bash -c 'id -un; grep -E "^(CapEff|CapPrm|NoNewPrivs):" /proc/self/status; command -v sudo || echo "no sudo"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = agent ]
  [[ "$output" == *$'CapPrm:\t0000000000000000'* ]]
  [[ "$output" == *$'CapEff:\t0000000000000000'* ]]
  [[ "$output" == *$'NoNewPrivs:\t1'* ]]
  [ "${lines[4]}" = "no sudo" ]
}

@test "agent: even root inside has no capabilities (chown fails)" {
  run in_agent_root bash -c 'grep "^CapEff:" /proc/self/status; chown root /home/agent/.claude.json'
  [ "$status" -ne 0 ]
  [ "${lines[0]}" = $'CapEff:\t0000000000000000' ]
  [[ "$output" == *"Operation not permitted"* ]]
}

@test "only the docker sidecar may be privileged; nothing has the host's docker socket" {
  local id name privileged
  for id in $(docker ps -q --filter "label=com.docker.compose.project=$PROJECT"); do
    name="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id")"
    privileged="$(docker inspect --format '{{.HostConfig.Privileged}}' "$id")"
    if [ "$name" = docker ] && [ "${DCC_E2E_DOCKER:-}" != stub ]; then
      [ "$privileged" = true ]
    else
      [ "$privileged" = false ] || { echo "$name is privileged" >&2; return 1; }
    fi
    ! mounts_of "$id" | grep -q docker.sock
  done
}

@test "docker sidecar: no host binds other than the workspace" {
  [ "$(mounts_of "$(service_id docker)" | awk '$1 == "bind"')" = "bind $WS $REMOTE_WS" ]
}

@test "agent: no long-lived host keys (~/.aws, ~/.gnupg, host ~/.ssh) are mounted or present" {
  ! mounts_of "$(service_id agent)" | grep -E " $HOME/\.(aws|gnupg|ssh)(/| )"
  run in_agent bash -c 'test -e ~/.aws && echo "has ~/.aws"; gpg --list-secret-keys --with-colons 2>/dev/null; ls ~/.gnupg/private-keys-v1.d 2>/dev/null'
  [ -z "$output" ]
}

@test "module endpoints listen on loopback only; no container publishes a port" {
  run in_agent ss -ltnH
  [ "$status" -eq 0 ]
  local port
  for port in 8080 8081 8082; do
    [[ "$output" == *"127.0.0.1:$port "* ]] || { echo "nothing on 127.0.0.1:$port" >&2; return 1; }
  done
  ! grep -E '(0\.0\.0\.0|\[::\]|\*):808[0-2] ' <<<"$output"
  local id
  for id in $(docker ps -q --filter "label=com.docker.compose.project=$PROJECT"); do
    [ "$(docker inspect --format '{{len .HostConfig.PortBindings}}' "$id")" = 0 ]
  done
}

@test "no container has an anonymous volume (every VOLUME of the images is mapped)" {
  local id
  for id in $(docker ps -q --filter "label=com.docker.compose.project=$PROJECT"); do
    run docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{.Destination}}{{println}}{{end}}{{end}}' "$id"
    # Named volumes are project-prefixed or fixed-name (dcc-*); an anonymous one is a bare 64-hex id
    ! grep -E '^[0-9a-f]{64} ' <<<"$output" || { echo "anonymous volume in $id" >&2; return 1; }
  done
}

# --- Docker sidecar -------------------------------------------------------------

@test "docker: the agent drives the sidecar's rootless dockerd over TLS" {
  require_dind
  run in_agent docker info --format '{{.SecurityOptions}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rootless"* ]]
}

@test "docker: inner containers see the workspace at the same path" {
  require_dind
  run in_agent docker run --rm -v "$REMOTE_WS:$REMOTE_WS" busybox:1.37 cat "$REMOTE_WS/hello.txt"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "hello from the host" ]
}

# --- postCreate ---------------------------------------------------------------

@test "postCreate: workspace is a safe.directory, trusted in ~/.claude.json, and HOST_HOME resolves" {
  run in_agent git status --short
  [ "$status" -eq 0 ]
  [ "$(in_agent jq -r --arg ws "$REMOTE_WS" '.projects[$ws].hasTrustDialogAccepted' /home/agent/.claude.json)" = true ]
  [ "$(in_agent bash -c 'readlink "$HOST_HOME"')" = /home/agent ]
  in_agent test -e /home/agent/.dcc-postcreate-done
}

# --- claude / codex -------------------------------------------------------------

@test "claude: ~/.claude is the host's directory; ~/.claude.json a container-local copy" {
  [ "$(in_agent cat /home/agent/.claude/host-file)" = host ]
  in_agent bash -c 'echo container >~/.claude/from-container'
  [ "$(cat "$HOME/.claude/from-container")" = container ]
  [ "$(in_agent jq -r .e2eMarker /home/agent/.claude.json)" = from-host ]
  # Not a bind (Claude Code replaces it by rename), and the host's file is untouched
  ! in_agent grep -q " /home/agent/.claude.json " /proc/self/mountinfo
  [ "$(cat "$HOME/.claude.json")" = '{"e2eMarker":"from-host"}' ]
}

@test "codex: ~/.codex is the host's directory" {
  [ "$(in_agent cat /home/agent/.codex/config.toml)" = 'model = "e2e-host-model"' ]
  in_agent bash -c 'echo container >~/.codex/from-container'
  [ "$(cat "$HOME/.codex/from-container")" = container ]
}

# --- gpg ------------------------------------------------------------------------

commit_signed() {
  in_agent git -c user.name=e2e -c user.email=e2e@example.invalid commit -q -S --allow-empty -m "$1"
}

@test "gpg: the agent has the public key only, and git's gpg.program is the wrapper" {
  in_agent gpg --list-keys "$GPG_FPR" >/dev/null
  [ "$(in_agent git config gpg.program)" = /usr/local/lib/dcc/gpg-sign-client.sh ]
}

@test "gpg: before the passphrase is cached, signing fails fast" {
  # --pinentry-mode error in the signer: no hang waiting for a passphrase
  SECONDS=0
  run commit_signed unwarmed
  [ "$status" -ne 0 ]
  [ "$SECONDS" -lt 30 ]
  # The image's git does not show gpg.program's stderr itself; the wrapper puts the reason there
  [[ "$output" == *"gpg-sign-client: signing failed (HTTP 503): "*"run capabilities/gpg/warm.sh on the host"* ]]
  run in_agent bash -c 'printf "tree %040d\n" 0 | /usr/local/lib/dcc/gpg-sign-client.sh --status-fd=2 -bsau x'
  [[ "$output" == *"passphrase not cached?"* ]]
}

@test "gpg: warm.sh finds the signer (by project and by workspace) and caches the passphrase" {
  local signer
  signer="$(service_id gpg-signer)"
  # Stand-in for typing the passphrase into pinentry: the agent caches it the same way
  printf 'warm' | docker exec -i "$signer" gpg --batch --pinentry-mode loopback --passphrase "$E2E_GPG_PASSPHRASE" \
    --local-user "$GPG_FPR" --detach-sign --output /dev/null -
  # warm.sh needs a terminal (docker exec -it); script(1) gives it one. Already cached → no prompt
  run timeout 60 script -qec "$REPO/capabilities/gpg/warm.sh -p $PROJECT" /dev/null
  [ "$status" -eq 0 ]
  run timeout 60 script -qec "$REPO/capabilities/gpg/warm.sh $WS" /dev/null
  [ "$status" -eq 0 ]
}

@test "gpg: commits are signed with the host key and verify inside the agent" {
  commit_signed signed
  in_agent git verify-commit HEAD
  [ "$(in_agent git log -1 --format=%GF)" = "$GPG_FPR" ]
  # The commit is in the host's workspace (whose objects the container user now owns)
  [ "$(git -c safe.directory='*' -C "$WS" log -1 --format=%s)" = signed ]
}

@test "gpg: the signer refuses payloads that are not git objects" {
  run in_agent bash -c 'curl -s -o /dev/null -w "%{http_code}" --data-binary "hello" "$DCC_GPG_SIGN_URI"'
  [ "$output" = 403 ]
}

@test "gpg: the private key exists only in the signer" {
  run docker exec "$(service_id gpg-signer)" gpg --list-secret-keys --with-colons
  [[ "$output" == *"$GPG_FPR"* ]]
  # Only the signing key's keygrip was copied, not the second key
  [[ "$output" != *"$GPG_FPR2"* ]]
}

# --- aws ------------------------------------------------------------------------

@test "aws: SDK container credentials resolve to the host profile, without ~/.aws in the agent" {
  run in_agent aws configure export-credentials --format process
  [ "$status" -eq 0 ]
  [ "$(jq -r .AccessKeyId <<<"$output")" = ASIAE2EDUMMYKEY00000 ]
  [ "$(jq -r .SessionToken <<<"$output")" = e2e-dummy-session-token ]
  run in_agent bash -c 'curl -sf "$AWS_CONTAINER_CREDENTIALS_FULL_URI"'
  [ "$(jq -r .SecretAccessKey <<<"$output")" = e2e-dummy-secret-access-key ]
  [ "$(jq -r .Expiration <<<"$output")" != null ]
  [ "$(in_agent printenv AWS_REGION)" = us-east-1 ]
}

# --- gh -------------------------------------------------------------------------

@test "gh: gh and git over https get the sidecar's token; the login cannot be changed" {
  [ "$(in_agent gh auth token)" = gho_e2e_dummy_token ]
  run in_agent git credential fill < <(printf 'protocol=https\nhost=github.com\n\n')
  [[ "$output" == *"username=x-access-token"* ]]
  [[ "$output" == *"password=gho_e2e_dummy_token"* ]]
  run in_agent gh auth logout
  [ "$status" -eq 1 ]
  [[ "$output" == *"run 'dcc gh-login' on the host"* ]]
  # The stored login (refresh token) is only in the sidecar's volume
  ! in_agent test -e /home/agent/.config/gh/hosts.yml
}

# --- ssh ------------------------------------------------------------------------

@test "ssh: the container key and GitHub settings are mounted read-only" {
  in_agent test -r /home/agent/.ssh/id_ed25519
  run in_agent touch /home/agent/.ssh/new
  [ "$status" -ne 0 ]
  run in_agent ssh -G github.com
  [[ "$output" == *"identityfile ~/.ssh/id_ed25519"* ]]
  [[ "$output" == *"identitiesonly yes"* ]]
  [[ "$output" == *"user git"* ]]
  in_agent ssh-keygen -F github.com -f /etc/ssh/ssh_known_hosts >/dev/null
}

# --- dcc creds / drift (last: they re-export the host's keys) -------------------

@test "creds: shows the existing container's selection" {
  run dcc creds "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"selected:  aws claude codex gh gpg ssh   # from the existing container"* ]]
  [[ "$output" == *"running:   aws claude codex gh gpg ssh   # $PROJECT"* ]]
}

@test "drift: a different selection or AWS profile is reported, not applied" {
  local before
  before="$(service_id agent)"
  run dcc up "$WS" --creds gpg,ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *"! credentials    container has aws claude codex gh gpg ssh; requested gpg ssh (-aws -claude -codex -gh)"* ]]
  [[ "$output" == *"run 'dcc recreate --creds gpg,ssh' to apply"* ]]
  DCC_AWS_PROFILE=other run dcc up "$WS"
  [[ "$output" == *"! aws            container was created with AWS_PROFILE=default; requested other"* ]]
  [ "$(service_id agent)" = "$before" ]
  [ "$(in_agent bash -c 'curl -sf "$AWS_CONTAINER_CREDENTIALS_FULL_URI"' | jq -r .AccessKeyId)" = ASIAE2EDUMMYKEY00000 ]
}

@test "drift: a new host signing key is reported against the running gpg-signer" {
  DCC_GPG_SIGNING_KEY="$GPG_FPR2" run dcc up "$WS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"! gpg            gpg-signer was started with signing key ${GPG_FPR:0:4}…${GPG_FPR: -4}; host now exports ${GPG_FPR2:0:4}…${GPG_FPR2: -4}"* ]]
}
