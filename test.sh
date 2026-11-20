#!/bin/bash
# Compile Sources/ (without the app's entry point) with Tests/main.swift and run the tests.
set -euo pipefail
cd "$(dirname "$0")"
BIN="$(mktemp -d)/nowbar-tests"
trap 'rm -rf "$(dirname "$BIN")"' EXIT
swiftc -O $(ls Sources/*.swift | grep -v '/main.swift$') Tests/main.swift -o "$BIN" \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement
"$BIN"
