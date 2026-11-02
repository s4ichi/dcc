JSONNET ?= jsonnet
SRC := template.jsonnet
OUT := docker-compose.yml docker-compose.workspace.yml docker-compose.base-image.yml capabilities/*/compose.yml
# lib/*.sh is followed by -x via the source directives in dcc (# shellcheck source=), so it is not listed separately
SCRIPTS := dcc lifecycle_hooks/*.sh capabilities/gpg/*.sh capabilities/gh/*.sh test/helpers/*.bash test/e2e/*.bash

.PHONY: all generate fmt check lint test test-sh test-py e2e clean

all: generate

# -S -m: write each top-level field (file name -> string) to its own file.
# jsonnet does not create subdirectories, so mkdir them first from the list of output file names.
generate:
	$(JSONNET) -S -e "std.join('\n', std.objectFields(import '$(SRC)'))" | xargs -n1 dirname | sort -u | xargs mkdir -p
	$(JSONNET) -S -m . $(SRC)

fmt:
	jsonnetfmt -i $(SRC)

# Evaluate Jsonnet + static checks of the shell scripts + component tests (no containers are started)
check: lint test
	$(JSONNET) $(SRC) >/dev/null

lint:
	shellcheck -x -s bash $(SCRIPTS)

# Component tests. What each suite covers: docs/testing.md
test: test-sh test-py

test-sh:
	bats --print-output-on-failure test

test-py:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test/python

# End-to-end tests: build the images and run dcc against a fake host on the local Docker daemon (takes minutes).
# DCC_E2E_* settings are at the top of test/e2e/helpers.bash
e2e:
	bats --print-output-on-failure test/e2e

clean:
	rm -f $(OUT)
