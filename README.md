# wasmlight

A WebAssembly runtime for Object Pascal, built for speed on a conformant
core. FreePascal throughout, built and tested with
[lwpt](https://github.com/frostney/lwpt). One validated module feeds three
execution tiers behind a single seam — an interpreter, a baseline JIT, and
an ahead-of-time compiler — under a host surface of WASI preview1 and the
Component Model. See [docs/architecture.md](docs/architecture.md).

## Status

Pre-0.1, early. What is shipped today is the whole path from bytes to a
validated, lowered module, plus the runtime state a tier will run on: the
bounds-checked binary reader with full LEB128 handling, the decoded module
model, the structural decoder, the validator that emits the register IR,
and the runtime layer below the tier seam (store, instances, the
memory-access chokepoint, traps, instantiation, and the precise
collector). It is driven by `wasmlight inspect` / `wasmlight validate`, and
`wasmspec` judges the upstream corpus's binary subset against decode and
validation. The execution tiers and the host surface are staged in
[docs/roadmap.md](docs/roadmap.md) — that file, not this one, is the honest
picture of what exists.

The project's durable direction and delivery gates live in
[VISION.md](VISION.md), [DEFINITION_OF_READY.md](DEFINITION_OF_READY.md),
and [DEFINITION_OF_DONE.md](DEFINITION_OF_DONE.md).

## Quick start

```bash
brew install frostney/tap/lwpt   # or the release tarball — see docs/quick-start.md
git clone https://github.com/frostney/wasmlight.git && cd wasmlight
lwpt install     # resolve deps, write lwpt.cfg
lwpt build       # all three programs, into build/
lwpt test        # co-located unit suites
```

## Usage

```bash
./build/wasmlight inspect module.wasm
```

```text
module.wasm: WebAssembly module, binary version 1, 37 bytes, 4 section(s)

SECTION                  OFFSET       SIZE
type                         10          4
function                     16          2
code                         20          4
custom "name"                26         11
```

`wasmspec` runs the upstream `.wast` conformance corpus over the subset the
shipped layers can judge — the binary-module `assert_malformed`,
`assert_invalid`, and top-level `module` cases:

```text
$ ./build/wasmspec tests/spec/testsuite
...
TOTAL files=288 errors=0 pass=1034 fail=35 skip=66050 staged=6 total=67125
```

For the full command set and every development command, see
[docs/quick-start.md](docs/quick-start.md) and
[docs/tooling.md](docs/tooling.md).

## Background

WebAssembly is a small spec with an unforgiving conformance surface: the
value of a runtime is that it traps exactly where the spec says and
rejects exactly what the spec says is invalid. wasmlight puts every such
rule in decode and validation, once, before any execution tier sees the
code — so the interpreter, the baseline JIT, and the AOT compiler are
three implementations of *speed*, not three implementations of *the
spec*. A tier that is faster because it behaves differently is a bug
([ADR-0001](docs/adr/0001-tiered-execution-seam.md)).

The performance target is the C and Rust runtimes, measured honestly and
never wired into a CI assertion. The rationale is in
[VISION.md](VISION.md).

## Contribution

Install the [lwpt](https://github.com/frostney/lwpt) release binary, then
`lwpt install` + `lwpt test`. See
[docs/quick-start.md](docs/quick-start.md).

## References

- [Agent instructions](AGENTS.md)
- [Glossary](CONTEXT.md)
- [Architecture decisions](docs/adr/)
- [License](LICENSE) (MIT)
