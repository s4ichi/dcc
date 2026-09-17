# shellcheck shell=bash
# 全ワークスペース横断。本体コンテナをワークスペースラベル (dcc / devcontainer CLI のどちらか) で
# 列挙し、compose プロジェクト単位で操作する。

list_containers() {
  local ids id
  ids="$(workspace_container_ids -a)"
  if [ -z "$ids" ]; then
    echo "No containers found."
    return 0
  fi
  local -a filters=()
  for id in $ids; do filters+=(--filter "id=$id"); done
  docker ps -a "${filters[@]}" \
    --format "table {{.ID}}\t{{.Status}}\t{{.Names}}\t{{.Label \"$PROJECT_LABEL\"}}\t{{.Label \"dcc.credentials\"}}\t$(workspace_template .Label)"
}

inspect_containers() {
  local id ids
  ids="$(workspace_container_ids -a)"
  if [ -z "$ids" ]; then
    echo "No containers found."
    return 0
  fi
  for id in $ids; do
    echo "== $id =="
    docker inspect "$id" --format "name={{.Name}}
status={{.State.Status}}
workspace=$(workspace_template 'index .Config.Labels')
project={{index .Config.Labels \"$PROJECT_LABEL\"}}
credentials={{index .Config.Labels \"dcc.credentials\"}}
image={{.Config.Image}}
"
  done
}

# ワークスペースを持つ全 compose プロジェクトで、プロジェクト単位の関数 ($@) を 1 回ずつ実行する。
# COMPOSE_PROJECT_NAME を差し替えた subshell で呼ぶので、関数側はワークスペース単位のときと同じでよい。
# -a: 停止中のコンテナしか無いプロジェクトも対象にする。どれかが失敗しても残りは実行し、最後に失敗する
for_each_project() {
  local ps_opts="" ids id project seen=" " failed=0
  [ "${1:-}" != -a ] || { ps_opts=-a; shift; }
  ids="$(workspace_container_ids $ps_opts)"
  if [ -z "$ids" ]; then
    step containers "none found"
    return 0
  fi
  for id in $ids; do
    project="$(label_of "$id" "$PROJECT_LABEL")"
    if [ -z "$project" ]; then
      warn containers "skipping non-compose container $id"
      continue
    fi
    case "$seen" in *" $project "*) continue ;; esac
    seen="$seen$project "
    ( COMPOSE_PROJECT_NAME="$project"; "$@" ) || failed=1
  done
  [ "$failed" -eq 0 ]
}
