# shellcheck shell=bash
# Across all workspaces. Enumerates agent containers by workspace label (from either dcc or the devcontainer CLI)
# and operates per compose project.

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

# Runs a per-project function ($@) once for every compose project that has a workspace.
# It is called in a subshell with COMPOSE_PROJECT_NAME swapped, so the function can be the same as in the per-workspace case.
# -a: also include projects that only have stopped containers. If any fails, the rest still run, and it fails at the end
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
