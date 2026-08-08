# The IR is register-based, not a mirror of the operand stack

The lowered IR that validation emits
([ADR-0007](./0007-validation-emits-the-lowered-ir.md)) assigns virtual
registers rather than reproducing WebAssembly's operand stack. Validation
already tracks the stack symbolically to type-check it, so the register
assignment falls out of the pass it is already running; what it buys is
the elimination of stack traffic, which is the interpreter's single
largest cost after dispatch. An operand-stack interpreter spends most of
its memory traffic pushing and popping values that a register machine
simply addresses.

Rejected: **a stack-based IR mirroring wasm one-for-one.** Its real
advantage is auditability — a structural correspondence to the spec makes
"does this match the specification" a short argument, which matters for a
project whose central claim is conformance. It was rejected because the
correspondence argument is available anyway at the validation boundary
(what validation *accepts* is checked against the spec by the conformance
corpus), while the stack traffic would be paid on every instruction
forever, in the tier that has to run everywhere.

Consequences:

- This refines ADR-0007's wording: the IR carries the static type of every
  **virtual register**, not of every stack slot. The property that matters
  downstream — full static type information for
  [precise GC stack maps](./0011-precise-gc-from-ir-derived-stack-maps.md)
  — is unchanged and, if anything, more direct.
- The baseline JIT and AOT compiler consume virtual registers, which is
  the input form a register allocator wants. This removes the second
  lowering an operand-stack IR would have needed on the way to machine
  code.
- Register assignment is now part of the pass that must be correct for
  validation to be correct. A bug there is a miscompilation, not a
  rejected module, so it needs its own differential testing against the
  interpreter rather than riding on validation's test coverage.
