.PHONY: all build test hooks design-shots app universal dmg run install install-only update helper helper-no-daemon metering-report uninstall icon geodata public-suffixes dmg-background site-check asset-check site-shots site-audit clean

all: test app

build:
	./Scripts/swiftpm.sh build

# Not `swift test`: neither XCTest nor swift-testing ships with Command Line
# Tools, so the suite is a plain executable. See Sources/NetworkMonitorTests.
test:
	@./Scripts/swiftpm.sh run NetworkMonitorTests

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

# The download: build/NetworkMonitor.dmg, universal, with a drag-to-Applications
# window. Upload it to a release under this exact name; see Scripts/make-dmg.sh.
dmg: universal
	@./Scripts/make-dmg.sh

# Stops every running copy, the installed one too, so it waits its turn in the
# Mac lane (#342) like everything else that uses the Mac as a whole.
run: app
	@./Scripts/mac-lane.sh /bin/sh -c 'pkill -f "NetworkMonitor.app/Contents/MacOS"; sleep 1; open build/NetworkMonitor.app'
	@echo "Running — look for ↓/↑ in the menu bar. Right-click the item for the menu."

# Installs to /Applications and enables launch at login. No Developer ID needed.
install:
	@./Scripts/install.sh

# Install without touching login items.
install-only:
	@./Scripts/install.sh --no-login

# Pull, verify, reinstall: updating a copy built from source. Releases update
# themselves with Sparkle (#132). Tests run first so a bad pull is caught before
# it replaces a working install.
update:
	@git pull --ff-only
	@$(MAKE) test
	@./Scripts/install.sh

# The root helper for hotspot metering: macOS and App Store updates, plus the
# apps no setting reaches (Claude, Slack, Canva, Chrome). Asks for a
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

# What hotspot metering reaches on this Mac, what it does not, any update
# downloads waiting to install, and the state of Low Data Mode. Read-only: it
# changes nothing and is safe while the app runs. Runs the freshly built bundle,
# whose identifier is the installed app's, so it reads the same settings.
metering-report: app
	@build/NetworkMonitor.app/Contents/MacOS/NetworkMonitor --metering-report

uninstall:
	@./Scripts/uninstall.sh

# Redraws Resources/AppIcon.icns. The .icns is committed, so this is only
# needed after editing the icon itself.
icon:
	@swift Scripts/make-icon.swift

# Rebuilds Resources/Geo from DB-IP's current month. The files are committed,
# so this is only for refreshing them, in a pull request of its own.
geodata:
	@./Scripts/geodata.sh

# Regenerates Sources/FirewallPolicy/PublicSuffixes.swift from the Public
# Suffix List (#318). Committed, like the geodata; refresh in a PR of its own.
public-suffixes:
	@python3 -I Scripts/public-suffixes.py

# Redraws Resources/DMG/background.tiff, which is committed like the icon.
dmg-background:
	@swift Scripts/make-dmg-background.swift

# The website's pictures of the app (#329). Both run against the installed app,
# quitting and relaunching it, so both wait their turn in the Mac lane (#342).
# They read the NetworkMonitor-site worktree beside the main checkout, found
# through git so it works from any worktree, unless SITE says otherwise.
# `site-check` says which pictures show a window whose interface changed;
# `site-shots` retakes them (or those in NAMES) and updates the page.
SITE ?= $(abspath $(dir $(shell git rev-parse --path-format=absolute --git-common-dir))../NetworkMonitor-site)
# It shares the accessibility rules with the tests.
build/site-shots: Scripts/site-shots.swift Sources/NetworkMonitorCore/AccessibilityAudit.swift
	@mkdir -p build
	swiftc -O -parse-as-library $^ -o $@

site-check: build/site-shots
	@build/site-shots coverage --site $(SITE)
	@./Scripts/mac-lane.sh build/site-shots check --site $(SITE) $(NAMES)

# Every image, GIF and video the site, the README and the docs use is listed
# with the window it shows, or why it shows none (#413). Files only, no app:
# CI runs it on every pull request, here and on the site.
asset-check: build/site-shots
	@build/site-shots coverage --site $(SITE)

site-shots: build/site-shots
	@./Scripts/mac-lane.sh build/site-shots update --site $(SITE) $(NAMES)

# The installed app's windows, with real data, against the tests' accessibility
# rules (#346).
site-audit: build/site-shots
	@./Scripts/mac-lane.sh build/site-shots audit --site $(SITE) $(NAMES)

# Pictures of every window from a made-up dataset, at 2x in light and dark,
# for the design work (#437): no real connections, sites or rules, and no
# screen or installed app, so it needs no Mac lane. OUT is where they go;
# ONLY narrows them to some names. In English for the United States, so they
# look the same whoever takes them, and the map's home isn't theirs.
OUT ?= build/design-shots
DESIGN_APP := build/DesignShots.app/Contents
design-shots:
	@./Scripts/swiftpm.sh build --product DesignShots
	@mkdir -p $(DESIGN_APP)/MacOS $(DESIGN_APP)/Resources
	@bin="$$(./Scripts/swiftpm.sh build --product DesignShots --show-bin-path 2>/dev/null | tail -1)"; \
	  cp "$$bin/DesignShots" $(DESIGN_APP)/MacOS/ && cp -R "$$bin/Sparkle.framework" $(DESIGN_APP)/MacOS/
	@cp -R Resources/Geo Resources/Blocklists Resources/Localization/*.lproj $(DESIGN_APP)/Resources/
	@cp Scripts/design-shots-Info.plist $(DESIGN_APP)/Info.plist
	@$(DESIGN_APP)/MacOS/DesignShots --out "$(OUT)" $(if $(ONLY),--only $(ONLY)) \
	  -AppleLanguages '(en)' -AppleLocale en_US

clean:
	swift package clean
	rm -rf .build build
