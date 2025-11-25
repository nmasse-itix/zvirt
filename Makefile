PREFIX ?= /usr/local
.PHONY: all test unit-test syntax-test e2e-test lint clean prerequisites install uninstall release tarball install-tarball srpm rpm copr-build copr-whoami
VERSION := $(shell git describe --tags --abbrev=0)

all: syntax-test lint unit-test e2e-test release

syntax-test:
	@echo "Running syntax tests..."
	@/bin/bash -nv src/bin/zvirt
	@/bin/bash -nv src/lib/zvirt/core.sh

prerequisites:
	@echo "Installing prerequisites..."
	@/bin/bash -Eeuo pipefail -c 'if ! bats --version &>/dev/null; then dnf install -y bats; fi'
	@/bin/bash -Eeuo pipefail -c 'if ! yq --version &>/dev/null; then dnf install -y yq; fi'
	@/bin/bash -Eeuo pipefail -c 'if ! shellcheck --version &>/dev/null; then dnf install -y shellcheck; fi'
	@/bin/bash -Eeuo pipefail -c 'if ! gh --version &>/dev/null; then dnf install -y gh; fi'
	@/bin/bash -Eeuo pipefail -c 'if ! rpmbuild --version &>/dev/null; then dnf install -y rpm-build; fi'
	@/bin/bash -Eeuo pipefail -c 'if ! copr-cli --version &>/dev/null; then dnf install -y copr-cli; fi'

unit-test: prerequisites
	@echo "Running unit tests..."
	@LANG=C LC_ALL=C BATS_LIB_PATH=$(PWD)/test/test_helper bats test/unit

e2e-test: prerequisites
	@echo "Running end-to-end tests..."
	@LANG=C LC_ALL=C BATS_LIB_PATH=$(PWD)/test/test_helper bats test/e2e

install:
	@echo "Installing zvirt..."
	@install -d $(PREFIX)/lib/zvirt $(PREFIX)/bin
	@install -m 755 src/bin/zvirt $(PREFIX)/bin/zvirt
	@install -m 644 src/lib/zvirt/core.sh $(PREFIX)/lib/zvirt/core.sh

uninstall:
	@echo "Uninstalling zvirt..."
	@rm -f $(PREFIX)/bin/zvirt
	@rm -rf $(PREFIX)/lib/zvirt

tarball:
	@echo "Creating release tarball..."
	@mkdir -p build
	@tar --exclude-vcs --exclude='*.swp' -czf build/zvirt-$(VERSION).tar.gz --transform "s|^src|zvirt-$(VERSION)|" src

install-tarball: tarball
	@echo "Installing zvirt from release tarball..."
	@tar -xvzf build/zvirt-$(VERSION).tar.gz --strip-components=1 -C $(PREFIX)

srpm: prerequisites tarball
	@echo "Creating SRPM..."
	@git ls-files | sed 's|^|./|' > build/filelist.txt
	@mkdir -p build/zvirt-$(VERSION)/SOURCES
	@tar --verbatim-files-from --files-from=build/filelist.txt -cvzf build/zvirt-$(VERSION)/SOURCES/zvirt-$(VERSION).tar.gz --transform "s|^./|zvirt-$(VERSION)/|"
	@rpmbuild --define "_topdir $$(pwd)/build/zvirt-$(VERSION)" --define "version $(VERSION)" -ba packaging/zvirt.spec

rpm: prerequisites
	@echo "Creating RPM..."
	@rpmbuild --define "_topdir $$(pwd)/build/zvirt-$(VERSION)" --define "version $(VERSION)" -bb packaging/zvirt.spec

# https://copr.fedorainfracloud.org/api/
copr-whoami: prerequisites
	@echo "Checking COPR identity..."
	@copr-cli whoami

copr-build: copr-whoami srpm
	@echo "Building RPM in COPR..."
	@copr-cli build --nowait nmasse-itix/zvirt build/zvirt-$(VERSION)/SRPMS/zvirt-$(VERSION)-*.src.rpm

release: prerequisites tarball srpm rpm copr-build
	@echo "Creating GitHub release..."
	@gh release create $(VERSION) build/zvirt-$(VERSION).tar.gz build/zvirt-$(VERSION)/SRPMS/zvirt-$(VERSION)-*.rpm --draft --title "v$(VERSION)" --notes "Release v$(VERSION) of zvirt. RPMs are in COPR [nmasse-itix/zvirt](https://copr.fedorainfracloud.org/coprs/nmasse-itix/zvirt/)."

clean:
	@echo "Cleaning up..."
	@rm -rf build/zvirt-*

lint: prerequisites
	@echo "Linting..."
	@cd src && shellcheck --severity=error bin/zvirt lib/zvirt/*.sh
