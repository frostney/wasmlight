# Connector resolve

## Executive Summary

- `ResolveConnectorPlan` in `Wasm.Connector.Resolve` builds an immutable
  [connector plan](../CONTEXT.md) from declaration records and a module's
  imports.
- Matching is unique and deny-by-default: `(connector class, method name)`
  plus the wasm signature after fixed marshalling. `EntryPoint` is the
  native symbol only.
- Unused declarations and their libraries are stripped from the plan.
  `wasmlight compile` is not this unit.

## Resolve contract

The caller supplies `TWlcDocument` values from `ParseConnector` (or
constructed records) and the guest imports. `WlcGuestImportsFromModule` / `ResolveConnectorModule` read
imports from a decoded `TWasmModule`. Built-in module names — typically
`wasi_snapshot_preview1` via `WLC_WASI_MODULE` — are skipped; they are
not discovered.

Guest key:

- module name = `[Connector]` class name
- import name = method name, never `EntryPoint`

`EntryPoint` (or the method name when omitted) is stored on the thunk as
`NativeSymbol`. It does not alias the guest name, reorder arguments, or
adapt types.

A non-built-in import resolves once or the call raises `EWasmLinkError`:

| Situation | Prefix |
| --- | --- |
| no declaration, or a non-function import | `unknown import` |
| name matches, marshalled signature does not | `incompatible import type` |
| two identical declarations share one guest key | `duplicate connector binding` |
| two distinct declarations share one guest key | `ambiguous connector binding` |
| a used method cannot be lowered | `unsupported connector type` |

There is no registry, network fetch, ambient library search, hidden
state, or adapter expression language.

## Marshalling used for matching

Fixed lowering, for signature comparison only. ABI placement and memory
copies are later work.

- Integers through 32 bits, `bool`, and `char` become `i32`; 64-bit
  integers become `i64`; `float`/`double` become `f32`/`f64`.
- `void` is an empty result list.
- Arrays, strings, pointer-sized names, structs, delegates, and
  `ref`/`in`/`out` parameters become `i32`.
- `MarshalAs(UnmanagedType.*)` overrides the default numeric width or
  marks a pointer (`LPStr`, `LPArray`, `SysInt`, …).
- Enums use their declared underlying type; the default is `int` → `i32`.

## The plan

`TWlcConnectorPlan` contains, in guest-import order:

- `Thunks` — one identity per resolved import: guest module/name, library,
  native symbol, method declaration, and marshalled wasm signature
- `Libraries` — unique `DllImport` names actually used
- `Connectors` — only classes with a used method, and only the types those
  methods reach

Unused methods, unused structs/enums/delegates, unused connector classes,
and unused libraries are absent. The plan does not load a library or emit
machine code.

## Related documents

- [ADR-0015](adr/0015-strict-native-compiler-and-runtime-shell.md) — compile
  contract and deny-by-default connector selection
- [CONTEXT.md](../CONTEXT.md) — connector, connector plan, entry point alias
- [Architecture](architecture.md) — layering
