# Changelog

All notable changes to wasmlight are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); entries are generated from Conventional Commits by git-cliff.

## [0.2.1] - 2026-09-28

### Bug Fixes

- find the shell catalog from the OS executable path, not argv[0] (#174)

### Documentation

- record the 0.2.0 retrospective lessons (#173)
- record WIT as rejected for connectors and the 2026-09-27 re-plan handoff (#147)
## [0.2.0] - 2026-09-28

### Bug Fixes

- refuse DOS device names under Windows preopens (#164)
- compile tail calls wider than 1024 slots natively in every tier (#159)
- contain preopens against symlinks and junctions on Windows (#160)
- keep class field order in release builds so baked offsets match Wasm.Target (#140)
- keep v128 values in GC fields, array elements, and exception payloads (#137)
- stop ARM64 inline struct.new freeing live structs and corrupting headers (#138)
- keep queued callbacks in order and reject non-command _start in run (#127)
- enforce exact pinned core conformance in every tier (#118)
- satisfy pinned core behavior on i386 (#124)
- reject incompatible native command entry signatures (#120)
- cancel notifications when bindings are released (#119)
- restore main workflows and an interpreter-free Linux shell (#114)
- compile large frames, wide calls, and out-of-range Arm64 branches (#104)
- restore i386 Windows pre-merge coverage (#26)

### Documentation

- bring roadmap, vision, ADR-0015, and runtime comparison to current truth (#165)
- describe the shipped native compiler contract and shared JIT units accurately (#129)
- align native compiler status with shipped behavior (#122)
- record the strict native compiler contract (#92)
- publish native compiler roadmap (#91)
- harden optimization-wave gates (#27)
- prevent invalid runtime benchmark comparisons (#22)

### Internal

- run an independent x64 write-back .wast net in every tier (#133)
- locate non-core tier divergences and keep passing logs quiet (#130)
- require each tier to really run and keep non-core output identical across tiers (#128)
- refresh code-review and engineering-standards skills to current upstream (#126)
- share memory and GC instruction helpers (#121)
- migrate project workflows to current upstream (#117)
- bump lwpt to 0.7.0 (#116)
- one shared v128 op body for both backends (#14)
- classify internal invariant defects as EWasmInternal (#13)
- sync known-good-route skills and add audit/delivery set (#12)
- require every pull-request branch to contain the main tip (#17)
- run the fast gate on pull requests to any base branch (#16)

### New Features

- embed connector plans and call native libraries from compiled executables (#162)
- embed immutable WASI capabilities in compiled executables (#161)
- ship four live-shell host archives through a dispatched release-asset workflow (#156)
- add a like-for-like interruptible runtime-comparison profile (#145)
- add checksum-pinned compiler archives and a draft Homebrew formula (#98)
- emit native WASI executables from wasmlight compile (#115)
- add connector callback thunks with deferred guest failures (#108)
- add connector memory copies, scoped borrows, and opaque handles (#95)
- plan 64-bit Unix C-ABI calls and load local libraries (#99)
- resolve imports uniquely and strip unused declarations (#96)
- add the immutable compiled WASI capability set (#105)
- add wasmlight compile with --target and --connector (#101)
- select runtime shells from an installed catalog (#107)
- package Mach-O runtime shells for both macOS targets (#102)
- package Linux ELF runtime shells without a host linker (#97)
- add the embedded native executable payload format (#94)
- add interpreter-free runtime-shell startup path (#109)
- compile try_table handlers on Arm64 and x64 (#106)
- add a strict all-or-fail whole-module compile API (#100)
- describe 64-bit Unix targets independently of host execution (#103)
- parse the Wasmlight Connector Language (#93)

### Performance

- speed up x64 memory loops and small memory-using calls (#142)
- speed up x64 calls, recursion, and memory loops (#141)
- allocate x64 structs inline and keep v128 values in xmm registers (#136)
- speed up x64 hot loops and generic direct calls (#135)
- speed up x64 memory access and integer ops (#134)
- speed up x64 scalar loops, recursion, and calls (#132)
- speed up ARM64 calls, recursion, pinned-memory loops, and host calls (#131)
- accelerate fixed array access on x64 (#28)
- emit numeric struct fields natively on x64 (#21)
- accelerate Arm64 array and SIMD hot paths (#20)
- inline the struct.new allocation fast path on arm64 (#19)
- accelerate compiled loop, call, and GC hot paths (#18)
- accelerate allocation and struct/array field access (#11)
- emit v128 moves and consts natively on arm64 and x64 (#10)
## [0.1.0] - 2026-08-15

### Bug Fixes

- restore tier CI and fully judge pinned core (#2)
- Bugfixes

### Documentation

- Doc updates

### Internal

- upgrade to LWPT 0.6.0 and clarify conformance status (#4)

### New Features

- add benchmark-gated optimization skill (#3)
- AOT
- Even more JIT
- More JIT
- JIT part 1
- Embedding
- SIMD
- Runner
- Interpreter
- Validation and IR
- Complete section body decoding

### Performance

- specialize x64 scalar calls (#7)
- bring Arm64 workloads within 1.5x of Wasmtime (#6)
- add runtime comparison and PR reporting (#5)
- accelerate compiled execution and restore tier CI (#1)
