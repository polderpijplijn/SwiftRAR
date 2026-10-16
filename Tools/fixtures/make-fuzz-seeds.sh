#!/bin/sh
# Generates Fuzz/seeds: small archives that seed the fuzzer's corpus.
#
# The fuzzer cuts every input at -max_len=65536, and all filter fixtures in
# Tests/Fixtures are larger, so it only ever saw them truncated: RAR5Filters
# was never reached and the RarVM filters only recognised. These seeds use the
# same data shapes as make-fixtures.sh, cut down so each archive stays below
# 64 KB with its filter intact:
#   seed-rar<4|5>-flt-<filter>  one filter forced per archive
#   seed-rar4-mct-heap     PPMd with 1 MB of model memory over high-entropy
#                          syllables, so the model fills up and PPMdHeap
#                          has to glue free blocks
#   seed-rar4-mct-restart  PPMd, 1 MB, order 5 over blocks that each repeat
#                          four times: the model runs out of memory and
#                          restarts, and glued blocks above 128 units split
#   seed-rar<4|5>-wrap     700 KB of near-repeats with the smallest
#                          dictionary, so copies and writes wrap around
#                          the 256 KB window
#   seed-rar5-wrap-flt     E8 with a patched 264 KB dictionary, so filter
#                          blocks span the window end (see below)
#   seed-rar4-flt-itanium  built by hand, as rar never emits Itanium (see
#                          below); rar 6.24 checks it
#   seed-rar4-mct-solid    solid, LZ then PPMd in one entry; the next
#                          entry starts with a PPMd header (issue #8)
#   seed-rar5-solid-grow   solid RAR5; entry 3 patched to a larger
#                          dictionary, which the decoder refuses
#   seed-rar5-flt-overflow built by hand: 8200 waiting filters, so the
#                          decoder drops them (see below)
#   seed-rar5-enc-header   encrypted headers (-hp), refused at once
#   seed-rar5-enc-file     encrypted data (-p), an encryption record
#   seed-rar5-time         mtime in the file header, and a time record
#                          patched to a Windows FILETIME (see below)
# Not made here: seed-rar4-mct-resize (issue #9), 128 PPMd resets at
# alternating memory sizes. PPMdTests.testAlternatingMemoryBlocks builds
# it with RAR4Builder and compares the committed copy byte for byte, so
# this script leaves it in place.
# rar never emits the RAR5 ARM filter either (see make-fixtures.sh), so it
# has no seed. The seed- prefix keeps them from overwriting the fixtures of
# the same name in the corpus.
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
# `rar a` adds to an existing archive, so start clean. Keep the seeds this
# script does not make (see the list above).
find "$out" -name '*.rar' ! -name seed-rar4-mct-resize.rar -delete

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
# PPMd restart: random blocks of 48 symbols, each written four times. A
# repeat costs almost no bits but still adds contexts, so 1 MB of model
# memory fills up within 64 KB of archive. The wide alphabet gives state
# arrays big enough that a glue run frees more than 128 units at once.
# (seed-rar4-mct-heap and even the full rar4-mct-mem fixture never split.)
r = random.Random(1)
text = bytearray()
while len(text) < 320_000:
    text += bytes(r.getrandbits(8) % 48 + 48 for _ in range(r.randrange(200, 2000))) * 4
os.makedirs(os.path.join(root, "restart", "book"))
with open(os.path.join(root, "restart", "book", "restart.txt"), "wb") as f:
    f.write(bytes(text[:320_000]))
# Window wrap-around: 700 KB that packs into a few KB. A 4 KB block is
# repeated with sparse mutations, so long matches cross the window end.
r = random.Random(8)
def mutated(data):
    for _ in range(len(data) // 400):
        data[r.randrange(len(data))] = r.getrandbits(8)
    return data
write("wrap", mutated(bytearray(bytes(r.getrandbits(8) for _ in range(4096)) * 171)[:700_000]))
# The same for E8: calls to a few fixed absolute targets, so the filtered
# data repeats as well and many filter blocks span the window end.
# Call offsets are relative to the position in the file, not in the block.
pattern = [r.choice((0x1000, 0x8000, 0x20000)) if r.random() < 0.2 else r.choice(ops) for _ in range(1500)]
code = bytearray()
while len(code) < 700_000:
    for op in pattern:
        code += b"\xe8" + struct.pack("<i", op - len(code) - 5) if isinstance(op, int) else op
write("wrap-e8", mutated(code[:700_000]))
# Solid PPMd continuation: x86-like code, then text, in one file. rar
# packs the code with LZ and switches to PPMd for the text, so the LZ
# tables stay read and the next solid entry starts inside the open PPMd
# block. (Text alone gets a new PPMd header for every entry.)
r = random.Random(4)
words = [bytes(r.getrandbits(8) % 26 + 97 for _ in range(r.randrange(2, 8))) for _ in range(400)]
def x86(size):
    data = bytearray()
    while len(data) < size:
        data += b"\xe8" + struct.pack("<i", r.randrange(-6000, 6000)) if r.random() < 0.15 else r.choice(ops)
    return bytes(data[:size])
def words_text(size):
    return b" ".join(r.choice(words) for _ in range(size // 4))[:size]
os.makedirs(os.path.join(root, "mct-solid", "book"))
for n, data in enumerate((x86(60_000) + words_text(60_000), words_text(8_000))):
    with open(os.path.join(root, "mct-solid", "book", f"{n}.bin"), "wb") as f:
        f.write(data)
# Solid RAR5: four small text files.
r = random.Random(12)
words = [bytes(r.getrandbits(8) % 26 + 97 for _ in range(r.randrange(2, 8))) for _ in range(300)]
os.makedirs(os.path.join(root, "solid", "book"))
for n in range(4):
    with open(os.path.join(root, "solid", "book", f"{n}.txt"), "wb") as f:
        f.write(b" ".join(r.choice(words) for _ in range(2000)))
PY

(cd "$work/e8" && "$RAR4" a -r -idq -ma4 -m3 -mce+ "$out/seed-rar4-flt-e8.rar" book)
(cd "$work/audio" && "$RAR4" a -r -idq -ma4 -m3 -mc4a+ "$out/seed-rar4-flt-audio.rar" book)
(cd "$work/delta" && "$RAR4" a -r -idq -ma4 -m3 -mc4d+ "$out/seed-rar4-flt-delta.rar" book)
(cd "$work/rgb" && "$RAR4" a -r -idq -ma4 -m3 -mcc+ "$out/seed-rar4-flt-rgb.rar" book)
(cd "$work/ppm" && "$RAR4" a -r -idq -ma4 -m3 -mc63:1t+ "$out/seed-rar4-mct-heap.rar" book)
(cd "$work/restart" && "$RAR4" a -r -idq -ma4 -m3 -mc5:1t+ "$out/seed-rar4-mct-restart.rar" book)
# -mct, not -mct+: rar must be free to pack the code with LZ.
(cd "$work/mct-solid" && "$RAR4" a -r -idq -ma4 -m3 -s -mct "$out/seed-rar4-mct-solid.rar" book)
(cd "$work/e8" && "$RAR5" a -r -idq -ma5 -m3 -mce+ "$out/seed-rar5-flt-e8.rar" book)
(cd "$work/audio" && "$RAR5" a -r -idq -ma5 -m3 -mca+ "$out/seed-rar5-flt-audio.rar" book)
(cd "$work/delta" && "$RAR5" a -r -idq -ma5 -m3 -mc4d+ "$out/seed-rar5-flt-delta.rar" book)
(cd "$work/rgb" && "$RAR5" a -r -idq -ma5 -m3 -mcc+ "$out/seed-rar5-flt-rgb.rar" book)
# The smallest dictionaries; the decoders still allocate 256 KB windows.
(cd "$work/wrap" && "$RAR4" a -r -idq -ma4 -m3 -md64k "$out/seed-rar4-wrap.rar" book)
(cd "$work/wrap" && "$RAR5" a -r -idq -ma5 -m3 -md128k "$out/seed-rar5-wrap.rar" book)
# rar never lets a filter block cross a 256 KB boundary of the file, and
# every real window is a multiple of that, so a filter never wraps. The
# seed is packed with a 256 KB dictionary, then its file header claims a
# RAR7 dictionary of 256 KB + 1/32 (RAR5-compatible data): the decoder's
# window becomes 264 KB and the filter blocks straddle its end. rar and
# SwiftRAR still extract it unchanged. -qo- leaves out the quick-open
# copy of the header, which would no longer match.
(cd "$work/wrap-e8" && "$RAR5" a -r -idq -ma5 -m3 -md256k -qo- -mce+ "$out/seed-rar5-wrap-flt.rar" book)
python3 - "$out/seed-rar5-wrap-flt.rar" <<'PY'
import sys, zlib
def vint(b, i):
    value = shift = 0
    while True:
        c = b[i]; i += 1
        value |= (c & 0x7F) << shift; shift += 7
        if c < 0x80:
            return value, i
def encode(value):
    out = bytearray()
    while value >= 0x80:
        out.append(value & 0x7F | 0x80); value >>= 7
    return bytes(out + bytes([value]))
path = sys.argv[1]
b = bytearray(open(path, "rb").read())
i = 8
while i < len(b):
    size, h = vint(b, i + 4)
    end = h + size
    kind, j = vint(b, h)
    flags, j = vint(b, j)
    if flags & 1:
        _, j = vint(b, j)
    data = 0
    if flags & 2:
        data, j = vint(b, j)
    if kind == 2:
        file_flags, j = vint(b, j)
        _, j = vint(b, j)  # unpacked size
        _, j = vint(b, j)  # attributes
        j += 4 * bool(file_flags & 2) + 4 * bool(file_flags & 4)  # mtime, CRC
        info, k = vint(b, j)
        # Version 1, 128 KB << 1 plus 1/32, compat flag (bit 20).
        info = info & ~0x3F & ~(0x3FF << 10) | 1 | 1 << 10 | 1 << 15 | 1 << 20
        header = b[h:j] + encode(info) + b[k:end]
        block = encode(len(header)) + header
        b[i:end] = zlib.crc32(block).to_bytes(4, "little") + block
        end = i + 4 + len(block)
    if kind == 5:
        break
    i = end + data
open(path, "wb").write(b)
PY
"$RAR5" t -idq "$out/seed-rar5-wrap-flt.rar"

# Solid RAR5: entry 2 continues the stream. rar never grows the window
# inside a solid stream, so the header of entry 3 is patched to claim a
# 1 MB dictionary: the decoder refuses it (UnRAR: "Not enough memory").
# rar tests the archive before the patch.
(cd "$work/solid" && "$RAR5" a -r -idq -ma5 -m3 -s -md128k -qo- "$out/seed-rar5-solid-grow.rar" book)
"$RAR5" t -idq "$out/seed-rar5-solid-grow.rar"
python3 - "$out/seed-rar5-solid-grow.rar" <<'PY'
import sys, zlib
def vint(b, i):
    value = shift = 0
    while True:
        c = b[i]; i += 1
        value |= (c & 0x7F) << shift; shift += 7
        if c < 0x80:
            return value, i
def encode(value):
    out = bytearray()
    while value >= 0x80:
        out.append(value & 0x7F | 0x80); value >>= 7
    return bytes(out + bytes([value]))
path = sys.argv[1]
b = bytearray(open(path, "rb").read())
i, files = 8, 0
while i < len(b):
    size, h = vint(b, i + 4)
    end = h + size
    kind, j = vint(b, h)
    flags, j = vint(b, j)
    if flags & 1:
        _, j = vint(b, j)
    data = 0
    if flags & 2:
        data, j = vint(b, j)
    if kind == 2:
        if files == 2:
            file_flags, j = vint(b, j)
            _, j = vint(b, j)  # unpacked size
            _, j = vint(b, j)  # attributes
            j += 4 * bool(file_flags & 2) + 4 * bool(file_flags & 4)  # mtime, CRC
            info, k = vint(b, j)
            info = info & ~(0x1F << 10) | 3 << 10  # 128 KB << 3
            header = b[h:j] + encode(info) + b[k:end]
            block = encode(len(header)) + header
            b[i:end] = zlib.crc32(block).to_bytes(4, "little") + block
            end = i + 4 + len(block)
        files += 1
    if kind == 5:
        break
    i = end + data
open(path, "wb").write(b)
PY

# Encryption: -hp encrypts the headers, so the parser meets an encryption
# header and refuses the archive; -p encrypts only the data, so the file
# headers carry an encryption record.
mkdir -p "$work/enc/book"
printf 'secret page\n' > "$work/enc/book/1.txt"
(cd "$work/enc" && "$RAR5" a -r -idq -ma5 -m3 -hpswiftrar -qo- "$out/seed-rar5-enc-header.rar" book)
(cd "$work/enc" && "$RAR5" a -r -idq -ma5 -m3 -pswiftrar -qo- "$out/seed-rar5-enc-file.rar" book)
"$RAR5" t -idq -pswiftrar "$out/seed-rar5-enc-header.rar"
"$RAR5" t -idq -pswiftrar "$out/seed-rar5-enc-file.rar"

# Timestamps: rar puts a whole-second mtime into the file header (Unix time
# flag) and one with nanoseconds into a time record, always in Unix format.
# The record of 1.txt is patched to a Windows FILETIME of the same instant;
# rar tests the archive and lists both times after the patch.
mkdir -p "$work/time/book"
printf 'first page\n' > "$work/time/book/1.txt"
printf 'second page\n' > "$work/time/book/2.txt"
touch -d 2024-05-17T12:34:56.5Z "$work/time/book/1.txt"
touch -d 2024-05-17T12:34:56Z "$work/time/book/2.txt" "$work/time/book"
(cd "$work/time" && "$RAR5" a -r -idq -ma5 -m3 -qo- "$out/seed-rar5-time.rar" book)
python3 - "$out/seed-rar5-time.rar" <<'PY'
import struct, sys, zlib
def vint(b, i):
    value = shift = 0
    while True:
        c = b[i]; i += 1
        value |= (c & 0x7F) << shift; shift += 7
        if c < 0x80:
            return value, i
def encode(value):
    out = bytearray()
    while value >= 0x80:
        out.append(value & 0x7F | 0x80); value >>= 7
    return bytes(out + bytes([value]))
path = sys.argv[1]
b = bytearray(open(path, "rb").read())
i, patched = 8, False
while i < len(b):
    size, h = vint(b, i + 4)
    end = h + size
    kind, j = vint(b, h)
    flags, j = vint(b, j)
    extra = data = 0
    if flags & 1:
        extra, j = vint(b, j)
    if flags & 2:
        data, j = vint(b, j)
    if kind == 2 and b[h:end].find(b"book/1.txt") >= 0:
        fixed, records, k = b[j:end - extra], bytearray(), end - extra
        while k < end:
            rsize, r = vint(b, k)
            rend = r + rsize
            rtype, r = vint(b, r)
            if rtype == 3:
                tflags, r = vint(b, r)
                assert tflags & 0x13 == 0x13, tflags  # Unix, mtime, ns
                seconds, = struct.unpack_from("<I", b, r)
                nanos, = struct.unpack_from("<I", b, r + 4 * bin(tflags & 0x0E).count("1"))
                filetime = (seconds + 11_644_473_600) * 10_000_000 + nanos // 100
                body = encode(3) + encode(0x02) + struct.pack("<Q", filetime)
                records += encode(len(body)) + body
                patched = True
            else:
                records += b[k:rend]
            k = rend
        head = encode(kind) + encode(flags) + encode(len(records))
        if flags & 2:
            head += encode(data)
        header = head + fixed + records
        block = encode(len(header)) + header
        b[i:end] = zlib.crc32(block).to_bytes(4, "little") + block
        end = i + 4 + len(block)
    if kind == 5:
        break
    i = end + data
assert patched
open(path, "wb").write(b)
PY
"$RAR5" t -idq "$out/seed-rar5-time.rar"
TZ=UTC "$RAR5" lt "$out/seed-rar5-time.rar" | grep -c '2024-05-17 12:34:56' | grep -qx 3

# Too many filters: rar never has 8192 filters waiting at once, so this
# RAR5 seed is written by hand. One LZ block whose tables code only two
# symbols, 0 (a zero literal) and 256 (a filter), with one bit each; 8200
# filter records, each for 4 bytes 200 bytes ahead. None can run before
# the data reaches it, so at 8192 the decoder writes out, still holds them
# all and drops them. Then 16 literals, short of every filter block. rar
# 7.23 must extract exactly those 16 zeros.
python3 - "$out/seed-rar5-flt-overflow.rar" "$work/overflow.expected" <<'PY'
import struct, sys, zlib
RECORDS, SIZE = 8200, 16
out = []
def put(value, count):
    out.extend(value >> i & 1 for i in reversed(range(count)))
# Bit lengths of the 20 table symbols: 1 gets 1 bit, 18 and 19 get 2.
lengths = [0] * 20
lengths[1], lengths[18], lengths[19] = 1, 2, 2
for length in lengths:
    put(length, 4)
def zeros(count):
    while count:
        n = min(count, 138)
        if n >= 11:
            put(0b11, 2); put(n - 11, 7)   # 19: 11 + 7 bits zeros
        else:
            put(0b10, 2); put(n - 3, 3)    # 18: 3 + 3 bits zeros
        count -= n
# 306 main + 64 distance + 16 low distance + 44 repeat lengths.
put(0, 1); zeros(255)        # literal 0
put(0, 1); zeros(429 - 256)  # symbol 256, nothing after it
for _ in range(RECORDS):
    put(1, 1)                # symbol 256: a filter
    put(0, 2); put(200, 8)   # block start, 1 byte
    put(0, 2); put(4, 8)     # block length, 1 byte
    put(1, 3)                # E8
for _ in range(SIZE):
    put(0, 1)
bits = len(out)
out += [0] * (-len(out) % 8)
data = bytes(int("".join(map(str, out[i:i + 8])), 2) for i in range(0, len(out), 8))
# Block header: last block, with tables, 2 size bytes, then its checksum.
flags = 0x80 | 0x40 | 1 << 3 | (bits - 1) % 8
size = len(data)
stream = bytes([flags, (0x5A ^ flags ^ size ^ size >> 8) & 0xFF]) + struct.pack("<H", size) + data

def vint(value):
    b = bytearray()
    while value >= 0x80:
        b.append(value & 0x7F | 0x80); value >>= 7
    return bytes(b + bytes([value]))
def header(body):
    block = vint(len(body)) + body
    return struct.pack("<I", zlib.crc32(block)) + block
name = b"overflow.bin"
unpacked = bytes(SIZE)
# File header with a data area and CRC32; attributes 0x20; RAR 5.0, -m3,
# 128 KB dictionary; Windows.
file_head = (vint(2) + vint(2) + vint(len(stream)) + vint(4) + vint(SIZE) + vint(0x20)
             + struct.pack("<I", zlib.crc32(unpacked)) + vint(3 << 7) + vint(0)
             + vint(len(name)) + name)
open(sys.argv[1], "wb").write(b"Rar!\x1a\x07\x01\x00" + header(vint(1) + vint(0) + vint(0))
    + header(file_head) + stream + header(vint(5) + vint(0) + vint(0)))
open(sys.argv[2], "wb").write(unpacked)
PY
"$RAR5" p -inul "$out/seed-rar5-flt-overflow.rar" | cmp - "$work/overflow.expected"

# rar never emits the Itanium filter, so this seed is written by hand: one
# LZ block of literals with flat tables, after a filter record for the
# whole entry. UnRAR recognises a filter program only by its length, CRC32
# and a first byte that is the XOR of the rest; the real Itanium program is
# not public, so the seed carries a stand-in that passes those checks.
# Its expected output comes from a Python copy of the filter, and rar 6.24
# must extract exactly that (a program that is not recognised fails there).
python3 - "$out/seed-rar4-flt-itanium.rar" "$work/itanium.expected" <<'PY'
import random, struct, sys, zlib
r = random.Random(10)

# The program: fix the XOR byte, then solve six free bytes for the CRC,
# which is affine in their bits (Gaussian elimination over GF(2)).
LENGTH, CRC, FREE = 120, 0x3769893F, range(1, 7)
def program(bits):
    code = bytearray(b"SwiftRAR stand-in for the RarVM Itanium filter program".ljust(LENGTH, b"."))
    for n, i in enumerate(FREE):
        code[i] = bits >> 8 * n & 0xFF
    code[0] = 0
    for byte in code[1:]:
        code[0] ^= byte
    return bytes(code)
base = zlib.crc32(program(0))
rows = [(zlib.crc32(program(1 << k)) ^ base, 1 << k) for k in range(8 * len(FREE))]
target, solution = CRC ^ base, 0
for bit in range(32):
    pivots = [row for row in rows if row[0] >> bit & 1]
    if not pivots:
        continue
    pivot = pivots[0]
    rows = [(a ^ pivot[0], b ^ pivot[1]) if a >> bit & 1 else (a, b) for a, b in rows if (a, b) != pivot]
    if target >> bit & 1:
        target ^= pivot[0]
        solution ^= pivot[1]
code = program(solution)
assert zlib.crc32(code) == CRC

# 32 KB of 16-byte Itanium-like bundles: about a third with a template the
# filter patches (0x10-0x1F with a non-zero slot mask) and opcode 5 in
# every slot, so their branch targets are rewritten.
def bits(data, at, count):
    return int.from_bytes(data[at // 8:at // 8 + 4], "little") >> (at & 7) & (1 << count) - 1
def set_bits(data, at, count, value):
    field = int.from_bytes(data[at // 8:at // 8 + 4], "little")
    mask = (1 << count) - 1 << (at & 7)
    data[at // 8:at // 8 + 4] = (field & ~mask | value << (at & 7) & mask).to_bytes(4, "little")
size = 32_768
packed = bytearray()
while len(packed) < size:
    bundle = bytearray(r.getrandbits(8) for _ in range(16)) + bytearray(4)
    if r.random() < 0.35:
        bundle[0] = bundle[0] & 0xE0 | r.choice((0x10, 0x12, 0x16, 0x18, 0x1C))
        for slot in range(3):
            set_bits(bundle, slot * 41 + 5 + 37, 4, 5)
    packed += bundle[:16]
# ExecuteStandardFilter for Itanium, the block starting at file offset 0.
masks = [4, 4, 6, 6, 0, 0, 7, 7, 4, 4, 0, 0, 4, 4, 0, 0]
data = bytearray(packed) + bytearray(4)
position = 0
while position < size - 21:
    template = (data[position] & 0x1F) - 0x10
    if template >= 0:
        for slot in range(3):
            start = 8 * position + slot * 41 + 5
            if masks[template] >> slot & 1 and bits(data, start + 37, 4) == 5:
                set_bits(data, start + 13, 20, bits(data, start + 13, 20) - position // 16 & 0xFFFFF)
    position += 16
unpacked = bytes(data[:size])
assert unpacked != packed

# The LZ stream, MSB first: a block with fresh tables (literals 0-253 get
# 8 bits, 254-257 get 9, nothing else, so no matches), symbol 257 with
# the filter record, the literals, then symbol 256 and "end of file".
out = []
def put(stream, value, count):
    stream.extend(value >> i & 1 for i in reversed(range(count)))
def pack(stream):
    stream += [0] * (-len(stream) % 8)
    return bytes(int("".join(map(str, stream[i:i + 8])), 2) for i in range(0, len(stream), 8))
def canonical(lengths):
    codes, code = {}, 0
    for length in range(1, 16):
        for symbol, l in enumerate(lengths):
            if l == length:
                codes[symbol] = (code, length)
                code += 1
        code <<= 1
    return codes
put(out, 0, 2)
pre_lengths = [0] * 20
for symbol, length in {8: 2, 9: 2, 19: 2, 18: 3, 0: 3}.items():
    pre_lengths[symbol] = length
for length in pre_lengths:
    put(out, length, 4)
pre = canonical(pre_lengths)
lengths = [8] * 254 + [9] * 4
for length in lengths:
    put(out, *pre[length])
put(out, *pre[19]); put(out, 127, 7)   # 138 of the 41 + 60 + 17 + 28 zeros
put(out, *pre[18]); put(out, 5, 3)     # the other 8
lit = canonical(lengths)
# Filter record (flag 0x20: block length given; new filter 0): block start
# 0, block length, program size, program, each a RarVM ReadData field.
record = []
put(record, 0, 6)
put(record, 2, 2); put(record, size, 16)
put(record, 1, 2); put(record, LENGTH, 8)
for byte in code:
    put(record, byte, 8)
record = pack(record)
put(out, *lit[257]); put(out, 0x20 | 6, 8); put(out, len(record) - 7, 8)
for byte in record:
    put(out, byte, 8)
for byte in packed:
    put(out, *lit[byte])
put(out, *lit[256]); put(out, 0, 2)
stream = pack(out)

# RAR 4 archive: marker, main header, file header, data, end header.
def block(kind, flags, body):
    head = struct.pack("<BHH", kind, flags, 7 + len(body)) + body
    return struct.pack("<H", zlib.crc32(head) & 0xFFFF) + head
name = b"itanium.bin"
file_head = struct.pack("<IIBIIBBHI", len(stream), size, 3, zlib.crc32(unpacked),
                        0x5D50_0000, 29, 0x33, len(name), 0o100644) + name
open(sys.argv[1], "wb").write(b"Rar!\x1a\x07\x00" + block(0x73, 0, bytes(6))
    + block(0x74, 0x8000, file_head) + stream + block(0x7B, 0x4000, b""))
open(sys.argv[2], "wb").write(unpacked)
PY
"$RAR4" p -inul "$out/seed-rar4-flt-itanium.rar" | cmp - "$work/itanium.expected"

# Every seed must fit the fuzzer's -max_len, or it is truncated again.
for f in "$out"/*.rar; do
    size="$(stat -f %z "$f")"
    [ "$size" -le 65536 ] || { echo "$f is $size bytes, over 64 KB" >&2; exit 1; }
done
ls -l "$out"
