# Agent Instructions

wasmlight is a WebAssembly runtime written in FreePascal, built and
released through [lwpt](https://github.com/frostney/lwpt). Read
[VISION.md](VISION.md) for direction and [CONTEXT.md](CONTEXT.md) for the
canonical vocabulary before planning anything.

## Hard Constraints

- **FreePascal only.** FPC 3.2.2, Delphi mode, flags centralised in
  `source/units/Shared.inc`. Do not introduce another compiled language or
  repeat compiler directives per unit. JIT and AOT backends emit machine
  code at run time; that is not an exception to this rule, it is the
  reason the rule matters.
- **lwpt is the only toolchain entry point** — install, build, test,
  format all go through it. Do not add another build system (no
  Make/CMake for builds) and do not invoke `fpc` directly except as
  `fpc @lwpt.cfg`.
- **`lwpt.cfg` and `lwpt.lock` are generated** by `lwpt install`; never
  hand-edit them. `lwpt.toml` is the manifest you edit.
- **`source/units/Version.inc` is generated** by
  `scripts/stamp-version.pas` from `[package].version` in `lwpt.toml`.
  It is committed so a fresh clone compiles, but never hand-edit it —
  change the manifest and let the `prebuild`/`pretest` hook restamp.
- **Names are UTF-8, and that is a DECODE rule.** The side condition is
  in the binary grammar, so a bad name is malformed, not invalid — it
  fails in `Wasm.Binary`, never reaching the validator. Overlong forms,
  surrogates, and anything above U+10FFFF are all excluded.
- **The conformance target is the 3.0 draft at a pinned commit**
  ([ADR-0004](docs/adr/0004-conformance-target-is-the-3-0-draft.md)).
  Never write "conformant to the latest spec" — a draft moves, and an
  unpinned claim is uncheckable. GC, exception handling, and tail calls
  are v1 scope, not future work.
- **Check the spec; do not recall it.** Two shipped bugs came from
  remembering: section ids are not the encoding order, and value types are
  signed LEB128 small negatives rather than raw bytes. Use the `wasm`
  MCP server (below) and cite the anchor.
- **Validation happens once, before any tier**, and emits the register-
  based IR every tier consumes
  ([ADR-0007](docs/adr/0007-validation-emits-the-lowered-ir.md),
  [ADR-0012](docs/adr/0012-the-ir-is-register-based.md)). No execution
  tier may re-derive or enforce a spec rule, no tier reads the raw binary,
  and there is no mode that skips validation for "trusted" modules.
- **Memory access goes through one chokepoint.** The strategy is chosen
  per memory by address type: guard pages for i32 memories on 64-bit
  hosts, guard-assisted explicit checks for i64 memories, explicit
  checks on 32-bit targets
  ([ADR-0005](docs/adr/0005-guard-page-linear-memory.md),
  [ADR-0010](docs/adr/0010-32-bit-targets-are-supported-on-bounds-checks.md),
  [ADR-0013](docs/adr/0013-i64-memories-take-guard-assisted-bounds-checks.md)).
  That is a platform-and-address-type difference, never a tier
  difference, and all must trap identically. A new caller that bypasses
  the chokepoint is the failure mode this design is most exposed to.
- **Every backend emits the epoch check and can produce a stack map** at
  loop back-edges and function entries
  ([ADR-0006](docs/adr/0006-epoch-interruption-not-fuel.md),
  [ADR-0011](docs/adr/0011-precise-gc-from-ir-derived-stack-maps.md)).
  These are the same safepoints, deliberately.
- **Traps unwind to the invocation trampoline**, never out of a signal
  handler or SEH filter
  ([ADR-0009](docs/adr/0009-traps-unwind-to-a-per-invocation-trampoline.md)).
- **Tiers must be observationally identical.** Any divergence between
  interpreter, baseline JIT, and AOT for the same module — including
  which trap fires and when — is a bug, not a tier characteristic. All
  three tiers are shipped, and this is **enforced in CI**: `wasmspec
  --tier=interp|jit|aot` over the pinned corpus must produce a
  byte-identical pinned-core tally (65,188 pass, 0 fail, 0 skip), and the
  JIT/AOT legs assert that identity against the interpreter. The JIT and
  AOT are a 64-bit-UNIX acceleration (`WASM_JIT_EXEC`, backends
  `Wasm.Jit.Arm64` / `Wasm.Jit.X64`); on Windows and 32-bit targets the
  runtime is interpreter-only — the tier of record, fully conformant, just
  unaccelerated. AOT never bypasses validation: `run --aot` always
  re-decodes and re-validates, and the `.waot` artifact is a per-module
  perf cache bound by hash, not a trust boundary.
- **The error hierarchy is load-bearing.** `EWasmDecodeError`,
  `EWasmValidationError`, `EWasmLinkError`, and `EWasmTrap` mean different
  things to a host; never collapse them or raise a bare `EWasmError` where
  a specific one applies. `EWasmException` — an uncaught wasm `throw` —
  is a **sibling of `EWasmTrap`, not a subclass**: it is the exception
  route, distinct from the trap route, and reaches the trampoline on its
  own path ([ADR-0009](docs/adr/0009-traps-unwind-to-a-per-invocation-trampoline.md)).
  A caught throw never surfaces as either. `EWasmExit` — a clean,
  guest-requested exit raised by WASI `proc_exit` — is a further sibling
  under `EWasmError`, declared in `Wasm.Engine`: it is neither a fault nor
  a `throw`, so never fold it into `EWasmTrap` or `EWasmException`; `run`
  maps it to the process exit code. Internal invariant defects — the
  `"internal: ..."` sites on paths the validator's proof makes unreachable —
  raise `EWasmInternal`, a leaf under `EWasmError`: never on a
  module-facing path, and never in place of one of the classes above.
- **A store belongs to one thread**
  ([ADR-0008](docs/adr/0008-a-store-is-confined-to-one-thread.md)). Do not
  add synchronisation to runtime structures "just in case" — that cost is
  paid on every access forever and is the thing this ADR exists to avoid.
- **Host capability is deny-by-default** — and now enforced, not just
  intended. Nothing reaches the host filesystem, clock, environment, or
  network except through an import the embedder explicitly granted. The
  boundary lives in `Wasm.Engine`'s `TWasmLinker` (an undefined import is
  absent, so instantiation fails with `EWasmLinkError` — no ambient
  fallback) and in `Wasm.Wasi`: a bare config grants stdio + clock +
  random only, **preopened directories are the sole route to the
  filesystem**, and every path is contained to its preopen — an absolute
  path, a `..` escape, or an escaping symlink is `ENOTCAPABLE` before any
  OS call. The wave-3 long tail (`sock_*`, `poll_oneoff`, the link/rename
  family) is not defined at all, so importing one fails to link.
- **Programs parse flags via lwpt's `cli` package** (`CLI.Options`,
  `CLI.Parser`, `CLI.Subcommands`) — no hand-rolled `ParamStr` loops in
  `source/apps/`. Two documented exceptions, both in `wasmlight`:
  1. It renders its own top-level help and unknown-command path, because
     the package's `PrintTopLevelHelp` hardcodes lwpt's tagline with no
     override. The command list is still read from the live registry.
  2. `wasmlight run` pre-scans `ParamStr` itself (`ParseRunArgs`) to split
     its own flags from the guest's argv, because `CLI.Parser` has no `--`
     terminator and raises on any unknown long flag — so a flag-shaped
     guest token (`app.wasm --verbose`) can't go through the registry
     parser. The scan owns only the `--`/positional/guest-argv split; the
     `--dir`/`--env` *values* are still applied through the cli package's
     `TRepeatableOption` objects, so the registry stays the single source of
     truth and `run --help` renders from it. The clean upstream fix is a
     `--` terminator in lwpt's `cli`; until it lands this pre-scan is the
     sanctioned workaround (embedding-spec.md §4.2).
- **Layout is fixed:** library units in `source/units/` (namespaced
  `Wasm.*.pas`, tests co-located as `Wasm.*.Test.pas`), program entry
  points in `source/apps/`, one-off automation in `scripts/` (add `tools/`
  when a non-Pascal harness needs a home), external corpora under
  `tests/`.
- **`build/` is generated** — never commit it.
- **No new dependencies** beyond lwpt's `testing` and `cli` packages
  without explicit maintainer approval.
- **Hot paths avoid the RTL/FCL.** Performance rivals C/Rust by design:
  prefer direct primitives on hot paths when a `wasmbench` measurement
  justifies it — see the RTL policy in
  [docs/code-style.md](docs/code-style.md).

## Runtime / Commands

lwpt is the **released binary on PATH**, installed from the maintainer's
Homebrew tap (`brew install frostney/tap/lwpt`) or from the checksum-
verified release tarball — see [docs/quick-start.md](docs/quick-start.md).
No sibling checkout, no bootstrap. Dependencies resolve from the same
release tag.

```bash
lwpt install           # resolve deps, regenerate lwpt.cfg + lwpt.lock
lwpt install --frozen  # CI mode: verify lockfile + committed modules, no network
lwpt format --check    # formatter gate (no flag = rewrite in place)
lwpt build             # all three programs (Linux, macOS, Windows)
lwpt test              # co-located unit suites
./build/wasmlight inspect <module.wasm>   # decode + report sections and entity counts
./build/wasmlight validate <module.wasm>  # decode + validate, report the lowered IR
./build/wasmlight run [--dir G=H] [--env K=V] [--aot <art.waot>] [--no-aot] [--] <module.wasm> [args...]  # run a WASI preview1 command to a process exit code (--aot loads a precompiled artifact for instant startup, falling back to interpret)
./build/wasmlight aot <module.wasm> [-o <artifact.waot>]  # compile ahead of time to a .waot artifact (64-bit UNIX)
./build/wasmspec [--tier=interp|jit|aot] <script.wast|dir>...  # run .wast conformance scripts (assemble, validate, execute) in a chosen tier
./build/wasmbench                          # component benchmarks (measurement only)
```

## Checking the spec

`.mcp.json` wires up [wasm-mcp](https://github.com/xyzzylabs/wasm-mcp), a
read-only MCP server serving the WebAssembly core, js-api, and web-api
specs from a pinned upstream commit. **Use it instead of recalling spec
behaviour** — [DEFINITION_OF_READY.md](DEFINITION_OF_READY.md) requires
claimed WebAssembly behaviour to be checked against the spec text and the
section cited, and this is how you do that without leaving the repo.

- `spec_version` first when you are going to cite something — it reports
  the pinned commit, which is what makes a citation reproducible.
- `instruction_get` / `instruction_search` for opcodes, stack signatures,
  and trap conditions; `type_get` for value types and type forms;
  `section_get` / `spec_search` for clause prose and anchors;
  `proposal_list` for proposal phases.

It never executes WebAssembly and never reaches the network at request
time, so its answers are data, not a second implementation to trust —
they still belong in a test.

## Code Organization

| Path | Role |
| --- | --- |
| `source/units/` | Library: `Wasm.Core` (vocabulary + errors), `Wasm.Binary` (bounds-checked reader, LEB128), `Wasm.Module` (decoded model), `Wasm.Decoder` + `Wasm.Decoder.*` (Common/Types/Entities/Segments/Expr — binary → model, all section bodies), `Wasm.Ir` (register IR data structures + disassembler; depends on `Wasm.Core` alone), `Wasm.Validator` (`ValidateModule`: module-shape rules, phase order, IR assembly) + `Wasm.Validator.Types` (type-section validity, canonicalisation, matching), `Wasm.Validator.Const` (constant expressions), `Wasm.Validator.Body` (the fused decode/type-check/emit body walk), the runtime layer: `Wasm.Runtime.Values` (the untagged value slot + reference encoding), `Wasm.Runtime.Traps` (trap vocabulary, fault handler, per-invocation trampoline), `Wasm.Runtime.Memory` (linear memory + the access chokepoint), `Wasm.Runtime.Store` (engine type table, store, instances), `Wasm.Runtime.Instantiate` (const-expr evaluator + instantiation sequence), `Wasm.Runtime.Gc` (precise non-moving mark-sweep collector, including GC-managed `exn` exception objects with a traced payload); the interpreter tier `Wasm.Interp` (explicit-frame dispatch over the IR, including `throw` / `throw_ref` / `try_table` by explicit activation-stack unwind) + `Wasm.Interp.Numeric` (bit-exact numeric leaf functions) + `Wasm.Interp.Vector` (bit-exact `v128` vector leaf functions); the two compiling tiers over the same seam (64-bit UNIX only) — the baseline JIT `Wasm.Jit` (the driver + per-store code cache + the `JitCanCompile` scope fence) over `Wasm.Jit.CodeBuffer` (W^X exec memory, emission, label/patch map) and the two backends `Wasm.Jit.Arm64` + `Wasm.Jit.X64` (per-op native codegen, position-independent), and the AOT layer `Wasm.Aot` (`AotCompileModule` over every function → serialize → re-validate-and-wire on load) + `Wasm.Aot.Artifact` (`.waot` read/write, module hash, self-checksum, the arch/IR-version/ABI-fingerprint guards); the wat text-format assembler `Wasm.Wat.Numbers` (numeric-literal text → exact bits), `Wasm.Wat.Lexer` (strict classified tokenizer for module text), `Wasm.Wat.Emit` (binary emitter: canonical LEB128, encoders, section backpatching), `Wasm.Wat.Opcodes` (mnemonic → opcode/immediate/alignment table), `Wasm.Wat.Names` (identifier/label resolution, implicit-typeuse dedup), `Wasm.Wat.Assembler` (module text + `(module quote …)` → bytes into the shipped decode/validate path); the conformance harness `Wasm.Wast` (.wast lexer/parser/classifier), `Wasm.Wast.Values` (assertion argument/result parser + matcher), `Wasm.Wast.Runner` (assembles text modules, decodes, validates, instantiates, and executes assertions through the interpreter); the 64-bit Unix C-ABI surface `Wasm.Abi` (AAPCS64 / SysV x86-64 call plans) + `Wasm.Native.Load` (application-local `.dylib`/`.so` load) + `Wasm.Native.Call` (precompiled call gates); and the embedding + host surface `Wasm.Engine` (the host-facing facade over the runtime: load/link/instantiate/call, guest-memory read/write through the chokepoint, host-root registration for HOST-1, the typed `TWasmLinker`, and the `EWasmExit` clean-exit class), `Wasm.Wasi` (the deny-by-default WASI preview1 host module — args/env/clock/CSPRNG-random/stdio + wave-2 filesystem behind preopen containment) + `Wasm.Wasi.Types` (errno/filetype/rights/oflags/fdflags/clockid/whence witx constants) + `Wasm.Wasi.Memory` (bounds-checked guest-memory marshalling for the host functions), and `Wasm.Run` (the testable core of `wasmlight run`: decode/validate → link deny-by-default → run `_start` → map the outcome to a process exit code) |
| `source/apps/` | Programs: `wasmlight` (CLI — `inspect` / `validate` / `run` [+ `--aot` / `--no-aot`] / `aot`), `wasmbench` (benchmarks), `wasmspec` (.wast conformance harness, `--tier=interp\|jit\|aot`) |
| `scripts/` | InstantFPC automation (`stamp-version.pas`) |
| `tests/fixtures/` | Real toolchain-compiled `.wasm` cross-check corpus (committed; regenerate with `regenerate.sh`) |
| `tests/spec/` | The upstream conformance harness lands here |
| `docs/` | Architecture, quick start, tooling, code style, build system, testing, deployment, roadmap, ADRs |

Layering is strictly bottom-up — see
[docs/architecture.md](docs/architecture.md). What is shipped today is the
decode layer, the validation layer that emits the IR, the runtime state
below the tier seam (store, instances, the memory chokepoint, the trap
path, instantiation, and the precise collector), the interpreter tier that
executes the IR, the wat text-format assembler, the `.wast` runner that
assembles, decodes, validates, instantiates, and executes over the whole
corpus, and the embedding API and WASI preview1 host surface that run that
core as real programs — `wasmlight run` executes a WASI command to a
process exit code under deny-by-default capabilities (Track F) — and both
compiling tiers behind the seam: the baseline JIT (Track I) and the AOT
compiler (Track J), two backends (aarch64 + x86-64) on a 64-bit UNIX host,
each proven byte-identical to the interpreter over the corpus. **The whole
roadmap A–J is delivered**; nothing in v1 is staged. What
[docs/roadmap.md](docs/roadmap.md) still lists as future is *beyond* v1
(threads, the Component Model), broader optimizing-compiler work, or
cross-platform CI validation — never a missing behaviour. Do not document
an unbuilt layer as if it exists, and do not re-describe a shipped one as
staged. `$FD` vector support is shipped end to end
(Track G): the validator types the `$FD` space, the assembler emits the
vector text forms, the interpreter's `Wasm.Interp.Vector` executes them,
and the harness judges SIMD per lane. **Exception handling is shipped end
to end (Track H):** the validator emits `try_table`'s handler tables and
the interpreter executes `throw` / `throw_ref` / `try_table` by an
explicit unwind over the activation stack, matching handlers by tag
store-address; `assert_exception` is judged and the harness's `STAGED`
column is now **0**. With Track H the interpreter executes **all of core
wasm 3.0** — nothing is staged. The one exception encoding out of scope is
the legacy `try`/`catch`/`delegate`/`rethrow` form (`testsuite/legacy/`,
not in 3.0); do not describe it as a gap to close. And the error-message
prefixes: those reachable through decode, validation, the assembler, and
the interpreter's traps are corpus-confirmed by `wasmspec`, while any
prefix no shipped path reaches yet still carries an `UNCONFIRMED` marker.

## Testing

- `lwpt test` discovers `source/units/*.Test.pas`; tests are co-located
  with the unit they cover and must keep providing regression value.
- Malformed-input cases are spelled as literal bytes next to the
  assertion, not loaded from fixtures — the defect should be readable in
  the test.
- The upstream WebAssembly spec testsuite is the external conformance net
  and is wired up through `build/wasmspec` (Track C's runner): it assembles
  text modules, decodes, validates, instantiates, and executes
  `assert_return` / `assert_trap` / `invoke` / `assert_exhaustion` /
  `assert_exception` through the interpreter — SIMD judged per lane (Track
  G) and exception-handling throwing judged (Track H), so the `staged`
  column is 0. The 257 pinned core scripts have no failures or skips;
  `assert_unlinkable`, the standard `spectest` host, module definitions /
  instances, and inline-module bodies are judged. Recursive residue belongs
  only to post-3.0 proposals, testsuite-local custom directives, and the
  explicitly out-of-scope legacy exception encoding. See
  [docs/testing.md](docs/testing.md) for the measured tallies.
- Two framework gotchas, both already worked around in the existing
  suites: FPC will not parse a generic call (`Expect<T>(...)`) as the lone
  statement of an `on ... do`, and the runner fails any test that records
  no assertion — so assert the outcome rather than only calling `Fail` on
  the bad path.
- Nothing in the test stack touches the external network.

## Safety / Boundaries

- Never commit generated state: `build/`, `.lwpt/tmp/`,
  `.lwpt/install.lock`.
- Benchmarks (`wasmbench`) are measurement tools; never wire their numbers
  into CI assertions.
- Edit `AGENTS.md` only — `CLAUDE.md` is a symlink to it.

<!-- lwpt:agents:begin -->

## `lwpt` command reference

Generated by `lwpt agents` from the toolkit's command registry and this project's manifest. Everything between the `lwpt:agents` markers is machine-written: edit outside the markers only, regenerate with `lwpt agents`, verify with `lwpt agents --check`. Run `lwpt <command> --help` for the same reference in a terminal.

### Subcommands

- `lwpt install [--frozen] [--silent]` — Resolve and fetch dependencies
  - `--frozen` — CI mode: refuse to update the lockfile, refuse network, verify hashes
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt add <source[@version]> [--name <name>] [--silent]` — Add a dependency to the manifest and install it
  - `--name=<value>` — Dependency name in the manifest (default: the source's last path segment)
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt remove <name> [<name>...] [--silent]` — Remove dependencies from the manifest and prune their modules
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt build [entry...] [--mode dev|release] [--clean] [--jobs N] [--verbose] [--silent]` — Compile manifest build entries
  - `--mode=<value>` — Build mode: dev (default) or release
  - `--clean` — Force a full rebuild in fresh private staging
  - `--jobs=<N>` — Maximum concurrent build entries (default: machine budget)
  - `--verbose` — Replay successful build-entry logs
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt format [--check] [--silent]` — Format uses-clauses and identifiers
  - `--check` — Report files needing formatting without rewriting; exit 1 if any
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt duplication [--json] [--silent]` — Report manifest-scoped Pascal token clones
  - `--json` — Emit the deterministic machine-readable analysis envelope
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt test [selector...] [--tier default|e2e] [--jobs N] [--bail N] [--verbose] [--inventory] [--silent]` — Discover and run *.Test.pas files
  - `--tier=<value>` — Test tier to include: default (unit + integration) or e2e (adds network-touching tier)
  - `--jobs=<N>` — Maximum concurrent test programs (default: shared machine budget)
  - `--bail=<N>` — Stop after N compile or runtime failures; 0 runs the full queue
  - `--verbose` — Replay successful test logs
  - `--inventory` — Emit registered suites and cases as deterministic JSON without running tests
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt repair [--silent]` — Reclaim install, build-session, and worker-lease residue
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt init [--yes] [--force] [--adopt] [--silent]` — Scaffold a new LWPT project or adopt an existing manifest
  - `--yes` — Skip prompts and use defaults derived from the directory name
  - `--force` — Overwrite an existing lwpt.toml without asking
  - `--adopt` — Fill in missing scaffold around an existing manifest without modifying it
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt run <task-name> | <subcommand> [subcommand-args...] [--silent]` — Invoke a user-declared run task (or a built-in subcommand by name)
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt health [--json] [--hotspots] [--silent]` — Report Pascal complexity and optional Git hotspots
  - `--json` — Write the deterministic machine-readable report
  - `--hotspots` — Enrich complexity with the latest 100 commits of local Git churn
  - `--silent` — Suppress ordinary output and emit only the final command result
- `lwpt agents [--check] [--silent]` — Write or verify the agent-facing command reference in AGENTS.md
  - `--check` — Verify the AGENTS.md block matches the current command surface; exit 1 when stale
  - `--silent` — Suppress ordinary output and emit only the final command result

### Run tasks

No run tasks declared in `lwpt.toml`.

### Manifest schema

Generated from the same immutable structural registry used by manifest validation. Domain-specific syntax and cross-field rules remain in the parser; see the project documentation for those details.

- `[package]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Package identity and Pascal unit roots.
  - `name`: string; optional; default: `unnamed`; invalid values are ignored as absent. Package name; the legacy root name fallback still warns.
  - `version`: string; optional; default: `0.0.0`; invalid values are ignored as absent. Package version.
  - `units`: array of strings; optional; default: `empty`; invalid values and items are skipped. Pascal unit-root paths.
- `[dependencies]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Named dependency declarations.
  - `<name>`: string or table; optional; other values retain legacy handling. Bare `<source>@<version>` shorthand or an inline table.
- `[dependencies].<name>` — string or inline table; all manifests; other values retain legacy handling; unknown keys are ignored. A source shorthand or expanded dependency declaration.
  - `source`: string; required; invalid values are errors. `owner/repo` (GitHub), `<host>:owner/repo` (built-in or custom host), an HTTPS tarball, a local path, or `workspace:<version>`.
  - `version`: string; optional; default: `none`; invalid values are ignored as absent. Version range, exact version, SHA, or tag.
  - `include`: array of strings; optional; default: `all files`; invalid values and items are skipped. Post-extraction include globs.
  - `exclude`: array of strings; optional; default: `none`; invalid values and items are skipped. Post-extraction exclude globs.
  - `repo`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `ref`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `tag`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `asset`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `path`: retired; optional; invalid values are errors. Retired; any declaration is an error.
  - `subdir`: retired; optional; invalid values are errors. Retired; use include globs.
- `[sources]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Named custom Git-host URL templates.
  - `<name>`: table; optional; invalid values are ignored as absent. One custom source declaration.
- `[sources].<name>` — inline table; all manifests; invalid values are ignored as absent; unknown keys are ignored. One custom Git-host source.
  - `archive`: string; required; invalid values are errors. HTTPS archive template containing {user}, {repository}, and {ref}.
  - `git`: string; required; invalid values are errors. HTTPS smart-HTTP template containing {user} and {repository}.
- `[workspaces]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Workspace discovery globs.
  - `include`: array of strings; optional; default: `empty`; invalid values and items are skipped. Workspace discovery globs.
  - `exclude`: array of strings; optional; default: `empty`; invalid values and items are skipped. Workspace exclusion globs.
- `[build]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Single-entry shorthand or named build entries.
  - `<name>`: string or table; optional; other values retain legacy handling. Named entry; build.source enables single-entry shorthand.
- `[build].<name>` — string or table; all manifests; other values retain legacy handling; unknown keys are ignored. One compiler-neutral build entry.
  - `source`: string; conditional; invalid values are ignored as absent. Compiler entry-point path.
  - `output`: string; optional; default: `build/<name>`; invalid values are ignored as absent. Published executable path.
  - `depends`: array of strings; optional; default: `empty`; invalid values are errors. Prerequisite build-entry names.
  - `flags`: array of strings; optional; default: `empty`; root manifest only; invalid values are errors. Ordered compiler-driver arguments.
  - `compiler`: string; optional; default: `[compiler].default`; root manifest only; invalid values are errors. Named compiler-profile override.
  - `target`: table; optional; default: `compiler native target`; root manifest only; invalid values are errors. Explicit target tuple.
  - `prebuild`: table; optional; default: `empty`; invalid values are ignored as absent. Per-entry prebuild command map.
  - `postbuild`: table; optional; default: `empty`; invalid values are ignored as absent. Per-entry postbuild command map.
- `[build].<name>.target` — table; root manifest only; invalid values are errors; unknown keys are errors. An explicit complete compiler target tuple.
  - `os`: string; required; invalid values are errors. Target operating system.
  - `architecture`: string; required; invalid values are errors. Target architecture.
  - `abi`: string; optional; default: `empty`; invalid values are errors. Optional target ABI.
  - `environment`: string; optional; default: `empty`; invalid values are errors. Optional target execution environment.
- `[compiler]` — table; root manifest only; invalid values are errors; unknown keys are ignored. Root-owned compiler profile selection.
  - `default`: string; optional; default: `host default`; invalid values are errors. Default profile name.
  - `profiles`: table; optional; default: `empty`; invalid values are errors. Named compiler-profile map.
- `[compiler.profiles].<name>` — table; root manifest only; invalid values are errors; unknown keys are ignored. One built-in or external compiler profile.
  - `driver`: string; required; invalid values are errors. Built-in or external driver identity.
  - `command`: string; optional; default: `driver default`; invalid values are errors. Direct compiler command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `version`: string; optional; default: `*`; invalid values are errors. Compiler version constraint.
  - `executable`: retired; optional; invalid values are errors. Retired; use command and args.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.
- `[version]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Generated version-include settings.
  - `output`: string; optional; default: `empty`; invalid values are ignored as absent. Generated include path.
  - `prefix`: string; optional; default: `BAKED`; invalid values are ignored as absent. Generated constant prefix.
- `[lwpt]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Toolkit-state path overrides.
  - `modules-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Installed-module directory override.
  - `archives-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Archive-cache directory override.
  - `tmp-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Private temporary directory override.
  - `sessions-dir`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Private compiler-session directory override.
  - `cfg-file`: string; optional; default: `toolkit default`; invalid values are ignored as absent. Compiler response-file override.
- `[format]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Formatter scope additions and subtractions.
  - `include`: array of strings; optional; default: `empty`; invalid values and items are skipped. Formatter-scope additions.
  - `exclude`: array of strings; optional; default: `empty`; invalid values and items are skipped. Formatter-scope subtraction.
- `[analysis]` — table; all manifests; invalid values are errors; unknown keys are ignored. Shared Pascal analysis source scope.
  - `include`: array of strings; optional; default: `empty`; invalid values are errors. Analysis-scope additions.
  - `exclude`: array of strings; optional; default: `empty`; invalid values are errors. Analysis-scope subtraction.
- `[health]` — table; all manifests; invalid values are errors; unknown keys are errors. Optional complexity and hotspot limits.
  - `max-routine-cyclomatic`: integer; optional; default: `unset`; invalid values are errors. Non-negative routine cyclomatic limit.
  - `max-routine-cognitive`: integer; optional; default: `unset`; invalid values are errors. Non-negative routine cognitive limit.
  - `max-file-cyclomatic`: integer; optional; default: `unset`; invalid values are errors. Non-negative file cyclomatic limit.
  - `max-file-cognitive`: integer; optional; default: `unset`; invalid values are errors. Non-negative file cognitive limit.
  - `max-hotspot-score`: integer; optional; default: `unset`; invalid values are errors. Integer hotspot limit from 0 to 100.
- `[duplication]` — table; all manifests; invalid values are errors; unknown keys are ignored. Token-clone floor and optional percentage limit.
  - `minimum-tokens`: integer; optional; default: `100`; invalid values are errors. Clone floor; minimum accepted value is 25.
  - `maximum-percent`: integer; optional; default: `unset`; invalid values are errors. Integer duplication limit from 0 to 100.
- `[test]` — table; all manifests; invalid values are ignored as absent; unknown keys are ignored. Test compiler and scheduler policy.
  - `bail`: integer; optional; default: `0`; invalid values are errors. Non-negative failure count; zero runs the full queue.
  - `flags`: array of strings; optional; default: `empty`; root manifest only; invalid values are errors. Ordered test compiler arguments.
- `[preinstall] / [postinstall] / [prebuild] / [postbuild] / [pretest] / [posttest]` — table; root manifest only; invalid values are ignored as absent; unknown keys are ignored. Root lifecycle command maps.
  - `<name>`: string or table; optional; invalid values are errors. One lifecycle hook.
- `<hook entry>` — string or inline table; all manifests; invalid values are errors; unknown keys are errors. A direct command with optional staleness gating.
  - `command`: string; required; invalid values are errors. Direct child-process command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `inputs`: array of strings; conditional; default: `empty`; invalid values are errors. Non-empty staleness input globs.
  - `output`: string; conditional; default: `empty`; invalid values are errors. Staleness output, paired with inputs.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.
- `[<task-name>]` — table; root manifest only; invalid values are errors; unknown keys are errors. An otherwise-unknown top-level section carrying command.
  - `command`: string; required; invalid values are errors. Direct child-process command.
  - `args`: array of strings; optional; default: `empty`; invalid values are errors. Ordered command arguments.
  - `inputs`: array of strings; conditional; default: `empty`; invalid values are errors. Non-empty staleness input globs.
  - `output`: string; conditional; default: `empty`; invalid values are errors. Staleness output, paired with inputs.
  - `script`: retired; optional; invalid values are errors. Retired; use command and args.

<!-- lwpt:agents:end -->
