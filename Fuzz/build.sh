#!/bin/sh
# Builds and optionally runs the libFuzzer harness.
#
# Requires the swift.org toolchain (https://www.swift.org/install/):
# Xcode's toolchain rejects -sanitize=fuzzer. If TOOLCHAINS is unset, the
# script selects swift-latest.xctoolchain from ~/Library/Developer/Toolchains
# or /Library/Developer/Toolchains.
#
# Usage: Fuzz/build.sh            build only
#        Fuzz/build.sh run [args] build, then fuzz with seeds from Tests/Fixtures
set -eu

here="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${TOOLCHAINS:-}" ]; then
    for dir in "$HOME/Library/Developer/Toolchains" /Library/Developer/Toolchains; do
        if [ -f "$dir/swift-latest.xctoolchain/Info.plist" ]; then
            TOOLCHAINS="$(plutil -extract CFBundleIdentifier raw "$dir/swift-latest.xctoolchain/Info.plist")"
            export TOOLCHAINS
            break
        fi
    done
    [ -n "${TOOLCHAINS:-}" ] || { echo "swift.org toolchain not found; see README" >&2; exit 1; }
fi
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
