#!/bin/sh
# Generates Tests/Fixtures with the real `rar` (brew install rar).
#
# Output: <rar4|rar5>-<variant>.rar, where the variant is
#   m0   store            -> must convert byte-exact (phase 1)
#   m3   normal LZ        -> .unsupportedCompression until phase 2 / 5
#   s    solid, -m3       -> .unsupportedCompression until phase 3 / 5
#   mct  PPMd for text    -> .unsupportedCompression until phase 4
# RAR5 has no PPMd, so rar5-mct ends up as normal LZ; it is kept for symmetry.
#
# Content is deterministic so regenerated fixtures differ only in timestamps.
set -eu

command -v rar >/dev/null 2>&1 || { echo "rar not found: brew install rar" >&2; exit 1; }

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/Tests/Fixtures"
work="$(mktemp -d)"
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

make() { # name, rar switches...
    name="$1"; shift
    rm -f "$out/$name.rar"
    (cd "$work" && rar a -r -idq "$@" "$out/$name.rar" book)
}

for format in 4 5; do
    make "rar$format-m0"  -ma$format -m0
    make "rar$format-m3"  -ma$format -m3
    make "rar$format-s"   -ma$format -m3 -s
    make "rar$format-mct" -ma$format -m3 -mct+
done
ls -l "$out"
