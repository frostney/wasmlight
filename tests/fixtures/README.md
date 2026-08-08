# Binary fixtures

Real toolchain output, committed so the decoder can be cross-checked
against binaries an actual assembler produced rather than against
hand-written byte arrays. The hand-written arrays in
`source/units/Wasm.Decoder.Test.pas` cover chosen bytes; these cover what
a real encoder chooses.

Everything here is tiny — the largest fixture is 219 bytes, and the whole
directory is well under 4 KB of `.wasm`.

## Toolchain

| Tool | Version | Source |
| --- | --- | --- |
| `wat2wasm`, `wasm-objdump` (wabt) | 1.0.41 | `brew install wabt` |
| `wasm-tools` | 1.255.0 | `brew install wasm-tools` |
| `python3` | 3.9.6 (system) | only for the byte-patched fixtures |

`wasm-tools validate --features all` is also used as an independent
oracle: it accepts every module in `valid/` and rejects every module in
`malformed/`.

## Regenerating

```sh
./regenerate.sh
```

Assembles each `valid/*.wasm` from the `valid/*.wat` beside it, then
derives the `malformed/*.wasm` set by patching known-good modules. Output
is deterministic; a clean tree after a run means nothing drifted.

### Two toolchain traps the script encodes

**Do not use `wat2wasm --enable-all`.** It switches on the experimental
*compact imports* proposal, and wabt then writes the import section in
that proposal's grouped-by-module form instead of the standard
`vec(mod, name, desc)`. The result is not a WebAssembly 3.0 module —
`wasm-tools` rejects it outright. It silently affected `imports.wasm`
alone, because that is the only fixture with an import section. The
script pins an explicit minimal feature list instead:
`--enable-exceptions --enable-multi-memory --enable-annotations`
(reference types, SIMD and bulk memory are already on by default in wabt
1.0.41).

**`customsections.wasm` is built with `wasm-tools`, not wabt.** wabt
parses the `(before X)` / `(after X)` placement directives on
`(@custom ...)` but ignores them, appending every custom section to the
end of the module. `wasm-tools` honours them, and interleaved placement is
the whole point of that fixture.

## `valid/` — must be ACCEPTED

Each has its `.wat` source beside it, except `padded-leb-size.wasm`,
which no assembler will emit (see below).

| Fixture | Bytes | Sections in encoding order | What it covers |
| --- | --- | --- | --- |
| `minimal.wasm` | 8 | *(none)* | Bare preamble, zero sections — the section loop must terminate immediately. |
| `exports.wasm` | 112 | type, function, table, memory, global, export, code | The plain ascending-id run, all five index spaces populated. |
| `imports.wasm` | 92 | type, import, function, export, code | All four import kinds (func, table, memory, global); function index space starts above zero. |
| `start.wasm` | 92 | type, function, table, memory, global, export, **start**, element, code, data | Start section (id 8) plus active element and active data segments. Ten sections, the longest run here. |
| `datacount.wasm` | 114 | type, function, memory, export, **data count**, code, data | **The ordering fixture.** See below. |
| `customsections.wasm` | 219 | **custom**, type, function, memory, **custom**, export, code, **custom**, **custom "name"** | Four custom sections interleaved at three different points plus a trailing `name` section with debug names. |
| `reftypes.wasm` | 127 | type, function, table, export, element, code | `funcref` and `externref` tables, `table.get`/`table.set`, `ref.null`, `ref.is_null`, `ref.func`, declarative element segment. |
| `simd.wasm` | 146 | type, function, memory, export, code | `v128` in signatures (type code −5 / `0x7B`), `v128.const`, lane ops, `v128.load`/`store` — the `0xFD` prefixed opcode space. |
| `multimemory.wasm` | 97 | type, function, memory, export, code, data | Two memories; the data segment bound to memory 1 forces the `flags = 0x02` explicit-memidx encoding. |
| `tags.wasm` | 92 | type, function, memory, **tag**, global, export, code | Tag section (id 13) and `try_table`/`throw`. See below. |
| `padded-leb-size.wasm` | 113 | type, function, table, memory, global, export, code | Legal **non-minimal LEB128**. See below. |

### The three fixtures that exist to catch specific decoder bugs

**`datacount.wasm` — section id order is not section encoding order.**
A passive data segment plus `memory.init` / `data.drop` forces the data
count section to be emitted, and the binary grammar places it *before*
the code section:

```text
type(1)  function(3)  memory(5)  export(7)  data count(12)  code(10)  data(11)
                                            ^^^^^^^^^^^^^^  ^^^^^^^
                                            id 12 precedes id 10
```

A decoder that enforces "section ids must strictly increase" rejects this
valid module. That is a real bug this fixture caught.

**`tags.wasm` — the second place where id order diverges.** The tag
section is id 13 but sits between memory (id 5) and global (id 6):

```text
type(1)  function(3)  memory(5)  tag(13)  global(6)  export(7)  code(10)
                                 ^^^^^^^  ^^^^^^^^^
                                 id 13 precedes id 6
```

**`padded-leb-size.wasm` — minimality is not required.** The binary format
specifies `uN` as "at most `ceil(N/7)` bytes", not "minimally encoded". A
padded encoding within that limit is legal. Here the type section size
`0x07` is rewritten as the two-byte `0x87 0x00`, which shifts every
subsequent section body by one byte. Every assembler emits minimal LEBs,
so this is patched in by `regenerate.sh` and has no `.wat`. Rejecting it,
or mis-reporting the shifted offsets, is a classic decoder bug.

## `malformed/` — must be REJECTED

All are byte patches of a valid module, so the corruption is one
documented edit rather than a hand-typed blob. Each must fail with
`EWasmDecodeError` — these are "the bytes are not a module" errors, not
validation errors.

| Fixture | Bytes | Corruption | Rule violated |
| --- | --- | --- | --- |
| `truncated-preamble.wasm` | 4 | Only the magic bytes | The preamble is 8 bytes: magic + version. |
| `bad-magic.wasm` | 8 | Byte 1 is `0x62` (`b`) not `0x61` (`a`) | Magic must be `00 61 73 6D`. |
| `bad-version.wasm` | 8 | Version field is 2 | Only version 1 is a core module. |
| `missing-size-leb.wasm` | 9 | File ends right after a section id byte | Every section header is id + size LEB. |
| `section-overrun.wasm` | 112 | Type section size patched to `0x7F` (127) with 102 bytes left | A section may not declare more bytes than remain. |
| `truncated-section.wasm` | 88 | Last 24 bytes chopped | Trailing section body runs past EOF. |
| `leb-size-overflow.wasm` | 116 | Section size LEB is `FF FF FF FF 7F` | A `u32` LEB may not set bits above 32. |
| `unknown-section-id.wasm` | 114 | Trailing section with id 200 | Section ids are 0–13. |
| `duplicate-section.wasm` | 121 | Type section appears twice in a row | Each known section may occur at most once. |
| `custom-name-overrun.wasm` | 14 | Custom section name length 64 inside a 4-byte body | The name is read from within the section's own declared extent and must never consume the next section. |
| `trailing-section-id.wasm` | 113 | One stray section id byte appended to a complete module | A module ends at its last section; trailing bytes are not a permitted suffix. |

## Feature support notes

Everything requested is covered by this toolchain; nothing had to be
skipped.

- **Exception handling / tag section (id 13):** supported. wabt 1.0.41
  assembles `try_table` / `throw` and emits a real tag section under
  `--enable-exceptions`.
- **SIMD, reference types, bulk memory:** on by default in wabt 1.0.41,
  no flag needed.
- **Multi-memory:** supported under `--enable-multi-memory`.
- **Debug `name` section:** emitted by `wasm-tools` from the `.wat`
  symbolic identifiers without being asked; wabt needs `--debug-names`.

## Cross-check status

As of wabt 1.0.41 / wasm-tools 1.255.0, `./build/wasmlight inspect` agrees
with the oracle on all 22 fixtures: it accepts all 11 in `valid/`, rejects
all 11 in `malformed/`, and its reported section offsets and sizes match
`wasm-objdump -h` exactly for every valid module, including the shifted
offsets in `padded-leb-size.wasm`.
