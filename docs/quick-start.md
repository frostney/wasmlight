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
curl -fsSLO https://github.com/frostney/lwpt/releases/download/0.4.0/lwpt-0.4.0-macos-arm64.tar.gz
curl -fsSLO https://github.com/frostney/lwpt/releases/download/0.4.0/lwpt-0.4.0-checksums.txt
shasum -a 256 -c <(grep macos-arm64 lwpt-0.4.0-checksums.txt)
tar xzf lwpt-0.4.0-macos-arm64.tar.gz
export PATH="$PWD/lwpt-0.4.0-macos-arm64:$PATH"   # or copy lwpt into ~/bin
```

Then set up the project:

```bash
git clone https://github.com/frostney/wasmlight.git && cd wasmlight
lwpt install        # resolve deps from the lwpt release tag, write lwpt.cfg
lefthook install    # pre-commit formatter hook
```

The `testing` and `cli` dependencies resolve from the `frostney/lwpt`
release tag with include filters (see `lwpt.toml`); no sibling checkout is
needed. The committed `.lwpt/modules/` tree plus `lwpt.lock` make
`lwpt install --frozen` work offline (CI mode).

## Build and test

```bash
lwpt build           # all three programs into build/
lwpt test            # co-located unit suites
```

## Run something

```bash
./build/wasmlight inspect module.wasm    # section table + entity counts
./build/wasmlight validate module.wasm   # decode + validate, report the IR
./build/wasmlight --version
./build/wasmbench --iterations 20000     # component benchmarks
```

`inspect` decodes the module and reports its section table plus a
summary of entity counts per index space (imports broken down by kind,
start function and data count when present).

`validate` decodes and then runs the whole static type check, which is
also the pass that lowers the module to the register IR every future
execution tier will consume. One line per module on success:

```console
$ ./build/wasmlight validate tests/fixtures/valid/exports.wasm
tests/fixtures/valid/exports.wasm: valid - 2 function(s) lowered, 2 in the function index space, IR format version 1
```

Both commands take more than one module. A failure names the error class,
because the class is the answer: `EWasmDecodeError` means the bytes are
not a module, `EWasmValidationError` means they are a module that is not
well-typed. The exit status is non-zero if any module failed.

```console
$ ./build/wasmlight validate tests/fixtures/valid/simd.wasm
wasmlight validate: tests/fixtures/valid/simd.wasm: EWasmValidationError: SIMD validation is not implemented ($FD 17 at offset 89)
```

That one is not a bug in the fixture. Vector (`$FD`) validation is
deliberately staged to Track G, and the validator says so rather than
accepting an instruction it has not checked.

The third program, `wasmspec`, runs `.wast` conformance scripts. It judges
the binary-module subset — `assert_malformed`, `assert_invalid`, and
top-level `module` — against decode and validation, and skips everything
that needs an execution tier:

```console
$ ./build/wasmspec tests/spec/testsuite/binary.wast
FAIL tests/spec/testsuite/binary.wast:55 assert_malformed got=malformed expected="END opcode expected" actual="unexpected end of section or function: reading byte at offset 3 (need 1 byte(s), 0 left)"
...
FILE tests/spec/testsuite/binary.wast pass=124 fail=3 skip=0 staged=0 total=127
TOTAL files=1 errors=0 pass=124 fail=3 skip=0 staged=0 total=127
```

A directory argument is walked recursively. See
[testing.md](testing.md) for what the corpus tallies mean and
[`tests/spec/README.md`](../tests/spec/README.md) for fetching it.

Those three commands are the whole shipped surface today — see
[roadmap.md](roadmap.md) for what comes next and in what order.

For the full command set (formatter, benchmarks, CI gates) see
[tooling.md](tooling.md).
