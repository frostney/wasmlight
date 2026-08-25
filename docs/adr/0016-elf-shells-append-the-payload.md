# ELF shells append the payload after the last file byte

`wasmlight compile` packages a released Linux runtime-shell template with a
verified payload without a host linker, compiler, or SDK
([ADR-0015](./0015-strict-native-compiler-and-runtime-shell.md)). The
packager copies the template bytes unchanged, appends the opaque payload,
and finishes with a fixed little-endian trailer at EOF. The Linux loader
maps only `PT_LOAD` extents
([System V ABI ELF program headers](https://refspecs.linuxbase.org/elf/gabi4+/ch5.pheader.html));
bytes past the last mapped file offset are ignored, so attachment cannot
invalidate executable loading or permissions. The trailer is the
placeholder seam until the interpreter-free shell and native-executable
payload format land: those consumers locate the payload by reading the
last 36 bytes, and they never parse the payload here.

Rejected: **rewriting program headers to add `PT_NOTE` or a new
`PT_LOAD`**, which mutates a released template and can break `PT_PHDR`,
PIE, or section-table layout. **Reserving an overlay hole in the
template**, which needs the shell before the packager and caps payload
size. **Invoking `ld`, `objcopy`, Zig, or a C toolchain**, which is the
host-linker path ADR-0015 already rejected.

Consequences:

- macOS and Linux compiler hosts emit both `aarch64-linux` and
  `x86_64-linux` from the same Pascal packager.
- Identical template, payload, and target bytes produce an identical
  packaged file: no timestamps, no header rewrite.
- A damaged payload is a trailer checksum failure, not an ELF-load
  failure. Startup validation still belongs to the shell.
