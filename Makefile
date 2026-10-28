JSONNET ?= jsonnet
SRC := template.jsonnet
OUT := docker-compose.yml docker-compose.workspace.yml docker-compose.base-image.yml capabilities/*/compose.yml
# lib/*.sh は dcc の source 指示 (# shellcheck source=) 経由で -x が辿るので、個別には並べない
SCRIPTS := dcc lifecycle_hooks/*.sh capabilities/gpg/*.sh capabilities/gh/*.sh

.PHONY: all generate fmt check lint test clean

all: generate

# -S -m: トップレベルの各フィールド (ファイル名 → 文字列) をそれぞれファイルに書き出す。
# jsonnet はサブディレクトリを作らないので、出力ファイル名一覧から先に mkdir する。
generate:
	$(JSONNET) -S -e "std.join('\n', std.objectFields(import '$(SRC)'))" | xargs -n1 dirname | sort -u | xargs mkdir -p
	$(JSONNET) -S -m . $(SRC)

fmt:
	jsonnetfmt -i $(SRC)

# Jsonnet の評価 + シェルスクリプトの静的検査 + テスト
check: lint test
	$(JSONNET) $(SRC) >/dev/null

lint:
	shellcheck -x -s bash $(SCRIPTS)

test:
	bats test

clean:
	rm -f $(OUT)
