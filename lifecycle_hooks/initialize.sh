#!/usr/bin/env bash
# Host-side preprocessing. For each credential module given as an argument, export and pre-check bind sources.
# Called from dcc up and the devcontainer initializeCommand:
#   initialize.sh gpg aws
# Paths are resolved with the same DCC_* environment variables as compose (same defaults).
# No output on success. A warning is one line "warn: <module>: <message>" (dcc turns it into a ! line as-is).
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"

warn_missing() {
  # $1: path, $2: module name, $3: note
  # A bind with no source either errors or gets an auto-created empty directory, depending on the compose version
  [ -e "$1" ] || echo "warn: $2: $1 not found; the module mounts it, so 'up' may fail or leave an empty directory there${3:+ ($3)}" >&2
}

for module in "$@"; do
  case "$module" in
    claude)
      warn_missing "${DCC_CLAUDE_DIR:-$HOME/.claude}" claude
      warn_missing "${DCC_CLAUDE_JSON:-$HOME/.claude.json}" claude "start Claude Code on the host once"
      ;;
    codex)
      warn_missing "${DCC_CODEX_DIR:-$HOME/.codex}" codex "start Codex on the host once"
      ;;
    gpg)
      "$repo/capabilities/gpg/export-host-keys.sh"
      ;;
    aws)
      aws_dir="${DCC_AWS_DIR:-$HOME/.aws}"
      warn_missing "$aws_dir/config" aws
      warn_missing "$aws_dir/login/cache" aws "run 'aws login' on the host once"
      ;;
    ssh)
      warn_missing "${DCC_SSH_DIR:-$repo/capabilities/ssh/data}" ssh
      ;;
    gh)
      # No host-side preprocessing (state lives in a volume; first time, dcc gh-login). docs/github.md
      ;;
    *)
      echo "warn: $module: unknown module (ignored)" >&2
      ;;
  esac
done
