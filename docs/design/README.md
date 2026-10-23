# Design contracts

The design contracts wasmlight's tracks were implemented against. Each was
checked against the source when it moved here, and its status note lists the
passages that no longer describe the shipped code. The code and
[architecture.md](../architecture.md) are the authority where they differ.

| Contract | Track | Scope |
| --- | --- | --- |
| [ir-spec.md](ir-spec.md) | B | validation, the register IR, `TWasmIrModule` |
| [wat-assembler.md](wat-assembler.md) | C | the `wat` text-format assembler |
| [runtime-spec.md](runtime-spec.md) | D | runtime state, memory, traps, instantiation, the collector |
| [simd-spec.md](simd-spec.md) | G | the `v128` instruction set |
| [eh-spec.md](eh-spec.md) | H | exception handling |

The contracts for the interpreter (Track E), the embedding API and WASI
(Track F), the baseline JIT (Track I) and the AOT compiler (Track J) were
retired rather than moved: the shipped code has moved past them, and
[architecture.md](../architecture.md) and the ADRs describe those areas.
Source comments that still cite `interp-spec`, `embedding-spec`, `jit-spec`
or `aot-spec` refer to those retired documents.
