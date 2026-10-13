#!/bin/sh
# Builds and optionally runs the libFuzzer harness.
#
# Requires the swift.org toolchain (https://www.swift.org/install/):
# Xcode's toolchain rejects -sanitize=fuzzer. Point TOOLCHAINS at it, e.g.
#   export TOOLCHAINS=$(plutil -extract CFBundleIdentifier raw \
#       ~/Library/Developer/Toolchains/swift-latest.xctoolchain/Info.plist)
#
# Usage: Fuzz/build.sh            build only
#        Fuzz/build.sh run [args] build, then fuzz with seeds from Tests/Fixtures
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
swift build -c release --package-path "$here" \
    -Xswiftc -sanitize=fuzzer,address \
    -Xswiftc -parse-as-library \
    -Xswiftc -g
binary="$(swift build -c release --package-path "$here" --show-bin-path)/SwiftRARFuzz"
echo "built $binary"

if [ "${1:-}" = "run" ]; then
    shift
    corpus="$here/corpus"
    mkdir -p "$corpus"
    cp "$here"/../Tests/Fixtures/*.rar "$corpus"/ 2>/dev/null || true
    "$binary" "$corpus" -max_len=65536 "$@"
fi
