#!/usr/bin/env bats
# Tests for lifecycle_hooks/ run on the test host. Container-only parts (git config --system, the module clients under
# /usr/local/lib/dcc) are replaced by stubs; the real thing is covered by test/e2e. Run with `make test`.

setup() {
  load helpers/common
  common_setup
  unset DCC_CREDS DCC_GPG_SIGNING_KEY GNUPGHOME HOST_HOME
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  # Keep the host export of the gpg module away from the repository's gnupg-host/
  export DCC_GPG_EXPORT_DIR="$BATS_TEST_TMPDIR/gnupg-host"
}

teardown() {
  gpgconf --homedir "$HOME/.gnupg" --kill all 2>/dev/null || true
}

# --- initialize.sh ------------------------------------------------------------

@test "initialize: no modules → no output" {
  run "$REPO/lifecycle_hooks/initialize.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "initialize: claude / codex warn about missing host files, one hook line each" {
  run "$REPO/lifecycle_hooks/initialize.sh" claude codex
  [ "$status" -eq 0 ]
  assert_hook_lines
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "warn: claude: $HOME/.claude not found; "* ]]
  [[ "${lines[1]}" == "warn: claude: $HOME/.claude.json not found; "*"(start Claude Code on the host once)" ]]
  [[ "${lines[2]}" == "warn: codex: $HOME/.codex not found; "* ]]
}

@test "initialize: claude / codex are silent when the host files exist" {
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  echo '{}' >"$HOME/.claude.json"
  run "$REPO/lifecycle_hooks/initialize.sh" claude codex
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "initialize: DCC_CLAUDE_DIR / DCC_CLAUDE_JSON / DCC_CODEX_DIR move the checked paths" {
  export DCC_CLAUDE_DIR="$BATS_TEST_TMPDIR/c" DCC_CLAUDE_JSON="$BATS_TEST_TMPDIR/c.json" DCC_CODEX_DIR="$BATS_TEST_TMPDIR/x"
  run "$REPO/lifecycle_hooks/initialize.sh" claude codex
  [[ "$output" == *"$DCC_CLAUDE_DIR not found"* ]]
  [[ "$output" == *"$DCC_CLAUDE_JSON not found"* ]]
  [[ "$output" == *"$DCC_CODEX_DIR not found"* ]]
}

@test "initialize: aws needs ~/.aws/config and ~/.aws/login/cache" {
  export DCC_AWS_DIR="$BATS_TEST_TMPDIR/aws"
  run "$REPO/lifecycle_hooks/initialize.sh" aws
  assert_hook_lines
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "warn: aws: $DCC_AWS_DIR/config not found; "* ]]
  [[ "${lines[1]}" == *"(run 'aws login' on the host once)" ]]
  mkdir -p "$DCC_AWS_DIR/login/cache"
  touch "$DCC_AWS_DIR/config"
  run "$REPO/lifecycle_hooks/initialize.sh" aws
  [ -z "$output" ]
}

@test "initialize: ssh checks DCC_SSH_DIR (default: capabilities/ssh/data)" {
  export DCC_SSH_DIR="$BATS_TEST_TMPDIR/ssh"
  run "$REPO/lifecycle_hooks/initialize.sh" ssh
  [ "$output" = "warn: ssh: $DCC_SSH_DIR not found; the module mounts it, so 'up' may fail or leave an empty directory there" ]
  mkdir "$DCC_SSH_DIR"
  run "$REPO/lifecycle_hooks/initialize.sh" ssh
  [ -z "$output" ]
}

@test "initialize: gpg runs the host export into DCC_GPG_EXPORT_DIR" {
  run "$REPO/lifecycle_hooks/initialize.sh" gpg
  [ "$status" -eq 0 ]
  [ "$output" = "warn: gpg: no secret keys on host; keys not exported" ]
  [ -d "$DCC_GPG_EXPORT_DIR" ]
  [ -f "$DCC_GPG_EXPORT_DIR/signing-key.txt" ]
}

@test "initialize: gh has no host-side step; an unknown module only warns" {
  run "$REPO/lifecycle_hooks/initialize.sh" gh nope
  [ "$status" -eq 0 ]
  [ "$output" = "warn: nope: unknown module (ignored)" ]
}

@test "initialize: knows every module in capabilities/" {
  local f modules=()
  for f in "$REPO"/capabilities/*/compose.yml; do
    f="${f%/compose.yml}"
    modules+=("${f##*/}")
  done
  [ "${#modules[@]}" -gt 0 ]
  run "$REPO/lifecycle_hooks/initialize.sh" "${modules[@]}"
  [ "$status" -eq 0 ]
  assert_hook_lines
  [[ "$output" != *"unknown module"* ]]
}

# --- postCreate-root.sh ---------------------------------------------------------

# getent resolves the container user to the fake home; git only records what would go to the system config
root_hook_stubs() {
  stub getent "echo \"\$2:x:$(id -u):$(id -g)::$HOME:/bin/bash\""
  stub git
  mkdir -p "$HOME/.claude" "$HOME/.codex"
}

@test "postCreate-root: registers the workspace as safe.directory in the system config, prints nothing" {
  root_hook_stubs
  mkdir "$BATS_TEST_TMPDIR/ws"
  cd "$BATS_TEST_TMPDIR/ws"
  run bash "$REPO/lifecycle_hooks/postCreate-root.sh" "$(id -un)"
  [ "$status" -eq 0 ]
  assert_hook_lines
  # The module clients live at fixed paths; when run inside a dcc container they exist and add their own lines
  [ -e /usr/local/lib/dcc ] || [ -z "$output" ]
  grep -qxF "git config --system --add safe.directory $BATS_TEST_TMPDIR/ws" "$STUB_LOG"
}

@test "postCreate-root: requires the user argument" {
  run bash "$REPO/lifecycle_hooks/postCreate-root.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: postCreate-root.sh <user>"* ]]
}

@test "postCreate-root: links HOST_HOME to the container home, only when it is a different, free path" {
  root_hook_stubs
  HOST_HOME="$BATS_TEST_TMPDIR/Users/me" run bash "$REPO/lifecycle_hooks/postCreate-root.sh" "$(id -un)"
  [ "$status" -eq 0 ]
  [ "$(readlink "$BATS_TEST_TMPDIR/Users/me")" = "$HOME" ]
  # An existing path is left alone
  mkdir "$BATS_TEST_TMPDIR/taken"
  HOST_HOME="$BATS_TEST_TMPDIR/taken" run bash "$REPO/lifecycle_hooks/postCreate-root.sh" "$(id -un)"
  [ ! -L "$BATS_TEST_TMPDIR/taken" ]
}

@test "postCreate-root: a home volume not owned by the user fails with a recreate hint" {
  root_hook_stubs
  stub stat 'echo 0'
  run bash "$REPO/lifecycle_hooks/postCreate-root.sh" "$(id -un)"
  [ "$status" -eq 1 ]
  assert_hook_lines
  [[ "${lines[0]}" == "warn: $HOME/.claude: owned by uid 0, not $(id -un); remove the volume (dcc-claude-home, or DCC_CLAUDE_HOME_VOLUME)"* ]]
}

@test "postCreate-root: the ownership check is skipped for directories shared by the claude / codex modules" {
  root_hook_stubs
  stub stat 'echo 0'
  DCC_CREDS=claude,codex run bash "$REPO/lifecycle_hooks/postCreate-root.sh" "$(id -un)"
  [ "$status" -eq 0 ]
  DCC_CREDS=claude run bash "$REPO/lifecycle_hooks/postCreate-root.sh" "$(id -un)"
  [ "$status" -eq 1 ]
  [[ "$output" == "warn: $HOME/.codex: owned by uid 0"* ]]
}

# --- postCreate.sh ------------------------------------------------------------

# claude update succeeds unless CLAUDE_UPDATE_FAIL is set; the fake home has the volumes the image would provide
user_hook_setup() {
  stub claude '
case "$1" in
  update) [ -z "${CLAUDE_UPDATE_FAIL:-}" ] ;;
  --version) echo "2.1.0 (Claude Code)" ;;
esac'
  mkdir -p "$HOME/.claude" "$HOME/.codex" "$BATS_TEST_TMPDIR/ws"
  chmod 755 "$HOME/.claude" "$HOME/.codex"
  cd "$BATS_TEST_TMPDIR/ws"
}

@test "postCreate: modules off → volumes locked down, workspace trusted, one hook line per fact" {
  user_hook_setup
  run bash "$REPO/lifecycle_hooks/postCreate.sh"
  [ "$status" -eq 0 ]
  assert_hook_lines
  [ "${lines[0]}" = "claude: updated to 2.1.0" ]
  [ "${lines[1]}" = "~/.claude: on volume dcc-claude-home (claude module off)" ]
  [ "${lines[2]}" = "claude: $BATS_TEST_TMPDIR/ws trusted" ]
  [ "${lines[3]}" = "~/.codex: on volume dcc-codex-home (codex module off)" ]
  [ "$(stat -c %a "$HOME/.claude")" = 700 ]
  [ "$(stat -c %a "$HOME/.codex")" = 700 ]
  [ "$(jq -r --arg ws "$BATS_TEST_TMPDIR/ws" '.projects[$ws].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ]
}

@test "postCreate: claude module → ~/.claude.json is a container-local copy of the host's, the host's is untouched" {
  user_hook_setup
  echo '{"userID":"host","projects":{"/elsewhere":{"hasTrustDialogAccepted":false}}}' >"$HOME/.claude.json.host"
  cp "$HOME/.claude.json.host" "$BATS_TEST_TMPDIR/original"
  DCC_CREDS=claude,codex run bash "$REPO/lifecycle_hooks/postCreate.sh"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "~/.claude: shared with host" ]
  [ "${lines[3]}" = "~/.codex: shared with host" ]
  [ ! -L "$HOME/.claude.json" ]
  [ "$(jq -r .userID "$HOME/.claude.json")" = host ]
  [ "$(jq -r '.projects["/elsewhere"].hasTrustDialogAccepted' "$HOME/.claude.json")" = false ]
  [ "$(jq -r --arg ws "$BATS_TEST_TMPDIR/ws" '.projects[$ws].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ]
  cmp "$HOME/.claude.json.host" "$BATS_TEST_TMPDIR/original"
}

@test "postCreate: a failed claude update only warns" {
  user_hook_setup
  CLAUDE_UPDATE_FAIL=1 run bash "$REPO/lifecycle_hooks/postCreate.sh"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "warn: claude: update failed (offline?); using 2.1.0" ]
}

@test "postCreate: gpg module → host public keys are imported for verification" {
  user_hook_setup
  local keys="$BATS_TEST_TMPDIR/keys" fpr
  fpr="$(new_gpg_key "$keys" "hook test <hook@example.invalid>")"
  mkdir "$HOME/.gnupg-host"
  gpg --homedir "$keys" --export --armor "$fpr" >"$HOME/.gnupg-host/pubkeys.asc"
  gpg --homedir "$keys" --export-ownertrust >"$HOME/.gnupg-host/ownertrust.txt"
  gpgconf --homedir "$keys" --kill all
  run bash "$REPO/lifecycle_hooks/postCreate.sh"
  [ "$status" -eq 0 ]
  [ "${lines[4]}" = "gpg: public keys imported for verification" ]
  gpg --list-keys "$fpr" >/dev/null
  # Public keys only
  [ -z "$(gpg --list-secret-keys --with-colons 2>/dev/null)" ]
}

@test "postCreate: without an export, nothing about gpg" {
  user_hook_setup
  run bash "$REPO/lifecycle_hooks/postCreate.sh"
  [[ "$output" != *"gpg"* ]]
}
