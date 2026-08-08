# Testing

## Executive Summary

- `lwpt test` discovers, compiles, and runs `source/units/*.Test.pas` as
  independent programs. Two suites today, 33 tests, all green.
- Unit suites are co-located with the unit they cover and carry the
  malformed-input cases as literal bytes.
- The upstream WebAssembly spec testsuite is the intended external
  conformance net and **is not wired up yet** — until it is, no
  conformance claim is verified.
- Two framework gotchas bite newcomers; both are listed below.

## Running

```bash
lwpt test               # every suite
lwpt test --jobs 4      # cap concurrency
lwpt test --bail 1      # stop at the first failure
lwpt test --verbose     # replay successful logs
```

Each `*.Test.pas` is a self-contained program using
`TestingPascalLibrary` from lwpt's `testing` package. The runner exits
non-zero if any test or compile fails.

## The three tiers

| Tier | What it proves | Status |
| --- | --- | --- |
| Co-located unit suites | The decoder matches *our reading* of the spec | shipped |
| Fixture cross-check | It matches *what toolchains actually emit* | shipped |
| Spec testsuite | It matches *the spec*, judged externally | planned |

The middle tier exists because the first two claims are not the same one.
The section-order bug this project fixed was invisible to hand-written
tests precisely because the same misreading produced both the code and
the fixture that was supposed to check it. Real toolchain output does not
share our misconceptions.

## Fixture cross-check

`tests/fixtures/` holds 22 real modules — 11 valid, 11 malformed —
assembled by **wabt 1.0.41** and independently validated by
**wasm-tools 1.255.0** as an oracle. `Wasm.Fixtures.Test` decodes every
one: valid modules must decode, malformed ones must be rejected, and no
section extent may fall outside its module.

Neither tool is needed to *run* the tests — the `.wasm` files are
committed. They are needed only to regenerate the corpus, via
`tests/fixtures/regenerate.sh`. Each fixture's `.wat` source sits beside
it; see [`tests/fixtures/README.md`](../tests/fixtures/README.md) for what
each one covers.

Two fixtures earn their place specifically:

- **`datacount.wasm`** — a passive data segment plus `memory.init` forces
  a data count section, which the grammar places *before* the code
  section. Id 12 precedes id 10. This is real wabt output, and a decoder
  written on "ids must increase" rejects it.
- **`tags.wasm`** — the second divergence, tag (id 13) between memory
  (id 5) and global (id 6).

The corpus size is asserted against a floor, so a corpus that vanishes
fails loudly instead of passing vacuously.

One trap worth knowing before regenerating: **`wat2wasm --enable-all` does
not produce Wasm 3.0.** It silently enables the experimental compact-imports
proposal, which re-encodes the import section into a grouped form that
`wasm-tools` rejects. `regenerate.sh` pins an explicit feature list
instead.

## What the unit suites cover

| Suite | Covers |
| --- | --- |
| `Wasm.Binary.Test` | LEB128 boundary encodings (u32/u64/s32/s64 extremes), and every rejection path: overlong, over-wide, truncated, unterminated. Plus fixed-width reads, names, sub-reader bounds, cursor arithmetic. |
| `Wasm.Decoder.Test` | Preamble acceptance and rejection, section walk and extents, ordering rules, duplicate sections, custom-section names and the overrun case, section lookup. |

Malformed modules are assembled byte-by-byte next to the assertion rather
than loaded from fixtures: each case *is* a specific malformation, and
spelling it inline puts the defect where the reader is already looking.
Broad well-formed coverage is the spec testsuite's job, not theirs.

## Framework gotchas

Both of these produce confusing failures and both are already worked
around in the existing suites — follow the existing pattern rather than
rediscovering them:

1. **FPC will not parse a generic call as the lone statement of an
   `on ... do`.** `on E: EFoo do Expect<Boolean>(True).ToBe(True);` fails
   to compile with "Illegal expression". Set a flag in the handler and
   assert after the `try`.
2. **The runner fails any test that records no assertion.** A rejection
   test that only calls `Fail` on the bad path asserts nothing when it
   passes. Assert the outcome instead — the suites use an
   `AssertRejected` helper that compares a `'<case>: rejected'` string, so
   the happy path records an assertion and the failure message names the
   case.

## Spec testsuite (planned)

The upstream corpus at
[WebAssembly/testsuite](https://github.com/WebAssembly/testsuite) is the
external conformance net, in the role the Autobahn suite plays for the
sibling duetto project: an independent judge that the project does not
get to grade itself against.

Its actual shape, measured against `WebAssembly/testsuite@main`: **288
`.wast` files** (257 of them the 3.0 root corpus), ~192,500 lines, and
**~64,100 assertions** — `assert_return` 53,291, `assert_trap` 5,252,
`assert_invalid` 3,009, `assert_malformed` 2,208, `assert_unlinkable` 262,
`assert_exception` 41, `assert_exhaustion` 15.

Intended shape, once there is an execution tier to point it at:

- The corpus is fetched, not vendored — `tests/spec/testsuite/` is
  gitignored, and `tests/spec/` holds only the harness configuration.
- A `wasmspec` program under `source/apps/` runs the `.wast` scripts and
  judges assertion outcomes, including the `assert_malformed` and
  `assert_invalid` cases that exercise decode and validation.
- Once a second execution tier exists, the harness runs per tier: every
  tier must produce identical outcomes
  ([ADR-0001](adr/0001-tiered-execution-seam.md)), so the suite doubles
  as the differential test between them.

Five requirements the corpus imposes on that harness, none of them
optional:

1. **Lazy decoding.** `(module quote ...)` and `(module binary ...)` —
   1,311 and 1,069 occurrences — must be parsed or decoded at *command
   execution* time, not script-parse time. Decoding eagerly means
   `assert_malformed` can never observe the failure it exists to observe.
2. **Failure strings are prefix-matched.** The reference interpreter
   checks that the expected string is a prefix of the actual message. Our
   error messages are therefore part of conformance, not merely
   diagnostics — a reworded message can fail the suite.
3. **NaN classes, not bit patterns.** `nan:canonical` (3,283) and
   `nan:arithmetic` (3,391) rule out bitwise float comparison.
4. **`(either ...)` results** (32 occurrences) for relaxed-SIMD outcomes
   that are implementation-defined within a documented set.
5. **Host references** — `(ref.extern n)` (140) and `(ref.host n)` — need
   a host-reference notion in the harness itself.

Two traps: `assert_malformed_custom` and `assert_invalid_custom` are
testsuite-local extensions absent from the reference grammar, so the
parser must not choke on them; and `assert_return` is 83% of all
assertions but is concentrated in the SIMD files, so **sequence by file,
not by assertion count** — a majority of assertions is not a majority of
features.

Until this exists, [roadmap.md](roadmap.md) is where it sits in the order
of work, and documentation must not describe conformance as verified.

## Boundaries

- Nothing in the test stack touches the external network.
- Benchmarks are not tests. `wasmbench` numbers never become CI
  assertions — see the "Honest measurement" principle in
  [VISION.md](../VISION.md).
