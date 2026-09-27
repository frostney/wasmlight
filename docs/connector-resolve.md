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
- `wasmlight compile --connector` embeds the plan in the executable; the
  runtime shell re-resolves it at startup, loads its libraries beside the
  executable, and binds each import as a host function. Scalar
  declarations are callable; other shapes fail closed at compile time.

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

## Embedding and startup

`wasmlight compile` writes the plan into the payload's connector-plan
section through `EncodeConnectorPlan` in `Wasm.Connector.Plan`: a
versioned (`WLCP`, version 1), fixed-width little-endian encoding of the
thunks, libraries, and stripped connectors. Source line and column
positions are not carried, so the same declarations always produce the
same bytes. A module that binds no connector import gets an empty section,
and its executable is unchanged.

At startup the runtime shell:

1. decodes the section strictly — a bad magic or version, a truncated
   record, an out-of-range enum, a non-canonical boolean or `SizeConst`, a
   non-numeric wasm type, or a trailing byte is
   `EWasmLinkError: malformed connector plan`, never a partial plan;
2. re-resolves the decoded connectors against the embedded module and
   requires the result to re-encode to the same bytes, so an edited
   symbol, library, or signature is rejected the same way;
3. loads each plan library once, before instantiation, through
   `Wasm.Native.Load`: a bare name gains the platform file name beside the
   executable, a relative path joins the executable directory, an absolute
   path stays literal, and no ambient loader path is searched. A missing
   library is `EWasmLinkError: unknown library`, a missing symbol
   `EWasmLinkError: unknown symbol`;
4. defines each import on the deny-by-default linker next to WASI
   (`Wasm.Connector.Host`), calling the native symbol through the
   precompiled C-ABI gate.

Declared but unused libraries are not in the plan and are never opened.

### Lowering a compiled executable can call

`Wasm.Connector.Host` lowers each parameter and the result to one C scalar:

| Declaration | C type | Guest value |
| --- | --- | --- |
| `sbyte`, `short`, `int`, `long` (and `Int8`…`Int64`) | signed, same width | truncated from `i32`/`i64` in, sign-extended out |
| `byte`, `ushort`, `char`, `uint`, `ulong` | unsigned, same width | truncated in, zero-extended out |
| `float`, `double` | `float`, `double` | `f32`, `f64` |
| `bool` / `MarshalAs(Bool)` | C `bool` (one byte) | non-zero `i32` in is `1`; result is `0` or `1` |
| enum | its underlying type (default `int`) | as that type |
| `void` result | — | no result |

`MarshalAs` with a numeric `UnmanagedType` selects that width. Arrays,
strings, pointer-sized names, structs, delegates, `[Scoped]` parameters,
and `ref`/`out`/`in` parameters have no lowering yet: `wasmlight compile`
rejects them with `EWasmLinkError: unsupported connector type`, and the
shell rejects them the same way. The compiler also checks every call plan
against the selected target's C ABI, so a plan that target cannot call is
`EWasmLinkError: incompatible call plan` before any executable is written.

## Related documents

- [ADR-0015](adr/0015-strict-native-compiler-and-runtime-shell.md) — compile
  contract and deny-by-default connector selection
- [CONTEXT.md](../CONTEXT.md) — connector, connector plan, entry point alias
- [Architecture](architecture.md) — layering
