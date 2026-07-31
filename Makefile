.PHONY: all build test app universal run install install-only uninstall clean

all: test app

build:
	swift build

# Not `swift test`: neither XCTest nor swift-testing ships with Command Line
# Tools, so the suite is a plain executable. See Sources/NetworkMonitorTests.
test:
	@swift run NetworkMonitorTests

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

uninstall:
	@./Scripts/uninstall.sh

clean:
	swift package clean
	rm -rf .build build
