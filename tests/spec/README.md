# Spec testsuite

The upstream [WebAssembly/testsuite](https://github.com/WebAssembly/testsuite)
corpus is this project's external conformance judge. It is **fetched, never
vendored**: `tests/spec/testsuite/` is gitignored, and only harness
configuration and this README are committed here.

The harness is `wasmspec` (`source/apps/wasmspec.pas`), built by `lwpt build`
alongside `wasmlight` and `wasmbench`. It parses scripts with `Wasm.Wast` and
judges commands with `Wasm.Wast.Runner`. See
[../../docs/testing.md](../../docs/testing.md) for where it sits among the
three test tiers and [../../docs/roadmap.md](../../docs/roadmap.md) for
Track C's remaining work.

## Fetching the corpus

```bash
git clone --depth 1 https://github.com/WebAssembly/testsuite tests/spec/testsuite
```

Record the commit you got — a conformance number without one is not
reproducible:

```bash
git -C tests/spec/testsuite rev-parse HEAD
```

## Running

```bash
lwpt build                                   # builds ./build/wasmspec
./build/wasmspec tests/spec/testsuite        # whole corpus, recursive
./build/wasmspec tests/spec/testsuite/binary.wast
./build/wasmspec --verbose tests/spec/testsuite/data.wast
./build/wasmspec --failures-only tests/spec/testsuite
```

A directory argument is walked recursively, so pointing at the checkout root
includes `proposals/` as well as the 3.0 root corpus. A file argument is taken
as given. Output is sorted by path, so two runs over the same tree are
diffable.

The exit code is `0` only when nothing failed and every script could be read
and parsed. Staged cases and skips do not fail a run; an unparseable script
does.

## Reading the output

Every line starts with a fixed token, so a run over hundreds of files can be
sorted, counted, and diffed with the shell.

| Token | Meaning |
| --- | --- |
| `PASS` | Judged, and the outcome matched (`--verbose` only) |
| `FAIL` | Judged, and it did not — carries `got=`, `expected=`, and `actual=` |
| `STAGED` | Would fail, but only on deliberately staged work (`$FD` vector validation, Track G) |
| `SKIP` | Not judged; carries `reason=` (`--verbose` only) |
| `FILE` | Per-file tally |
| `TOTAL` | Aggregate tally, plus the file and error counts |
| `ERROR` | A script that could not be read or parsed — operational, never a conformance result |

On a `FAIL` (and a `STAGED`), `got=` names the error CLASS we produced,
from `WastErrorKindName`:

| `got=` | Meaning |
| --- | --- |
| `none` | No error was raised (an assertion that demanded one is a fail) |
| `malformed` | `EWasmDecodeError` — the bytes are not a module |
| `invalid` | `EWasmValidationError` — a module, but not well-typed |
| `internal` | Any other exception — a bug in this project, always a fail |

`got=` is the wrong-class detector: `expected=` and `actual=` compare the
message *wording*, but `got=` is how you see that a module was rejected for
the wrong reason (upstream wanted `malformed`, we said `invalid`).

An `ERROR` line has a fixed field shape so it is as greppable as a `FAIL`:

```text
ERROR <path> <class> <quoted-detail>
```

`<class>` is the class of the exception that stopped the file
(`EWastParseError`, `EWasmDecodeError`, …), or the sentinel
`unresolved-argument` when a positional named nothing on disk.

Extracting the distinct failure signatures is the main use of a run today.
The `actual=` string carries per-case offsets, so strip it and key on the
`got=`/`expected=` pair — that is the signature:

```bash
./build/wasmspec tests/spec/testsuite \
  | grep '^FAIL' \
  | sed -E 's/.*(got=[^ ]+ expected="[^"]*").*/\1/' \
  | sort | uniq -c | sort -rn
```

## What is judged today

Decode (`Wasm.Decoder`) and validation (`Wasm.Validator`) are shipped; there is
no execution tier and no text-format assembler. So exactly three command shapes
get a real verdict, and all three need the module in the `(module binary "...")`
form:

- `(module binary ...)` at top level — must decode **and** validate
- `(assert_malformed (module binary ...) "...")` — must raise `EWasmDecodeError`
- `(assert_invalid (module binary ...) "...")` — must raise `EWasmValidationError`

Everything else is `SKIP` with a reason, never a silent pass:

| Reason | Applies to |
| --- | --- |
| `text format not yet assembled` | `(module ...)` and `(module quote ...)`, wherever they appear |
| `needs an execution tier` | `register`, `invoke`, `assert_return`, `assert_trap`, `assert_unlinkable`, `assert_exception`, `assert_exhaustion` |
| `directive not in the reference grammar` | `assert_malformed_custom`, `assert_invalid_custom`, anything else unrecognised |
| `no module operand` | An assertion that should carry a module and does not |

Modules are assembled and decoded at command-execution time, never at
script-parse time — otherwise `assert_malformed` could not observe the failure
it exists to observe.

The match against the script's expected string is a **prefix** match, per the
reference interpreter: the expected string must be a prefix of our message. Our
error messages are therefore part of conformance, not merely diagnostics.

`STAGED` exists for one reason. `$FD` vector validation is staged to Track G and
raises `SIMD validation is not implemented`. A case that trips that specific
message and would otherwise fail is counted separately, so known-absent work
cannot bury real divergences — and it is never counted as a pass.

## Where the numbers stand

`WebAssembly/testsuite@de54fd27ecf3e68dfd16b6199c548df77b6a2cc1`, 288 scripts:

```text
TOTAL files=288 errors=0 pass=1034 fail=35 skip=66050 staged=6 total=67125
```

Split by corpus: the 3.0 root is 257 scripts (`pass=787 fail=17 staged=6`), and
the non-root trees (`proposals/`, `legacy/`, `custom/`) add 31 scripts
(`pass=247 fail=18 staged=0`).

The first run, before the message prefixes were settled, read
`errors=1 pass=218 fail=851`. Nearly every one of those 851 was a message-prefix
divergence rather than a wrong verdict — the module was rejected, with the right
error class, but our wording did not start with upstream's canonical string.
Settling them is what the run was for; the prefixes now live as `MSG_*`
constants across four units — `Wasm.Binary` (decode) and, for validation,
`Wasm.Validator.Types`, `Wasm.Validator.Body`, and `Wasm.Validator` — and a
raise site appends its context after the prefix rather than in front of it. (The
runtime units carry their own `MSG_*` trap and link strings, but those are
execution-tier messages the binary subset never reaches.)

Judged commands are `pass + fail + staged` = **1,075** — the corpus's
`(module binary ...)` cases the runner reached, which is the ceiling until a text
assembler exists. The `staged` column belongs in that sum: a staged case was
attempted and set aside, not skipped. Read the `skip` column as the size of the
unbuilt work, not as coverage. The `skip` and `total` columns grew against the
first run only because `annotations.wast` now parses: its commands are counted
and skipped instead of the file being an `ERROR`.

### What the 35 remaining failures are

Every one is `got=malformed` from us, so none is a wrong-CLASS rejection between
`malformed` and `invalid`. But they are not all the same kind of divergence, and
the blanket "rejected where upstream rejects" is wrong for six of them: for those
six upstream *accepts* the module.

**Six are false rejections on out-of-scope proposals** — the `expected=""` cases,
where the script presents the module as valid and we reject it. They exercise
post-3.0 features outside the pinned conformance target
([ADR-0004](../../docs/adr/0004-conformance-target-is-the-3-0-draft.md)):
`custom-descriptors`' `$4D` descriptor composite type
(`binary-descriptors.wast:2`, `:66`, `ref_get_desc.wast:253`) and its exact
reference types (`exact.wast:111`, `:125`), and `wide-arithmetic`'s `$FC`
subopcode 19 (`wide-arithmetic.wast:326`). The out-of-scope justification holds —
3.0 does not have these features, and a conformant 3.0 runtime may reject a
module that uses them — but the honest label is a *false rejection*, not a
wording mismatch: the day the feature lands, these modules must be accepted.

The other **29 are message-wording divergences**: the module is rejected as
`malformed`, exactly as upstream rejects it as `malformed`, but our message is
not a prefix of upstream's `expected=` string. They fall into three groups.

**Six more are post-3.0 proposal cases upstream also rejects**, with a wording we
do not match: `custom-descriptors`' `malformed definition type` (×3), `exact`'s
`malformed storage type` (×2), and `custom-page-sizes`' `invalid custom page
size` for the `$08` limits flag (×1). Same out-of-scope features as the false
rejections above — but here upstream expects a rejection too, so only the string
differs.

**Nine come from upstream reading past a declared size where we do not.** Our
decoder gives every section body and every code entry a `SubReader` bounded by
its declared size, so a read cannot leave the thing that declared it. The
reference interpreter reads on and checks the position afterwards, so where a
test module's declared size is short, it reaches a defect further along that we
never see. Three conditions, each recurring in the three `binary.wast` copies
(the root plus the `custom-descriptors/` and `custom-page-sizes/` mirrors):

| Condition | Upstream says | We say |
| --- | --- | --- |
| a code entry with no `end`, followed by another entry (`binary.wast:55`) | `END opcode expected` (it peeks the next entry's size byte, `\05`, and reads it as `else`) | `unexpected end of section or function` |
| the same, followed by a data section (`binary.wast:92`) | `section size mismatch` (it consumes the data section's `\0b` as the `end`) | the same |
| an export section declaring two exports and spelling one (`binary.wast:737`) | `length out of bounds` (it reads the next section's bytes as a name length) | the same |

The first two are the SAME condition for us — a function body span that runs out
before its `end` — so at most one of the two wordings can be matched, and the
one that is matched is the one the corpus asks for 28 times elsewhere. Matching
either of the other two would mean giving up bounded section bodies, which is
what makes `length out of bounds` and `section size mismatch` right everywhere
else.

**Fourteen are `binary-leb128.wast` cases.** Thirteen share one root cause: a
deliberately overlong or over-wide LEB128 whose bytes run past the section or
code entry that declares them. Upstream reads the whole encoding and reports
`integer too large` / `integer representation too long`; we report the section
bound first. One further case (`:1067`) spells `functype` as the two-byte
sLEB128 `\e0\7f`; we reject the multi-byte spelling of a literal-byte production
as `malformed composite type`, where upstream reports `integer representation too
long`. (Thirteen plus one is the fourteen — the `:1067` case is not additional to
them.)

That is `6 + 6 + 9 + 14 = 35`. Everything else the corpus asserts about message
wording is matched, including the 528 `malformed UTF-8 encoding` cases and the
`unknown memory <index>` form, where the index is part of the prefix and not of
the context after it.
