# shellcheck shell=bash
# Shared by test/*.bats and test/e2e/*.bats (`load helpers/common` / `load ../helpers/common`).
# Stubs on PATH, free ports, throwaway GnuPG keyrings, and running the sidecar servers (server.py) on the test host.
# What each suite covers and how to run it: docs/testing.md

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO

# Per-test stub directory, first on PATH. Every stub call is appended to $STUB_LOG as "<name> <args>"
common_setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  mkdir -p "$STUB_DIR"
  : >"$STUB_LOG"
  PATH="$STUB_DIR:$PATH"
  export STUB_LOG
  export NO_COLOR=1
}

# stub <name> [body]: an executable <name> that logs its arguments and then runs body (bash)
stub() {
  {
    echo '#!/usr/bin/env bash'
    # shellcheck disable=SC2016  # $* and $STUB_LOG expand when the stub runs
    printf 'printf "%%s\\n" "%s $*" >>"$STUB_LOG"\n' "$1"
    printf '%s\n' "${2:-}"
  } >"$STUB_DIR/$1"
  chmod +x "$STUB_DIR/$1"
}

# A TCP port nothing listens on right now
free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# start_server <log> <port> <server.py> [VAR=value...]: runs a sidecar server in the background and waits until it listens.
# Prints the pid. fd 3 is closed so bats does not wait for the server
start_server() {
  local log="$1" port="$2" script="$3" pid
  shift 3
  env BIND_PORT="$port" "$@" python3 "$script" >"$log" 2>&1 3>&- &
  pid=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$port/" && { echo "$pid"; return 0; }
    sleep 0.1
  done
  cat "$log" >&2
  return 1
}

# new_gpg_key <gnupghome> <uid> [passphrase]: generates an ed25519 signing key and prints its fingerprint.
# The agent is stopped afterwards so a passphrase given here is not left cached
new_gpg_key() {
  local home="$1" uid="$2" pass="${3:-}"
  mkdir -p "$home"
  chmod 700 "$home"
  gpg --homedir "$home" --batch --quiet --pinentry-mode loopback --passphrase "$pass" \
    --quick-gen-key "$uid" ed25519 sign never 2>/dev/null
  gpgconf --homedir "$home" --kill gpg-agent
  gpg --homedir "$home" --list-secret-keys --with-colons "$uid" | awk -F: '$1=="fpr"{print $10; exit}'
}

# Keygrips of a key (one per line)
gpg_keygrips() {
  gpg --homedir "$1" --list-secret-keys --with-keygrip --with-colons "$2" | awk -F: '$1=="grp"{print $10}'
}

# Hook output must be "<subject>: <predicate>" / "warn: <subject>: <predicate>" (dcc's relay turns it into log lines)
assert_hook_lines() {
  local line
  # shellcheck disable=SC2154  # lines is set by bats' run
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^(warn:\ )?[^:\ ][^:]*:\ .+ ]] || { echo "not a hook line: $line" >&2; return 1; }
  done
}
