.PHONY: all test unit-test syntax-test integration-test lint clean

all: syntax-test unit-test lint

syntax-test:
	@echo "Running syntax tests..."
	@/bin/bash -nv src/zvirt
	@/bin/bash -nv src/lib/core.sh

unit-test:
	@echo "Running unit tests..."
	@LANG=LC_ALL=C BATS_LIB_PATH=$(PWD)/test/test_helper bats test/unit

clean:
lint:
	@echo "Linting..."
	@shellcheck src/zvirt src/lib/*.sh
