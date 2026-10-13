#!/bin/sh
# Generates Tests/Fixtures with RARLAB's official `rar` for macOS.
#
# Two pinned versions are downloaded into Tools/fixtures/.build (git-ignored):
#   RAR 6.24 for RAR4 archives (RAR 7 dropped -ma4)
#   RAR 7.23 for RAR5 archives
# The Homebrew cask was disabled on 2026-09-01 (fails Gatekeeper). `rar` is
# trialware and used here only to generate test fixtures.
#
# Output: <rar4|rar5>-<variant>.rar, where the variant is
#   m0   store            -> must convert byte-exact (phase 1)
#   m3   normal LZ        -> .unsupportedCompression until phase 2 / 5
#   s    solid, -m3       -> .unsupportedCompression until phase 3 / 5
#   mct  PPMd for text    -> .unsupportedCompression until phase 4
#   m3-md64  -m3 with a 64 KB dictionary plus a ~1 MB text (RAR4 only), so
#            the 256 KB window UnRAR allocates wraps within one entry (phase 2)
#   m3-big   long distances and low-distance repeats, filters off (phase 2)
#   m3-flt   the same data with rar's filters on -> unsupported until phase 3
# RAR5 has no PPMd, so rar5-mct ends up as normal LZ; it is kept for symmetry.
#
# Content is deterministic so regenerated fixtures differ only in timestamps.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
build="$root/Tools/fixtures/.build"

# fetch <version> <arm64 sha256>: prints the path of that rar binary.
fetch() {
    version="$1"; sha="$2"
    case "$(uname -m)" in arm64) arch=arm ;; *) arch=x64; sha="" ;; esac
    dir="$build/rar-$version"
    if [ ! -x "$dir/rar/rar" ]; then
        mkdir -p "$dir"
        tarball="$build/rarmacos-$arch-$version.tar.gz"
        [ -f "$tarball" ] || curl -fsSL -o "$tarball" "https://www.rarlab.com/rar/rarmacos-$arch-$version.tar.gz"
        if [ -n "$sha" ]; then
            actual="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
            [ "$actual" = "$sha" ] || { echo "checksum mismatch for $tarball: $actual" >&2; rm -f "$tarball"; exit 1; }
        fi
        tar -xzf "$tarball" -C "$dir"
    fi
    echo "$dir/rar/rar"
}

RAR4="$(fetch 624 dabe335834fb5f0fc236f03ba0d12c19fad7243cc56b980db61201ff94d84795)"
RAR5="$(fetch 723 68b393c000758d477fde43c955ff7542f12f76f3f5e87cdda923152fc791bd4d)"

out="$root/Tests/Fixtures"
work="$(mktemp -d "${TMPDIR:-/tmp}/swiftrar-fixtures.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/book/pages" "$out"
# Incompressible "images" and compressible text, plus an empty file, a
# non-ASCII name and a nested directory.
python3 - "$work/book" <<'EOF'
import os, random, sys
root = sys.argv[1]
rng = random.Random(1)
for i in range(1, 4):
    with open(os.path.join(root, "pages", f"page{i:02}.jpg"), "wb") as f:
        f.write(bytes(rng.getrandbits(8) for _ in range(40_000 * i)))
text = "".join(f"Line {n}: the quick brown fox jumps over the lazy dog.\n" for n in range(4_000))
with open(os.path.join(root, "ComicInfo.xml"), "w") as f:
    f.write("<?xml version=\"1.0\"?>\n<ComicInfo>\n" + text + "</ComicInfo>\n")
with open(os.path.join(root, "pages", "één – ünïcode.txt"), "w") as f:
    f.write(text)
open(os.path.join(root, "pages", "empty.txt"), "w").close()
EOF

make() { # rar-binary, name, rar switches...
    tool="$1"; name="$2"; shift 2
    rm -f "$out/$name.rar"
    (cd "$work" && "$tool" a -r -idq "$@" "$out/$name.rar" book)
}

for format in 4 5; do
    if [ "$format" = 4 ]; then tool="$RAR4"; else tool="$RAR5"; fi
    make "$tool" "rar$format-m0"  -ma$format -m0
    make "$tool" "rar$format-m3"  -ma$format -m3
    make "$tool" "rar$format-s"   -ma$format -m3 -s
    make "$tool" "rar$format-mct" -ma$format -m3 -mct+
done

# m3-md64 adds ~1 MB of word salad: compressible, with matches at many
# distances, and larger than the window, so a single entry wraps it.
python3 - "$work/book" <<'EOF'
import os, random, sys
rng = random.Random(2)
words = [f"w{rng.getrandbits(24):x}" for _ in range(3_000)]
with open(os.path.join(sys.argv[1], "pages", "long.txt"), "w") as f:
    f.write(" ".join(rng.choice(words) for _ in range(130_000)))
EOF
make "$RAR4" "rar4-m3-md64" -ma4 -m3 -md64k

# m3-big and m3-flt archive a separate book with one 1.8 MB binary: a random
# block, the same block with a byte flipped every 4 KiB (matches at distances
# beyond 256 KiB), and fixed-size records (repeated low distance bits).
# m3-big turns rar's filters off; m3-flt leaves them on, so rar picks a RarVM
# filter for the records (phase 3).
mkdir -p "$work/big/book/pages"
python3 - "$work/big/book" <<'EOF'
import os, random, struct, sys
rng = random.Random(3)
a = bytearray(rng.getrandbits(8) for _ in range(600_000))
b = bytearray(a)
for i in range(0, len(b), 4096):
    b[i] ^= 0xFF
records = b"".join(struct.pack("<II", n, n * 3) + b"record-padding-24-bytes!" for n in range(20_000))
with open(os.path.join(sys.argv[1], "pages", "big.bin"), "wb") as f:
    f.write(bytes(a) + bytes(b) + records)
EOF
(
    work="$work/big"
    make "$RAR4" "rar4-m3-big" -ma4 -m3 -mcd- -mce- -mci- -mca- -mcc-
    make "$RAR4" "rar4-m3-flt" -ma4 -m3
)
ls -l "$out"
