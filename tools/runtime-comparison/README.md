# Runtime comparison harness

This harness compares command-level execution of wasmlight, Wasmtime, Wasmer,
WasmEdge, WAMR, wazero, and wasm3 on identical self-checking WASI preview1
modules. It is a measurement tool, never a CI assertion.

The default suite contains eleven checked workloads:

| Workload | Hot-path boundary |
| --- | --- |
| `startup` | Process launch, artifact load, instantiation, a tiny loop, and `proc_exit` |
| `loop` | 300 million dependent scalar integer iterations |
| `fib` | Recursive one-parameter direct calls through `fib(35)` |
| `memory` | 50 million paired varying-address `i32.store`/`i32.load` operations |
| `memory-load` | 100 million cache-resident varying-address `i32.load` operations |
| `memory-store` | 100 million cache-resident varying-address `i32.store` operations |
| `call` | 50 million generic two-parameter cross-function direct calls |
| `memory-grow` | 4,096 one-page linear-memory growth operations, with every page touched |
| `gc` | Two million struct allocations with a rotating 1,024-object live root set |
| `simd` | One million dependent `i32x4` arithmetic iterations |
| `host-call` | One million WASI monotonic-clock calls and result reads |

## Boundary

- `best` uses a precompiled artifact for wasmlight, Wasmtime, Wasmer, and
  WasmEdge; WAMR AOT when a runnable `wamrc` is present; a pre-populated compiler
  cache for wazero; and wasm3's interpreter. WAMR falls back to its interpreter
  when `wamrc` is absent.
- `interpreter` compares wasmlight, WasmEdge, WAMR, wazero, and wasm3. The
  installed Wasmtime and Wasmer CLIs do not expose equivalent interpreters.
- Compilation and cache population happen before measurement.
- Each sample measures a fresh process from spawn through the module's checked
  `proc_exit`. This is command latency, not an in-process call microbenchmark.
- Each workload exits nonzero when its computed result is wrong.
- One warm-up and seven measured samples are the defaults. Runtime order rotates
  between samples, and the entire run holds `/tmp/wasmlight-perf-gate.lock`.

Workloads run only on peers verified to support their required proposal and
host surface. An unavailable cell is rendered as `—`, not treated as a failed
measurement. GC currently runs on wasmlight and Wasmtime; the current WABT
parser does not accept the Core 3.0 GC text forms, so that fixture is assembled
with `wasm-tools parse`. SIMD runs on wasmlight, Wasmtime, Wasmer, WasmEdge, and
wazero. The host-call workload runs everywhere except wasm3. The other eight
workloads run on all seven peers.

The WAMR project supports AOT and JIT, but its 2.4.5 macOS release publishes
`wamrc` only for x86-64. An arm64 macOS host without Rosetta therefore records
the installed interpreter and labels that limitation. The pinned Linux x86-64
CI tool bundle includes `wamrc` and measures WAMR AOT.

## Prerequisites

Build wasmlight in release mode first:

```sh
lwpt build --mode release
```

The peer commands and fixture tools must be on `PATH`: `wasmtime`, `wasmer`,
`wasmedge`, `iwasm`, `wazero`, `wasm3`, `wat2wasm`, and `wasm-tools`.

## Run

```sh
python3 tools/runtime-comparison/bench.py
```

Generated modules, artifacts, raw samples, and a rendered result table land in
`build/runtime-comparison/`. Use `--help` to select workloads, profiles, sample
counts, or preparation without measurement.

For a focused run, repeat `--workload` as needed:

```sh
python3 tools/runtime-comparison/bench.py \
  --profile best \
  --workload memory-load \
  --workload memory-store \
  --workload gc
```

## Pull-request gate

The `runtime-comparison` job in `.github/workflows/pr.yml` builds release
binaries from the PR base and head, then measures both on one Linux x86-64
runner. It runs the `best` profile against every pinned peer, uploads both raw
JSON reports, and the `runtime-comparison-comment` job updates one marker-based
PR comment.

Peer executables are immutable release assets, except wasm3, which is built from
a pinned commit archive because its published x86-64 ELF traps on GitHub's
runner CPU. Every download has a checked-in SHA-256 digest. The prepared tree is
cached under the GitHub runner tool cache with a key derived from
`install-ci-tools.sh`; changing any version or digest invalidates the whole
cache deliberately.

This is an executable gate, not a numeric performance gate. A broken build,
artifact, fixture, result check, or runtime invocation fails the PR job. Timing
deltas are informational because hosted-runner noise is not a correctness
signal and benchmark values are never CI assertions.
