# shellcheck shell=bash
# Credential modules (capabilities/<name>/compose.yml).
# Input: CREDS_REQUEST / CREDS_EXPLICIT (parse_args), CREDS_DEFAULT (DCC_CREDS from the environment), existing container's labels
# Result: CREDS (whitespace-separated, canonical order), DCC_CREDS (comma-separated, exported for compose), ALL_CREDS,
#       CREDS_SOURCE (flags | container | DCC_CREDS | none; for display)
# Checking for mismatch with the existing container (drift) is also here.

cred_overlay() {
  printf '%s/%s/compose.yml' "$CAPABILITIES_DIR" "$1"
}

# Available module names = directory names of capabilities/<name>/compose.yml (one per line, sort order = canonical order)
list_all_creds() {
  local f
  for f in "$CAPABILITIES_DIR"/*/compose.yml; do
    [ -e "$f" ] || die "no credential overlays ($CAPABILITIES_DIR/*/compose.yml; run 'make generate' in $CONFIG_DIR)"
    f="${f%/compose.yml}"
    printf '%s\n' "${f##*/}"
  done
}

# Precedence: flags > (with --adopt) existing container's label > DCC_CREDS > none.
# Modules can only take effect at creation, so `dcc` without flags uses the existing container's (including stopped)
# selection as-is. Only when flags are given does check_creds_drift warn about a mismatch
resolve_creds() {
  local all requested name running
  all="$(list_all_creds)"
  ALL_CREDS="$(printf '%s' "$all" | paste -sd ' ' -)"

  if [ "$CREDS_EXPLICIT" -eq 1 ]; then
    requested="$CREDS_REQUEST"
    CREDS_SOURCE=flags
  elif [ "${1:-}" = --adopt ] && running="$(agent_label dcc.credentials)"; then
    requested="$running"
    CREDS_SOURCE=container
  elif [ -n "$CREDS_DEFAULT" ]; then
    requested="$CREDS_DEFAULT"
    CREDS_SOURCE=DCC_CREDS
  else
    requested=""
    CREDS_SOURCE=none
  fi

  requested="$(printf '%s' "$requested" | tr ' ,' '\n' | grep -v '^$' || true)"
  for name in $requested; do
    printf '%s\n' "$all" | grep -qx "$name" \
      || die "unknown credential module '$name' (available: $ALL_CREDS)"
  done
  CREDS=""
  for name in $all; do
    printf '%s\n' "$requested" | grep -qx "$name" && CREDS="${CREDS:+$CREDS }$name"
  done
  DCC_CREDS="$(printf '%s' "$CREDS" | tr ' ' ',')"
  export DCC_CREDS
}

has_cred() {
  case " $CREDS " in *" $1 "*) return 0 ;; esac
  return 1
}

# COMPOSE_FILES: base -> workspace -> credential overlay ($1: whitespace-separated) -> local/compose.yml -> DCC_COMPOSE_FILES
compose_files() {
  local name f
  for f in docker-compose.yml docker-compose.workspace.yml; do
    [ -f "$CONFIG_DIR/$f" ] || die "$CONFIG_DIR/$f not found (run 'make generate' in $CONFIG_DIR)"
  done
  COMPOSE_FILES=(-f "$CONFIG_DIR/docker-compose.yml" -f "$CONFIG_DIR/docker-compose.workspace.yml")
  for name in $1; do
    COMPOSE_FILES+=(-f "$(cred_overlay "$name")")
  done
  [ -f "$LOCAL_DIR/compose.yml" ] && COMPOSE_FILES+=(-f "$LOCAL_DIR/compose.yml")
  local IFS=:
  for f in ${DCC_COMPOSE_FILES:-}; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || die "DCC_COMPOSE_FILES: $f not found"
    COMPOSE_FILES+=(-f "$f")
  done
}

# Command to apply this selection (shown on the second line of the warning)
recreate_hint() {
  if [ -n "$DCC_CREDS" ]; then
    printf "dcc recreate --creds %s" "$DCC_CREDS"
  else
    printf "dcc recreate --no-creds"
  fi
}

# Signing key (fingerprint) the host just exported. Empty if none
host_signing_key() {
  cat "$GPG_EXPORT_DIR/signing-key.txt" 2>/dev/null || true
}

# Warns if what is baked into the existing container differs from this request. It doesn't take effect until recreated,
# so here it only warns and connects to the existing one. The three checks are independent
check_drift() {
  check_creds_drift
  check_aws_profile_drift
  check_gpg_key_drift
}

# Credential module selection (label dcc.credentials)
check_creds_drift() {
  local running name added="" removed=""
  running="$(agent_label dcc.credentials | tr ',' ' ')" || return 0
  [ "$running" != "$CREDS" ] || return 0
  for name in $CREDS; do
    case " $running " in *" $name "*) ;; *) added="${added:+$added }+$name" ;; esac
  done
  for name in $running; do
    case " $CREDS " in *" $name "*) ;; *) removed="${removed:+$removed }-$name" ;; esac
  done
  warn credentials "container has ${running:-none}; requested ${CREDS:-none} (${added:+$added}${added:+${removed:+ }}${removed})" \
    "run '$(recreate_hint)' to apply"
}

# AWS_PROFILE of the aws module (label dcc.aws-profile)
check_aws_profile_drift() {
  has_cred aws || return 0
  local want running
  want="${DCC_AWS_PROFILE:-${AWS_PROFILE:-default}}"
  running="$(agent_label dcc.aws-profile)" || return 0
  [ -n "$running" ] && [ "$running" != "$want" ] || return 0
  warn aws "container was created with AWS_PROFILE=$running; requested $want" \
    "run 'AWS_PROFILE=$want $(recreate_hint)' to apply"
}

# Signing key of the gpg module (the key pinned by the running gpg-signer, and the key the host just exported)
check_gpg_key_drift() {
  has_cred gpg || return 0
  local running want
  running="$(signer_signing_key)"
  want="$(host_signing_key)"
  [ -n "$running" ] && [ -n "$want" ] && [ "$running" != "$want" ] || return 0
  warn gpg "gpg-signer was started with signing key $(short_key "$running"); host now exports $(short_key "$want")" \
    "run '$(recreate_hint)' to apply"
}

# Output of dcc creds (stdout). Available modules / defaults / this resolution / existing container's selection
show_creds() {
  local running
  echo "available: $ALL_CREDS"
  echo "DCC_CREDS: ${CREDS_DEFAULT:-(unset)}"
  case "$CREDS_SOURCE" in
    flags)     echo "selected:  ${CREDS:-(none)}   # from flags" ;;
    container) echo "selected:  ${CREDS:-(none)}   # from the existing container" ;;
    DCC_CREDS) echo "selected:  ${CREDS:-(none)}   # from DCC_CREDS" ;;
    none)      echo "selected:  (none)" ;;
  esac
  if running="$(agent_label dcc.credentials | tr ',' ' ')"; then
    echo "running:   ${running:-(none)}   # $COMPOSE_PROJECT_NAME"
  else
    echo "running:   (not running)   # $COMPOSE_PROJECT_NAME"
  fi
}
