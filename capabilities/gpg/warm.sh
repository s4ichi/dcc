#!/usr/bin/env bash
# Cache the signing key's passphrase in gpg-agent inside the gpg-signer sidecar (run in an interactive terminal on the host).
# The cache lasts for the sidecar's lifetime, so once is enough until it is recreated. dcc calls this automatically before starting claude.
#   warm.sh [workspace]     find the sidecar from the agent container that has the workspace (default: current directory)
#   warm.sh -p <project>    specify by compose project name
set -euo pipefail

project=""
workspace="$PWD"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p|--project) project="$2"; shift ;;
    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) workspace="$1" ;;
  esac
  shift
done

if [ -z "$project" ]; then
  [ -d "$workspace" ] || { echo "gpg-warm: workspace not found: $workspace" >&2; exit 1; }
  workspace="$(cd "$workspace" && pwd)"
  project="$(
    {
      docker ps -aq --filter "label=dcc.workspace=$workspace"
      docker ps -aq --filter "label=devcontainer.local_folder=$workspace"
    } | head -n 1 | xargs -r docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}'
  )"
  [ -n "$project" ] || { echo "gpg-warm: no container found for workspace $workspace (use -p <project>)" >&2; exit 1; }
fi

id="$(docker ps -q \
  --filter "label=com.docker.compose.project=$project" \
  --filter "label=com.docker.compose.service=gpg-signer" \
  | head -n 1)"
[ -n "$id" ] || { echo "gpg-warm: gpg-signer sidecar is not running in project $project (gpg module enabled?)" >&2; exit 1; }

exec docker exec -it "$id" /usr/local/bin/gpg-warm.sh
