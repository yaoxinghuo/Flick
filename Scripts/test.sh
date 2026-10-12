#!/bin/bash
# Runs `swift test` locally. With Command Line Tools only (no Xcode), the bundled
# Testing.framework is not on the default search path, so we add it explicitly.
# On machines with Xcode (and in CI) plain `swift test` works, and this script
# detects that and stays out of the way.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

if [ -d "/Applications/Xcode.app" ] || ! xcode-select -p 2>/dev/null | grep -q "CommandLineTools"; then
    exec swift test "$@"
elif [ ! -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
    echo "error: Testing.framework not found under $CLT_FRAMEWORKS" >&2
    echo "Install Xcode or a newer Command Line Tools to run tests." >&2
    exit 1
else
    # -F: find Testing.framework
    # -disable-cross-import-overlays: Testing's Foundation overlay would pull in
    #   _Testing_Foundation, which ships without a swiftmodule in CLT.
    # -rpath: let the test bundle find the framework at runtime.
    exec swift test "$@" \
        -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -F -Xlinker "$CLT_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
fi
