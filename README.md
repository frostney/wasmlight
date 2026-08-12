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

Pre-0.1, early — but the roadmap is complete. What is shipped today is the
whole path from bytes — or from text — to a running module: the
bounds-checked binary reader with full LEB128 handling, the decoded module
model, the structural decoder, the validator that emits the register IR,
the runtime layer below the tier seam (store, instances, the memory-access
chokepoint, traps, instantiation, and the precise collector), and **three
interchangeable execution tiers** over that IR — the interpreter (the tier
of record, on every platform), a **baseline JIT**, and an **ahead-of-time
compiler** — each executing the **complete core wasm 3.0 instruction
set**, `v128` SIMD and exception handling (`throw` / `throw_ref` /
`try_table`) included, plus a wat text-format assembler. The JIT and AOT
run in two backends, aarch64 and x86-64, on a 64-bit UNIX host; on Windows
and 32-bit targets the runtime is interpreter-only, and still fully
conformant. On top of that core sits the host surface: the `Wasm.Engine`
embedding API and a deny-by-default WASI preview1 host, so the runtime
**runs real WASI programs** — `wasmlight run hello.wasm` prints `hello`
and exits 0, and a program granted a preopen reads the filesystem through
it. It is driven by `wasmlight inspect` / `wasmlight validate` /
`wasmlight run` / `wasmlight aot`, and `wasmspec` runs the upstream
conformance corpus in any tier (`--tier=interp|jit|aot`) — assembling text
modules, validating, instantiating, and executing the assertions, SIMD
judged per lane and `assert_exception` judged. All three tiers produce
**byte-identical** corpus results (**65,204 pass**) on both arches.
[docs/roadmap.md](docs/roadmap.md) is the honest picture of exactly what
exists and what remains (broader optimizing-compiler work, the characterized
non-3.0-core corpus failures, and cross-platform CI validation).

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

On a 64-bit UNIX host, `wasmlight aot` compiles a module ahead of time to a
`.waot` artifact, and `run --aot` loads it for instant startup — always
re-validating the module first and falling back to the interpreter if the
artifact is stale, wrong-arch, or absent (`--no-aot` forces interpret):

```text
$ ./build/wasmlight aot tests/fixtures/wasi/hello.wasm -o hello.waot
$ ./build/wasmlight run --aot hello.waot tests/fixtures/wasi/hello.wasm
hello
```

`wasmspec` runs the upstream `.wast` conformance corpus — assembling text
modules, validating, instantiating, and executing `assert_return` /
`assert_trap` / `invoke` through the interpreter:

```text
$ ./build/wasmspec tests/spec/testsuite
...
ROOT      pass=64671 fail=33  skip=610  staged=0 total=65314
PROPOSALS pass=533   fail=356 skip=922  staged=0 total=1811
TOTAL files=288 errors=0 pass=65204 fail=389 skip=1532 staged=0 total=67125
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
