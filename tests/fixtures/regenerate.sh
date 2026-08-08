#!/usr/bin/env bash
#
# Regenerate every .wasm fixture in this directory from its .wat source.
#
# Requires (macOS: `brew install wabt wasm-tools`):
#   wat2wasm    -- wabt 1.0.41
#   wasm-tools  -- 1.255.0
#   python3     -- only for the malformed/ fixtures, which are byte patches
#
# Usage:  ./regenerate.sh
#
# Every valid/*.wasm is assembled from the valid/*.wat next to it. Every
# malformed/*.wasm is derived by patching a known-good module, so the
# corruption is a single documented byte edit rather than a hand-typed
# blob. See README.md for what each fixture covers.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALID="$HERE/valid"
MALFORMED="$HERE/malformed"

for tool in wat2wasm wasm-tools python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: $tool not on PATH (brew install wabt wasm-tools)" >&2
    exit 1
  }
done

mkdir -p "$VALID" "$MALFORMED"

# --- valid fixtures ------------------------------------------------------
#
# wat2wasm is the default assembler: it emits no name section unless asked,
# which keeps the fixtures minimal and their section tables exactly the
# feature under test.
#
# Do NOT use --enable-all here. It switches on the experimental
# "compact imports" proposal, and wabt then encodes the import section in
# that proposal's grouped-by-module form instead of the standard
# vec(mod, name, desc). The result is not a WebAssembly 3.0 module -- it is
# rejected by wasm-tools 1.255.0 -- and it silently changed imports.wasm
# only, because that is the only fixture with an import section. The
# feature list below is the minimum these sources actually need; reference
# types, SIMD and bulk memory are already on by default in wabt 1.0.41.
FEATURES=(
  --enable-exceptions    # tags.wat: tag section + try_table
  --enable-multi-memory  # multimemory.wat: two memories, memidx data segment
  --enable-annotations   # customsections.wat: the (@custom ...) syntax
)

WAT2WASM_ONLY=(
  minimal
  exports
  imports
  start
  datacount
  reftypes
  simd
  multimemory
  tags
)

for name in "${WAT2WASM_ONLY[@]}"; do
  wat2wasm "${FEATURES[@]}" "$VALID/$name.wat" -o "$VALID/$name.wasm"
  echo "valid/$name.wasm  ($(wc -c <"$VALID/$name.wasm" | tr -d ' ') bytes)  [wat2wasm]"
done

# customsections.wat is assembled with wasm-tools, not wabt: wabt ignores
# the (before X)/(after X) placement directives on (@custom ...) and appends
# every custom section to the end of the module. Interleaved placement is
# the entire point of that fixture. wasm-tools also emits a `name` section
# from the symbolic identifiers without being asked.
wasm-tools parse "$VALID/customsections.wat" -o "$VALID/customsections.wasm"
echo "valid/customsections.wasm  ($(wc -c <"$VALID/customsections.wasm" | tr -d ' ') bytes)  [wasm-tools]"

# --- malformed fixtures --------------------------------------------------
#
# Each is a minimal, precisely located corruption of a valid module. A
# conforming decoder must REJECT all of them with a decode error.

python3 - "$VALID" "$MALFORMED" <<'PY'
import sys, pathlib

valid = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])

def read(name):
    return bytearray((valid / name).read_bytes())

def write(name, data, note):
    (out / name).write_bytes(bytes(data))
    print(f"malformed/{name}  ({len(data)} bytes)  -- {note}")

# 1. Preamble magic corrupted: 00 61 73 6d -> 00 62 73 6d.
b = read("minimal.wasm")
b[1] = 0x62
write("bad-magic.wasm", b, "magic byte 1 is 0x62('b'), not 0x61('a')")

# 2. Preamble version 1 -> 2. Only version 1 is a core module.
b = read("minimal.wasm")
b[4] = 0x02
write("bad-version.wasm", b, "binary version field is 2, not 1")

# 3. Truncated module: exports.wasm cut in the middle of a section body,
#    so the final section header declares more bytes than the file holds.
b = read("exports.wasm")
write("truncated-section.wasm", b[: len(b) - 24],
      "last 24 bytes chopped; trailing section overruns EOF")

# 4. Section size field inflated in place. The type section of
#    exports.wasm sits at offset 8 (id) / 9 (size, one LEB byte).
#    0x7F = 127 declared bytes with far fewer remaining.
b = read("exports.wasm")
assert b[8] == 0x01, "expected type section id at offset 8"
b[9] = 0x7F
write("section-overrun.wasm", b,
      "type section declares 127 bytes, module has fewer remaining")

# 5. A section id outside the defined range 0..13 appended to a valid
#    module. 0xC8 = 200, body length 0.
b = read("exports.wasm")
b += bytes([0xC8, 0x00])
write("unknown-section-id.wasm", b, "trailing section with id 200")

# 6. Prescribed section order violated: the type section of exports.wasm
#    is duplicated immediately after itself. Each known section may occur
#    at most once, so the repeat must be rejected.
b = read("exports.wasm")
size = b[9]
type_section = b[8 : 10 + size]
b[10 + size : 10 + size] = type_section
write("duplicate-section.wasm", b,
      "type section (id 1) appears twice in a row")

# 7. File ends immediately after a section id byte, so the size LEB that
#    must follow it is not there at all.
b = read("exports.wasm")
write("missing-size-leb.wasm", b[:9],
      "section id at offset 8 with no size LEB after it")

# 8. Custom section whose name length runs past its own declared body.
#    Body is 4 bytes; the name claims 0x40 = 64. The name must be read
#    bounded by the section, never allowed to consume the next section.
b = bytearray(read("exports.wasm")[:8])
b += bytes([0x00, 0x04, 0x40, 0x41, 0x42, 0x43])
write("custom-name-overrun.wasm", b,
      "custom section name length 64 inside a 4-byte body")

# 9. Section size LEB is five bytes encoding a value above 2^32-1.
b = read("exports.wasm")
b[9:10] = bytes([0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
write("leb-size-overflow.wasm", b,
      "section size LEB sets bits above 32")

# 10. A valid module with one stray section id byte appended and nothing
#     after it. Trailing bytes are not a permitted module suffix.
b = read("exports.wasm") + bytes([0x01])
write("trailing-section-id.wasm", b,
      "lone trailing section id byte after a complete module")

# 11. Only the 4 magic bytes: shorter than the 8-byte preamble.
write("truncated-preamble.wasm", bytearray(b"\x00asm"),
      "4-byte file, preamble needs 8")
PY

# --- a VALID fixture that no assembler will emit -------------------------
#
# LEB128 in the binary format is "at most ceil(N/7) bytes", NOT "minimal".
# A padded encoding within that limit is legal and must be ACCEPTED, but
# every assembler emits minimal LEBs, so this one is patched in: the type
# section size 0x07 is rewritten as the two-byte 0x87 0x00. Rejecting it
# is a classic decoder bug, which is why it lives in valid/ and not in
# malformed/.
python3 - "$VALID" <<'PY'
import sys, pathlib
valid = pathlib.Path(sys.argv[1])
b = bytearray((valid / "exports.wasm").read_bytes())
assert b[8] == 0x01 and b[9] == 0x07, "exports.wasm type section header moved"
b[9:10] = bytes([0x87, 0x00])
(valid / "padded-leb-size.wasm").write_bytes(bytes(b))
print(f"valid/padded-leb-size.wasm  ({len(b)} bytes)  [patched from exports.wasm]")
PY

echo
echo "done."
