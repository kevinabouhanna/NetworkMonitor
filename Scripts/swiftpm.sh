#!/bin/bash
#
# Runs a SwiftPM subcommand on the build system this project can rely on.
#
# Swift 6.4 made the new `swiftbuild` build system the default, and with Command
# Line Tools 27 it fails before compiling anything: "Could not initialize build
# system ... Unknown error parsing property list". The native build system still
# works under both Command Line Tools and Xcode, so every build in the Makefile
# and the scripts goes through here and asks for it by name. Toolchains that
# predate the option already build natively and are left alone.
#
# SwiftPM prints a deprecation warning for `--build-system native` on every run.
# That is expected. Drop this wrapper once `swiftbuild` works with Command Line
# Tools.
#
# Usage:
#   ./Scripts/swiftpm.sh build -c release
#   ./Scripts/swiftpm.sh run NetworkMonitorTests

set -euo pipefail

if [ $# -eq 0 ]; then
  echo "usage: $0 <build|run> [options]" >&2
  exit 2
fi

subcommand="$1"
shift

if swift build --help 2>/dev/null | grep -q -- '--build-system'; then
  exec swift "$subcommand" --build-system native "$@"
fi
exec swift "$subcommand" "$@"
