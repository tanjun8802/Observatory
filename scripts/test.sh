#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
developer="$(xcode-select -p)"
frameworks="$developer/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
    # Standalone Command Line Tools keep Swift Testing outside SwiftPM's default search paths.
    swift test --disable-xctest -Xswiftc "-F$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$developer/Library/Developer/usr/lib" "$@"
else
    swift test --disable-xctest "$@"
fi
