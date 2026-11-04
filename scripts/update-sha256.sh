#!/usr/bin/env bash
# Rewrites each `ARG <NAME>=<sha256>` that has a `# sha256: <url>` comment directly above it to the sha256 of that
# download. `${VAR}` in the URL expands to the ARG defaults of the same file. Knows nothing about the tools themselves.
# Run by Renovate after a version bump (renovate.json) and by hand with `make sha256`. docs/architecture.md
set -euo pipefail

update() {
  local file="$1" line url="" name var sum tmp
  local -A args=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^ARG[[:space:]]+([A-Za-z0-9_]+)=(.*)$ ]]; then
      args["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done <"$file"

  tmp="$(mktemp)"
  # shellcheck disable=SC2064 # expand now: tmp is local
  trap "rm -f '$tmp'" RETURN
  while IFS= read -r line; do
    if [[ -n "$url" ]]; then
      if [[ ! "$line" =~ ^ARG[[:space:]]+([A-Za-z0-9_]+)=[0-9a-f]{64}$ ]]; then
        echo "$file: '# sha256:' is not directly above 'ARG <NAME>=<sha256>': $line" >&2
        return 1
      fi
      name="${BASH_REMATCH[1]}"
      for var in "${!args[@]}"; do
        url="${url//"\${$var}"/${args[$var]}}"
      done
      # shellcheck disable=SC2016 # a literal "${" left over
      if [[ "$url" == *'${'* ]]; then
        echo "$file: $name: unresolved variable in $url" >&2
        return 1
      fi
      sum="$(curl -fsSL "$url" | sha256sum)"
      line="ARG $name=${sum%% *}"
      echo "$name: ${sum%% *}" >&2
      url=""
    elif [[ "$line" =~ ^#[[:space:]]*sha256:[[:space:]]*(.+)$ ]]; then
      url="${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "$line"
  done <"$file" >"$tmp"
  # Rewrite in place, keeping the file's mode
  cat "$tmp" >"$file"
}

for f in "${@:-Dockerfile}"; do
  update "$f"
done
