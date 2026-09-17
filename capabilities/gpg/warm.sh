#!/usr/bin/env bash
# 署名鍵のパスフレーズを gpg-signer sidecar 内の gpg-agent にキャッシュする (ホストの対話ターミナルで実行)。
# キャッシュは sidecar の寿命いっぱい残るので、作り直すまで 1 回でよい。dcc は claude 起動前に自動で呼ぶ。
#   warm.sh [workspace]     ワークスペースを持つ本体コンテナから sidecar を探す (既定: カレント)
#   warm.sh -p <project>    compose プロジェクト名で指定
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
