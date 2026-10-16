#!/bin/sh
# Generates Fuzz/seeds: small archives that seed the fuzzer's corpus.
#
# The fuzzer cuts every input at -max_len=65536, and all filter fixtures in
# Tests/Fixtures are larger, so it only ever saw them truncated: RAR5Filters
# was never reached and the RarVM filters only recognised. These seeds use the
# same data shapes as make-fixtures.sh, cut down so each archive stays below
# 64 KB with its filter intact:
#   rar<4|5>-flt-<filter>  one filter forced per archive
#   rar4-mct-heap          PPMd with 1 MB of model memory over high-entropy
#                          syllables, so the model fills up and PPMdHeap
#                          has to glue free blocks
# rar never emits the RAR5 ARM or the RAR4 Itanium filter (see
# make-fixtures.sh), so those have no seed.
#
# Uses the same pinned rar binaries as make-fixtures.sh.
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

out="$root/Fuzz/seeds"
work="$(mktemp -d "${TMPDIR:-/tmp}/swiftrar-seeds.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
# `rar a` adds to an existing archive, so start clean.
rm -f "$out"/*.rar

python3 - "$work" <<'PY'
import math, os, random, struct, sys
root = sys.argv[1]
rng = random.Random(4)
def write(name, data):
    os.makedirs(os.path.join(root, name, "book"), exist_ok=True)
    with open(os.path.join(root, name, "book", name + ".bin"), "wb") as f:
        f.write(bytes(data))
# x86-like code with calls (E8) and jumps (E9), 90 KB.
ops = [b"\x55", b"\x48\x89\xe5", b"\x8b\x45\xfc", b"\x83\xc0\x01", b"\x5d\xc3", b"\x90"]
code = bytearray()
while len(code) < 90_000:
    r = rng.random()
    if r < 0.15:
        code += b"\xe8" + struct.pack("<i", rng.randrange(-6_000, 6_000))
    elif r < 0.22:
        code += b"\xe9" + struct.pack("<i", rng.randrange(-6_000, 6_000))
    else:
        code += rng.choice(ops)
write("e8", code)
# 16-bit stereo sine waves with a little noise.
audio = bytearray()
for n in range(12_000):
    for f in (0.013, 0.021):
        audio += struct.pack("<h", int(12_000 * math.sin(n * f)) + rng.randrange(-40, 40))
write("audio", audio)
write("delta", audio[::-1])
# 24-bit image, 200 px wide.
rgb = bytearray()
for y in range(60):
    for x in range(200):
        rgb += bytes(((x + y + rng.randrange(4)) & 0xFF, (2 * y + rng.randrange(4)) & 0xFF, (x * y // 64) & 0xFF))
write("rgb", rgb)
# PPMd: random printable syllables, no long repeats, so many distinct
# high-order contexts per byte.
r = random.Random(6)
syll = [bytes(r.getrandbits(8) % 94 + 33 for _ in range(r.randrange(2, 5))) for _ in range(4000)]
text = bytearray()
while len(text) < 80_000:
    text += r.choice(syll)
os.makedirs(os.path.join(root, "ppm", "book"))
with open(os.path.join(root, "ppm", "book", "ppm.txt"), "wb") as f:
    f.write(bytes(text[:80_000]))
PY

(cd "$work/e8" && "$RAR4" a -r -idq -ma4 -m3 -mce+ "$out/rar4-flt-e8.rar" book)
(cd "$work/audio" && "$RAR4" a -r -idq -ma4 -m3 -mc4a+ "$out/rar4-flt-audio.rar" book)
(cd "$work/delta" && "$RAR4" a -r -idq -ma4 -m3 -mc4d+ "$out/rar4-flt-delta.rar" book)
(cd "$work/rgb" && "$RAR4" a -r -idq -ma4 -m3 -mcc+ "$out/rar4-flt-rgb.rar" book)
(cd "$work/ppm" && "$RAR4" a -r -idq -ma4 -m3 -mc63:1t+ "$out/rar4-mct-heap.rar" book)
(cd "$work/e8" && "$RAR5" a -r -idq -ma5 -m3 -mce+ "$out/rar5-flt-e8.rar" book)
(cd "$work/audio" && "$RAR5" a -r -idq -ma5 -m3 -mca+ "$out/rar5-flt-audio.rar" book)
(cd "$work/delta" && "$RAR5" a -r -idq -ma5 -m3 -mc4d+ "$out/rar5-flt-delta.rar" book)
(cd "$work/rgb" && "$RAR5" a -r -idq -ma5 -m3 -mcc+ "$out/rar5-flt-rgb.rar" book)

# Every seed must fit the fuzzer's -max_len, or it is truncated again.
for f in "$out"/*.rar; do
    size="$(stat -f %z "$f")"
    [ "$size" -le 65536 ] || { echo "$f is $size bytes, over 64 KB" >&2; exit 1; }
done
ls -l "$out"
