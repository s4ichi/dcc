#!/usr/bin/env bats
# scripts/update-sha256.sh (`make sha256`): rewrites `ARG <NAME>=<sha256>` from the `# sha256: <url>` comment above it.
# Downloads are file:// URLs into the test's temp directory, so nothing leaves the host.

setup() {
  load helpers/common
  D="$BATS_TEST_TMPDIR"
  mkdir -p "$D/dl/v2"
  printf 'amd64 v2\n' >"$D/dl/v2/tool-amd64.tgz"
  printf 'arm64 v2\n' >"$D/dl/v2/tool-arm64.tgz"
  OLD=0000000000000000000000000000000000000000000000000000000000000000
}

sum() { sha256sum "$1" | cut -d' ' -f1; }

@test "rewrites each annotated sha256 from its URL, expanding the file's ARGs" {
  # dockerfile <amd64 sha> <arm64 sha>: the fixture; OTHER_SHA256 has no comment and must be left alone
  dockerfile() {
    cat <<EOF
FROM scratch
ARG TOOL_VERSION=v2
# sha256: file://$D/dl/\${TOOL_VERSION}/tool-amd64.tgz
ARG TOOL_SHA256_AMD64=$1
# sha256: file://$D/dl/\${TOOL_VERSION}/tool-arm64.tgz
ARG TOOL_SHA256_ARM64=$2
ARG OTHER_SHA256=$OLD
RUN echo "\${TOOL_SHA256_AMD64}"
EOF
  }
  dockerfile "$OLD" "$OLD" >"$D/Dockerfile"
  dockerfile "$(sum "$D/dl/v2/tool-amd64.tgz")" "$(sum "$D/dl/v2/tool-arm64.tgz")" >"$D/expected"
  run "$REPO/scripts/update-sha256.sh" "$D/Dockerfile"
  [ "$status" -eq 0 ]
  cmp "$D/expected" "$D/Dockerfile"
}

@test "a failed download leaves the file unchanged" {
  cat >"$D/Dockerfile" <<EOF
ARG TOOL_VERSION=v3
# sha256: file://$D/dl/\${TOOL_VERSION}/tool-amd64.tgz
ARG TOOL_SHA256_AMD64=$OLD
EOF
  cp "$D/Dockerfile" "$D/before"
  run "$REPO/scripts/update-sha256.sh" "$D/Dockerfile"
  [ "$status" -ne 0 ]
  cmp "$D/before" "$D/Dockerfile"
}

@test "an unknown variable in the URL is an error" {
  cat >"$D/Dockerfile" <<EOF
# sha256: file://$D/dl/\${NOPE}/tool-amd64.tgz
ARG TOOL_SHA256_AMD64=$OLD
EOF
  run "$REPO/scripts/update-sha256.sh" "$D/Dockerfile"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unresolved variable'* ]]
}

@test "the comment must be directly above a sha256 ARG" {
  cat >"$D/Dockerfile" <<EOF
# sha256: file://$D/dl/v2/tool-amd64.tgz
ARG TOOL_VERSION=v2
EOF
  run "$REPO/scripts/update-sha256.sh" "$D/Dockerfile"
  [ "$status" -ne 0 ]
  [[ "$output" == *'is not directly above'* ]]
}
