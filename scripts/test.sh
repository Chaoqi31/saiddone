#!/usr/bin/env bash
# Run the test suite. With only the Command Line Tools installed (no Xcode), Swift Testing lives in
# a framework directory SwiftPM does not search by default, so pass it explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=()
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  CLT="$(xcode-select -p)/Library/Developer"
  FLAGS=(
    -Xswiftc -F -Xswiftc "$CLT/Frameworks"
    -Xlinker -F -Xlinker "$CLT/Frameworks"
    -Xlinker -rpath -Xlinker "$CLT/Frameworks"
    -Xlinker -rpath -Xlinker "$CLT/usr/lib"
  )
fi

swift test "${FLAGS[@]}" "$@"
