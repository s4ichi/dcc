JSONNET ?= jsonnet
SRC := template.jsonnet
OUT := docker-compose.yml docker-compose.workspace.yml docker-compose.base-image.yml capabilities/*/compose.yml
# lib/*.sh is followed by -x via the source directives in dcc (# shellcheck source=), so it is not listed separately
SCRIPTS := dcc lifecycle_hooks/*.sh capabilities/gpg/*.sh capabilities/gh/*.sh

.PHONY: all generate fmt check lint test clean

all: generate

# -S -m: write each top-level field (file name -> string) to its own file.
# jsonnet does not create subdirectories, so mkdir them first from the list of output file names.
generate:
	$(JSONNET) -S -e "std.join('\n', std.objectFields(import '$(SRC)'))" | xargs -n1 dirname | sort -u | xargs mkdir -p
	$(JSONNET) -S -m . $(SRC)

fmt:
	jsonnetfmt -i $(SRC)

# Evaluate Jsonnet + static checks of the shell scripts + tests
check: lint test
	$(JSONNET) $(SRC) >/dev/null

lint:
	shellcheck -x -s bash $(SCRIPTS)

test:
	bats test

clean:
	rm -f $(OUT)
