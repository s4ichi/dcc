# shellcheck shell=bash
# ログ (stderr)。ヘッダー 1 ブロックの後、1 行につき「主語 + 何をした / どうなった」を 1 つだけ書く。
#   "▸ <主語>  <述語>  (補足)"   dcc が対象に対して行ったこと、または分かったこと (step)
#   "! <主語>  <述語>"           警告 (黄)。2 行目は対処 (warn)
#   "! <主語>  failed"           失敗 (赤)。続けてそのコマンドの出力を全部字下げして出す (fail / run_step)
#   "✓ ready   <秒>"             完了 (done_step)
# 主語は containers / image / volume / credentials / claude / ~/.claude / gpg / aws … のように
# 「dcc が触った対象」で、関数名や compose のサブコマンド名は使わない。
# 外部ツール (compose / フック) の出力は成功時には出さず、失敗時にだけ全部出す。DCC_VERBOSE=1 で常時流す。
# 色は TTY のときだけ (NO_COLOR で無効)。

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_CYN=$'\e[36m' C_RST=$'\e[0m'
else
  C_BOLD="" C_DIM="" C_RED="" C_GRN="" C_YEL="" C_CYN="" C_RST=""
fi
SUBJECT_WIDTH=14

# $1: 主語、$2: 述語、$3: 補足 (薄い色で括弧付き)
step() {
  printf '%s▸%s %s%-*s%s %s%s\n' "$C_CYN" "$C_RST" "$C_BOLD" "$SUBJECT_WIDTH" "$1" "$C_RST" "$2" \
    "${3:+  $C_DIM($3)$C_RST}" >&2
}

done_step() {
  printf '%s✓ %-*s %s%s\n' "$C_GRN" "$SUBJECT_WIDTH" "$1" "$2" "$C_RST" >&2
}

# $1: 主語、$2: 述語、$3: 対処 (任意)
warn() {
  printf '%s! %-*s %s%s\n' "$C_YEL" "$SUBJECT_WIDTH" "$1" "$2" "$C_RST" >&2
  [ -z "${3:-}" ] || printf '%s  %-*s %s%s\n' "$C_YEL" "$SUBJECT_WIDTH" "" "$3" "$C_RST" >&2
}

fail() {
  printf '%s! %-*s %s%s\n' "$C_RED" "$SUBJECT_WIDTH" "$1" "$2" "$C_RST" >&2
}

# 字下げ。compose が非 TTY で出す logrus 形式 (time=… level=… msg=…) は level と msg だけにする
indent() {
  local line msg
  while IFS= read -r line; do
    if [[ "$line" =~ ^time=\"[^\"]*\"\ level=([a-z]+)\ msg=\"(.*)\"$ ]]; then
      msg="${BASH_REMATCH[2]//\\\"/\"}"
      line="${BASH_REMATCH[1]}: ${msg#Warning: }"
    fi
    printf '  %s\n' "$line"
  done
}

# run_step: $1: 主語、残り: コマンド。出力は成功時は捨て、失敗時に "! <主語> failed" に続けて全部出して終了する。
#   -s            常に流す (字下げ付き)。DCC_VERBOSE=1 も同じ
#   -t            端末をそのまま渡す (字下げしない)。docker build のように自前の進捗表示を持つもの用
run_step() {
  local stream="" tty="" subject out
  case "$1" in
    -s) stream=1; shift ;;
    -t) tty=1; shift ;;
  esac
  subject="$1"
  shift
  if [ -n "$tty" ]; then
    "$@" && return 0
    fail "$subject" "failed"
    exit 1
  fi
  if [ -n "$stream" ] || [ -n "${DCC_VERBOSE:-}" ]; then
    "$@" 2>&1 | indent >&2 && return 0
    fail "$subject" "failed"
    exit 1
  fi
  out="$("$@" 2>&1)" && return 0
  fail "$subject" "failed"
  printf '%s\n' "$out" | indent >&2
  exit 1
}

# フック (initialize.sh / postCreate.sh) の出力を dcc の行形式にする。
#   "warn: <主語>: <述語>" → ! 行、"<主語>: <述語>" → ▸ 行、それ以外 → 字下げ
relay() {
  local line rest
  while IFS= read -r line; do
    case "$line" in
      "warn: "*": "*)
        rest="${line#warn: }"
        warn "${rest%%: *}" "${rest#*: }"
        ;;
      *": "*) step "${line%%: *}" "${line#*: }" ;;
      *) printf '  %s\n' "$line" >&2 ;;
    esac
  done
}

# 使い方の誤り (未知のモジュール、引数不足、生成物が無い等)。exit 2。実行時の失敗は fail + exit 1
die() {
  printf '%s! %-*s %s%s\n' "$C_YEL" "$SUBJECT_WIDTH" dcc "$*" "$C_RST" >&2
  exit 2
}

# fingerprint を EE66…0320 の形に縮める (12 桁以下はそのまま)
short_key() {
  [ "${#1}" -gt 12 ] && printf '%s…%s' "${1:0:4}" "${1: -4}" || printf '%s' "$1"
}
