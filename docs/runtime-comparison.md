# Runtime comparison

This is a dated comparison, not a permanent ranking. Runtime capabilities and
performance move independently, and a benchmark result is meaningful only with
its workload, tier, host, and method attached.

## Bottom line

On the CI x86-64 runner, wasmlight's compiled tier (measured through
`run --aot`) is at a geometric mean of 0.79x Wasmtime's time across the
eleven fixtures, and 0.65x when Wasmtime also runs with epoch interruption,
which wasmlight always polls (ADR-0006). It starts a precompiled command
faster than every compiled peer and beats Wasmtime on SIMD, GC allocation,
and WASI host calls. The remaining gaps are store-heavy memory loops and
`memory.grow`, where Wasmtime's optimizing compiler is ahead, and fib, where
WasmEdge's and WAMR's LLVM AOT are ahead.

The interpreter comparison below predates the JIT and AOT work of
September 2026 and was measured on a different host; it is kept as the
latest interpreter-only data point, not as a current compiled-tier result.

## Product shape

| Runtime | Product centre | Execution engines | Standards / host emphasis | Most useful comparison with wasmlight |
| --- | --- | --- | --- | --- |
| **wasmlight** (main, 2026-09-27) | FreePascal runtime-platform building block | Register interpreter, baseline JIT, per-module AOT cache, and a strict native compiler; JIT/AOT on arm64 and x86-64 UNIX | Pinned Core 3.0 draft including GC, exception handling, SIMD, and tail calls; deny-by-default WASI preview1 subset | The subject: one validated IR shared by every tier, unusually small AOT artifacts, full core scope, and no external compiler backend |
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

Measured 2026-09-27 by the pull-request `runtime-comparison` job
([run 36356488359](https://github.com/frostney/wasmlight/actions/runs/36356488359))
on one GitHub-hosted `Linux-6.17.0-1022-azure-x86_64` runner. The wasmlight
column is PR #159's head `f82a2c4`, whose tree is main `66562d6`. Every cell
is the median wall-clock process time of seven rotated samples after one
warm-up; compilation and cache population are outside the timer, and every
workload verifies its result. The parenthesized ratio is
`wasmlight / runtime`: above 1 means that peer was faster.

### Best available configuration

| Workload | wasmlight | Wasmtime | Wasmer | WasmEdge | WAMR | wazero | wasm3 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| startup | 1.413 | 3.632 (0.39x) | 12.899 (0.11x) | 6.895 (0.20x) | 10.063 (0.14x) | 2.566 (0.55x) | 0.926 (1.53x) |
| loop | 411.323 | 413.758 (0.99x) | 422.914 (0.97x) | 416.834 (0.99x) | 419.773 (0.98x) | 412.216 (1.00x) | 1799.931 (0.23x) |
| fib | 52.672 | 70.845 (0.74x) | 79.112 (0.67x) | 28.278 (1.86x) | 35.439 (1.49x) | 79.637 (0.66x) | 547.720 (0.10x) |
| memory | 30.886 | 33.296 (0.93x) | 43.141 (0.72x) | 28.112 (1.10x) | 33.187 (0.93x) | 57.843 (0.53x) | 438.380 (0.07x) |
| memory-load | 57.897 | 60.855 (0.95x) | 77.920 (0.74x) | 35.418 (1.63x) | 39.158 (1.48x) | 112.323 (0.52x) | 1020.443 (0.06x) |
| memory-store | 58.273 | 49.834 (1.17x) | 77.639 (0.75x) | 36.943 (1.58x) | 56.506 (1.03x) | 112.343 (0.52x) | 576.825 (0.10x) |
| call | 70.701 | 87.096 (0.81x) | 96.892 (0.73x) | 75.838 (0.93x) | 78.762 (0.90x) | 98.884 (0.71x) | 936.541 (0.08x) |
| memory-grow | 33.342 | 23.905 (1.39x) | 34.733 (0.96x) | 38.064 (0.88x) | 35.752 (0.93x) | 110.738 (0.30x) | 127.185 (0.26x) |
| gc | 32.404 | 42.400 (0.76x) | — | — | — | — | — |
| simd | 2.645 | 4.533 (0.58x) | 13.017 (0.20x) | 7.533 (0.35x) | — | 3.401 (0.78x) | — |
| host-call | 54.949 | 112.854 (0.49x) | 190.486 (0.29x) | 95.282 (0.58x) | 39.682 (1.38x) | 61.015 (0.90x) | — |

Times are milliseconds. A dash means the runtime cannot run that fixture
from its CLI. The `memory-grow` and `gc` cells moved by 13–30% between the
base and candidate builds of the same run with no related code change; treat
them as noisy.

### Like-for-like: interruption checks on

wasmlight always polls its epoch. Here each peer also runs with its own
interruption checks compiled in: Wasmtime epoch interruption, WasmEdge
`--interruptible` AOT, and wazero `-timeout`. Wasmer, WAMR AOT, and wasm3
expose no CLI-reachable interruption and are omitted.

| Workload | wasmlight | Wasmtime | WasmEdge | wazero |
| --- | ---: | ---: | ---: | ---: |
| startup | 1.453 | 3.674 (0.40x) | 6.786 (0.21x) | 2.639 (0.55x) |
| loop | 411.797 | 416.796 (0.99x) | 667.901 (0.62x) | 6824.822 (0.06x) |
| fib | 52.886 | 73.533 (0.72x) | 28.453 (1.86x) | 79.708 (0.66x) |
| memory | 30.606 | 48.790 (0.63x) | 121.501 (0.25x) | 1221.931 (0.03x) |
| memory-load | 57.945 | 87.785 (0.66x) | 236.385 (0.25x) | 2270.885 (0.03x) |
| memory-store | 58.299 | 62.254 (0.94x) | 237.339 (0.25x) | 2379.679 (0.02x) |
| call | 71.600 | 115.924 (0.62x) | 116.400 (0.62x) | 1220.706 (0.06x) |
| memory-grow | 26.719 | 25.228 (1.06x) | 40.358 (0.66x) | 114.612 (0.23x) |
| gc | 28.165 | 42.379 (0.66x) | — | — |
| simd | 2.730 | 7.445 (0.37x) | 9.495 (0.29x) | 25.271 (0.11x) |
| host-call | 54.763 | 114.637 (0.48x) | 96.007 (0.57x) | 82.814 (0.66x) |

### Interpreter-only comparison (2026-08-14, Apple M5 Max)

Measured at commit `83c132b9d52a` on a Mac17,6 (arm64, macOS 26.5.2) with the
same method. CI does not run the interpreters, so this is the latest
interpreter-only data point.

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
[`tools/runtime-comparison/`](../tools/runtime-comparison/README.md). It now:

1. assembles eleven checked WAT fixtures and validates the resulting binaries;
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
restored from an installer-content-addressed cache (wasm3 is built once from its
pinned source commit), raw reports are retained as a workflow artifact, and one
sticky PR comment shows the same-runner delta plus the candidate's peer
comparison. The job requires every build and self-checking execution to succeed;
timing changes remain informational and cannot fail a PR.

The boundary is a fresh process through a self-checking WASI `proc_exit`.
Consequently, `startup` measures process launch, artifact/module loading,
instantiation, a 2,000-iteration loop, and one host call. The heavy workloads
use the same boundary but are long enough to be dominated by guest execution.
They are not in-process call microbenchmarks.

The expanded suite keeps materially different runtime costs separate: paired
memory traffic, load-only traffic, store-only traffic, generic cross-function
calls, repeated `memory.grow`, GC allocation with a bounded live root set,
dependent SIMD arithmetic, and repeated WASI host calls. Every fixture checks
its final value or invariant before a successful `proc_exit`. Workloads are
capability-scoped rather than weakened to the least capable peer: unsupported
runtime cells are recorded as unavailable. See the harness README for the
current capability matrix.

## What this does not establish

- The compiled-tier numbers come from one GitHub-hosted x86-64 runner; the CI
  job does not measure aarch64, and the runner's CPU model is not recorded.
- It does not measure compilation time, peak RSS, repeated instantiation
  throughput, multi-instance density, or concurrent stores.
- Eleven focused kernels do not predict a full application mix.
- No security or correctness ranking follows from speed. Conformance claims
  require each project's own pinned corpus and exact feature configuration.

The next useful benchmark expansion is repeated instantiation throughput and
one real toolchain-compiled WASI application. The focused kernels should remain
diagnostic inputs rather than be treated as an application-level ranking.
