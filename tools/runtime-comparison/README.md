# Runtime comparison harness

This harness compares command-level execution of wasmlight, Wasmtime, Wasmer,
WasmEdge, WAMR, wazero, and wasm3 on identical self-checking WASI preview1
modules. It is a measurement tool, never a CI assertion.

## Boundary

- `best` uses a precompiled artifact for wasmlight, Wasmtime, Wasmer, and
  WasmEdge; a pre-populated compiler cache for wazero; and the interpreter-only
  configurations available from the installed WAMR and wasm3 packages.
- `interpreter` compares wasmlight, WasmEdge, WAMR, wazero, and wasm3. The
  installed Wasmtime and Wasmer CLIs do not expose equivalent interpreters.
- Compilation and cache population happen before measurement.
- Each sample measures a fresh process from spawn through the module's checked
  `proc_exit`. This is command latency, not an in-process call microbenchmark.
- Each workload exits nonzero when its computed result is wrong.
- One warm-up and seven measured samples are the defaults. Runtime order rotates
  between samples, and the entire run holds `/tmp/wasmlight-perf-gate.lock`.

The WAMR project supports AOT and JIT, but its 2.4.5 macOS release publishes
`wamrc` only for x86-64. The benchmark host is arm64 and has no Rosetta, so this
snapshot records WAMR's installed interpreter and labels that limitation.

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
