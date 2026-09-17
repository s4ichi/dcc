# shellcheck shell=bash
# credential モジュール (capabilities/<name>/compose.yml)。
# 入力: CREDS_REQUEST / CREDS_EXPLICIT (parse_args)、CREDS_DEFAULT (環境の DCC_CREDS)、既存コンテナのラベル
# 結果: CREDS (空白区切り、正規順)、DCC_CREDS (カンマ区切り、compose 用に export)、ALL_CREDS、
#       CREDS_SOURCE (flags | container | DCC_CREDS | none。表示用)
# 既存コンテナとの不一致 (drift) の検査もここ。

cred_overlay() {
  printf '%s/%s/compose.yml' "$CAPABILITIES_DIR" "$1"
}

# 利用可能なモジュール名 = capabilities/<name>/compose.yml のディレクトリ名 (1 行 1 つ、ソート順 = 正規順)
list_all_creds() {
  local f
  for f in "$CAPABILITIES_DIR"/*/compose.yml; do
    [ -e "$f" ] || die "no credential overlays ($CAPABILITIES_DIR/*/compose.yml; run 'make generate' in $CONFIG_DIR)"
    f="${f%/compose.yml}"
    printf '%s\n' "${f##*/}"
  done
}

# 優先順: フラグ > (--adopt のとき) 既存コンテナのラベル > DCC_CREDS > 無し。
# モジュールは作成時にしか反映できないので、フラグ無しの `dcc` は既存コンテナ (停止中も含む) の
# 選択をそのまま使う。フラグを付けたときだけ check_creds_drift が不一致を警告する
resolve_creds() {
  local all requested name running
  all="$(list_all_creds)"
  ALL_CREDS="$(printf '%s' "$all" | paste -sd ' ' -)"

  if [ "$CREDS_EXPLICIT" -eq 1 ]; then
    requested="$CREDS_REQUEST"
    CREDS_SOURCE=flags
  elif [ "${1:-}" = --adopt ] && running="$(claude_label dcc.credentials)"; then
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

# COMPOSE_FILES: base → workspace → credential overlay ($1: 空白区切り) → local/compose.yml → DCC_COMPOSE_FILES
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

# 今回の選択を適用するためのコマンド (警告の 2 行目に出す)
recreate_hint() {
  if [ -n "$DCC_CREDS" ]; then
    printf "dcc recreate --creds %s" "$DCC_CREDS"
  else
    printf "dcc recreate --no-creds"
  fi
}

# ホストが今 export した署名鍵 (fingerprint)。無ければ空
host_signing_key() {
  cat "$GPG_EXPORT_DIR/signing-key.txt" 2>/dev/null || true
}

# 既存コンテナに焼き込まれたものと今回の要求が違えば警告する。作り直すまで反映されないので、
# ここでは警告だけして既存に接続する。3 つの検査はそれぞれ独立
check_drift() {
  check_creds_drift
  check_aws_profile_drift
  check_gpg_key_drift
}

# credential モジュールの選択 (ラベル dcc.credentials)
check_creds_drift() {
  local running name added="" removed=""
  running="$(claude_label dcc.credentials | tr ',' ' ')" || return 0
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

# aws モジュールの AWS_PROFILE (ラベル dcc.aws-profile)
check_aws_profile_drift() {
  has_cred aws || return 0
  local want running
  want="${DCC_AWS_PROFILE:-${AWS_PROFILE:-default}}"
  running="$(claude_label dcc.aws-profile)" || return 0
  [ -n "$running" ] && [ "$running" != "$want" ] || return 0
  warn aws "container was created with AWS_PROFILE=$running; requested $want" \
    "run 'AWS_PROFILE=$want $(recreate_hint)' to apply"
}

# gpg モジュールの署名鍵 (実行中の gpg-signer が固定した鍵と、ホストが今 export した鍵)
check_gpg_key_drift() {
  has_cred gpg || return 0
  local running want
  running="$(signer_signing_key)"
  want="$(host_signing_key)"
  [ -n "$running" ] && [ -n "$want" ] && [ "$running" != "$want" ] || return 0
  warn gpg "gpg-signer was started with signing key $(short_key "$running"); host now exports $(short_key "$want")" \
    "run '$(recreate_hint)' to apply"
}

# dcc creds の出力 (stdout)。利用可能なモジュール / 既定値 / 今回の解決結果 / 既存コンテナの選択
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
  if running="$(claude_label dcc.credentials | tr ',' ' ')"; then
    echo "running:   ${running:-(none)}   # $COMPOSE_PROJECT_NAME"
  else
    echo "running:   (not running)   # $COMPOSE_PROJECT_NAME"
  fi
}
