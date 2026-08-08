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
lwpt build           # both programs into build/
lwpt test            # co-located unit suites
```

## Run something

```bash
./build/wasmlight inspect module.wasm    # decode and report the section table
./build/wasmlight --version
./build/wasmbench --iterations 20000     # component benchmarks
```

`inspect` is the whole shipped surface today — see
[roadmap.md](roadmap.md) for what comes next and in what order.

For the full command set (formatter, benchmarks, CI gates) see
[tooling.md](tooling.md).
