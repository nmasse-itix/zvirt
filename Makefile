PREFIX ?= /usr/local
.PHONY: all test unit-test syntax-test e2e-test lint clean prerequisites install uninstall release tarball install-tarball

all: syntax-test lint unit-test e2e-test release

syntax-test:
	@echo "Running syntax tests..."
	@/bin/bash -nv src/zvirt
	@/bin/bash -nv src/lib/core.sh

prerequisites:
	@echo "Installing prerequisites..."
	@/bin/bash -Eeuo pipefail -c 'if ! bats --version &>/dev/null; then dnf install -y bats; fi'
	@/bin/bash -Eeuo pipefail -c 'if ! yq --version &>/dev/null; then dnf install -y yq; fi'
	@/bin/bash -Eeuo pipefail -c 'if ! shellcheck --version &>/dev/null; then dnf install -y shellcheck; fi'
	@/bin/bash -Eeuo pipefail -c 'if ! gh --version &>/dev/null; then dnf install -y gh; fi'

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

tarball:
	@echo "Creating release tarball..."
	@set -Eeuo pipefail; VERSION=$$(git describe --tags --abbrev=0); tar --exclude-vcs --exclude='*.swp' -czf zvirt-$$VERSION.tar.gz --transform "s|^src|zvirt-$$VERSION|" src

install-tarball: tarball
	@echo "Installing zvirt from release tarball..."
	@set -Eeuo pipefail; VERSION=$$(git describe --tags --abbrev=0); tar -xvzf zvirt-$$VERSION.tar.gz --strip-components=1 -C $(PREFIX)



release: prerequisites tarball
	@echo "Creating GitHub release..."
	@set -Eeuo pipefail; VERSION=$$(git describe --tags --abbrev=0); gh release create $$VERSION zvirt-$$VERSION.tar.gz --draft --title "zvirt $$VERSION" --notes "Release $$VERSION of zvirt."

clean:
lint: prerequisites
	@echo "Linting..."
	@cd src && shellcheck --severity=error bin/zvirt lib/zvirt/*.sh
