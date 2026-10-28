#!/usr/bin/env bash
# gh モジュールの本体側 client。token は gh-token sidecar から毎回受け取り、本体には保存しない。docs/github.md
#   /usr/local/bin/gh として呼ばれたとき: GH_TOKEN に入れて /usr/bin/gh を実行する
#     (gh は GH_TOKEN を refresh しないので、実行のたびに取り直す)
#   `<this> git-credential get` (git の credential helper): $DCC_GH_HOST の https に token を返す
set -euo pipefail

real_gh=/usr/bin/gh

fetch_token() {
  local uri="${DCC_GH_TOKEN_URI:?gh-token-client: DCC_GH_TOKEN_URI is not set (gh module not enabled)}"
  local resp http
  resp="$(mktemp)"
  if ! http="$(curl -sS -o "$resp" -w '%{http_code}' --max-time 30 "$uri")"; then
    rm -f "$resp"
    echo "gh-token-client: cannot reach the gh-token sidecar" >&2
    return 1
  fi
  if [ "$http" != 200 ]; then
    echo "gh-token-client: $(cat "$resp")" >&2
    rm -f "$resp"
    return 1
  fi
  cat "$resp"
  rm -f "$resp"
}

# git は key=value の行を渡し、空行で終わる。host が一致するときだけ答え、それ以外は何も返さない
git_credential() {
  local line protocol="" host=""
  [ "${1:-}" = get ] || exit 0 # store / erase: 保存するものは無い (token は sidecar が管理する)
  while IFS= read -r line && [ -n "$line" ]; do
    case "$line" in
      protocol=*) protocol="${line#protocol=}" ;;
      host=*) host="${line#host=}" ;;
    esac
  done
  [ "$protocol" = https ] && [ "$host" = "${DCC_GH_HOST:-github.com}" ] || exit 0
  local token
  token="$(fetch_token)" || exit 0 # 次の helper (無ければ git のプロンプト) に任せる
  printf 'username=x-access-token\npassword=%s\n' "$token"
}

if [ "${1:-}" = git-credential ]; then
  shift
  git_credential "$@"
  exit 0
fi

# 認証状態は sidecar 側の volume にあり、本体の gh からは変えられない
case "${1:-} ${2:-}" in
  "auth login" | "auth logout" | "auth refresh" | "auth switch" | "auth setup-git")
    echo "gh-token-client: gh credentials are managed by the gh-token sidecar; run 'dcc gh-login' on the host" >&2
    exit 1
    ;;
esac

if token="$(fetch_token)"; then
  GH_TOKEN="$token" exec "$real_gh" "$@"
fi
exec "$real_gh" "$@"
