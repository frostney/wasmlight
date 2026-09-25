# Native callers release callback pointers before their binding ends

Native callers must unregister callbacks and finish in-flight calls before
`Unbind`, `EndScope`, or hub destruction. The portable cdecl thunk pool reuses
released addresses; invoking an old pointer after its lifetime is unsupported.
This replaces the earlier claim that a pointer stays inert indefinitely after
hub destruction, which cannot hold when a finite pool reuses the same address.

We chose explicit caller ownership over unique executable thunks and permanent
process-lifetime tombstones. It preserves portable bounded storage and repeated
binding on all supported hosts without introducing another machine-code emitter.
Queued notifications remain runtime-owned: releasing a binding cancels its
pending work, and notifications already copied into a drain batch check their
binding generation before delivery. They never invoke a replacement binding.
