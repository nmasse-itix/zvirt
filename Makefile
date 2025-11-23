.PHONY: all test unit-test syntax-test e2e-test lint clean prerequisites

all: syntax-test unit-test lint

syntax-test:
	@echo "Running syntax tests..."
	@/bin/bash -nv src/zvirt
	@/bin/bash -nv src/lib/core.sh

prerequisites:
	@echo "Installing prerequisites..."
	@/bin/bash -Eeuo pipefail -c 'if ! bats --version &>/dev/null; then dnf install -y bats; fi'
	@/bin/bash -Eeuo pipefail -c 'if ! yq --version &>/dev/null; then dnf install -y yq; fi'

unit-test: prerequisites
	@echo "Running unit tests..."
	@LANG=LC_ALL=C BATS_LIB_PATH=$(PWD)/test/test_helper bats test/unit

e2e-test: prerequisites
	@echo "Running end-to-end tests..."
	@LANG=LC_ALL=C BATS_LIB_PATH=$(PWD)/test/test_helper bats test/e2e

clean:
lint:
	@echo "Linting..."
	@shellcheck src/zvirt src/lib/*.sh
