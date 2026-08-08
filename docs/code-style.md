# Code style

## Executive Summary

- `lwpt format` is the canonical formatter; `lwpt format --check` is the
  gate. Style questions that the formatter settles are not style
  questions.
- Namespaced `Wasm.*` unit filenames, flat under `source/units/`, tests
  co-located as `Wasm.*.Test.pas`.
- The **RTL policy**: hot paths may bypass the RTL, but only with a
  `wasmbench` measurement behind the decision.

## Formatter

```bash
lwpt format          # rewrite in place
lwpt format --check  # exit non-zero on drift (CI + pre-commit)
```

The formatter owns uses-clause ordering and identifier casing. Its scope
is seeded by `[package].units`; `scripts/*.pas` is added explicitly in
`[format] include` because it holds project-owned Pascal that is not a
unit. Toolkit state under `.lwpt/` is excluded by lwpt itself.

## Naming and layout

- One namespace, `Wasm.*`, flat under `source/units/` until a sub-area
  earns nesting. `Wasm.Exec.Jit.X64` is nesting by namespace, not by
  directory.
- Types are `T`-prefixed (`TWasmReader`, `TWasmModule`); enum members
  carry a short namespace prefix (`wvtI32`, `wsCustom`, `wetInterpreter`)
  so a bare member name is unambiguous at a call site.
- Exceptions are `E`-prefixed and derive from `EWasmError`. Raise the
  specific class — the four subclasses mean different things to a host
  (see [architecture.md](architecture.md#error-boundaries)).
- Test programs are `Wasm.<Unit>.Test.pas`, co-located with the unit they
  cover.

## Comments

Comment the decision, not the mechanics. A unit header says what the unit
owns and what belongs elsewhere; a comment inside a routine explains why
the non-obvious choice was made — the width check that looks redundant,
the sub-reader that exists to stop one section reading into the next.
Do not restate what the next line does.

## The RTL policy

wasmlight targets C and Rust runtime performance, and the FPC RTL is not
always the fastest way to move a byte. Hot paths — the LEB128 reader, the
interpreter dispatch loop, memory-access checks, canonical ABI lifting and
lowering — may use direct primitives instead of RTL calls, subject to
three rules:

1. **Measure first.** A hot-path deviation from the RTL needs a
   `wasmbench` number in the PR that motivated it. "Obviously faster" is
   not a measurement.
2. **Never hand-roll crypto.** Not applicable to any path shipped today,
   and not to become applicable by accident.
3. **Correctness does not bend.** A faster path that changes observable
   behaviour is not a faster path; it is a bug. This applies with full
   force across execution tiers
   ([ADR-0001](adr/0001-tiered-execution-seam.md)).

Cold paths — CLI handling, diagnostics, error formatting, the build
scripts — use the RTL freely. Clarity wins there.

## Records over classes on hot paths

`TWasmReader` is a record over a raw pointer because every byte of every
module passes through it: no allocation, no indirection, no lifetime
question at the call site. The trade is that it **borrows** its buffer
([ADR-0003](adr/0003-module-borrows-its-buffer.md)), so the buffer must
outlive the reader. Where a test or a caller keeps a reader, it keeps the
buffer in the same scope or longer — the existing unit suites hold theirs
in a suite field for exactly this reason.
