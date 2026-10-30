#!/usr/bin/env bash
# The part run once as root after container creation (cwd is the workspace). The agent container has no sudo and the agent's
# processes cannot become root, so dcc calls this with `compose exec --user root`. Work done as the container user
# is in postCreate.sh (run after this). How to call it from devcontainer: docs/devcontainer.md.
#   postCreate-root.sh <user>
# Output conventions are the same as postCreate.sh ("<subject>: <predicate>" / "warn: <subject>: <predicate>").
# root has no capabilities (cap_drop ALL), so work needing CAP_* such as chown cannot be done here either.
# shellcheck disable=SC2088  # the subject "~/.claude" is a string for display and must not be expanded
set -euo pipefail

user="${1:?usage: postCreate-root.sh <user>}"
uid="$(id -u "$user")"
home="$(getent passwd "$user" | cut -d: -f6)"

has_cred() {
  case ",${DCC_CREDS:-}," in *",$1,"*) return 0 ;; esac
  return 1
}

# When ~/.claude / ~/.codex are volumes (module disabled), check that the owner is the container user.
# This relies on the empty volume inheriting the owner of the image's directory on first mount, so it is not fixed here
# (no CAP_CHOWN). A volume first mounted with an old image stays root-owned; in that case recreate it
check_volume_owner() {
  # $1: module name, $2: directory, $3: volume name for display
  has_cred "$1" && return 0
  [ "$(stat -c %u "$2")" = "$uid" ] && return 0
  echo "warn: $2: owned by uid $(stat -c %u "$2"), not $user; remove the volume ($3) and run 'dcc recreate' with the current image" >&2
  return 1
}
check_volume_owner claude "$home/.claude" "dcc-claude-home, or DCC_CLAUDE_HOME_VOLUME"
check_volume_owner codex "$home/.codex" "dcc-codex-home, or DCC_CODEX_HOME_VOLUME"

# Metadata of plugins installed on the host contains absolute host paths, so
# symlink the host home -> container home to resolve them
if [ -n "${HOST_HOME:-}" ] && [ "${HOST_HOME}" != "${home}" ] && [ ! -e "${HOST_HOME}" ]; then
  mkdir -p "$(dirname "${HOST_HOME}")"
  ln -sfn "${home}" "${HOST_HOME}"
fi

# The bound workspace keeps the host uid, so register it in safe.directory.
# ~/.gitconfig is ro, so write to system
git config --system --add safe.directory "$(pwd)"

# When the gpg module is enabled: register the wrapper that delegates signing to the gpg-signer sidecar as gpg.program
# (the main path is compose's GIT_CONFIG_* environment variables; this is a fallback in case env is stripped).
# Importing the public key for verification goes into the container user's keyring, so postCreate.sh does it
client=/usr/local/lib/dcc/gpg-sign-client.sh
if [ -x "$client" ]; then
  git config --system gpg.program "$client"
  echo "gpg: signing delegated to gpg-signer"
fi

# When the gh module is enabled: make git's https auth use the gh-token sidecar's short-lived token.
# gh auth setup-git fails trying to write ~/.gitconfig (ro), so register it in system
client=/usr/local/lib/dcc/gh-token-client.sh
if [ -x "$client" ]; then
  host="${DCC_GH_HOST:-github.com}"
  git config --system --replace-all "credential.https://${host}.helper" "!${client} git-credential"
  echo "gh: token served by gh-token sidecar (gh and git over https://${host})"
fi
