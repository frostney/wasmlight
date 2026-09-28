# WIT is not the connector language

Connectors stay declaration-only `.wlc` bindings
([ADR-0015](./0015-strict-native-compiler-and-runtime-shell.md)); WIT is not
adopted as the connector language. WIT describes component interfaces, not
native bindings. Probed on 2026-09-27 against `WebAssembly/component-model`
`d1daf82`, wasm-tools 1.259.0, and wit-bindgen 0.62.0:

- the grammar has no library or symbol attribute, no pointer type, no
  function-typed parameter, no explicit enum value, and no `out`
  parameter; and
- neither the Component Model nor wit-bindgen defines a native host ABI.

Rejected: **WIT as the connector language**. It would still need a
native-mapping sidecar, which is `.wlc` again, and it would pull in the
canonical ABI that
[ADR-0014](./0014-the-component-model-is-deferred-to-post-v1.md) defers.

Consequences:

- Guests built by WIT tooling cannot use connectors. Their import modules
  are interface names such as `local:libc/libc`, which no `.wlc` class name
  can match, and they pass lists and strings as `(ptr, len)` pairs with
  results through a return pointer and the guest's `cabi_realloc`.
- If connectors ever accept such guests, that convention is the canonical
  ABI's flat lowering and must be the one implementation the Component
  Model re-entry reuses, never a separate connector lowering.
- Component resources and connector opaque handles are both guest-visible
  handle tables. The Component Model re-entry extends the connector tables
  rather than adding a second one.
