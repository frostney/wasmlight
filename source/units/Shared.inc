{$mode delphi} {$H+}
{$M+}
{$IFDEF PRODUCTION}
  {$optimization autoInline}
  {$overflowchecks off}
  {$rangechecks off}
  {$S-}
  {$OBJECTCHECKS OFF}
  {$C-}
{$ELSE}
  {$overflowchecks on}
  {$rangechecks on}
  {$S+}
  {$OBJECTCHECKS ON}
  {$C+}
{$ENDIF}
{$modeswitch advancedrecords}
{ Typed constants are read-only. Delphi mode defaults them writable, which
  would make constants like WASM_MAGIC mutable globals. }
{$J-}

{ Guard-page linear memory and the MMU fault path (ADR-0005, ADR-0009,
  ADR-0013) exist only where a 4 GiB-plus reservation AND a POSIX fault
  handler both do: a 64-bit UNIX host. Everything else — 32-bit hosts and
  Windows this wave — takes explicit bounds checks and installs no handler.

  This capability flag is centralised HERE, next to the other build
  directives (AGENTS.md: directives are not repeated per unit), so that
  Wasm.Runtime.Memory (the chokepoint) and Wasm.Runtime.Traps (the fault
  handler) split on the SAME symbol. A bare UNIX ifdef in the trap unit
  would install a real SIGSEGV/SIGBUS handler on a 32-bit UNIX host that
  has no guard memory to attribute — a handler claiming to be a no-op. }
{$IF DEFINED(UNIX) AND DEFINED(CPU64)}
  {$DEFINE WASM_GUARD_STRATEGIES}
{$ENDIF}

{ 64-bit Unix C-ABI call gates and application-local dlopen (issue #43,
  ADR-0015). Centralised here so Wasm.Native.Call and Wasm.Native.Load
  fail closed on the same hosts — a bare UNIX ifdef would let 32-bit
  Unix dlopen a library that no shipped plan can apply. }
{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_NATIVE_CALL}
{$ENDIF}
