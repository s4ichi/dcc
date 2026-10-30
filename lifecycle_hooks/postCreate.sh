#!/usr/bin/env bash
# Run once as the container user after container creation (cwd is the workspace). Work that needs root goes in
# postCreate-root.sh (dcc runs it first as root). The agent container has no sudo.
# Output is "what happened to the container" as "<subject>: <predicate>", one per line (dcc turns them into ▸ lines as-is).
# Warnings are "warn: <subject>: <predicate>". Don't print work whose result is the same every time (safe.directory etc.).
# shellcheck disable=SC2088  # the subject "~/.claude" is a string for display and must not be expanded
set -euo pipefail

has_cred() {
  case ",${DCC_CREDS:-}," in *",$1,"*) return 0 ;; esac
  return 1
}

# Update Claude Code to latest. The result stays in the container layer and recreate reverts to the baked-in version (updated here again then).
# Even if it fails (offline etc.) it can start with the baked-in version, so only warn.
if claude update >/dev/null 2>&1; then
  echo "claude: updated to $(claude --version | awk '{print $1}')"
else
  echo "warn: claude: update failed (offline?); using $(claude --version | awk '{print $1}')" >&2
fi

# Initialize ~/.claude.
# - claude module enabled: ~/.claude is a rw bind of the host's. With a single-file bind, ~/.claude.json's
#   atomic write fails with EXDEV, so copy the initial value passed ro into the container-local file
# - disabled: ~/.claude is an empty volume shared by all workspaces (owner is inherited from the image; postCreate-root.sh
#   has checked it). Its contents are left to Claude Code
if has_cred claude; then
  cp "${HOME}/.claude.json.host" "${HOME}/.claude.json"
  echo "~/.claude: shared with host"
else
  chmod 700 "${HOME}/.claude"
  echo "~/.claude: on volume dcc-claude-home (claude module off)"
fi

# Mark the workspace as trusted. ~/.claude.json is container-local, so an approval is lost on recreate and
# the prompt appears every time. The container itself is treated as the boundary, so skip the prompt (docs/claude-code.md)
claude_json="${HOME}/.claude.json"
[ -s "${claude_json}" ] || echo '{}' >"${claude_json}"
jq --arg ws "${PWD}" '.projects[$ws].hasTrustDialogAccepted = true' "${claude_json}" >"${claude_json}.tmp"
mv "${claude_json}.tmp" "${claude_json}"
echo "claude: ${PWD} trusted"

# Same for ~/.codex (enabled: rw bind of the host's, disabled: empty volume shared by all workspaces). ~/.codex has
# no standalone file like ~/.claude.json, so no copy is needed. The Codex binary lives in /opt/codex (image), and
# unlike claude it is not updated here (update by rebuilding the image)
if has_cred codex; then
  echo "~/.codex: shared with host"
else
  chmod 700 "${HOME}/.codex"
  echo "~/.codex: on volume dcc-codex-home (codex module off)"
fi

# When the gpg module is enabled: import the public key and ownertrust into the container user's keyring for verification
# (signing is delegated to the gpg-signer sidecar via the wrapper postCreate-root.sh registered)
setup_gnupg() {
  local export_dir="${HOME}/.gnupg-host"

  [ -s "${export_dir}/pubkeys.asc" ] || return 0

  gpg --batch --quiet --import "${export_dir}/pubkeys.asc" 2>/dev/null
  if [ -s "${export_dir}/ownertrust.txt" ]; then
    gpg --quiet --import-ownertrust "${export_dir}/ownertrust.txt" 2>/dev/null
  fi
  echo "gpg: public keys imported for verification"
}
setup_gnupg
