# shellcheck shell=bash
# Logging (stderr). After one header block, each line says exactly one "subject + what was done / what happened".
#   "▸ <subject>  <predicate>  (note)"   something dcc did to, or found out about, the subject (step)
#   "! <subject>  <predicate>"          warning (yellow). Second line is the remedy (warn)
#   "! <subject>  failed"               failure (red). Followed by the command's full output, indented (fail / run_step)
#   "✓ ready   <seconds>"              done (done_step)
# The subject is "what dcc touched", like containers / image / volume / credentials / claude / ~/.claude / gpg / aws ...;
# never function names or compose subcommand names.
# Output of external tools (compose / hooks) is hidden on success and shown in full only on failure. DCC_VERBOSE=1 always streams it.
# Color only on a TTY (disabled by NO_COLOR).

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_CYN=$'\e[36m' C_RST=$'\e[0m'
else
  C_BOLD="" C_DIM="" C_RED="" C_GRN="" C_YEL="" C_CYN="" C_RST=""
fi
SUBJECT_WIDTH=14

# $1: subject, $2: predicate, $3: note (dimmed, in parentheses)
step() {
  printf '%s▸%s %s%-*s%s %s%s\n' "$C_CYN" "$C_RST" "$C_BOLD" "$SUBJECT_WIDTH" "$1" "$C_RST" "$2" \
    "${3:+  $C_DIM($3)$C_RST}" >&2
}

done_step() {
  printf '%s✓ %-*s %s%s\n' "$C_GRN" "$SUBJECT_WIDTH" "$1" "$2" "$C_RST" >&2
}

# $1: subject, $2: predicate, $3: remedy (optional)
warn() {
  printf '%s! %-*s %s%s\n' "$C_YEL" "$SUBJECT_WIDTH" "$1" "$2" "$C_RST" >&2
  [ -z "${3:-}" ] || printf '%s  %-*s %s%s\n' "$C_YEL" "$SUBJECT_WIDTH" "" "$3" "$C_RST" >&2
}

fail() {
  printf '%s! %-*s %s%s\n' "$C_RED" "$SUBJECT_WIDTH" "$1" "$2" "$C_RST" >&2
}

# Indent. compose's logrus-format output on a non-TTY (time=... level=... msg=...) is reduced to level and msg
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

# run_step: $1: subject, rest: command. Output is discarded on success; on failure it prints "! <subject> failed" then everything, and exits.
#   -s            always stream (indented). Same as DCC_VERBOSE=1
#   -t            pass the terminal through (no indent). For things with their own progress display, like docker build
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

# Converts hook (initialize.sh / postCreate.sh) output into dcc's line format.
#   "warn: <subject>: <predicate>" -> ! line, "<subject>: <predicate>" -> ▸ line, anything else -> indented
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

# Usage error (unknown module, missing argument, missing generated files, etc.). exit 2. Runtime failures are fail + exit 1
die() {
  printf '%s! %-*s %s%s\n' "$C_YEL" "$SUBJECT_WIDTH" dcc "$*" "$C_RST" >&2
  exit 2
}

# Shortens a fingerprint to the form EE66...0320 (12 digits or fewer are left as-is)
short_key() {
  [ "${#1}" -gt 12 ] && printf '%s…%s' "${1:0:4}" "${1: -4}" || printf '%s' "$1"
}
