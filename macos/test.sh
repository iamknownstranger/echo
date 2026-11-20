#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Some Command Line Tools releases ship TestingMacros in a nested directory
# which SwiftPM omits when rebuilding the test plan after a release build.
tool_bin="$(dirname "$(xcrun --find swiftc)")"
plugin_dir="$tool_bin/../lib/swift/host/plugins/testing"
args=(--disable-xctest --enable-swift-testing)
if [[ -f "$plugin_dir/libTestingMacros.dylib" ]]; then
    args+=(-Xswiftc -load-plugin-library -Xswiftc "$plugin_dir/libTestingMacros.dylib")
fi
exec xcrun swift test "${args[@]}" "$@"
