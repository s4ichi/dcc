#!/usr/bin/env bats
# Tests for the gpg module on the test host: the host export (export-host-keys.sh), git signing through the agent-side
# wrapper (gpg-sign-client.sh) against the real signing server (server.py) with a throwaway keyring, and warm.sh's
# lookup of the sidecar (docker is a stub). Run with `make test`.

bats_require_minimum_version 1.5.0

setup_file() {
  load helpers/common
  command -v gpg >/dev/null || skip "gpg not installed"
  export KEYS="$BATS_FILE_TMPDIR/keys" LOCKED="$BATS_FILE_TMPDIR/locked"
  FPR1="$(new_gpg_key "$KEYS" "signer one <one@example.invalid>")"
  FPR2="$(new_gpg_key "$KEYS" "signer two <two@example.invalid>")"
  # A passphrase-protected key in its own keyring, for the "not warmed" path
  FPR_LOCKED="$(new_gpg_key "$LOCKED" "locked <locked@example.invalid>" "e2e-passphrase")"
  export FPR1 FPR2 FPR_LOCKED

  SIGN_PORT="$(free_port)"
  LOCKED_PORT="$(free_port)"
  SIGN_PID="$(start_server "$BATS_FILE_TMPDIR/signer.log" "$SIGN_PORT" "$REPO/capabilities/gpg/server.py" \
    GNUPGHOME="$KEYS" DCC_GPG_SIGNING_KEY="$FPR1")"
  LOCKED_PID="$(start_server "$BATS_FILE_TMPDIR/locked.log" "$LOCKED_PORT" "$REPO/capabilities/gpg/server.py" \
    GNUPGHOME="$LOCKED" DCC_GPG_SIGNING_KEY="$FPR_LOCKED")"
  export SIGN_PORT LOCKED_PORT SIGN_PID LOCKED_PID
}

teardown_file() {
  kill "${SIGN_PID:-}" "${LOCKED_PID:-}" 2>/dev/null || true
  gpgconf --homedir "$KEYS" --kill all 2>/dev/null || true
  gpgconf --homedir "$LOCKED" --kill all 2>/dev/null || true
}

setup() {
  load helpers/common
  common_setup
  # When run inside a dcc container with the gpg module, the real module settings are in the environment
  unset DCC_GPG_SIGNING_KEY DCC_GNUPG_DIR DCC_GPG_SIGN_URI GIT_CONFIG_COUNT
  export OUT="$BATS_TEST_TMPDIR/gnupg-host"
  export DCC_GPG_EXPORT_DIR="$OUT" GNUPGHOME="$KEYS"
  # Only the test's own git config
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  : >"$GIT_CONFIG_GLOBAL"
}

# --- export-host-keys.sh ------------------------------------------------------

@test "export: public keys, ownertrust, and the signing key's keygrips / fingerprint; nothing secret" {
  DCC_GPG_SIGNING_KEY="$FPR1" run "$REPO/capabilities/gpg/export-host-keys.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(stat -c %a "$OUT")" = 700 ]
  [ "$(cat "$OUT/signing-key.txt")" = "$FPR1" ]
  diff <(gpg_keygrips "$KEYS" "$FPR1") "$OUT/keygrips.txt"
  grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$OUT/pubkeys.asc"
  [ -s "$OUT/ownertrust.txt" ]
  ! grep -rq "PRIVATE KEY" "$OUT"
  # Both keys with a secret part are exported for verification
  local imported="$BATS_TEST_TMPDIR/verify"
  mkdir -m 700 "$imported"
  gpg --homedir "$imported" --batch --quiet --import "$OUT/pubkeys.asc" 2>/dev/null
  gpg --homedir "$imported" --list-keys "$FPR1" "$FPR2" >/dev/null
  gpgconf --homedir "$imported" --kill all
}

@test "export: falls back to git user.signingkey and drops a trailing '!'" {
  git config --global user.signingkey "${FPR2}!"
  run "$REPO/capabilities/gpg/export-host-keys.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/signing-key.txt")" = "$FPR2" ]
}

@test "export: an email selects the key too" {
  DCC_GPG_SIGNING_KEY=two@example.invalid run "$REPO/capabilities/gpg/export-host-keys.sh"
  [ "$(cat "$OUT/signing-key.txt")" = "$FPR2" ]
}

@test "export: no signing key configured → warns, public keys still exported, no key selected" {
  DCC_GPG_SIGNING_KEY="$FPR1" run "$REPO/capabilities/gpg/export-host-keys.sh"
  run "$REPO/capabilities/gpg/export-host-keys.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "warn: gpg: no signing key (set DCC_GPG_SIGNING_KEY or git user.signingkey on the host); "* ]]
  [ -s "$OUT/pubkeys.asc" ]
  # The previous run's selection is cleared
  [ ! -s "$OUT/signing-key.txt" ]
  [ ! -s "$OUT/keygrips.txt" ]
}

@test "export: unknown signing key → warns" {
  DCC_GPG_SIGNING_KEY=nobody@example.invalid run "$REPO/capabilities/gpg/export-host-keys.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "warn: gpg: signing key 'nobody@example.invalid' not found in host keyring; gpg-signer will refuse to sign" ]
}

@test "export: no secret keys on the host → warns" {
  local empty="$BATS_TEST_TMPDIR/empty"
  mkdir -m 700 "$empty"
  DCC_GNUPG_DIR="$empty" run "$REPO/capabilities/gpg/export-host-keys.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "warn: gpg: no secret keys on host; keys not exported" ]
  gpgconf --homedir "$empty" --kill all
}

@test "export: no gpg on the host → warns and exits 0" {
  local bin="$BATS_TEST_TMPDIR/bin" t
  mkdir "$bin"
  for t in bash env mkdir chmod dirname; do ln -s "$(command -v "$t")" "$bin/$t"; done
  PATH="$bin" run "$REPO/capabilities/gpg/export-host-keys.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "warn: gpg: host gpg not found; keys not exported (signed commits unavailable)" ]
}

# --- gpg-sign-client.sh + server.py -------------------------------------------

# A repository whose gpg.program is the wrapper. user.signingkey is deliberately bogus: the signer picks the key
new_repo() {
  local repo="$BATS_TEST_TMPDIR/repo"
  git init -q "$repo"
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.signingkey ignored-by-the-signer
  git -C "$repo" config gpg.program "$REPO/capabilities/gpg/agent/gpg-sign-client.sh"
  echo "$repo"
}

@test "client: git commit -S is signed by the signer's key and verifies" {
  local repo
  repo="$(new_repo)"
  DCC_GPG_SIGN_URI="http://127.0.0.1:$SIGN_PORT/sign" git -C "$repo" commit -q -S --allow-empty -m signed
  git -C "$repo" verify-commit HEAD
  [ "$(git -C "$repo" log -1 --format=%GF)" = "$FPR1" ]
  [ "$(git -C "$repo" log -1 --format=%G?)" = G ]
}

@test "client: signed tags work too" {
  local repo
  repo="$(new_repo)"
  git -C "$repo" commit -q --allow-empty -m base
  DCC_GPG_SIGN_URI="http://127.0.0.1:$SIGN_PORT/sign" git -C "$repo" tag -s -m signed v1
  git -C "$repo" verify-tag v1
}

@test "client: a payload that is not a git object is refused (403)" {
  DCC_GPG_SIGN_URI="http://127.0.0.1:$SIGN_PORT/sign" \
    run --separate-stderr "$REPO/capabilities/gpg/agent/gpg-sign-client.sh" --status-fd=2 -bsau X <<<"hello"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"refusing to sign"* ]]
  [[ "$stderr" == *"signing failed (HTTP 403)"* ]]
}

@test "client: unreachable signer → exit 2" {
  DCC_GPG_SIGN_URI="http://127.0.0.1:$(free_port)/sign" \
    run "$REPO/capabilities/gpg/agent/gpg-sign-client.sh" --status-fd=2 -bsau X <<<"tree 0123456789012345678901234567890123456789"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot reach the gpg-signer sidecar"* ]]
}

@test "client: without the gpg module (no DCC_GPG_SIGN_URI) signing fails with a clear message" {
  run "$REPO/capabilities/gpg/agent/gpg-sign-client.sh" --status-fd=2 -bsau X <<<"x"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DCC_GPG_SIGN_URI is not set (gpg module not enabled)"* ]]
}

@test "client: the reason reaches git's stderr once per failure, appended (a redirected log is not truncated)" {
  local repo log="$BATS_TEST_TMPDIR/git.log"
  repo="$(new_repo)"
  echo "earlier line" >"$log"
  ! DCC_GPG_SIGN_URI="http://127.0.0.1:$(free_port)/sign" \
    git -C "$repo" commit -q -S --allow-empty -m unreachable 2>>"$log"
  [ "$(head -n 1 "$log")" = "earlier line" ]
  grep -qF "gpg-sign-client: cannot reach the gpg-signer sidecar" "$log"
  # Called directly (not by git), the message is not written twice
  run --separate-stderr env DCC_GPG_SIGN_URI="http://127.0.0.1:$(free_port)/sign" \
    "$REPO/capabilities/gpg/agent/gpg-sign-client.sh" --status-fd=2 -bsau X <<<"x"
  [ "$(grep -c "cannot reach" <<<"$stderr")" -eq 1 ]
}

@test "client: anything but signing is plain gpg" {
  stub gpg 'echo "plain gpg"'
  run "$REPO/capabilities/gpg/agent/gpg-sign-client.sh" --verify sig -
  [ "$output" = "plain gpg" ]
  grep -qxF "gpg --verify sig -" "$STUB_LOG"
}

@test "server: a passphrase that is not cached fails fast with the warm hint" {
  local repo
  repo="$(new_repo)"
  DCC_GPG_SIGN_URI="http://127.0.0.1:$LOCKED_PORT/sign" \
    run timeout 20 git -C "$repo" commit -q -S --allow-empty -m locked
  [ "$status" -ne 0 ]
  [ "$status" -ne 124 ]
  # Even a git that keeps gpg.program's stderr to itself shows the reason (the wrapper writes to git's stderr)
  [[ "$output" == *"gpg-sign-client: signing failed (HTTP 503): gpg exited"*"run capabilities/gpg/warm.sh"* ]]
  DCC_GPG_SIGN_URI="http://127.0.0.1:$LOCKED_PORT/sign" \
    run "$REPO/capabilities/gpg/agent/gpg-sign-client.sh" --status-fd=2 -bsau X \
    <<<"tree 0123456789012345678901234567890123456789"
  [ "$status" -eq 2 ]
  [[ "$output" == *"passphrase not cached? run capabilities/gpg/warm.sh"* ]]
  [[ "$output" == *"signing failed (HTTP 503)"* ]]
}

@test "server: logs neither payload nor signature" {
  ! grep -q "tree \|BEGIN PGP" "$BATS_FILE_TMPDIR/signer.log"
  grep -q "^POST /sign 200" "$BATS_FILE_TMPDIR/signer.log"
}

# --- warm.sh ------------------------------------------------------------------

@test "warm: -p <project> execs gpg-warm.sh in that project's gpg-signer" {
  stub docker '[ "$1" = ps ] && echo signer123; true'
  run "$REPO/capabilities/gpg/warm.sh" -p dcc-proj-1234
  [ "$status" -eq 0 ]
  grep -qF "docker ps -q --filter label=com.docker.compose.project=dcc-proj-1234 --filter label=com.docker.compose.service=gpg-signer" "$STUB_LOG"
  grep -qxF "docker exec -it signer123 /usr/local/bin/gpg-warm.sh" "$STUB_LOG"
}

@test "warm: a workspace argument is resolved through the workspace label" {
  local ws="$BATS_TEST_TMPDIR/ws"
  mkdir "$ws"
  stub docker "
case \"\$*\" in
  *'label=dcc.workspace=$ws'*) echo agent1 ;;
  'inspect '*agent1) echo dcc-ws-abcd ;;
  *'project=dcc-ws-abcd'*) echo signer9 ;;
esac"
  run "$REPO/capabilities/gpg/warm.sh" "$ws"
  [ "$status" -eq 0 ]
  grep -qxF "docker exec -it signer9 /usr/local/bin/gpg-warm.sh" "$STUB_LOG"
}

@test "warm: no container for the workspace / no signer → explains and exits 1" {
  stub docker ':'
  mkdir "$BATS_TEST_TMPDIR/ws"
  run "$REPO/capabilities/gpg/warm.sh" "$BATS_TEST_TMPDIR/ws"
  [ "$status" -eq 1 ]
  [ "$output" = "gpg-warm: no container found for workspace $BATS_TEST_TMPDIR/ws (use -p <project>)" ]
  run "$REPO/capabilities/gpg/warm.sh" -p some-project
  [ "$status" -eq 1 ]
  [[ "$output" == *"gpg-signer sidecar is not running in project some-project"* ]]
  run "$REPO/capabilities/gpg/warm.sh" "$BATS_TEST_TMPDIR/missing"
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace not found"* ]]
}
