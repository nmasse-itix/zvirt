PREFIX ?= /usr/local
.PHONY: all test unit-test syntax-test e2e-test lint clean prerequisites install

all: syntax-test unit-test e2e-test lint install

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
	@LANG=C LC_ALL=C BATS_LIB_PATH=$(PWD)/test/test_helper bats test/unit

e2e-test: prerequisites
	@echo "Running end-to-end tests..."
	@LANG=C LC_ALL=C BATS_LIB_PATH=$(PWD)/test/test_helper bats test/e2e

install:
	@echo "Installing zvirt..."
	@install -d $(PREFIX)/lib/zvirt
	@install -m 755 src/bin/zvirt $(PREFIX)/bin/zvirt
	@install -m 644 src/lib/zvirt/core.sh $(PREFIX)/lib/zvirt/core.sh

uninstall:
	@echo "Uninstalling zvirt..."
	@rm -f $(PREFIX)/bin/zvirt
	@rm -rf $(PREFIX)/lib/zvirt

release:
	@echo "Creating release tarball..."
	@set -Eeuo pipefail; VERSION=$$(git describe --tags --abbrev=0); tar --exclude-vcs --exclude='*.swp' -czf zvirt-$$VERSION.tar.gz --transform "s|^src|zvirt-$$VERSION|" src

install-release:
	@echo "Installing zvirt from release tarball..."
	@set -Eeuo pipefail; VERSION=$$(git describe --tags --abbrev=0); tar -xvzf zvirt-$$VERSION.tar.gz --strip-components=1 -C $(PREFIX)

clean:
lint:
	@echo "Linting..."
	@shellcheck src/bin/zvirt src/lib/zvirt/*.sh
