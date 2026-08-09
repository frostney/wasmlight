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
  which trap fires and when — is a bug, not a tier characteristic.
- **The error hierarchy is load-bearing.** `EWasmDecodeError`,
  `EWasmValidationError`, `EWasmLinkError`, and `EWasmTrap` mean different
  things to a host; never collapse them or raise a bare `EWasmError` where
  a specific one applies. `EWasmException` — an uncaught wasm `throw` —
  is a **sibling of `EWasmTrap`, not a subclass**: it is the exception
  route, distinct from the trap route, and reaches the trampoline on its
  own path ([ADR-0009](docs/adr/0009-traps-unwind-to-a-per-invocation-trampoline.md)).
  A caught throw never surfaces as either.
- **A store belongs to one thread**
  ([ADR-0008](docs/adr/0008-a-store-is-confined-to-one-thread.md)). Do not
  add synchronisation to runtime structures "just in case" — that cost is
  paid on every access forever and is the thing this ADR exists to avoid.
- **Host capability is deny-by-default.** Nothing reaches the host
  filesystem, clock, environment, or network except through an import the
  embedder explicitly granted.
- **Programs parse flags via lwpt's `cli` package** (`CLI.Options`,
  `CLI.Parser`, `CLI.Subcommands`) — no hand-rolled `ParamStr` loops in
  `source/apps/`. One documented exception: `wasmlight` renders its own
  top-level help and unknown-command path, because the package's
  `PrintTopLevelHelp` hardcodes lwpt's tagline with no override. The
  command list is still read from the live registry.
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
./build/wasmspec <script.wast|dir>...     # run .wast conformance scripts (assemble, validate, execute)
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
| `source/units/` | Library: `Wasm.Core` (vocabulary + errors), `Wasm.Binary` (bounds-checked reader, LEB128), `Wasm.Module` (decoded model), `Wasm.Decoder` + `Wasm.Decoder.*` (Common/Types/Entities/Segments/Expr — binary → model, all section bodies), `Wasm.Ir` (register IR data structures + disassembler; depends on `Wasm.Core` alone), `Wasm.Validator` (`ValidateModule`: module-shape rules, phase order, IR assembly) + `Wasm.Validator.Types` (type-section validity, canonicalisation, matching), `Wasm.Validator.Const` (constant expressions), `Wasm.Validator.Body` (the fused decode/type-check/emit body walk), the runtime layer: `Wasm.Runtime.Values` (the untagged value slot + reference encoding), `Wasm.Runtime.Traps` (trap vocabulary, fault handler, per-invocation trampoline), `Wasm.Runtime.Memory` (linear memory + the access chokepoint), `Wasm.Runtime.Store` (engine type table, store, instances), `Wasm.Runtime.Instantiate` (const-expr evaluator + instantiation sequence), `Wasm.Runtime.Gc` (precise non-moving mark-sweep collector, including GC-managed `exn` exception objects with a traced payload); the interpreter tier `Wasm.Interp` (explicit-frame dispatch over the IR, including `throw` / `throw_ref` / `try_table` by explicit activation-stack unwind) + `Wasm.Interp.Numeric` (bit-exact numeric leaf functions) + `Wasm.Interp.Vector` (bit-exact `v128` vector leaf functions); the wat text-format assembler `Wasm.Wat.Numbers` (numeric-literal text → exact bits), `Wasm.Wat.Lexer` (strict classified tokenizer for module text), `Wasm.Wat.Emit` (binary emitter: canonical LEB128, encoders, section backpatching), `Wasm.Wat.Opcodes` (mnemonic → opcode/immediate/alignment table), `Wasm.Wat.Names` (identifier/label resolution, implicit-typeuse dedup), `Wasm.Wat.Assembler` (module text + `(module quote …)` → bytes into the shipped decode/validate path); and the conformance harness `Wasm.Wast` (.wast lexer/parser/classifier), `Wasm.Wast.Values` (assertion argument/result parser + matcher), `Wasm.Wast.Runner` (assembles text modules, decodes, validates, instantiates, and executes assertions through the interpreter) |
| `source/apps/` | Programs: `wasmlight` (CLI), `wasmbench` (benchmarks), `wasmspec` (.wast conformance harness) |
| `scripts/` | InstantFPC automation (`stamp-version.pas`) |
| `tests/fixtures/` | Real toolchain-compiled `.wasm` cross-check corpus (committed; regenerate with `regenerate.sh`) |
| `tests/spec/` | The upstream conformance harness lands here |
| `docs/` | Architecture, quick start, tooling, code style, build system, testing, deployment, roadmap, ADRs |

Layering is strictly bottom-up — see
[docs/architecture.md](docs/architecture.md). What is shipped today is the
decode layer, the validation layer that emits the IR, the runtime state
below the tier seam (store, instances, the memory chokepoint, the trap
path, instantiation, and the precise collector), the interpreter tier that
executes the IR, the wat text-format assembler, and the `.wast` runner that
assembles, decodes, validates, instantiates, and executes over the whole
corpus; the baseline JIT and AOT tiers behind the seam and the host surface
are staged in [docs/roadmap.md](docs/roadmap.md). Do not document an
unbuilt layer as if it exists. `$FD` vector support is shipped end to end
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
  column is 0. What still skips is host imports the harness does not
  provide and `assert_unlinkable`. See [docs/testing.md](docs/testing.md)
  for what is judged versus skipped and the measured tallies.
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
