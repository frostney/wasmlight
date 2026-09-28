# Cross-architecture emission follows 0.2.0

[ADR-0015](./0015-strict-native-compiler-and-runtime-shell.md) makes every
shipped compiler emit every released target. That remains the contract, but
it is delivered in `0.3.0` by
[#148](https://github.com/frostney/wasmlight/issues/148), not in `0.2.0`.
Strict compilation of WASI command modules to native executables shipped in
`0.2.0` with embedded connector plans and compiled capability sets. Until
that issue lands, a compiler emits for its own architecture on both 64-bit
UNIX operating systems, and a target it cannot emit fails with a
diagnostic, never with a fallback.

Rejected: **holding `0.2.0` for all-to-all emission**, which would have put
the largest remaining backend change (both backends in one compiler,
selected by `--target`) ahead of every other `0.2.0` deliverable.

Consequences:

- Release archives carry same-architecture runtime shells for Linux and
  macOS ([deployment.md](../deployment.md)); the all-to-all
  `--require-compile` gate lands with #148.
- Documentation states the host-architecture limit until #148 ships.
