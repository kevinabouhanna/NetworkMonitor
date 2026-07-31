.PHONY: all build test app universal run install clean

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

install: app
	@pkill -f "NetworkMonitor.app/Contents/MacOS" 2>/dev/null || true
	@rm -rf /Applications/NetworkMonitor.app
	@cp -R build/NetworkMonitor.app /Applications/
	@open /Applications/NetworkMonitor.app
	@echo "Installed to /Applications and launched."

clean:
	swift package clean
	rm -rf .build build
