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
| `STAGED` | Would fail, but only on deliberately staged work (`$FD` vector support, Track G) |
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
| `text` | `EWasmTextError` — the `.wat` text-format source would not assemble |
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

Decode (`Wasm.Decoder`), validation (`Wasm.Validator`), the wat text-format
assembler (`Wasm.Wat.*`), and the interpreter (`Wasm.Interp`) are all shipped, so
a command no longer needs the `(module binary "...")` form to be judged. Text and
quoted modules assemble to bytes and re-enter the same decode/validate/instantiate
path a binary module takes:

- `(module ...)` / `(module quote ...)` / `(module binary ...)` at top level —
  assemble (text/quote), decode, validate, **instantiate**, run any start function
- `(assert_malformed (module ...) "...")` — a TEXT/quote operand must raise
  `EWasmTextError` from the assembler; a BINARY operand must raise
  `EWasmDecodeError`. A decode error on the assembler's OWN output is an
  invariant violation, reported `internal`, never scored as malformed
- `(assert_invalid (module ...) "...")` — the module must assemble, then raise
  `EWasmValidationError`
- `(assert_return ...)`, `(assert_trap (invoke ...) ...)`, `(invoke ...)`,
  `(assert_exhaustion ...)` — run through the interpreter and compare
- `(assert_trap (module ...) ...)` / `(assert_exhaustion (module ...) ...)` —
  the instantiation-trap form: the module is built and instantiated for real,
  an out-of-bounds active segment traps after earlier ones persist, and a
  trapping start function is judged

Everything else is `SKIP` with a reason, never a silent pass:

| Reason | Applies to |
| --- | --- |
| `no instantiated module` | An `assert_return` / `invoke` whose module did not instantiate — overwhelmingly the staged vector modules |
| `needs an execution tier` | An action whose module the assembler cannot yet build for another reason |
| `import not provided by the harness` | A module importing something the harness does not supply |
| `exception handling not implemented (Track H)` | `assert_exception` and throwing forms |
| `assert_unlinkable` | Linkage is not yet judged (the operand is still assembled and validated as a pre-check) |
| `directive not in the reference grammar` | `assert_malformed_custom`, `assert_invalid_custom`, anything else unrecognised |

Modules are assembled and decoded at command-execution time, never at
script-parse time — otherwise `assert_malformed` could not observe the failure
it exists to observe.

The match against the script's expected string is a **prefix** match, per the
reference interpreter: the expected string must be a prefix of our message. Our
error messages — text, decode, validation, and trap — are therefore part of
conformance, not merely diagnostics.

`STAGED` exists for one reason. `$FD` vector support is staged to Track G, so a
module whose text names a `v128` instruction the assembler cannot emit trips
`unknown operator` and is counted separately, keeping the vector files from
burying real divergences. It is never a pass, and every assertion downstream of a
staged module skips as `no instantiated module`.

## Where the numbers stand

`WebAssembly/testsuite@de54fd27ecf3e68dfd16b6199c548df77b6a2cc1`, 288 scripts:

```text
ROOT      pass=38367 fail=88  skip=25239 staged=1620 total=65314
PROPOSALS pass=533   fail=356 skip=922   staged=0    total=1811
TOTAL files=288 errors=0 pass=38900 fail=444 skip=26161 staged=1620 total=67125
```

`ROOT` is everything outside `proposals/` (the 3.0 target plus the out-of-scope
`legacy/` tree); `PROPOSALS` is the post-3.0 proposal mirrors. Message prefixes
now live as `MSG_*` constants across the decode, validation, assembler, and
runtime units — the interpreter's traps reach the runtime `MSG_*` strings the
binary-only runs never did, and a raise site appends its context after the
prefix rather than in front of it.

Judged commands are `pass + fail + staged` = **~40,900** — up from the old
binary-only ceiling of 1,075, now that text modules assemble and assertions
execute. The `staged` column (1,620) belongs in that sum: a staged case was
attempted and set aside, not skipped. The `skip` column is dominated by the
25,721 `no instantiated module` cases — assertions against the staged vector
modules — so read it as the size of the vector work still ahead, not as a
coverage gap in the shipped layers.

### What the 444 failures are

The split is the headline: **356 are `PROPOSALS`** and only **88 are `ROOT`**, so
the failures cluster in post-3.0 features, not in the 3.0 target. None is a
wrong-CLASS rejection between `malformed` and `invalid`.

**`PROPOSALS` (356)** exercise features outside the pinned conformance target
([ADR-0004](../../docs/adr/0004-conformance-target-is-the-3-0-draft.md)):
`custom-descriptors` (descriptor composite types, exact reference types, the
`type … does not have a descriptor` family), `custom-page-sizes` (the `invalid
custom page size` limits flag), `wide-arithmetic` (the `$FC` subopcode), and
threads. They appear as **false rejections** (`expected=""`, ~130 of them: the
script presents the module as valid and a 3.0 runtime rejects it — the day the
feature lands, these must be accepted) and as **wording mismatches** on modules
upstream also rejects. The justification holds — 3.0 does not have these
features — but the honest label on the `expected=""` cases is *false rejection*,
not diagnostics.

**`ROOT` (88)** are three kinds:

- **Legacy exception handling** (`testsuite/legacy/try_catch.wast`,
  `rethrow.wast`, `throw.wast`) — the pre-3.0 `try`/`catch`/`delegate`/`rethrow`
  encoding, out of 3.0 scope (Track H covers the 3.0 `try_table` form only).
- **The `binary-leb128` and `binary` wording divergences** carried since the
  binary subset — deliberately overlong or over-wide LEB128 whose bytes run past
  the section that declares them, where upstream reads the whole encoding
  (`integer too large` / `integer representation too long`) and our bounded
  `SubReader` reports the section bound first. Our decoder gives every section
  body and code entry a reader bounded by its declared size, which is what makes
  `length out of bounds` and `section size mismatch` right everywhere else.
- **A few assembler/execution edges** — `expected=""` text cases the assembler
  does not yet build, and a handful of execution-tier `type mismatch` and
  `unknown …` wordings.

Extract the live signatures rather than trusting this list to stay exact — the
grep in the "Reading the output" section keys on the `got=`/`expected=` pair and
survives corpus bumps. Everything the corpus asserts about the settled 3.0
message wording is still matched, including the `malformed UTF-8 encoding` cases
and the `unknown memory <index>` form, where the index is part of the prefix and
not of the context after it.
