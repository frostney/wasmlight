# Runtime comparison

This is a dated comparison, not a permanent ranking. Runtime capabilities and
performance move independently, and a benchmark result is meaningful only with
its workload, tier, host, and method attached.

## Bottom line

wasmlight is already a credible low-latency, self-contained runtime rather than
a miniature copy of an optimizing server engine. On this host it starts a
precompiled command faster than every measured peer, and its baseline AOT is
within 1.48–1.51x of the optimizing compilers on a dependency-heavy integer
loop. The main performance gap is code quality around calls and memory:
optimizing compiled peers are 7.96–15.64x faster on recursive Fibonacci and
2.66–4.66x faster on varying-address memory.

The interpreter has a different shape. It starts fastest and beats the explicit
WasmEdge and wazero interpreters on all three heavy workloads, but WAMR and
wasm3 are 4.62–9.32x faster. That makes fast interpreter dispatch and compiled
call lowering the two clearest performance study targets.

## Product shape

| Runtime | Product centre | Execution engines | Standards / host emphasis | Most useful comparison with wasmlight |
| --- | --- | --- | --- | --- |
| **wasmlight 0.1.0** | FreePascal runtime-platform building block | Register interpreter, baseline JIT, per-module AOT cache; JIT/AOT on arm64 and x86-64 UNIX | Pinned Core 3.0 draft including GC, exception handling, SIMD, and tail calls; deny-by-default WASI preview1 subset | The subject: one validated IR shared by every tier, unusually small AOT artifacts, full core scope, and no external compiler backend |
| **Wasmtime 47.0.3** | Production standalone and embeddable runtime | Optimizing Cranelift compilation and serialized precompiled modules | Core Wasm, WASI, and the Component Model; strong security and resource-control posture | Performance and production-hardening ceiling; broader component ecosystem. [Official introduction](https://docs.wasmtime.dev/) |
| **Wasmer 7.2.1** | Cross-platform runtime and package ecosystem | Singlepass, Cranelift, LLVM, plus delegated V8/browser engines | Broad proposal matrix and WASI/WASIX application surface | Backend choice, packaging, and portability across native and constrained platforms. [Runtime features](https://docs.wasmer.io/runtime/features/) |
| **WasmEdge 0.17.1** | Cloud-native, edge, and AI-oriented runtime | Interpreter, JIT, LLVM AOT | Core 3.0 is the CLI default; resource limits, statistics, and plugin extensions | The closest three-mode CLI comparison and an optimizing AOT ceiling. [CLI guide](https://wasmedge.org/docs/start/build-and-run/cli/) |
| **WAMR 2.4.5** | Embedded, IoT, TEE, and small-footprint runtime | Classic/fast interpreters, fast/LLVM JIT, LLVM AOT depending on build | Highly configurable WASI and platform surface | The most relevant footprint and fast-interpreter reference. [Running modes](https://bytecodealliance.github.io/wamr.dev/blog/introduction-to-wamr-running-modes/) |
| **wazero 1.12.0** | Pure-Go embedding | Native-code compiler/cache and interpreter | Core 1.0/2.0 focus, built-in selective WASI preview1, zero CGO dependencies | Language-native embedding, cache behavior, and Go portability. [Project overview](https://wazero.io/) and [engine design](https://wazero.io/docs/how_do_compiler_functions_work/) |
| **wasm3 0.5.0** | Tiny, portable interpreter for constrained systems | Interpreter | Broad baseline Wasm and partial WASI; no fixed-width SIMD, exception handling, or tail calls; minimal-maintenance phase | The dispatch-speed and minimum-footprint reference, not a full Core 3.0 substitute. [Project status](https://github.com/wasm3/wasm3) |

wasmlight's differentiator is the combination, not a single exclusive feature:
full pinned Core 3.0 behavior, three observationally identical tiers, a native
FreePascal embedding surface, capability-denying host defaults, and AOT as a
validated cache rather than a trust boundary. Wasmtime is the stronger default
when maximum optimized throughput, Component Model support, and a mature
multi-language ecosystem matter more. WAMR or wasm3 are stronger starting
points for the smallest embedded interpreter. wazero is the obvious choice for
a zero-CGO Go application. Wasmer and WasmEdge offer broader backend or plugin
ecosystems than wasmlight intends to carry.

## Performance snapshot

Measured 2026-08-14 at wasmlight commit
`83c132b9d52a4a2ec8826b772157d6c24885999c` on a Mac17,6 with an Apple M5 Max,
arm64, macOS 26.5.2. The remote-default baseline was
`a7d9565304ee1138b4e76763810559e7ba1112d1`.

Every cell below is median wall-clock process time in milliseconds from seven
samples after one warm-up. Lower is better. Compilation is outside the timer.
The parenthesized ratio is `wasmlight / runtime`: above 1 means that peer was
faster; below 1 means wasmlight was faster.

### Best available installed configuration

| Workload | wasmlight AOT | Wasmtime AOT | Wasmer AOT | WasmEdge AOT | WAMR interp | wazero cached compiler | wasm3 interp |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| startup | 2.191 (1.00x) | 3.510 (0.62x) | 5.695 (0.38x) | 9.008 (0.24x) | 2.700 (0.81x) | 3.012 (0.73x) | 2.768 (0.79x) |
| nonlinear loop, 300M | 503.042 (1.00x) | 334.220 (1.51x) | 336.933 (1.49x) | 339.525 (1.48x) | 1126.788 (0.45x) | 334.321 (1.50x) | 830.913 (0.61x) |
| recursive fib(35) | 353.371 (1.00x) | 32.971 (10.72x) | 34.324 (10.30x) | 22.589 (15.64x) | 222.811 (1.59x) | 44.399 (7.96x) | 216.629 (1.63x) |
| varying-address memory, 50M | 82.054 (1.00x) | 17.602 (4.66x) | 20.075 (4.09x) | 20.477 (4.01x) | 194.098 (0.42x) | 30.904 (2.66x) | 179.126 (0.46x) |

This table is intentionally labelled “installed configuration.” WAMR supports
AOT and JIT as a product, but the official 2.4.5 macOS `wamrc` release is
x86-64-only and this arm64 host has no Rosetta. Its row therefore measures the
installed interpreter, not WAMR's performance ceiling. wasm3 is
interpreter-only. The wazero cache was populated before timing.

For the nonlinear-loop artifact, sizes were 830 bytes (wasmlight), 50,832 bytes
(Wasmtime), 7,608 bytes (Wasmer), and 4,743 bytes (WasmEdge). These formats do
not package identical metadata, so the values explain load behaviour but are
not a general footprint ranking.

### Interpreter-only comparison

| Workload | wasmlight | WasmEdge | WAMR | wazero | wasm3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| startup | 2.096 (1.00x) | 8.855 (0.24x) | 2.679 (0.78x) | 2.979 (0.70x) | 2.678 (0.78x) |
| nonlinear loop, 300M | 5525.538 (1.00x) | 11802.591 (0.47x) | 1147.170 (4.82x) | 22327.548 (0.25x) | 853.836 (6.47x) |
| recursive fib(35) | 1056.130 (1.00x) | 1082.089 (0.98x) | 228.446 (4.62x) | 1431.871 (0.74x) | 227.186 (4.65x) |
| varying-address memory, 50M | 1689.483 (1.00x) | 2752.320 (0.61x) | 194.423 (8.69x) | 5140.498 (0.33x) | 181.224 (9.32x) |

The installed Wasmtime and Wasmer CLIs do not expose an equivalent interpreter,
so they are absent rather than relabelled as one.

## Method

The reusable harness is in
[`tools/runtime-comparison/`](../tools/runtime-comparison/README.md). It:

1. assembles four checked WAT fixtures and validates the resulting binaries;
2. precompiles all available artifacts and populates wazero's native cache;
3. verifies every command exits successfully before accepting a timing;
4. holds `/tmp/wasmlight-perf-gate.lock` for the complete measurement;
5. rotates runtime order for every sample; and
6. records every sample, min/max spread, runtime version, command, artifact
   size, host identity, Git commit, and module SHA-256 in
   `build/runtime-comparison/results.json`.

The command is:

```sh
python3 tools/runtime-comparison/bench.py --samples 7
```

Pull requests run the `best` profile for the base and candidate release binaries
on one Linux x86-64 runner. Pinned, checksum-verified peer executables are
restored from an installer-content-addressed cache, raw reports are retained as
a workflow artifact, and one sticky PR comment shows the same-runner delta plus
the candidate's peer comparison. The job requires every build and self-checking
execution to succeed; timing changes remain informational and cannot fail a PR.

The boundary is a fresh process through a self-checking WASI `proc_exit`.
Consequently, `startup` measures process launch, artifact/module loading,
instantiation, a 2,000-iteration loop, and one host call. The heavy workloads
use the same boundary but are long enough to be dominated by guest execution.
They are not in-process call microbenchmarks.

The substantive compiled-workload spreads were 0.38–4.24%, except wazero's
memory result at 29.69%; treat that cell as directional. Startup spreads were
3.48–16.02%, expected for 2–9 ms process measurements. wasmlight's interpreter
loop spread was 17.08%; other heavy interpreter cells were below 10%.

## What this does not establish

- It is one Apple Silicon host, not a cross-platform ranking.
- It does not measure compilation time, peak RSS, host-call throughput,
  multi-instance density, or concurrent stores.
- Four small kernels do not predict a full application mix.
- No security or correctness ranking follows from speed. Conformance claims
  require each project's own pinned corpus and exact feature configuration.
- WAMR AOT/JIT still needs a native arm64 `wamrc` build before its performance
  ceiling can be compared fairly.

The next useful benchmark expansion is host-call and instantiation throughput,
followed by one real toolchain-compiled WASI application. For runtime
optimization, the current evidence says to profile recursive call/return first,
then the memory chokepoint, while protecting wasmlight's startup and artifact
size advantages.
