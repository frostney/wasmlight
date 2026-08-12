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

The pinned commit is recorded in [`testsuite.commit`](testsuite.commit) — a
conformance number is only reproducible against a specific commit, and CI
checks out exactly that SHA. Fetch it the same way:

```bash
git clone --filter=blob:none https://github.com/WebAssembly/testsuite tests/spec/testsuite
git -C tests/spec/testsuite checkout "$(tr -d '[:space:]' < tests/spec/testsuite.commit)"
git -C tests/spec/testsuite rev-parse HEAD   # should match testsuite.commit
```

CI (`.github/workflows/{pr,ci}.yml`) runs the corpus on every platform under
`--tier=interp`, and on the 64-bit UNIX legs also under `--tier=jit` and
`--tier=aot`, asserting all three tiers produce an identical pass/fail/skip
tally (the observational-identity invariant, ADR-0001). To bump the pinned
commit, edit `testsuite.commit` and re-check the tallies locally first.

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
| `STAGED` | Would fail, but only on deliberately staged work. Nothing is staged today — Track H shipped exception-handling throwing, the last thing this held — so the column reads 0 |
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
- `(assert_exception (invoke ...))` — run through the interpreter; the
  invocation must throw an uncaught wasm exception (`EWasmException`),
  which Track H's `throw` / `throw_ref` / `try_table` execution produces
- `(assert_trap (module ...) ...)` / `(assert_exhaustion (module ...) ...)` —
  the instantiation-trap form: the module is built and instantiated for real,
  an out-of-bounds active segment traps after earlier ones persist, and a
  trapping start function is judged

Everything else is `SKIP` with a reason, never a silent pass:

| Reason | Applies to |
| --- | --- |
| `no instantiated module` | An `assert_return` / `invoke` whose module did not instantiate — now mostly modules downstream of an unprovided import |
| `needs an execution tier` | An action whose module the assembler cannot yet build for another reason |
| `import not provided by the harness` | A module importing something the harness does not supply |
| `assert_unlinkable` | Linkage is not yet judged (the operand is still assembled and validated as a pre-check) |
| `directive not in the reference grammar` | `assert_malformed_custom`, `assert_invalid_custom`, anything else unrecognised |

Modules are assembled and decoded at command-execution time, never at
script-parse time — otherwise `assert_malformed` could not observe the failure
it exists to observe.

The match against the script's expected string is a **prefix** match, per the
reference interpreter: the expected string must be a prefix of our message. Our
error messages — text, decode, validation, and trap — are therefore part of
conformance, not merely diagnostics.

`STAGED` sets aside a case that was attempted but deliberately deferred, so it is
never counted as a pass. **Nothing populates it today.** It held two things in
turn: before Track G, the `$FD` vector text the assembler could not emit; then,
before Track H, exception-handling *throwing*. The assembler builds the vector
forms and the interpreter executes the throwing now, so both pass and the column
reads 0. The status stays in the harness for the next deferred feature.

## Where the numbers stand

`WebAssembly/testsuite@de54fd27ecf3e68dfd16b6199c548df77b6a2cc1`, 288 scripts:

```text
ROOT      pass=64651 fail=52  skip=611  staged=0 total=65314
PROPOSALS pass=533   fail=356 skip=922  staged=0 total=1811
TOTAL files=288 errors=0 pass=65184 fail=408 skip=1533 staged=0 total=67125
```

`ROOT` is everything outside `proposals/` (the 3.0 target plus the out-of-scope
`legacy/` tree); `PROPOSALS` is the post-3.0 proposal mirrors. Message prefixes
now live as `MSG_*` constants across the decode, validation, assembler, and
runtime units — the interpreter's traps reach the runtime `MSG_*` strings the
binary-only runs never did, and a raise site appends its context after the
prefix rather than in front of it.

Judged commands are `pass + fail` = **~65,592**. The `staged` column is **0**:
Track H shipped exception-handling throwing, so `try_table`, `throw`, and
`throw_ref` execute and `assert_exception` is judged — the whole core 3.0
instruction set now runs. The `skip` column (~1,533) is the residue: assertions
downstream of an unprovided import, host imports the harness does not provide,
and `assert_unlinkable`.

### What the 408 failures are

The split is the headline: **356 are `PROPOSALS`** and only **52 are `ROOT`**, so
the failures cluster in post-3.0 features, not in the 3.0 target — and none is a
SIMD or exception-handling execution failure. None is a wrong-CLASS rejection
between `malformed` and `invalid`.

**`PROPOSALS` (356)** exercise features outside the pinned conformance target
([ADR-0004](../../docs/adr/0004-conformance-target-is-the-3-0-draft.md)):
`custom-descriptors` (descriptor composite types, exact reference types, the
`type … does not have a descriptor` family), `custom-page-sizes` (the `invalid
custom page size` limits flag), `wide-arithmetic` (the `$FC` subopcode), and
threads. They appear as **false rejections** (`expected=""`: the script presents
the module as valid and a 3.0 runtime rejects it — the day the feature lands,
these must be accepted) and as **wording mismatches** on modules upstream also
rejects. The justification holds — 3.0 does not have these features — but the
honest label on the `expected=""` cases is *false rejection*, not diagnostics.

**`ROOT` (52)** are five kinds:

- **Legacy exception handling** (`testsuite/legacy/try_catch.wast`,
  `rethrow.wast`, `throw.wast`, `try_delegate.wast`, 16 cases) — the pre-3.0
  `try`/`catch`/`delegate`/`rethrow` encoding, out of 3.0 scope and staying
  failing (Track H covers the 3.0 `try_table` form only, which passes).
- **The `binary-leb128` and `binary` wording divergences** carried since the
  binary subset — deliberately overlong or over-wide LEB128 whose bytes run past
  the section that declares them, where upstream reads the whole encoding
  (`integer too large` / `integer representation too long`) and our bounded
  `SubReader` reports the section bound first. Our decoder gives every section
  body and code entry a reader bounded by its declared size, which is what makes
  `length out of bounds` and `section size mismatch` right everywhere else.
- **The M7 `extern.convert_any` / `any.convert_extern` imprecision** — a handful
  of `ref_test.wast` / `ref_cast.wast` `assert_return` cases where our result
  does not match the expected extern/any round-trip.
- **Two 3.0 `throw` message-wording edges** (`throw.wast`) — `assert_invalid`
  cases where the module is correctly rejected but our type-mismatch wording
  differs from upstream's (a validator-message divergence, not a throwing bug;
  `try_table.wast` and `throw_ref.wast` pass clean).
- **A few assembler/decoder edges** — `expected=""` text cases the assembler does
  not yet build (`instance.wast`, `id.wast`, `table*.wast`, `memory*.wast`,
  `call_indirect64.wast`) and a few decoder wordings (`binary.wast`,
  `obsolete-keywords.wast`, `ref_func.wast`).

Extract the live signatures rather than trusting this list to stay exact — the
grep in the "Reading the output" section keys on the `got=`/`expected=` pair and
survives corpus bumps. Everything the corpus asserts about the settled 3.0
message wording is still matched, including the `malformed UTF-8 encoding` cases
and the `unknown memory <index>` form, where the index is part of the prefix and
not of the context after it.
