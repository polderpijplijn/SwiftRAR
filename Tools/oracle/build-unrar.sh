#!/bin/sh
# Provides the official unrar binary as a test oracle and prints its path.
#
# Order: $SWIFTRAR_UNRAR, an unrar already on PATH, then a local build from
# RARLAB's official UnRAR source in Tools/oracle/.build (git-ignored), or in
# $SWIFTRAR_ORACLE_DIR when set (CI keeps it outside the checkout).
#
# The UnRAR source is downloaded and built here only. It is never committed
# and never linked into the SwiftRAR package.
set -eu

UNRAR_VERSION="7.3.1"
UNRAR_SHA256="634900842a3737d9cc15bbcc71d4c74cc713437e0bca296a573424fe5f2660ab"

here="$(cd "$(dirname "$0")" && pwd)"
build="${SWIFTRAR_ORACLE_DIR:-$here/.build}"
binary="$build/unrar/unrar"

if [ "${SWIFTRAR_UNRAR:-}" != "" ] && [ -x "$SWIFTRAR_UNRAR" ]; then
    echo "$SWIFTRAR_UNRAR"; exit 0
fi
if [ "${1:-}" != "--build" ] && command -v unrar >/dev/null 2>&1; then
    command -v unrar; exit 0
fi
if [ -x "$binary" ]; then
    echo "$binary"; exit 0
fi

mkdir -p "$build"
tarball="$build/unrarsrc-$UNRAR_VERSION.tar.gz"
if [ ! -f "$tarball" ]; then
    curl -fsSL -o "$tarball" "https://www.rarlab.com/rar/unrarsrc-$UNRAR_VERSION.tar.gz" >&2
fi
actual="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
if [ "$actual" != "$UNRAR_SHA256" ]; then
    echo "checksum mismatch for $tarball: $actual" >&2
    rm -f "$tarball"
    exit 1
fi

rm -rf "$build/unrar"
tar -xzf "$tarball" -C "$build"
make -C "$build/unrar" -f makefile unrar -j4 >&2
echo "$binary"
