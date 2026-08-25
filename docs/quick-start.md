# Quick start

## Executive Summary

- Prerequisites: FPC 3.2.2 and the lwpt release binary on PATH; Lefthook
  for the pre-commit hook.
- `lwpt install` resolves dependencies, `lwpt build` compiles the
  programs into `build/`, `lwpt test` runs the co-located unit suites.
- Homebrew is the shortest path to lwpt; the release tarball is the
  fallback and is what CI uses.

## Setup

Install lwpt from the maintainer's tap (it depends on `fpc`, so this
brings the compiler too):

```bash
brew install frostney/tap/lwpt
```

Or from the release, if you are not on Homebrew — pick the archive for
your platform (`linux-x64`, `linux-arm64`, `macos-arm64`, `macos-x64`
tarballs, or the `windows-x64` / `windows-x86` zips):

```bash
curl -fsSLO https://github.com/frostney/lwpt/releases/download/0.6.0/lwpt-0.6.0-macos-arm64.tar.gz
curl -fsSLO https://github.com/frostney/lwpt/releases/download/0.6.0/lwpt-0.6.0-checksums.txt
shasum -a 256 -c <(grep macos-arm64 lwpt-0.6.0-checksums.txt)
tar xzf lwpt-0.6.0-macos-arm64.tar.gz
export PATH="$PWD/lwpt-0.6.0-macos-arm64:$PATH"   # or copy lwpt into ~/bin
```

Then set up the project:

```bash
git clone https://github.com/frostney/wasmlight.git && cd wasmlight
lwpt install        # resolve deps from the lwpt release tag, write lwpt.cfg
lefthook install    # pre-commit formatter + agent-reference hooks
```

The `testing` and `cli` dependencies resolve from the `frostney/lwpt`
release tag with include filters (see `lwpt.toml`); no sibling checkout is
needed. The committed `.lwpt/modules/` tree plus `lwpt.lock` make
`lwpt install --frozen` work offline (CI mode).

## Build and test

```bash
lwpt build           # all four programs into build/
lwpt test            # co-located unit suites
```

## Run something

```bash
./build/wasmlight inspect module.wasm    # section table + entity counts
./build/wasmlight validate module.wasm   # decode + validate, report the IR
./build/wasmlight run module.wasm        # run a WASI preview1 command
./build/wasmlight compile module.wasm -o app  # CLI is registered; native emission is not shipped
./build/wasmlight --version
./build/wasmbench --workload loop --tier jit --samples 5
# workloads: decode, leb128, startup, loop, fib, memory, numeric, simd
# size with --execution-iterations, --fib-input, --memory-iterations, or
# --numeric-iterations / --simd-iterations; tier defaults to all
```

`inspect` decodes the module and reports its section table plus a
summary of entity counts per index space (imports broken down by kind,
start function and data count when present).

`validate` decodes and then runs the whole static type check, which is
also the pass that lowers the module to the register IR every future
execution tier will consume. One line per module on success:

```console
$ ./build/wasmlight validate tests/fixtures/valid/exports.wasm
tests/fixtures/valid/exports.wasm: valid - 2 function(s) lowered, 2 in the function index space, IR format version 2
```

Both commands take more than one module. A failure names the error class,
because the class is the answer: `EWasmDecodeError` means the bytes are
not a module, `EWasmValidationError` means they are a module that is not
well-typed. The exit status is non-zero if any module failed.

The `v128` vector set now validates like anything else (Track G) — the
fixture that exercises it is no exception:

```console
$ ./build/wasmlight validate tests/fixtures/valid/simd.wasm
tests/fixtures/valid/simd.wasm: valid - 5 function(s) lowered, 5 in the function index space, IR format version 2
```

The IR format version is **2**: it bumped from 1 when Track G appended the
vector ops.

The third program, `wasmspec`, runs `.wast` conformance scripts. It
assembles text modules, decodes, validates, instantiates, and *executes*
the assertions through the interpreter — `assert_return`, `assert_trap`,
`invoke`, and `assert_exhaustion` — prefix-matching messages and comparing
results:

```console
$ ./build/wasmspec tests/spec/testsuite/i32.wast
FILE tests/spec/testsuite/i32.wast pass=460 fail=0 skip=0 staged=0 total=460
ROOT pass=460 fail=0 skip=0 staged=0 total=460
PROPOSALS pass=0 fail=0 skip=0 staged=0 total=0
TOTAL files=1 errors=0 pass=460 fail=0 skip=0 staged=0 total=460
```

A directory argument is walked recursively, and the aggregate splits `ROOT`
(core plus the mirror's `custom/` and `legacy/` trees) from `PROPOSALS`.
The 257 pinned core scripts are clean at `pass=65188 fail=0 skip=0 staged=0`.
Over the whole recursive mirror the tally is `pass=65851 fail=368 skip=904
staged=0` across 288 files; the residue is confined to post-3.0 proposals,
testsuite-local custom directives, and the explicitly out-of-scope legacy
exception encoding.
See [testing.md](testing.md) for what the tallies mean and
[`tests/spec/README.md`](../tests/spec/README.md) for fetching the corpus.

## Run a WASI program

`wasmlight run` executes a real WASI preview1 command to a process exit
code. The committed hello-world fixture prints to stdout through
`fd_write` and returns:

```console
$ ./build/wasmlight run tests/fixtures/wasi/hello.wasm
hello
$ echo $?
0
```

The capability model is **deny-by-default**: a bare `run` grants the guest
stdio, the clock, and random, and nothing else — no environment, no
filesystem. `--env KEY=VALUE` adds exactly the variables named, and `--dir
GUEST=HOST` grants a preopened directory, which is the *only* route to the
host filesystem; every path inside it is contained, so a `..` escape or an
absolute path is refused before any OS call. Arguments after the module
(or after `--`) are passed to the guest as argv:

```bash
./build/wasmlight run --dir /data=./out --env LANG=C app.wasm arg1 arg2
```

Those programs are the shipped surface today: decode, validate,
instantiate, and execute the **complete core wasm 3.0 instruction set** —
every numeric, reference, GC, SIMD, and exception-handling instruction —
conformance-tested against the pinned core corpus (65,188 pass, no failures or
skips),
**and run WASI preview1 command modules** under deny-by-default sandboxing.
`wasmlight-shell` is the interpreter-free runtime-shell template; it is
built with the other programs and is not a user-facing compile command.
See [roadmap.md](roadmap.md) for what comes next and in what order.

For the full command set (formatter, benchmarks, CI gates) see
[tooling.md](tooling.md).
