# wasmlight

A WebAssembly runtime for Object Pascal, built for speed on a conformant
core. FreePascal throughout, built and tested with
[lwpt](https://github.com/frostney/lwpt). One validated module feeds three
execution tiers behind a single seam — an interpreter, a baseline JIT, and
an ahead-of-time compiler — under a deny-by-default host surface of WASI
preview1 (the Component Model is post-v1,
[ADR-0014](docs/adr/0014-the-component-model-is-deferred-to-post-v1.md)).
See [docs/architecture.md](docs/architecture.md).

## Status

Pre-0.1, early. What is shipped today is the whole path from bytes — or
from text — to a running module: the bounds-checked binary reader with
full LEB128 handling, the decoded module model, the structural decoder, the
validator that emits the register IR, the runtime layer below the tier seam
(store, instances, the memory-access chokepoint, traps, instantiation, and
the precise collector), and the interpreter tier that executes the IR — the
**complete core wasm 3.0 instruction set**, `v128` SIMD and exception
handling (`throw` / `throw_ref` / `try_table`) included — plus a wat
text-format assembler. On top of that core sits the host surface: the
`Wasm.Engine` embedding API and a deny-by-default WASI preview1 host, so
the runtime now **runs real WASI programs** — `wasmlight run
hello.wasm` prints `hello` and exits 0, and a program granted a preopen
reads the filesystem through it. It is driven by `wasmlight inspect` /
`wasmlight validate` / `wasmlight run`, and `wasmspec` runs the upstream
conformance corpus — assembling text modules, validating, instantiating,
and executing the assertions, SIMD judged per lane and `assert_exception`
judged. Only the baseline JIT and AOT tiers (performance, not behaviour)
are staged in [docs/roadmap.md](docs/roadmap.md) — that file, not this one,
is the honest picture of what exists.

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

`wasmlight run` executes a WASI preview1 command module to a process exit
code, deny-by-default — stdio, clock, and random only, unless `--dir` grants
a preopened directory or `--env` sets a variable:

```text
$ ./build/wasmlight run tests/fixtures/wasi/hello.wasm
hello
$ echo $?
0
```

`wasmspec` runs the upstream `.wast` conformance corpus — assembling text
modules, validating, instantiating, and executing `assert_return` /
`assert_trap` / `invoke` through the interpreter:

```text
$ ./build/wasmspec tests/spec/testsuite
...
ROOT      pass=64651 fail=52  skip=611  staged=0 total=65314
PROPOSALS pass=533   fail=356 skip=922  staged=0 total=1811
TOTAL files=288 errors=0 pass=65184 fail=408 skip=1533 staged=0 total=67125
```

SIMD is judged per lane (Track G) and exception handling is judged (Track
H), so `staged` is 0 and the interpreter executes all of core wasm 3.0; the
failures are dominated by post-3.0 proposals outside the pinned 3.0 target,
not 3.0 regressions.

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
