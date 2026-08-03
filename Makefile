.PHONY: all build test hooks app universal run install install-only update helper helper-no-daemon uninstall icon clean

all: test app

build:
	swift build

# Not `swift test`: neither XCTest nor swift-testing ships with Command Line
# Tools, so the suite is a plain executable. See Sources/NetworkMonitorTests.
test:
	@swift run NetworkMonitorTests

# Points git at Scripts/hooks, so pre-push runs the suite before anything
# reaches the remote. Run once per clone. Hooks are version-controlled this way
# rather than living unshared in .git/hooks.
hooks:
	@chmod +x Scripts/hooks/*
	@git config core.hooksPath Scripts/hooks
	@echo "Installed: pre-push now runs 'make test'."

app:
	@./Scripts/bundle.sh

universal:
	@./Scripts/bundle.sh --universal

run: app
	@pkill -f "NetworkMonitor.app/Contents/MacOS" 2>/dev/null || true
	@open build/NetworkMonitor.app
	@echo "Running — look for ↓/↑ in the menu bar. Right-click the item for the menu."

# Installs to /Applications and enables launch at login. No Developer ID needed.
install:
	@./Scripts/install.sh

# Install without touching login items.
install-only:
	@./Scripts/install.sh --no-login

# Pull, verify, reinstall. This is the update mechanism until the app can
# update itself. Tests run first so a bad pull is caught before it replaces a
# working install.
update:
	@git pull --ff-only
	@$(MAKE) test
	@./Scripts/install.sh

# The root helper for hotspot metering: macOS and App Store updates, plus the
# apps that only honour managed policy (Claude, Slack, Canva). Asks for a
# password; everything else in this Makefile does not.
#
# `helper` installs the hourly self-heal daemon too, which undoes everything if
# the app is ever dragged to the Trash — at the cost of a second row in Login
# Items. `helper-no-daemon` keeps NetworkMonitor the only row there and makes
# `make uninstall` the sole cleanup path.
helper:
	@./Scripts/install-helper.sh

helper-no-daemon:
	@./Scripts/install-helper.sh --no-daemon

uninstall:
	@./Scripts/uninstall.sh

# Redraws Resources/AppIcon.icns. The .icns is committed, so this is only
# needed after editing the icon itself.
icon:
	@swift Scripts/make-icon.swift

clean:
	swift package clean
	rm -rf .build build
