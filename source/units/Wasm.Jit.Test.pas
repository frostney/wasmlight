{ Unit suite for Wasm.Jit — the differential milestone and the Wave-2 spine
  (.agent/design/jit-spec.md §11, §12.2, §12.3 Wave 2).

  THE METHOD IS DIFFERENTIAL (ADR-0001, §11). Every test builds a small module,
  runs an export INTERPRETED (the tier of record, the oracle), then force-
  compiles the function and runs the SAME inputs COMPILED, and asserts the two
  are observationally identical: bitwise-equal results (so NaN payloads, ±0, and
  32-bit wrap are all checked), and — for a trap — the same trap message. A
  divergence is a JIT bug the harness catches on the first exercising input.

  Wave 1 proved the spine end to end for i32.add (TestMilestoneAddIdentical).
  Wave 2 grows op coverage: consts, i32/i64 integer arithmetic/logic/shift and
  compares (inlined native A64), div/rem and all float ops (leaf-called into
  Wasm.Interp.Numeric, so NaN bits / rounding / div-rem trap kind+timing are the
  interpreter's by construction), select, control flow (jumps, branches,
  br_table, an if/else, a loop with a back-edge epoch safepoint), and
  unreachable. Each is a self-contained module run under both tiers.

  THE EPOCH INTERRUPT trap IS differentially tested (TestEpochInterruptDiffer-
  ential): an interpreted caller bumps Store.Epoch through a host callback, then
  calls a COMPILED leaf whose loop back-edge must trap 'interrupt' at the same
  point the interpreter would. This exercises the shared per-invocation epoch
  snapshot (jit-spec §6) — the snapshot is seeded once at the outermost entry
  and read by both tiers, so a compiled leaf inherits the invocation's original
  value rather than re-reading the already-bumped epoch. TestLoopSum additionally
  proves the back-edge epoch-CHECK code does not false-trip when the epoch is
  unchanged.

  FPC gotchas (AGENTS.md): every test records an assertion; a generic
  Expect<T>(...) is never the lone statement of an `on..do`. }
program Wasm.Jit.Test;

{$I Shared.inc}
{ The Wave-3 host callbacks address their flat param/result blocks as A[i],
  which is pointer arithmetic on PWasmValue. }
{$POINTERMATH ON}

{$IF DEFINED(UNIX) AND (DEFINED(CPUAARCH64) OR DEFINED(CPUX86_64))}
  {$DEFINE WASM_JIT_EXEC}
{$ENDIF}
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUAARCH64)}
  {$DEFINE WASM_JIT_ARM64}
{$ENDIF}
{$IF DEFINED(WASM_JIT_EXEC) AND DEFINED(CPUX86_64)}
  {$DEFINE WASM_JIT_X64}
{$ENDIF}
{ WASM_JIT_BACKEND: a JIT backend exists for this target, so the
  differential tests (compile a function, run it, compare bit-for-bit to
  the interpreter) run against whichever backend is present. The
  comparison logic is backend-agnostic — the tests gate on this, not on a
  specific arch, so the same suite proves both aarch64 and x86-64. }
{$IF DEFINED(WASM_JIT_ARM64) OR DEFINED(WASM_JIT_X64)}
  {$DEFINE WASM_JIT_BACKEND}
{$ENDIF}

uses
  SysUtils,

  TestingPascalLibrary,
  Wasm.Core,
  Wasm.Decoder,
  Wasm.Interp,
  Wasm.Ir,
  Wasm.Jit,
  Wasm.Jit.Arm64,
  Wasm.Module,
  Wasm.Runtime.Instantiate,
  Wasm.Runtime.Store,
  Wasm.Runtime.Traps,
  Wasm.Runtime.Values,
  Wasm.Validator;

const
  JIT_BACKEND_AVAILABLE = {$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF};

{ --- byte-assembly helpers (mirrors Wasm.Interp.Test) -------------------- }

function ULeb(const AValue: UInt32): TWasmBytes;
var
  Rest: UInt32;
  Count: Integer;
begin
  Result := nil;
  Rest := AValue;
  Count := 0;
  repeat
    SetLength(Result, Count + 1);
    if Rest < $80 then
      Result[Count] := Byte(Rest)
    else
      Result[Count] := Byte((Rest and $7F) or $80);
    Rest := Rest shr 7;
    Inc(Count);
  until Rest = 0;
end;

{ Signed LEB128 (i32.const / i64.const literals). FPC's `shr` is logical, so the
  arithmetic right shift is done with SarInt64 to keep the sign for negatives. }
function SLeb(const AValue: Int64): TWasmBytes;
var
  V: Int64;
  B: Byte;
  More: Boolean;
  Count: Integer;
begin
  Result := nil;
  V := AValue;
  Count := 0;
  repeat
    B := Byte(V and $7F);
    V := SarInt64(V, 7);
    if ((V = 0) and ((B and $40) = 0)) or ((V = -1) and ((B and $40) <> 0)) then
      More := False
    else
    begin
      B := B or $80;
      More := True;
    end;
    SetLength(Result, Count + 1);
    Result[Count] := B;
    Inc(Count);
  until not More;
end;

function BLit(const A: array of Byte): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function Cat(const AParts: array of TWasmBytes): TWasmBytes;
var
  I, J, N: Integer;
begin
  N := 0;
  for I := 0 to High(AParts) do
    Inc(N, Length(AParts[I]));
  SetLength(Result, N);
  N := 0;
  for I := 0 to High(AParts) do
    for J := 0 to High(AParts[I]) do
    begin
      Result[N] := AParts[I][J];
      Inc(N);
    end;
end;

function VecOf(const AItems: array of TWasmBytes): TWasmBytes;
var
  Body: TWasmBytes;
  I, J, N: Integer;
begin
  N := 0;
  for I := 0 to High(AItems) do
    Inc(N, Length(AItems[I]));
  SetLength(Body, N);
  N := 0;
  for I := 0 to High(AItems) do
    for J := 0 to High(AItems[I]) do
    begin
      Body[N] := AItems[I][J];
      Inc(N);
    end;
  Result := Cat([ULeb(UInt32(Length(AItems))), Body]);
end;

function Sect(const AId: Byte; const ABody: TWasmBytes): TWasmBytes;
begin
  Result := Cat([BLit([AId]), ULeb(UInt32(Length(ABody))), ABody]);
end;

function CodeEntry(const ABody: TWasmBytes): TWasmBytes;
begin
  Result := Cat([ULeb(UInt32(Length(ABody))), ABody]);
end;

function StrBytes(const AName: string): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AName));
  for I := 1 to Length(AName) do
    Result[I - 1] := Byte(AName[I]);
end;

{ A SIMD instruction opcode: the 0xFD prefix followed by the SIMD sub-opcode as
  ULeb128 (so sub-opcodes >= 128, e.g. i32x4.add = 174, take two bytes). The
  sub-opcode is the wasm binary $FD number from Wasm.Ir's enum comments. }
function Fd(const AOp: UInt32): TWasmBytes;
begin
  Result := Cat([BLit([$FD]), ULeb(AOp)]);
end;

{ A 16-byte v128 immediate/lane block from up to 16 seed bytes (rest zero). }
function V16(const A: array of Byte): TWasmBytes;
var
  I: Integer;
begin
  SetLength(Result, 16);
  for I := 0 to 15 do
    if I <= High(A) then
      Result[I] := A[I]
    else
      Result[I] := 0;
end;

const
  WASM_HEADER: array[0 .. 7] of Byte = ($00, $61, $73, $6D, $01, $00, $00, $00);

{ A one-function module: type signature ASig (a full 0x60... functype), code
  body ABody (locals vector + instructions + end), exported as AName (func 0). }
function OneFunc(const ASig, ABody: TWasmBytes; const AName: string): TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([ASig])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([Cat([ULeb(UInt32(Length(AName))), StrBytes(AName),
      BLit([$00, $00])])])),
    Sect(10, VecOf([CodeEntry(ABody)]))
  ]);
end;

function VBits(const ABits: UInt64): TWasmValue;
begin
  Result.Bits := ABits;
end;

{ The bump host callback for the epoch differential: the one documented cross-
  thread epoch write (ADR-0006), reached synchronously from guest code. }
procedure JitBumpEpochCallback(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  AStore.Epoch := AStore.Epoch + 1;
end;

{ The epoch differential module (jit-spec §6). An interpreted CALLER (it has
  calls, so JitCanCompile declines it) first calls a host that BUMPS the epoch,
  then calls a COMPILED leaf that spins a loop with a safepoint back-edge:

    import "e"."bump" (func)                    ; func 0 (host)
    (func $leaf (local i32)                     ; func 1 — compilable (no calls)
      i32.const 3  local.set 0
      block loop
        local.get 0  i32.eqz  br_if 1           ; forward exit (no safepoint)
        local.get 0  i32.const 1  i32.sub  local.set 0
        br 0                                    ; UNCONDITIONAL back-edge = safepoint
      end end)
    (func $run  call 0  call 1)                 ; func 2 — declined (has calls)

  exported "run" (func 2) and "leaf" (func 1). Because the epoch is bumped
  BETWEEN the outermost entry and the leaf's entry, the leaf's first back-edge
  must trap 'interrupt' under BOTH tiers once the snapshot is shared. }
function EpochModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $00])])),
    Sect(2, VecOf([BLit([$01, $65, $04, $62, $75, $6D, $70, $00, $00])])),
    Sect(3, VecOf([BLit([$00]), BLit([$00])])),
    Sect(7, VecOf([
      BLit([$03, $72, $75, $6E, $00, $02]),
      BLit([$04, $6C, $65, $61, $66, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([$01, $01, $7F,
        $41, $03, $21, $00,
        $02, $40, $03, $40,
        $20, $00, $45, $0D, $01,
        $20, $00, $41, $01, $6B, $21, $00,
        $0C, $00,
        $0B, $0B, $0B]),
      CodeEntry([$00, $10, $00, $10, $01, $0B])]))
  ]);
end;

{ --- Wave-3 modules: the call family (jit-spec §12.3 Wave 3) ------------

  Each is a complete module built from literal bytes so the shape under test is
  readable next to the assertion. Section ids in encoding order: 1 type,
  2 import, 3 func, 4 table, 7 export, 9 elem, 10 code. }

function ExportEntry(const AName: string; const AKind: Byte;
  const AIndex: UInt32): TWasmBytes;
begin
  Result := Cat([ULeb(UInt32(Length(AName))), StrBytes(AName), BLit([AKind]),
    ULeb(AIndex)]);
end;

{ A direct call between two wasm functions:

    (func $helper (param i32 i32) (result i32) (i32.sub ...))   ; func 0
    (func $run    (param i32) (result i32)
      (i32.add (call $helper (local.get 0) (i32.const 7)) (i32.const 1)))

  run(10) = (10-7)+1 = 4. Which of the two is compiled is chosen per test, so
  the SAME module exercises compiled->compiled, compiled->interpreted, and
  interpreted->compiled. }
function CallPairModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $02, $7F, $7F, $01, $7F]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01])])),
    Sect(7, VecOf([
      ExportEntry('helper', $00, 0),
      ExportEntry('run', $00, 1)])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $20, $01, $6B, $0B]),
      CodeEntry([$00, $20, $00, $41, $07, $10, $00, $41, $01, $6A, $0B])]))
  ]);
end;

{ call_indirect over a 4-entry table holding [$double, $other, null, null]:

    (func $double (param i32) (result i32) (i32.mul (local.get 0) 2))  ; type 0
    (func $other  (result i32) (i32.const 9))                          ; type 1
    (func $run (param i32 i32) (result i32)
      (call_indirect (type 0) (local.get 0) (local.get 1)))            ; type 2

  run(v, 0) hits; run(v, 4..) is out of bounds; run(v, 2) is a null element;
  run(v, 1) is a type mismatch — the three traps in the checked order. }
function CallIndirectModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7F, $01, $7F]),
      BLit([$60, $00, $01, $7F]),
      BLit([$60, $02, $7F, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$02])])),
    Sect(4, VecOf([BLit([$70, $00, $04])])),
    Sect(7, VecOf([
      ExportEntry('double', $00, 0),
      ExportEntry('run', $00, 2)])),
    { active segment on table 0 at offset 0, elements [func 0, func 1]; the
      remaining two entries stay null. }
    Sect(9, VecOf([BLit([$00, $41, $00, $0B, $02, $00, $01])])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $41, $02, $6C, $0B]),
      CodeEntry([$00, $41, $09, $0B]),
      CodeEntry([$00, $20, $00, $20, $01, $11, $00, $00, $0B])]))
  ]);
end;

{ call_ref, with the funcref arriving as a PARAMETER:

    (func $double  (param i32) (result i32) (i32.mul (local.get 0) 2))   ; type 0
    (func $run     (param i32 (ref null 0)) (result i32)
      (call_ref 0 (local.get 0) (local.get 1)))                          ; type 1
    (func $mk      (param i32) (result i32) (call $run (local.get 0) (ref.func 0)))
    (func $mknull  (result i32) (call $run (i32.const 5) (ref.null 0)))   ; type 2

  $run is the function under test and holds nothing but the call — the
  ref-PRODUCING ops (`ref.func`, `ref.null`) sit in the wrappers, because they
  are Wave-4 templates and would otherwise decline the very function whose
  iroCallRef this test exists to compile. The declarative element segment is
  what makes `ref.func 0` valid. }
function CallRefModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7F, $01, $7F]),
      BLit([$60, $02, $7F, $63, $00, $01, $7F]),
      BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$00]), BLit([$02])])),
    Sect(7, VecOf([
      ExportEntry('double', $00, 0),
      ExportEntry('run', $00, 1),
      ExportEntry('mk', $00, 2),
      ExportEntry('mknull', $00, 3)])),
    Sect(9, VecOf([BLit([$03, $00, $01, $00])])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $41, $02, $6C, $0B]),
      CodeEntry([$00, $20, $00, $20, $01, $14, $00, $0B]),
      CodeEntry([$00, $20, $00, $D2, $00, $10, $01, $0B]),
      CodeEntry([$00, $41, $05, $D0, $00, $10, $01, $0B])]))
  ]);
end;

{ Self tail recursion — the O(1) acceptance test (jit-spec §4.5, §13 item 5):

    (func $count (param i64) (result i64)
      (if (i64.eqz (local.get 0)) (then (return (i64.const 42))))
      (return_call $count (i64.sub (local.get 0) (i64.const 1))))

  count(1e6) = 42 must run in BOUNDED native stack. A tail call that grew the
  native stack by even one frame would exhaust an 8 MiB stack long before a
  million iterations, so completing IS the proof. }
function TailSelfModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7E, $01, $7E])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([ExportEntry('count', $00, 0)])),
    Sect(10, VecOf([
      CodeEntry([$00,
        $20, $00, $50, $04, $40, $42, $2A, $0F, $0B,
        $20, $00, $42, $01, $7D, $12, $00,
        $0B])]))
  ]);
end;

{ Mutual tail recursion: $a tail-calls $b tail-calls $a. $a(0) = 1, $b(0) = 2,
  so an even argument lands back in $a. Both are compiled, so the whole chain
  stays inside the trampoline loop. }
function TailMutualModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7E, $01, $7E])])),
    Sect(3, VecOf([BLit([$00]), BLit([$00])])),
    Sect(7, VecOf([
      ExportEntry('a', $00, 0),
      ExportEntry('b', $00, 1)])),
    Sect(10, VecOf([
      CodeEntry([$00,
        $20, $00, $50, $04, $40, $42, $01, $0F, $0B,
        $20, $00, $42, $01, $7D, $12, $01,
        $0B]),
      CodeEntry([$00,
        $20, $00, $50, $04, $40, $42, $02, $0F, $0B,
        $20, $00, $42, $01, $7D, $12, $00,
        $0B])]))
  ]);
end;

{ Deep NON-tail recursion, which must exhaust at the same LOGICAL depth under
  both tiers (jit-spec §13 item 2):

    (func $rec (param i32) (result i32)
      (if (i32.eqz (local.get 0)) (then (return (i32.const 0))))
      (i32.add (call $rec (i32.sub (local.get 0) (i32.const 1))) (i32.const 1))) }
function RecurseModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(7, VecOf([ExportEntry('rec', $00, 0)])),
    Sect(10, VecOf([
      CodeEntry([$00,
        $20, $00, $45, $04, $40, $41, $00, $0F, $0B,
        $20, $00, $41, $01, $6B, $10, $00, $41, $01, $6A,
        $0B])]))
  ]);
end;

{ A TWO-result call, so the result unmarshal loop is exercised beyond one slot:

    (func $pair (result i32 i64) (i32.const 3) (i64.const 4))
    (func $run  (result i64) ... (call $pair) ... 3 + 4 = 7) }
function MultiValueModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $02, $7F, $7E]),
      BLit([$60, $00, $01, $7E])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01])])),
    Sect(7, VecOf([
      ExportEntry('pair', $00, 0),
      ExportEntry('run', $00, 1)])),
    Sect(10, VecOf([
      CodeEntry([$00, $41, $03, $42, $04, $0B]),
      CodeEntry([$02, $01, $7F, $01, $7E,
        $10, $00, $21, $01, $21, $00,
        $20, $00, $AC, $20, $01, $7C, $0B])]))
  ]);
end;

{ A v128 value passed THROUGH a call, so the flat marshaling moves a two-slot
  operand. Whether either function compiles depends on the v128 op coverage of
  the moment (Wave 6); the differential assertion holds either way, and the
  test reports which tier actually ran. }
function VecThroughCallModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7B, $01, $7B])])),
    Sect(3, VecOf([BLit([$00]), BLit([$00])])),
    Sect(7, VecOf([
      ExportEntry('id', $00, 0),
      ExportEntry('run', $00, 1)])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $0B]),
      CodeEntry([$00, $20, $00, $10, $00, $0B])]))
  ]);
end;

{ Host interop across the compiled seam:

    (import "e" "inc" (func (param i32) (result i32)))   ; func 0, host
    (func $callhost (param i32) (result i32) (call 0 (local.get 0)))
    (func $tailhost (param i32) (result i32) (return_call 0 (local.get 0))) }
function HostCallModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(2, VecOf([Cat([
      ULeb(1), StrBytes('e'), ULeb(3), StrBytes('inc'), BLit([$00, $00])])])),
    Sect(3, VecOf([BLit([$00]), BLit([$00])])),
    Sect(7, VecOf([
      ExportEntry('callhost', $00, 1),
      ExportEntry('tailhost', $00, 2)])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $10, $00, $0B]),
      CodeEntry([$00, $20, $00, $12, $00, $0B])]))
  ]);
end;

{ The EH-transparency shape (jit-spec §8.3/§10.2). A `throw` is delivered by
  an explicit unwind over the ACTIVATION STACK that stops at the first frame
  the interpreter cannot resume past, and every tier-seam frame is such a
  frame — so a compiled function sitting BETWEEN a throw and its handler would
  turn a caught exception into an uncaught one. $middle is exactly that
  function: nothing but a call, no handler of its own, in a module that has a
  tag. The fence must therefore refuse to compile it.

    (tag  $e (param i32))
    (func $thrower (param i32) (throw $e (local.get 0)))
    (func $middle  (param i32) (result i32) (call $thrower ...) (i32.const 0))
    (func $outer   (param i32) (result i32)
      (block $h (result i32)
        (try_table (result i32) (catch $e $h) (call $middle (local.get 0)))
        (return))) }
function ThrowAcrossCallModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7F, $00]),
      BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$01])])),
    { The tag section (id 13) encodes between memory and global, i.e. before
      the export section — ids are not the encoding order. }
    Sect(13, VecOf([BLit([$00, $00])])),
    Sect(7, VecOf([
      ExportEntry('middle', $00, 1),
      ExportEntry('outer', $00, 2)])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $08, $00, $0B]),
      CodeEntry([$00, $20, $00, $10, $00, $41, $00, $0B]),
      CodeEntry([$00,
        $02, $7F,
        $1F, $7F, $01, $00, $00, $01,
        $20, $00, $10, $01,
        $0B,
        $0F,
        $0B,
        $0B])]))
  ]);
end;

{ The imported host function the two modules above call: n -> n + 100. }
procedure JitIncCallback(const AStore: TWasmStore; const AData: Pointer;
  const AParams: PWasmValue; const AResults: PWasmValue);
begin
  AResults[0] := MakeValueI32(AParams[0].I32 + 100);
end;

{ --- Waves 4/5 modules: memory / table / reference / global / GC --------

  Each is a complete module in literal bytes so the shape under test reads next
  to the assertion. Stateful ops (grow, fill, set) are run under DiffFresh —
  two SEPARATE fresh stores (jit-spec §11.2) — so the compiled run never sees
  the interpreted run's mutations. Section ids in encoding order: 1 type,
  3 func, 5 memory, 6 global, 7 export, 9 elem, 12 datacount, 10 code,
  11 data. }

{ Memory basics: store/load round-trip, a sign-extending narrow load from a
  pre-initialised data segment, an out-of-bounds load, size, grow, fill, copy.
  (memory 1) with an active data segment [$FF,$11,..$77] at offset 0. }
function MemBasicModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $02, $7F, $7F, $01, $7F]),          { 0: (i32,i32)->i32 }
      BLit([$60, $01, $7F, $01, $7F]),               { 1: (i32)->i32 }
      BLit([$60, $00, $01, $7F]),                    { 2: ()->i32 }
      BLit([$60, $03, $7F, $7F, $7F, $01, $7F])])),  { 3: (i32,i32,i32)->i32 }
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$01]), BLit([$02]),
      BLit([$01]), BLit([$03]), BLit([$03]), BLit([$01])])),
    Sect(5, VecOf([BLit([$00, $01])])),              { memory min 1 }
    Sect(7, VecOf([
      ExportEntry('sload', $00, 0),
      ExportEntry('load8s', $00, 1),
      ExportEntry('oobload', $00, 2),
      ExportEntry('size', $00, 3),
      ExportEntry('grow', $00, 4),
      ExportEntry('fill', $00, 5),
      ExportEntry('copy', $00, 6),
      ExportEntry('offsetload', $00, 7)])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $20, $01, $36, $02, $00,
        $20, $00, $28, $02, $00, $0B]),              { store arg1@arg0; load arg0 }
      CodeEntry([$00, $20, $00, $2C, $00, $00, $0B]), { i32.load8_s arg0 }
      CodeEntry([$00, $20, $00, $28, $02, $00, $0B]), { i32.load arg0 (OOB) }
      CodeEntry([$00, $3F, $00, $0B]),               { memory.size }
      CodeEntry([$00, $20, $00, $40, $00, $0B]),      { memory.grow arg0 }
      CodeEntry([$00, $20, $00, $20, $01, $20, $02, $FC, $0B, $00,
        $20, $00, $2D, $00, $00, $0B]),               { fill; load8_u arg0 }
      CodeEntry([$00, $20, $00, $20, $01, $20, $02, $FC, $0A, $00, $00,
        $20, $00, $2D, $00, $00, $0B]),               { copy; load8_u arg0 }
      CodeEntry([$00, $20, $00, $28, $02, $04, $0B])])), { i32.load offset=4 }
    Sect(11, VecOf([Cat([BLit([$00, $41, $00, $0B]),
      ULeb(8), BLit([$FF, $11, $22, $33, $44, $55, $66, $77])])]))
  ]);
end;

{ The largest valid memory64 memarg offset. The IR stores immediates in an
  Int64 slot, so this value exercises the unsigned bit-pattern boundary in
  every tier. It is valid to compile and traps only when the load executes. }
function Mem64MaxOffsetModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(5, VecOf([BLit([$04, $01])])),              { memory i64 min 1 }
    Sect(7, VecOf([ExportEntry('load', $00, 0)])),
    Sect(10, VecOf([CodeEntry([$00,
      $42, $00,                                      { i64.const 0 }
      $28, $02,                                      { i32.load align=2 }
      $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $01,
      $0B])]))                                       { offset=High(UInt64) }
  ]);
end;

{ A helper-free, zero-offset i32 memory loop: on aarch64 this is the exact
  shape allowed to pin the live base and retain numeric slots across scalar
  accesses. It stores and reloads i=0..n-1 and returns their sum. }
function MemLoopModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([ExportEntry('run', $00, 0)])),
    Sect(10, VecOf([CodeEntry([
      $01, $02, $7F,                  { locals: i, acc }
      $03, $40,                       { loop }
      $41, $00, $20, $01, $36, $02, $00, { memory[0] := i }
      $20, $02, $41, $00, $28, $02, $00, $6A, $21, $02, { acc += memory[0] }
      $20, $01, $41, $01, $6A, $22, $01, { ++i }
      $20, $00, $49, $0D, $00,        { while i < n }
      $0B, $20, $02, $0B])]))
  ]);
end;

{ The varying-address store/load pair used by the narrow aarch64 forwarding
  plan. The store's memory effect is observable independently at address 4
  after run(2), so reusing its value for the following load cannot accidentally
  turn into deleting the store. }
function MemForwardModuleBytes(const AMemoryPages: Byte = 1): TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(5, VecOf([BLit([$00, AMemoryPages])])),
    Sect(7, VecOf([ExportEntry('run', $00, 0)])),
    Sect(10, VecOf([CodeEntry([
      $01, $03, $7F,                  { locals: i, acc, addr }
      $03, $40,                       { loop }
      $20, $01, $41, $FF, $FF, $00, $71, $41, $02, $74, $21, $03,
      $20, $03, $20, $01, $36, $02, $00, { memory[addr] := i }
      $20, $02, $20, $03, $28, $02, $00, $6A, $21, $02,
      $20, $01, $41, $01, $6A, $21, $01,
      $20, $01, $20, $00, $49, $0D, $00,
      $0B, $20, $02, $0B])]))
  ]);
end;

{ A loop parameter is a dynamic IR slot whose next use is reached through the
  back edge rather than later in lexical order. The cached Arm64 path must
  reconcile it at the jump even though ordinary remaining-use counting has
  reached zero. The varying-address memory body keeps this on the optimized
  helper-free path; after 100 iterations the last observed value is 106. }
function MemLoopCarriedModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])),
    Sect(3, VecOf([BLit([$00])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([ExportEntry('run', $00, 0)])),
    Sect(10, VecOf([CodeEntry([
      $01, $06, $7F,                  { locals: i, acc, addr, seen, hot1, hot2 }
      $41, $07,                       { loop-carried value = 7 }
      $03, $00,                       { loop (param i32) (result i32) }
      $22, $04, $41, $01, $6A,       { seen = carried; carried += 1 }
      $20, $05, $41, $01, $6A, $21, $05,
      $20, $05, $41, $01, $6A, $21, $05, { keep hot1 statically allocated }
      $20, $06, $41, $01, $6A, $21, $06,
      $20, $06, $41, $01, $6A, $21, $06, { keep hot2 statically allocated }
      $20, $01, $41, $FF, $FF, $00, $71, $41, $02, $74, $21, $03,
      $20, $03, $20, $01, $36, $02, $00, { memory[addr] := i }
      $20, $02, $20, $03, $28, $02, $00, $6A, $21, $02,
      $20, $01, $41, $01, $6A, $21, $01, { ++i }
      $20, $01, $20, $00, $49, $0D, $00, { while i < n }
      $0B, $1A, $20, $04, $0B])]))
  ]);
end;

{ memory.init / data.drop over a PASSIVE data segment (needs the datacount
  section). init copies [srcoff..) of the segment to [arg0..); dropinit drops
  the segment then inits a non-empty range, which must trap. }
function MemInitModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $03, $7F, $7F, $7F, $01, $7F])])), { (i32,i32,i32)->i32 }
    Sect(3, VecOf([BLit([$00]), BLit([$00])])),
    Sect(5, VecOf([BLit([$00, $01])])),
    Sect(7, VecOf([
      ExportEntry('init', $00, 0),
      ExportEntry('dropinit', $00, 1)])),
    Sect(12, ULeb(1)),                               { datacount = 1 }
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $20, $01, $20, $02, $FC, $08, $00, $00,
        $20, $00, $2D, $00, $00, $0B]),               { memory.init 0 0; load8_u arg0 }
      CodeEntry([$00, $FC, $09, $00,                   { data.drop 0 }
        $20, $00, $20, $01, $20, $02, $FC, $08, $00, $00, { memory.init 0 0 (traps) }
        $20, $00, $2D, $00, $00, $0B])])),
    Sect(11, VecOf([Cat([BLit([$01]),                 { passive segment }
      ULeb(4), BLit([$AA, $BB, $CC, $DD])])]))
  ]);
end;

{ Table basics over an externref table (values are ref.null extern, so no
  functions or element segment are needed): size, set+get, grow, fill, and an
  out-of-bounds get. }
function TableModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $01, $7F]),                    { 0: ()->i32 }
      BLit([$60, $01, $7F, $01, $7F]),               { 1: (i32)->i32 }
      BLit([$60, $02, $7F, $7F, $01, $7F])])),       { 2: (i32,i32)->i32 }
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$01]), BLit([$01]),
      BLit([$02])])),
    Sect(4, VecOf([BLit([$6F, $00, $04])])),         { externref table min 4 }
    Sect(7, VecOf([
      ExportEntry('tsize', $00, 0),
      ExportEntry('tsetget', $00, 1),
      ExportEntry('tgrow', $00, 2),
      ExportEntry('toobget', $00, 3),
      ExportEntry('tfill', $00, 4)])),
    Sect(10, VecOf([
      CodeEntry([$00, $FC, $10, $00, $0B]),           { table.size }
      CodeEntry([$00, $20, $00, $D0, $6F, $26, $00,   { set null@arg0 }
        $20, $00, $25, $00, $D1, $0B]),               { get arg0; is_null }
      CodeEntry([$00, $D0, $6F, $20, $00, $FC, $0F, $00, $0B]), { grow by arg0 }
      CodeEntry([$00, $20, $00, $25, $00, $D1, $0B]), { get arg0 (OOB); is_null }
      CodeEntry([$00, $20, $00, $D0, $6F, $20, $01, $FC, $11, $00,
        $FC, $10, $00, $0B])]))                       { fill; table.size }
  ]);
end;

{ Globals: a mutable i32 global (init 0) and a mutable externref global (init
  null). gget reads the i32; gset writes then reads it; grefset writes null to
  the ref global then checks is_null. }
function GlobalModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $01, $7F]),                    { 0: ()->i32 }
      BLit([$60, $01, $7F, $01, $7F])])),            { 1: (i32)->i32 }
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$00])])),
    Sect(6, VecOf([
      BLit([$7F, $01, $41, $00, $0B]),               { (mut i32) = 0 }
      BLit([$6F, $01, $D0, $6F, $0B])])),            { (mut externref) = null }
    Sect(7, VecOf([
      ExportEntry('gget', $00, 0),
      ExportEntry('gset', $00, 1),
      ExportEntry('grefset', $00, 2)])),
    Sect(10, VecOf([
      CodeEntry([$00, $23, $00, $0B]),                { global.get 0 }
      CodeEntry([$00, $20, $00, $24, $00, $23, $00, $0B]), { set 0 arg0; get 0 }
      CodeEntry([$00, $D0, $6F, $24, $01, $23, $01, $D1, $0B])])) { ref set/get null }
  ]);
end;

{ Reference ops on funcref (func 0 is declared in a declarative element segment
  so ref.func 0 is valid): is_null on null and on a funcref, ref.eq of the same
  funcref, and ref.as_non_null on a null (a 'null reference' trap). }
function RefModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $01, $7F])])),    { ()->i32 (and func 0 unused) }
    Sect(3, VecOf([BLit([$00]), BLit([$00]), BLit([$00]), BLit([$00]),
      BLit([$00])])),
    Sect(7, VecOf([
      ExportEntry('isnull_null', $00, 1),
      ExportEntry('isnull_func', $00, 2),
      ExportEntry('refeq', $00, 3),
      ExportEntry('asnonnull_trap', $00, 4)])),
    Sect(9, VecOf([BLit([$03, $00, $01, $00])])),    { declarative elem: func 0 }
    Sect(10, VecOf([
      CodeEntry([$00, $41, $00, $0B]),                { func 0: i32.const 0 }
      CodeEntry([$00, $D0, $70, $D1, $0B]),           { ref.null func; is_null -> 1 }
      CodeEntry([$00, $D2, $00, $D1, $0B]),           { ref.func 0; is_null -> 0 }
      CodeEntry([$00, $D0, $6D, $D0, $6D, $D3, $0B]), { ref.null eq x2; ref.eq -> 1 }
      CodeEntry([$00, $D0, $70, $D4, $1A, $41, $00, $0B])])) { null as_non_null (trap) }
  ]);
end;

{ GC structs. type 0 = struct (mut i32); type 1 = struct (mut i8) (packed, for
  get_s/get_u); type 2 has a (ref null 0) field for the set round-trip. All
  test functions return a NUMERIC field value (never a ref handle), so the
  comparison is heap-address-independent across the two fresh stores. }
function GcStructModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $01, $7F, $01]),                    { 0: struct (mut i32) }
      BLit([$5F, $01, $78, $01]),                    { 1: struct (mut i8) }
      BLit([$60, $01, $7F, $01, $7F])])),            { 2: (i32)->i32 }
    Sect(3, VecOf([BLit([$02]), BLit([$02]), BLit([$02]), BLit([$02])])),
    Sect(7, VecOf([
      ExportEntry('rt', $00, 0),
      ExportEntry('gets', $00, 1),
      ExportEntry('getu', $00, 2),
      ExportEntry('setget', $00, 3)])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $FB, $00, $00, $FB, $02, $00, $00, $0B]),
      CodeEntry([$00, $20, $00, $FB, $00, $01, $FB, $03, $01, $00, $0B]),
      CodeEntry([$00, $20, $00, $FB, $00, $01, $FB, $04, $01, $00, $0B]),
      CodeEntry([$01, $01, $63, $00,                  { local (ref null 0) }
        $FB, $01, $00, $21, $01,                      { new_default; local.set1 }
        $20, $01, $20, $00, $FB, $05, $00, $00,       { struct.set 0 0 = arg0 }
        $20, $01, $FB, $02, $00, $00, $0B])]))        { struct.get 0 0 }
  ]);
end;

{ GC arrays. type 0 = array (mut i32); type 1 = array (mut i8) packed. Round-
  trip, length, packed sign/zero get, and an out-of-bounds get (a 'out of
  bounds array access' trap). }
function GcArrayModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5E, $7F, $01]),                          { 0: array (mut i32) }
      BLit([$5E, $78, $01]),                          { 1: array (mut i8) }
      BLit([$60, $02, $7F, $7F, $01, $7F]),           { 2: (i32,i32)->i32 }
      BLit([$60, $01, $7F, $01, $7F])])),             { 3: (i32)->i32 }
    Sect(3, VecOf([BLit([$02]), BLit([$03]), BLit([$02]), BLit([$02])])),
    Sect(7, VecOf([
      ExportEntry('rt', $00, 0),
      ExportEntry('len', $00, 1),
      ExportEntry('gets', $00, 2),
      ExportEntry('oobget', $00, 3)])),
    Sect(10, VecOf([
      { new array0 (val=arg0,len=arg1); array.get index 0 -> arg0 }
      CodeEntry([$00, $20, $00, $20, $01, $FB, $06, $00,
        $41, $00, $FB, $0B, $00, $0B]),
      { new_default array0 (len=arg0); array.len -> arg0 }
      CodeEntry([$00, $20, $00, $FB, $07, $00, $FB, $0F, $0B]),
      { new array1 packed (val=arg0,len=arg1); array.get_s index 0 }
      CodeEntry([$00, $20, $00, $20, $01, $FB, $06, $01,
        $41, $00, $FB, $0C, $01, $0B]),
      { new array0 (val=7,len=2); array.get index arg0 (OOB traps) }
      CodeEntry([$00, $41, $07, $41, $02, $FB, $06, $00,
        $20, $00, $FB, $0B, $00, $0B])]))
  ]);
end;

{ i31: ref.i31 then i31.get_s / i31.get_u (31-bit sign vs zero extension), and
  i31.get_s on a null (a 'null i31 reference' trap). }
function I31ModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7F, $01, $7F]),               { 0: (i32)->i32 }
      BLit([$60, $00, $01, $7F])])),                 { 1: ()->i32 }
    Sect(3, VecOf([BLit([$00]), BLit([$00]), BLit([$01])])),
    Sect(7, VecOf([
      ExportEntry('gets', $00, 0),
      ExportEntry('getu', $00, 1),
      ExportEntry('null_trap', $00, 2)])),
    Sect(10, VecOf([
      CodeEntry([$00, $20, $00, $FB, $1C, $FB, $1D, $0B]), { ref.i31; i31.get_s }
      CodeEntry([$00, $20, $00, $FB, $1C, $FB, $1E, $0B]), { ref.i31; i31.get_u }
      CodeEntry([$00, $D0, $6C, $FB, $1D, $0B])]))         { null i31; get_s (trap) }
  ]);
end;

{ THE GC-SAFEPOINT WALKABILITY PROOF (jit-spec §9). An array is allocated and
  held in a local; a struct.new that references it then allocates — and with
  the heap threshold forced to 0 that struct.new triggers a COLLECTION while
  the array is live only in the frame's register file. If the compiled frame
  were not walkable (Slots/RefRegBits published by JitEnterFrame), the array
  would be freed and array.len would fault or return garbage. Returning arg0
  (the original length) under BOTH tiers is the proof.

    type 0 = array (mut i32); type 1 = struct (mut (ref null 0))
    (func (param i32) (result i32) (local (ref null 0)) (local (ref null 1))
      local.get0  array.new_default 0  local.set1        ; the live array
      local.get1  struct.new 1  local.set2               ; ALLOC -> may collect
      local.get1  array.len) }
function GcCollectModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5E, $7F, $01]),                          { 0: array (mut i32) }
      BLit([$5F, $01, $63, $00, $01]),                { 1: struct (mut (ref null 0)) }
      BLit([$60, $01, $7F, $01, $7F])])),             { 2: (i32)->i32 }
    Sect(3, VecOf([BLit([$02])])),
    Sect(7, VecOf([ExportEntry('collect', $00, 0)])),
    Sect(10, VecOf([
      CodeEntry([$02, $01, $63, $00, $01, $63, $01,   { local (ref null 0),(ref null 1) }
        $20, $00, $FB, $07, $00, $21, $01,            { array.new_default; set1 }
        $20, $01, $FB, $00, $01, $21, $02,            { struct.new 1; set2 }
        $20, $01, $FB, $0F, $0B])]))                  { array.len -> arg0 }
  ]);
end;

{ --- Wave-6 modules: v128 SIMD via the Wasm.Interp.Vector leaves ---------

  Each is a complete module in literal bytes so the v128 shape reads next to the
  assertion. A v128 op is `0xFD <ULeb subop>` (Fd), a const/shuffle carries a
  16-byte immediate (V16), a lane op a laneidx byte, a memory op a memarg
  (align, offset). Every function under test compiles now that Wave 6 stops
  declining v128 functions — the differential driver asserts the compiled
  result is bit-identical to the interpreter, per lane. }

{ Pure v128 compute (no memory, no GC): const, splat, extract/replace lane,
  i32x4.add, i32x4.eq, i8x16.shuffle, i8x16.swizzle. Every export returns an
  extracted scalar lane, so the comparison is a plain i32. }
function SimdComputeModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7F, $01, $7F]),               { 0: (i32)->i32 }
      BLit([$60, $00, $01, $7F])])),                 { 1: ()->i32 }
    Sect(3, VecOf([BLit([$00]), BLit([$00]), BLit([$00]),
      BLit([$01]), BLit([$01]), BLit([$01])])),
    Sect(7, VecOf([
      ExportEntry('dbl', $00, 0),
      ExportEntry('cmp', $00, 1),
      ExportEntry('rep', $00, 2),
      ExportEntry('konst', $00, 3),
      ExportEntry('shuf', $00, 4),
      ExportEntry('swz', $00, 5)])),
    Sect(10, VecOf([
      { splat arg into 4 lanes, add to itself, extract lane 0 = 2*arg }
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(17), BLit([$20, $00]), Fd(17),
        Fd(174), Fd(27), BLit([$00, $0B])])),
      { splat==splat -> all-ones lanes; extract lane 0 = 0xFFFFFFFF }
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(17), BLit([$20, $00]), Fd(17),
        Fd(55), Fd(27), BLit([$00, $0B])])),
      { splat arg; replace lane 1 with const 123; extract lane 1 = 123 }
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(17), BLit([$41, $7B]), Fd(28),
        BLit([$01]), Fd(27), BLit([$01, $0B])])),
      { v128.const 00..0F; extract i32 lane 1 = 0x07060504 }
      CodeEntry(Cat([BLit([$00]), Fd(12),
        V16([$00, $01, $02, $03, $04, $05, $06, $07,
        $08, $09, $0A, $0B, $0C, $0D, $0E, $0F]),
        Fd(27), BLit([$01, $0B])])),
      { shuffle two consts by a lane mask; extract i32 lane 0 }
      CodeEntry(Cat([BLit([$00]), Fd(12), V16([$10, $11, $12, $13]),
        Fd(12), V16([$20, $21, $22, $23]),
        Fd(13), V16([$00, $01, $02, $03, $10, $11, $12, $13,
        $04, $05, $06, $07, $14, $15, $16, $17]),
        Fd(27), BLit([$00, $0B])])),
      { swizzle data by an index vector; extract u8 lane 0 }
      CodeEntry(Cat([BLit([$00]), Fd(12),
        V16([$AA, $BB, $CC, $DD, $EE]),
        Fd(12), V16([$04, $03, $02, $01]),
        Fd(14), Fd(22), BLit([$00, $0B])]))
    ]))
  ]);
end;

{ v128 float ops whose identity is the whole point: a NaN through f32x4.add
  (canonical-NaN bits), and pmin/pmax/relaxed_min (payload-preserving / R=0
  selection). Signatures take f32 params carrying the exact bit patterns. }
function SimdFloatModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $01, $7D, $01, $7D]),               { 0: (f32)->f32 }
      BLit([$60, $02, $7D, $7D, $01, $7D])])),        { 1: (f32,f32)->f32 }
    Sect(3, VecOf([BLit([$00]), BLit([$01]), BLit([$01]), BLit([$01])])),
    Sect(7, VecOf([
      ExportEntry('nanadd', $00, 0),
      ExportEntry('pmin', $00, 1),
      ExportEntry('pmax', $00, 2),
      ExportEntry('relmin', $00, 3)])),
    Sect(10, VecOf([
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(19), BLit([$20, $00]), Fd(19),
        Fd(228), Fd(31), BLit([$00, $0B])])),
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(19), BLit([$20, $01]), Fd(19),
        Fd(234), Fd(31), BLit([$00, $0B])])),
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(19), BLit([$20, $01]), Fd(19),
        Fd(235), Fd(31), BLit([$00, $0B])])),
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(19), BLit([$20, $01]), Fd(19),
        Fd(269), Fd(31), BLit([$00, $0B])]))
    ]))
  ]);
end;

{ v128 through linear memory: a store/load round-trip, an out-of-bounds load
  (traps 'out of bounds memory access'), and a load8_lane. memarg is
  (align, offset); v128 ops carry no special encoding beyond that. }
function SimdMemModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $00, $01, $7F])])),    { ()->i32 }
    Sect(3, VecOf([BLit([$00]), BLit([$00]), BLit([$00])])),
    Sect(5, VecOf([BLit([$00, $01])])),              { memory min 1 page }
    Sect(7, VecOf([
      ExportEntry('rt', $00, 0),
      ExportEntry('oob', $00, 1),
      ExportEntry('l8lane', $00, 2)])),
    Sect(10, VecOf([
      { store a const at 0, load it back, extract i32 lane 1 }
      CodeEntry(Cat([BLit([$00, $41, $00]), Fd(12),
        V16([$00, $01, $02, $03, $04, $05, $06, $07,
        $08, $09, $0A, $0B, $0C, $0D, $0E, $0F]),
        Fd(11), BLit([$00, $00]),
        BLit([$41, $00]), Fd(0), BLit([$00, $00]),
        Fd(27), BLit([$01, $0B])])),
      { v128.load 16 bytes at index 65530 -> [65530,65546) exceeds one page }
      CodeEntry(Cat([BLit([$00]), Cat([BLit([$41]), SLeb(65530)]),
        Fd(0), BLit([$00, $00]), Fd(27), BLit([$00, $0B])])),
      { store known bytes, then load8_lane byte at addr 3 into lane 5, extract.
        load8_lane is [i32 addr, v128] -> [v128]: push the ADDRESS first, then
        the source vector on top, then the instruction. }
      CodeEntry(Cat([BLit([$00, $41, $00]), Fd(12),
        V16([$90, $91, $92, $93, $94, $95, $96, $97,
        $98, $99, $9A, $9B, $9C, $9D, $9E, $9F]),
        Fd(11), BLit([$00, $00]),
        BLit([$41, $03]), Fd(12), V16([$00]),
        Fd(84), BLit([$00, $00, $05]),
        Fd(22), BLit([$05, $0B])]))
    ]))
  ]);
end;

{ The IR-only v128 ops: iroMoveVec (a v128 local.set/get is a 16-byte copy) and
  iroSelectVec (a typed select over two v128 operands). }
function SimdMoveSelectModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([BLit([$60, $01, $7F, $01, $7F])])), { (i32)->i32 }
    Sect(3, VecOf([BLit([$00]), BLit([$00])])),
    Sect(7, VecOf([
      ExportEntry('mv', $00, 0),
      ExportEntry('sel', $00, 1)])),
    Sect(10, VecOf([
      { local v128 <- splat arg (iroMoveVec on set); get; extract lane 0 }
      CodeEntry(Cat([BLit([$01, $01, $7B]),
        BLit([$20, $00]), Fd(17), BLit([$21, $01, $20, $01]),
        Fd(27), BLit([$00, $0B])])),
      { splat(arg) ? cond=arg : splat(99); typed select over v128; extract 0 }
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(17), BLit([$41, $63]), Fd(17),
        BLit([$20, $00, $1C, $01, $7B]), Fd(27), BLit([$00, $0B])]))
    ]))
  ]);
end;

{ A v128 global (mut v128) initialised by a v128.const: global.get and a
  set/get round-trip exercise iroGlobalGetVec / iroGlobalSetVec. }
function SimdGlobalModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$60, $00, $01, $7F]),                    { 0: ()->i32 }
      BLit([$60, $01, $7F, $01, $7F])])),            { 1: (i32)->i32 }
    Sect(3, VecOf([BLit([$00]), BLit([$01])])),
    Sect(6, VecOf([Cat([BLit([$7B, $01]), Fd(12),
      V16([$07, $00, $00, $00, $08, $00, $00, $00]), BLit([$0B])])])),
    Sect(7, VecOf([
      ExportEntry('gget', $00, 0),
      ExportEntry('grt', $00, 1)])),
    Sect(10, VecOf([
      CodeEntry(Cat([BLit([$00, $23, $00]), Fd(27), BLit([$00, $0B])])),
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(17), BLit([$24, $00, $23, $00]),
        Fd(27), BLit([$02, $0B])]))
    ]))
  ]);
end;

{ A v128 struct field (iroStructGetVec / iroStructSetVec) and a v128 array
  element (iroArrayGetVec / iroArraySetVec / iroArrayFillVec). Every export
  returns an extracted scalar lane, heap-address-independent across the two
  fresh stores DiffFresh uses. }
function SimdStructArrayModuleBytes: TWasmBytes;
begin
  Result := Cat([
    BLit(WASM_HEADER),
    Sect(1, VecOf([
      BLit([$5F, $01, $7B, $01]),                    { 0: struct (mut v128) }
      BLit([$5E, $7B, $01]),                          { 1: array (mut v128) }
      BLit([$60, $01, $7F, $01, $7F])])),            { 2: (i32)->i32 }
    Sect(3, VecOf([BLit([$02]), BLit([$02]), BLit([$02]), BLit([$02])])),
    Sect(7, VecOf([
      ExportEntry('srt', $00, 0),
      ExportEntry('sset', $00, 1),
      ExportEntry('art', $00, 2),
      ExportEntry('afill', $00, 3)])),
    Sect(10, VecOf([
      { struct.new type0 with a splat field; struct.get field0; extract lane 0 }
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(17),
        BLit([$FB, $00, $00, $FB, $02, $00, $00]),
        Fd(27), BLit([$00, $0B])])),
      { struct.new_default; struct.set field0 = splat; struct.get; extract 2 }
      CodeEntry(Cat([BLit([$01, $01, $63, $00,
        $FB, $01, $00, $21, $01,
        $20, $01, $20, $00]), Fd(17), BLit([$FB, $05, $00, $00,
        $20, $01, $FB, $02, $00, $00]), Fd(27), BLit([$02, $0B])])),
      { array.new type1 (val=splat,len=3); array.get index 0; extract lane 1 }
      CodeEntry(Cat([BLit([$00, $20, $00]), Fd(17),
        BLit([$41, $03, $FB, $06, $01, $41, $00, $FB, $0B, $01]),
        Fd(27), BLit([$01, $0B])])),
      { array.new_default(len4); array.fill val=splat count4; get; extract 0 }
      CodeEntry(Cat([BLit([$01, $01, $63, $01,
        $41, $04, $FB, $07, $01, $21, $01,
        $20, $01, $41, $00, $20, $00]), Fd(17),
        BLit([$41, $04, $FB, $10, $01,
        $20, $01, $41, $00, $FB, $0B, $01]), Fd(27), BLit([$00, $0B])]))
    ]))
  ]);
end;

{ --- the milestone module (Wave 1, kept as the anchor) ------------------- }

function AddModuleBytes: TWasmBytes;
begin
  { (func (export "add") (param i32 i32) (result i32) local.get0 local.get1
    i32.add) }
  Result := OneFunc(BLit([$60, $02, $7F, $7F, $01, $7F]),
    BLit([$00, $20, $00, $20, $01, $6A, $0B]), 'add');
end;

function MaskedShiftModuleBytes: TWasmBytes;
begin
  { (func (export "maskshift") (param i32) (result i32)
      (i32.shl (i32.and (local.get 0) (i32.const 16383)) (i32.const 2))) }
  Result := OneFunc(BLit([$60, $01, $7F, $01, $7F]),
    BLit([$00, $20, $00, $41, $FF, $FF, $00, $71, $41, $02, $74, $0B]),
    'maskshift');
end;

type
  TInputPair = record
    A, B: Int32;
  end;

  TCallOutcome = record
    Trapped: Boolean;
    Msg: string;
    Bits: UInt64;                    { result slot 0 }
    Extra: array[0 .. 3] of UInt64;  { result slots 1..4 (multi-value, v128) }
  end;

  TJitTests = class(TTestSuite)
  private
    FBytes: TWasmBytes;
    FModule: TWasmModule;
    FIr: TWasmIrModule;
    FEngine: TWasmEngine;
    FStore: TWasmStore;
    FImports: TWasmImports;
    FInstance: TWasmModuleInstance;
    FJit: TWasmJitContext;

    { Wave-3 knobs the differential driver reads. FDiffCompile names the
      EXPORTS to force-compile (empty = just the invoked one), which is how a
      compiled->interpreted or an interpreted->compiled call is built: the tier
      of each participant is chosen, not inferred from op coverage, so the test
      keeps meaning as later waves widen the predicate. FDiffResultSlots is the
      flat result-slot count to compare (>1 for multi-value and v128). }
    FDiffCompile: array of string;
    FDiffResultSlots: Integer;
    FDiffCompiledAll: Boolean;
    { When assigned, the module under test imports exactly one function, of
      module type 0, bound to this callback (the host-interop shape). }
    FDiffHost: TWasmHostFunc;

    { >= 0 forces Store.Heap.Threshold on BOTH tiers before the invoke, so a
      GC-triggering op (struct.new/array.new) collects mid-body — the §9
      walkability probe. -1 (default) leaves the heap's own threshold. }
    FDiffThreshold: Int64;

    procedure BuildAdd;
    function AddAddr: TWasmFuncAddr;
    function CallAdd(const AA, AB: Int32): TWasmValue;
    procedure CompileExports(const ANames: array of string);

    { The differential driver: build ABytes, run AExport interpreted, force-
      compile it, run it compiled, assert both outcomes are identical. Uses only
      local state so a single test can drive many modules. Returns whether the
      function actually compiled (AFalse = declined, ABoth runs interpreted). }
    function DiffModule(const ABytes: TWasmBytes; const AExport: string;
      const AParams: array of TWasmValue): Boolean;

    { Like DiffModule but on TWO SEPARATE FRESH STORES (jit-spec §11.2), one per
      tier, so a STATEFUL op (memory.grow / .fill / table.grow / global.set /
      allocation) under the compiled run never observes the interpreted run's
      mutations. Force-compiles the invoked export (or FDiffCompile). Returns
      whether it compiled under the JIT store. }
    function DiffFresh(const ABytes: TWasmBytes; const AExport: string;
      const AParams: array of TWasmValue): Boolean;

    { The trap message AExport produces, run INTERPRETED (the tier of record).
      DiffModule already proves the compiled tier produces the same string; this
      is what lets a test NAME the message rather than only assert the two tiers
      agree on whatever it is. Returns '' when the call did not trap. }
    function TrapMessageOf(const ABytes: TWasmBytes; const AExport: string;
      const AParams: array of TWasmValue): string;
  protected
    procedure BeforeEach; override;
    procedure AfterEach; override;
  public
    procedure SetupTests; override;

    procedure TestSlotSizeMatchesInterp;
    procedure TestMilestoneAddIdentical;
    procedure TestForceCompileSetsEntry;

    procedure TestI32Arith;
    procedure TestMaskedShiftFusion;
    procedure TestI64Arith;
    procedure TestI32Compare;
    procedure TestF64Ops;
    procedure TestF32SqrtNan;
    procedure TestDivRemTraps;
    procedure TestConstsAndConversions;
    procedure TestSelect;
    procedure TestNestedIf;
    procedure TestLoopSum;
    procedure TestBrTable;
    procedure TestUnreachable;
    procedure TestEpochInterruptDifferential;
    procedure TestEpochInterruptAcrossSeamToInterpCallee;

    { --- Wave 3: the call family ------------------------------------- }
    procedure TestCallCompiledToCompiled;
    procedure TestCallCompiledToInterpreted;
    procedure TestCallInterpretedToCompiled;
    procedure TestCallIndirectHit;
    procedure TestCallIndirectTraps;
    procedure TestCallRef;
    procedure TestMultiValueCall;
    procedure TestVecThroughCall;
    procedure TestHostCallInterop;
    procedure TestTailCallSelfIsBounded;
    procedure TestTailCallMutual;
    procedure TestTailCallCrossTierBounded;
    procedure TestTailCallToHost;
    procedure TestNativeScalarSelfProofGate;
    procedure TestDeepRecursionExhausts;
    procedure TestThrowAcrossCompiledFrameCaught;

    { --- Waves 4 & 5: memory / table / reference / global / GC ------- }
    procedure TestMemoryLoadStore;
    procedure TestForwardedMemoryLoadKeepsStoreEffect;
    procedure TestForwardedMemoryLoadKeepsStoreOobTrap;
    procedure TestMemoryLocalAliasCodeShape;
    procedure TestMemoryLoopCache;
    procedure TestMemoryLoopCarriedCache;
    procedure TestMemoryOobTraps;
    procedure TestMemory64MaxOffset;
    procedure TestMemorySizeGrow;
    procedure TestMemoryFillCopy;
    procedure TestMemoryInitDrop;
    procedure TestTableOps;
    procedure TestTableOobTrap;
    procedure TestGlobals;
    procedure TestReferenceOps;
    procedure TestStructRoundTrip;
    procedure TestArrayRoundTrip;
    procedure TestArrayOobTrap;
    procedure TestI31;
    procedure TestGcMidBodyCollectionWalkable;

    { --- Wave 6: v128 SIMD via the Wasm.Interp.Vector leaves --------- }
    procedure TestSimdCompute;
    procedure TestSimdFloatNanPminRelaxed;
    procedure TestSimdMemory;
    procedure TestSimdMemoryOob;
    procedure TestSimdMoveSelect;
    procedure TestSimdGlobal;
    procedure TestSimdStructArray;
  end;

procedure TJitTests.BeforeEach;
begin
  FModule := TWasmModule.Create;
  FIr := nil;
  FEngine := TWasmEngine.Create;
  FStore := TWasmStore.Create(FEngine);
  FInstance := nil;
  FJit := nil;
  FImports.Funcs := nil;
  FImports.Tables := nil;
  FImports.Mems := nil;
  FImports.Globals := nil;
  FImports.Tags := nil;
  WasmInterpValueSlots := 1 shl 16;
  WasmInterpMaxDepth := 256;
  FDiffCompile := nil;
  FDiffResultSlots := 1;
  FDiffCompiledAll := False;
  FDiffHost := nil;
  FDiffThreshold := -1;
end;

procedure TJitTests.CompileExports(const ANames: array of string);
var
  I: Integer;
begin
  SetLength(FDiffCompile, Length(ANames));
  for I := 0 to High(ANames) do
    FDiffCompile[I] := ANames[I];
end;

procedure TJitTests.AfterEach;
begin
  FreeAndNil(FJit);
  FreeAndNil(FStore);
  FreeAndNil(FEngine);
  FreeAndNil(FIr);
  FreeAndNil(FModule);
end;

procedure TJitTests.BuildAdd;
begin
  FBytes := AddModuleBytes;
  DecodeModule(FBytes, FModule);
  FreeAndNil(FIr);
  FIr := ValidateModule(FModule, FBytes);
  FInstance := InstantiateModule(FStore, FIr, @FBytes[0],
    NativeUInt(Length(FBytes)), FImports);
  RegisterInterpreter(FStore);
end;

function TJitTests.AddAddr: TWasmFuncAddr;
var
  Kind: TWasmExternKind;
  Addr: UInt32;
begin
  if not FInstance.FindExport('add', Kind, Addr) then
    raise EWasmError.Create('no export named add');
  Result := Addr;
end;

function TJitTests.CallAdd(const AA, AB: Int32): TWasmValue;
var
  Params: array[0 .. 1] of TWasmValue;
  Res: array[0 .. 0] of TWasmValue;
begin
  Params[0] := MakeValueI32(AA);
  Params[1] := MakeValueI32(AB);
  Res[0].Bits := High(UInt64);
  InterpInvoke(FStore, AddAddr, @Params[0], @Res[0]);
  Result := Res[0];
end;

{ --- the differential driver -------------------------------------------- }

function TJitTests.DiffModule(const ABytes: TWasmBytes; const AExport: string;
  const AParams: array of TWasmValue): Boolean;
var
  Module: TWasmModule;
  Ir: TWasmIrModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Imports: TWasmImports;
  Instance: TWasmModuleInstance;
  Jit: TWasmJitContext;
  Kind: TWasmExternKind;
  Addr: UInt32;
  Canon, TypeIds: TWasmEngineTypeIds;

  function Invoke: TCallOutcome;
  var
    P: array of TWasmValue;
    Res: array[0 .. 4] of TWasmValue;
    I: Integer;
  begin
    SetLength(P, Length(AParams));
    for I := 0 to High(AParams) do
      P[I] := AParams[I];
    for I := 0 to High(Res) do
      Res[I].Bits := High(UInt64);
    Result.Trapped := False;
    Result.Msg := '';
    Result.Bits := 0;
    for I := 0 to High(Result.Extra) do
      Result.Extra[I] := 0;
    try
      if Length(P) = 0 then
        InterpInvoke(Store, Addr, nil, @Res[0])
      else
        InterpInvoke(Store, Addr, @P[0], @Res[0]);
      Result.Bits := Res[0].Bits;
      for I := 0 to High(Result.Extra) do
        Result.Extra[I] := Res[I + 1].Bits;
    except
      on E: EWasmTrap do
      begin
        Result.Trapped := True;
        Result.Msg := E.Message;
      end;
    end;
  end;

  { Force-compile the exports FDiffCompile names (or the invoked one when it is
    empty). Returns True when every requested function actually compiled. }
  function CompileRequested: Boolean;
  var
    I: Integer;
    K: TWasmExternKind;
    A: UInt32;
  begin
    if Length(FDiffCompile) = 0 then
    begin
      Result := Jit.ForceCompile(Addr);
      Exit;
    end;
    Result := True;
    for I := 0 to High(FDiffCompile) do
    begin
      if not Instance.FindExport(FDiffCompile[I], K, A) then
        raise EWasmError.CreateFmt('no export named %s', [FDiffCompile[I]]);
      if not Jit.ForceCompile(A) then
        Result := False;
    end;
  end;

var
  InterpOut, JitOut: TCallOutcome;
  Slot: Integer;
begin
  Module := TWasmModule.Create;
  Engine := TWasmEngine.Create;
  Store := TWasmStore.Create(Engine);
  Ir := nil;
  Jit := nil;
  Imports.Funcs := nil;
  Imports.Tables := nil;
  Imports.Mems := nil;
  Imports.Globals := nil;
  Imports.Tags := nil;
  Result := False;
  try
    DecodeModule(ABytes, Module);
    Ir := ValidateModule(Module, ABytes);
    if Assigned(FDiffHost) then
    begin
      { The host import needs its engine type id, so intern before
        instantiating (the shape the epoch test established). }
      Engine.InternModule(Ir, Canon, TypeIds);
      SetLength(Imports.Funcs, 1);
      Imports.Funcs[0] := Store.AddHostFunc(TypeIds[0], FDiffHost, nil);
    end;
    Instance := InstantiateModule(Store, Ir, @ABytes[0],
      NativeUInt(Length(ABytes)), Imports);
    RegisterInterpreter(Store);
    if not Instance.FindExport(AExport, Kind, Addr) then
      raise EWasmError.CreateFmt('no export named %s', [AExport]);

    { Reference: interpreter, before any compilation. }
    InterpOut := Invoke;

    { Compile and run again: now every call routes through the machine code. }
    Jit := RegisterJit(Store);
    Result := CompileRequested;
    FDiffCompiledAll := Result;
    JitOut := Invoke;

    { A normal compiled return, including the direct compiled-to-compiled
      epilogue, must retire both runtime views of the activation. This catches
      a fast return that copies the value correctly but leaves either the GC
      chain or the shared logical-frame cursors stale for the next call. }
    Expect<Boolean>(Store.Heap.CurrentFrame = nil).ToBe(True);
    Expect<NativeUInt>(InterpContextFor(Store)^.Depth).ToBe(0);
    Expect<NativeUInt>(InterpContextFor(Store)^.ValueTop).ToBe(0);

    { Observational identity: same trap-or-value, bitwise. }
    Expect<Boolean>(JitOut.Trapped).ToBe(InterpOut.Trapped);
    if InterpOut.Trapped then
      Expect<string>(JitOut.Msg).ToBe(InterpOut.Msg)
    else
    begin
      Expect<UInt64>(JitOut.Bits).ToBe(InterpOut.Bits);
      for Slot := 1 to FDiffResultSlots - 1 do
        Expect<UInt64>(JitOut.Extra[Slot - 1]).ToBe(InterpOut.Extra[Slot - 1]);
    end;
  finally
    FreeAndNil(Jit);
    FreeAndNil(Store);
    FreeAndNil(Engine);
    FreeAndNil(Ir);
    FreeAndNil(Module);
  end;
end;

{ --- the two-fresh-stores differential driver (jit-spec §11.2) ----------- }

function TJitTests.DiffFresh(const ABytes: TWasmBytes; const AExport: string;
  const AParams: array of TWasmValue): Boolean;

  { Run AExport once on a brand-new store. When ACompile, register the JIT and
    force-compile the requested export(s); ACompiled reports whether every
    requested function actually compiled. }
  function RunTier(const ACompile: Boolean; out ACompiled: Boolean): TCallOutcome;
  var
    Module: TWasmModule;
    Ir: TWasmIrModule;
    Engine: TWasmEngine;
    Store: TWasmStore;
    Imports: TWasmImports;
    Instance: TWasmModuleInstance;
    Jit: TWasmJitContext;
    Kind: TWasmExternKind;
    Addr, A: UInt32;
    K: TWasmExternKind;
    P: array of TWasmValue;
    Res: array[0 .. 4] of TWasmValue;
    I: Integer;
  begin
    ACompiled := False;
    Result.Trapped := False;
    Result.Msg := '';
    Result.Bits := 0;
    for I := 0 to High(Result.Extra) do
      Result.Extra[I] := 0;
    Module := TWasmModule.Create;
    Engine := TWasmEngine.Create;
    Store := TWasmStore.Create(Engine);
    Ir := nil;
    Jit := nil;
    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    try
      DecodeModule(ABytes, Module);
      Ir := ValidateModule(Module, ABytes);
      Instance := InstantiateModule(Store, Ir, @ABytes[0],
        NativeUInt(Length(ABytes)), Imports);
      RegisterInterpreter(Store);
      { The §9 walkability probe: force a collection on every allocation so a
        struct.new/array.new collects mid-body under BOTH tiers. }
      if FDiffThreshold >= 0 then
        Store.Heap.Threshold := UInt64(FDiffThreshold);
      if not Instance.FindExport(AExport, Kind, Addr) then
        raise EWasmError.CreateFmt('no export named %s', [AExport]);

      if ACompile then
      begin
        Jit := RegisterJit(Store);
        if Length(FDiffCompile) = 0 then
          ACompiled := Jit.ForceCompile(Addr)
        else
        begin
          ACompiled := True;
          for I := 0 to High(FDiffCompile) do
          begin
            if not Instance.FindExport(FDiffCompile[I], K, A) then
              raise EWasmError.CreateFmt('no export named %s', [FDiffCompile[I]]);
            if not Jit.ForceCompile(A) then
              ACompiled := False;
          end;
        end;
      end;

      SetLength(P, Length(AParams));
      for I := 0 to High(AParams) do
        P[I] := AParams[I];
      for I := 0 to High(Res) do
        Res[I].Bits := High(UInt64);
      try
        if Length(P) = 0 then
          InterpInvoke(Store, Addr, nil, @Res[0])
        else
          InterpInvoke(Store, Addr, @P[0], @Res[0]);
        Result.Bits := Res[0].Bits;
        for I := 0 to High(Result.Extra) do
          Result.Extra[I] := Res[I + 1].Bits;
      except
        on E: EWasmTrap do
        begin
          Result.Trapped := True;
          Result.Msg := E.Message;
        end;
      end;
    finally
      FreeAndNil(Jit);
      FreeAndNil(Store);
      FreeAndNil(Engine);
      FreeAndNil(Ir);
      FreeAndNil(Module);
    end;
  end;

var
  InterpOut, JitOut: TCallOutcome;
  InterpCompiled: Boolean;
  Slot: Integer;
begin
  InterpOut := RunTier(False, InterpCompiled);   { the oracle }
  JitOut := RunTier(True, Result);               { the compiled tier }

  Expect<Boolean>(JitOut.Trapped).ToBe(InterpOut.Trapped);
  if InterpOut.Trapped then
    Expect<string>(JitOut.Msg).ToBe(InterpOut.Msg)
  else
  begin
    Expect<UInt64>(JitOut.Bits).ToBe(InterpOut.Bits);
    for Slot := 1 to FDiffResultSlots - 1 do
      Expect<UInt64>(JitOut.Extra[Slot - 1]).ToBe(InterpOut.Extra[Slot - 1]);
  end;
end;

{ --- the layout guard --------------------------------------------------- }

procedure TJitTests.TestSlotSizeMatchesInterp;
begin
  Expect<NativeUInt>(WasmJitFrameOffsets.ValueSlotSize)
    .ToBe(NativeUInt(ARM64_SLOT_SIZE));
end;

{ --- force-compile sets the seam --------------------------------------- }

procedure TJitTests.TestForceCompileSetsEntry;
var
  Compiled: Boolean;
begin
  BuildAdd;
  Expect<Boolean>(FStore.Funcs[AddAddr].CompiledEntry <> nil).ToBe(False);

  FJit := RegisterJit(FStore);
  Compiled := FJit.ForceCompile(AddAddr);

  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  Expect<Boolean>(FStore.Funcs[AddAddr].CompiledEntry <> nil).ToBe(True);
  Expect<Boolean>(FStore.Funcs[AddAddr].CompiledDirectEntry =
    FStore.Funcs[AddAddr].CompiledEntry).ToBe(True);
  Expect<Boolean>(FJit.ForceCompile(AddAddr)).ToBe(True);
  {$ELSE}
  Expect<Boolean>(Compiled).ToBe(False);
  Expect<Boolean>(FStore.Funcs[AddAddr].CompiledEntry <> nil).ToBe(False);
  Expect<Boolean>(FStore.Funcs[AddAddr].CompiledDirectEntry = nil).ToBe(True);
  {$ENDIF}
end;

{ --- THE differential milestone (Wave 1) -------------------------------- }

procedure TJitTests.TestMilestoneAddIdentical;
const
  Inputs: array[0 .. 4] of TInputPair = (
    (A: 17; B: 25),
    (A: 40; B: 2),
    (A: 0; B: 0),
    (A: -1; B: 1),
    (A: MaxInt; B: 1)
  );
var
  InterpBits: array[0 .. 4] of UInt64;
  I: Integer;
  V: TWasmValue;
  Compiled: Boolean;
begin
  BuildAdd;
  for I := 0 to High(Inputs) do
    InterpBits[I] := CallAdd(Inputs[I].A, Inputs[I].B).Bits;

  V.Bits := InterpBits[0];
  Expect<Int32>(V.I32).ToBe(42);

  FJit := RegisterJit(FStore);
  Compiled := FJit.ForceCompile(AddAddr);

  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  Expect<Boolean>(FStore.Funcs[AddAddr].CompiledEntry <> nil).ToBe(True);
  for I := 0 to High(Inputs) do
  begin
    V := CallAdd(Inputs[I].A, Inputs[I].B);
    Expect<UInt64>(V.Bits).ToBe(InterpBits[I]);
  end;
  V := CallAdd(17, 25);
  Expect<Int32>(V.I32).ToBe(42);
  V := CallAdd(MaxInt, 1);
  Expect<Int32>(V.I32).ToBe(Low(Int32));
  {$ELSE}
  Expect<Boolean>(Compiled).ToBe(False);
  for I := 0 to High(Inputs) do
  begin
    V := CallAdd(Inputs[I].A, Inputs[I].B);
    Expect<UInt64>(V.Bits).ToBe(InterpBits[I]);
  end;
  {$ENDIF}
end;

{ --- Wave 2: numeric spine ---------------------------------------------- }

{ Build a (param i32 i32)(result i32) function whose body is
  `local.get0 local.get1 OP`. }
function I32BinModule(const AOp: Byte; const AName: string): TWasmBytes;
begin
  Result := OneFunc(BLit([$60, $02, $7F, $7F, $01, $7F]),
    BLit([$00, $20, $00, $20, $01, AOp, $0B]), AName);
end;

function I64BinModule(const AOp: Byte; const AName: string): TWasmBytes;
begin
  Result := OneFunc(BLit([$60, $02, $7E, $7E, $01, $7E]),
    BLit([$00, $20, $00, $20, $01, AOp, $0B]), AName);
end;

procedure TJitTests.TestI32Arith;
const
  Ops: array[0 .. 12] of Byte = (
    $6A, $6B, $6C,          { add sub mul }
    $71, $72, $73,          { and or xor }
    $74, $75, $76,          { shl shr_s shr_u }
    $77, $78,               { rotl rotr }
    $6E, $70);              { div_u rem_u (leaf, non-trapping here) }
  Pairs: array[0 .. 4] of TInputPair = (
    (A: 12; B: 5),
    (A: -7; B: 3),
    (A: Integer($FFFFFFFF); B: 33),   { shift count masks to 1 }
    (A: 100; B: 7),
    (A: Integer($80000000); B: -1));
var
  I, J: Integer;
  Compiled: Boolean;
begin
  for I := 0 to High(Ops) do
    for J := 0 to High(Pairs) do
    begin
      Compiled := DiffModule(I32BinModule(Ops[I], 'op'), 'op',
        [MakeValueI32(Pairs[J].A), MakeValueI32(Pairs[J].B)]);
      {$IFDEF WASM_JIT_BACKEND}
      Expect<Boolean>(Compiled).ToBe(True);
      {$ELSE}
      Expect<Boolean>(Compiled).ToBe(False);
      {$ENDIF}
    end;
end;

procedure TJitTests.TestMaskedShiftFusion;
begin
  Expect<Boolean>(DiffFresh(MaskedShiftModuleBytes, 'maskshift',
    [MakeValueI32(Integer($DEADBEEF))])).ToBe(
      {$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

procedure TJitTests.TestI64Arith;
const
  Ops: array[0 .. 10] of Byte = (
    $7C, $7D, $7E,          { add sub mul }
    $83, $84, $85,          { and or xor }
    $86, $87, $88,          { shl shr_s shr_u }
    $89, $8A);              { rotl rotr }
var
  I: Integer;
  Compiled: Boolean;
begin
  for I := 0 to High(Ops) do
  begin
    Compiled := DiffModule(I64BinModule(Ops[I], 'op'), 'op',
      [VBits(UInt64($0123456789ABCDEF)), VBits(UInt64(69))]);
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
    { Also a negative/large second operand to exercise the sign paths. }
    Compiled := DiffModule(I64BinModule(Ops[I], 'op'), 'op',
      [VBits(UInt64($FFFFFFFFFFFFFFFF)), VBits(UInt64(200))]);
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
  end;
end;

procedure TJitTests.TestI32Compare;
const
  { eqz is unary; the rest are binary. }
  BinOps: array[0 .. 9] of Byte = (
    $46, $47,               { eq ne }
    $48, $49, $4A, $4B,     { lt_s lt_u gt_s gt_u }
    $4C, $4D, $4E, $4F);    { le_s le_u ge_s ge_u }
  Pairs: array[0 .. 3] of TInputPair = (
    (A: 5; B: 5),
    (A: -1; B: 1),
    (A: 1; B: -1),
    (A: Integer($80000000); B: 1));
var
  I, J: Integer;
  Compiled: Boolean;
begin
  for I := 0 to High(BinOps) do
    for J := 0 to High(Pairs) do
    begin
      Compiled := DiffModule(I32BinModule(BinOps[I], 'op'), 'op',
        [MakeValueI32(Pairs[J].A), MakeValueI32(Pairs[J].B)]);
      {$IFDEF WASM_JIT_BACKEND}
      Expect<Boolean>(Compiled).ToBe(True);
      {$ENDIF}
    end;

  { i32.eqz (0x45): (param i32)(result i32) local.get0 i32.eqz. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7F, $01, $7F]),
      BLit([$00, $20, $00, $45, $0B]), 'eqz'), 'eqz', [MakeValueI32(0)]);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7F, $01, $7F]),
      BLit([$00, $20, $00, $45, $0B]), 'eqz'), 'eqz', [MakeValueI32(9)]);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
end;

function F64BinModule(const AOp: Byte; const AName: string): TWasmBytes;
begin
  Result := OneFunc(BLit([$60, $02, $7C, $7C, $01, $7C]),
    BLit([$00, $20, $00, $20, $01, AOp, $0B]), AName);
end;

procedure TJitTests.TestF64Ops;
const
  Ops: array[0 .. 6] of Byte = (
    $A0, $A1, $A2, $A3,     { add sub mul div }
    $A4, $A5,               { min max }
    $A6);                   { copysign }
  { A signalling-ish NaN payload and a quiet NaN, plus ordinary values. Both
    tiers must canonicalize a NaN result to the positive canonical pattern. }
  QNAN = UInt64($7FF8000000000001);
var
  I: Integer;
  Compiled: Boolean;
begin
  for I := 0 to High(Ops) do
  begin
    { normal x normal }
    Compiled := DiffModule(F64BinModule(Ops[I], 'op'), 'op',
      [MakeValueF64(3.5), MakeValueF64(-1.25)]);
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
    { NaN x normal — the NaN-bit identity case (§13 item 1). }
    Compiled := DiffModule(F64BinModule(Ops[I], 'op'), 'op',
      [VBits(QNAN), MakeValueF64(2.0)]);
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
    { division/other by zero -> inf or NaN, never a trap for floats. }
    Compiled := DiffModule(F64BinModule(Ops[I], 'op'), 'op',
      [MakeValueF64(1.0), MakeValueF64(0.0)]);
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
  end;
end;

procedure TJitTests.TestF32SqrtNan;
var
  Compiled: Boolean;
begin
  { (param f32)(result f32) local.get0 f32.sqrt (0x91). sqrt(-4) is a canonical
    NaN both tiers; sqrt(16) is 4.0. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7D, $01, $7D]),
      BLit([$00, $20, $00, $91, $0B]), 'sq'), 'sq', [MakeValueF32(16.0)]);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7D, $01, $7D]),
      BLit([$00, $20, $00, $91, $0B]), 'sq'), 'sq', [MakeValueF32(-4.0)]);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
end;

procedure TJitTests.TestDivRemTraps;
var
  Compiled: Boolean;
begin
  { div_s (0x6D): divide-by-zero and INT_MIN/-1 overflow both trap, same
    message, same tier; a normal case returns. }
  Compiled := DiffModule(I32BinModule($6D, 'ds'), 'ds',
    [MakeValueI32(20), MakeValueI32(6)]);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
  DiffModule(I32BinModule($6D, 'ds'), 'ds',
    [MakeValueI32(10), MakeValueI32(0)]);            { divide by zero }
  DiffModule(I32BinModule($6D, 'ds'), 'ds',
    [MakeValueI32(Integer($80000000)), MakeValueI32(-1)]); { overflow }

  { rem_s (0x6F): divide-by-zero traps; INT_MIN % -1 = 0 does NOT trap. }
  DiffModule(I32BinModule($6F, 'rs'), 'rs',
    [MakeValueI32(10), MakeValueI32(0)]);            { divide by zero }
  DiffModule(I32BinModule($6F, 'rs'), 'rs',
    [MakeValueI32(Integer($80000000)), MakeValueI32(-1)]); { -> 0, no trap }

  { i64 div_s (0x7F) zero + overflow. }
  DiffModule(I64BinModule($7F, 'ds64'), 'ds64',
    [VBits(5), VBits(0)]);
  DiffModule(I64BinModule($7F, 'ds64'), 'ds64',
    [VBits(UInt64($8000000000000000)), VBits(UInt64($FFFFFFFFFFFFFFFF))]);
end;

procedure TJitTests.TestConstsAndConversions;
var
  Compiled: Boolean;
begin
  { i32.const then wrap-independent return: (result i32) i32.const 0xABCD. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $00, $01, $7F]),
      Cat([BLit([$00, $41]), SLeb(305419896), BLit([$0B])]),  { 0x12345678 }
      'k'), 'k', []);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}

  { i64.const negative: (result i64) i64.const -3. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $00, $01, $7E]),
      Cat([BLit([$00, $42]), SLeb(-3), BLit([$0B])]), 'k64'), 'k64', []);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}

  { i64.extend_i32_s (0xAC): (param i32)(result i64) local.get0 i64.extend_i32_s.
    Leaf-called conversion. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7F, $01, $7E]),
      BLit([$00, $20, $00, $AC, $0B]), 'ext'), 'ext',
    [MakeValueI32(-5)]);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}

  { f64.convert_i32_s (0xB7) then i32.trunc_f64_s (0xAA) round-trip a value:
    (param i32)(result i32) local.get0 f64.convert_i32_s i32.trunc_f64_s. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7F, $01, $7F]),
      BLit([$00, $20, $00, $B7, $AA, $0B]), 'rt'), 'rt',
    [MakeValueI32(-1234)]);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}

  { i32.trunc_f64_s of a NaN traps 'invalid conversion to integer', same both
    tiers (the leaf calls TrapNow). Feed a NaN through reinterpret-free: use a
    (param f64)(result i32) local.get0 i32.trunc_f64_s. }
  DiffModule(
    OneFunc(BLit([$60, $01, $7C, $01, $7F]),
      BLit([$00, $20, $00, $AA, $0B]), 'tr'), 'tr',
    [VBits(UInt64($7FF8000000000000))]);   { NaN -> trap }
  { And an out-of-range +inf -> 'integer overflow'. }
  DiffModule(
    OneFunc(BLit([$60, $01, $7C, $01, $7F]),
      BLit([$00, $20, $00, $AA, $0B]), 'tr'), 'tr',
    [VBits(UInt64($7FF0000000000000))]);   { +inf -> trap }
end;

procedure TJitTests.TestSelect;
var
  Compiled: Boolean;
begin
  { (param i32 i32 i32)(result i32) local.get0 local.get1 local.get2 select.
    select (0x1B) picks arg0 if the condition (arg2) is non-zero. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $03, $7F, $7F, $7F, $01, $7F]),
      BLit([$00, $20, $00, $20, $01, $20, $02, $1B, $0B]), 'sel'), 'sel',
    [MakeValueI32(111), MakeValueI32(222), MakeValueI32(1)]);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
  Compiled := DiffModule(
    OneFunc(BLit([$60, $03, $7F, $7F, $7F, $01, $7F]),
      BLit([$00, $20, $00, $20, $01, $20, $02, $1B, $0B]), 'sel'), 'sel',
    [MakeValueI32(111), MakeValueI32(222), MakeValueI32(0)]);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
end;

procedure TJitTests.TestNestedIf;
const
  Pairs: array[0 .. 2] of TInputPair = (
    (A: 9; B: 4),
    (A: 4; B: 9),
    (A: 5; B: 5));
var
  Body: TWasmBytes;
  I: Integer;
  Compiled: Boolean;
begin
  { (param i32 i32)(result i32): if a>b then a-b else b-a (an if/else, which
    lowers to branch_if_not + jumps + merge moves). }
  Body := BLit([
    $00,                    { no locals }
    $20, $00, $20, $01, $4A,{ get0 get1 gt_s }
    $04, $7F,               { if (result i32) }
    $20, $00, $20, $01, $6B,{ get0 get1 sub }
    $05,                    { else }
    $20, $01, $20, $00, $6B,{ get1 get0 sub }
    $0B,                    { end if }
    $0B]);                  { end func }
  for I := 0 to High(Pairs) do
  begin
    Compiled := DiffModule(
      OneFunc(BLit([$60, $02, $7F, $7F, $01, $7F]), Body, 'ad'), 'ad',
      [MakeValueI32(Pairs[I].A), MakeValueI32(Pairs[I].B)]);
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
  end;
end;

procedure TJitTests.TestLoopSum;
var
  Body: TWasmBytes;
  Compiled: Boolean;
begin
  { (param i32)(result i32): sum i for i in n..1 via a loop whose back-edge
    carries the epoch safepoint (§6). This exercises the emitted epoch-check on
    every iteration without tripping it (Store.Epoch is unchanged), and proves
    the compiled loop result matches the interpreter's. }
  Body := BLit([
    $01, $01, $7F,          { 1 local group: 1 x i32 (the accumulator, reg 1) }
    $02, $40,               { block void (L1) }
    $03, $40,               { loop void (L0) }
    $20, $00, $45,          { local.get0; i32.eqz }
    $0D, $01,               { br_if 1 -> break out of L1 }
    $20, $01, $20, $00, $6A,{ local.get1; local.get0; i32.add }
    $21, $01,               { local.set1 (acc += i) }
    $20, $00, $41, $01, $6B,{ local.get0; i32.const 1; i32.sub }
    $21, $00,               { local.set0 (i -= 1) }
    $0C, $00,               { br 0 -> loop back-edge (safepoint) }
    $0B,                    { end loop }
    $0B,                    { end block }
    $20, $01,               { local.get1 (return acc) }
    $0B]);                  { end func }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $01, $7F, $01, $7F]), Body, 'sum'), 'sum',
    [MakeValueI32(0)]);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
  { A handful of back-edges. }
  DiffModule(OneFunc(BLit([$60, $01, $7F, $01, $7F]), Body, 'sum'), 'sum',
    [MakeValueI32(5)]);
  { Many back-edges -> the epoch check runs 100 times and never false-trips. }
  DiffModule(OneFunc(BLit([$60, $01, $7F, $01, $7F]), Body, 'sum'), 'sum',
    [MakeValueI32(100)]);
end;

procedure TJitTests.TestBrTable;
var
  Body: TWasmBytes;
  Compiled: Boolean;
  Sel: Integer;
begin
  { (param i32)(result i32): local defaults 30; br_table selects: 0 -> 10,
    anything else -> 30. }
  Body := BLit([
    $01, $01, $7F,          { local reg 1 }
    $41, $1E, $21, $01,     { i32.const 30; local.set1 }
    $02, $40,               { block (L1) }
    $02, $40,               { block (L0) }
    $20, $00,               { local.get0 (selector) }
    $0E, $01, $00, $01,     { br_table [0] default 1 }
    $0B,                    { end L0 }
    $41, $0A, $21, $01,     { i32.const 10; local.set1 }
    $0C, $00,               { br 0 -> L1 end (L0 already closed) }
    $0B,                    { end L1 }
    $20, $01,               { local.get1 }
    $0B]);                  { end func }
  for Sel := 0 to 3 do
  begin
    Compiled := DiffModule(
      OneFunc(BLit([$60, $01, $7F, $01, $7F]), Body, 'bt'), 'bt',
      [MakeValueI32(Sel)]);
    {$IFDEF WASM_JIT_BACKEND}
    Expect<Boolean>(Compiled).ToBe(True);
    {$ENDIF}
  end;
end;

procedure TJitTests.TestUnreachable;
var
  Compiled: Boolean;
begin
  { (result i32) unreachable — both tiers trap 'unreachable'. }
  Compiled := DiffModule(
    OneFunc(BLit([$60, $00, $01, $7F]), BLit([$00, $00, $0B]), 'boom'),
    'boom', []);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(Compiled).ToBe(True);
  {$ENDIF}
end;

{ FIX 1 (jit-spec §6): the epoch snapshot is shared per outermost invocation
  and read by BOTH tiers. An interpreted caller bumps the epoch via a host call
  then calls a compiled leaf; the leaf's back-edge must trap 'interrupt' exactly
  as the interpreter would. Before the fix the compiled prologue re-snapshotted
  the already-bumped epoch and did NOT trap — the differential gap this closes.
  This is the epoch-interrupt case Wave 2 explicitly deferred to Wave 3. }
procedure TJitTests.TestEpochInterruptDifferential;

  function RunOnce(const ACompileLeaf: Boolean): TCallOutcome;
  var
    Bytes: TWasmBytes;
    Module: TWasmModule;
    Ir: TWasmIrModule;
    Engine: TWasmEngine;
    Store: TWasmStore;
    Imports: TWasmImports;
    Instance: TWasmModuleInstance;
    Jit: TWasmJitContext;
    Canon, TypeIds: TWasmEngineTypeIds;
    HostAddr, LeafAddr, RunAddr: TWasmFuncAddr;
    Kind: TWasmExternKind;
    Addr: UInt32;
    Res: array[0 .. 0] of TWasmValue;
  begin
    Result.Trapped := False;
    Result.Msg := '';
    Result.Bits := 0;
    Bytes := EpochModuleBytes;
    Module := TWasmModule.Create;
    Engine := TWasmEngine.Create;
    Store := TWasmStore.Create(Engine);
    Ir := nil;
    Jit := nil;
    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    try
      DecodeModule(Bytes, Module);
      Ir := ValidateModule(Module, Bytes);
      { The host import needs its engine type id, so intern before instantiate. }
      Engine.InternModule(Ir, Canon, TypeIds);
      HostAddr := Store.AddHostFunc(TypeIds[0], @JitBumpEpochCallback, nil);
      SetLength(Imports.Funcs, 1);
      Imports.Funcs[0] := HostAddr;
      Instance := InstantiateModule(Store, Ir, @Bytes[0],
        NativeUInt(Length(Bytes)), Imports);
      RegisterInterpreter(Store);

      if not Instance.FindExport('leaf', Kind, Addr) then
        raise EWasmError.Create('no export named leaf');
      LeafAddr := Addr;
      if not Instance.FindExport('run', Kind, Addr) then
        raise EWasmError.Create('no export named run');
      RunAddr := Addr;

      if ACompileLeaf then
      begin
        Jit := RegisterJit(Store);
        { Only the LEAF is force-compiled, so the caller stays interpreted —
          exactly the interpreted-caller -> compiled-leaf shape the shared
          snapshot targets. (Since Wave 3 the caller WOULD compile, calls and
          all; leaving it interpreted here is deliberate, and RunAddr is
          referenced below so the tier choice stays explicit.) }
        Expect<Boolean>(Jit.ForceCompile(LeafAddr)).ToBe(JIT_BACKEND_AVAILABLE);
        Expect<Boolean>(Store.Funcs[RunAddr].CompiledEntry = nil).ToBe(True);
      end;

      Store.Epoch := 0;
      Store.EpochSnapshot := 0;
      Res[0].Bits := 0;
      try
        InterpInvoke(Store, RunAddr, nil, @Res[0]);
      except
        on E: EWasmTrap do
        begin
          Result.Trapped := True;
          Result.Msg := E.Message;
        end;
      end;
      { The leaf is a helper-free integer loop, so its instruction set and
        back-edge make it eligible for the function-wide static register
        cache. An epoch mismatch must still unwind past that cached frame and
        leave no stale trampoline or GC frame. A fresh outermost invocation on
        the same store re-captures the now-current epoch and must complete. }
      Expect<Boolean>(CurrentTrampoline = nil).ToBe(True);
      Expect<Boolean>(Store.Heap.CurrentFrame = nil).ToBe(True);
      if Result.Trapped then
      begin
        InterpInvoke(Store, LeafAddr, nil, nil);
        Expect<Boolean>(CurrentTrampoline = nil).ToBe(True);
        Expect<Boolean>(Store.Heap.CurrentFrame = nil).ToBe(True);
      end;
    finally
      FreeAndNil(Jit);
      FreeAndNil(Store);
      FreeAndNil(Engine);
      FreeAndNil(Ir);
      FreeAndNil(Module);
    end;
  end;

var
  InterpOut, JitOut: TCallOutcome;
begin
  { The oracle: fully interpreted, a mid-invocation epoch bump traps at the
    leaf's back-edge. }
  InterpOut := RunOnce(False);
  Expect<Boolean>(InterpOut.Trapped).ToBe(True);
  Expect<Boolean>(Pos('interrupt', InterpOut.Msg) > 0).ToBe(True);

  { The fix: the compiled leaf inherits the invocation's original snapshot and
    traps identically — same outcome, same message. }
  JitOut := RunOnce(True);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(JitOut.Trapped).ToBe(True);
  Expect<Boolean>(Pos('interrupt', JitOut.Msg) > 0).ToBe(True);
  Expect<string>(JitOut.Msg).ToBe(InterpOut.Msg);
  {$ELSE}
  { Off the JIT leg the leaf runs interpreted too, so both sides agree by
    construction. }
  Expect<Boolean>(JitOut.Trapped).ToBe(InterpOut.Trapped);
  Expect<string>(JitOut.Msg).ToBe(InterpOut.Msg);
  {$ENDIF}
end;


procedure TJitTests.TestEpochInterruptAcrossSeamToInterpCallee;

  { Fix B, the OTHER seam direction from TestEpochInterruptDifferential: force-
    compile the CALLER ($run) and leave the callee ($leaf) interpreted, so the
    compiled caller reaches the interpreted leaf across the seam through
    Arm64/X64CallInterpreted -> TierInvoke -> InterpTierInvoke. The epoch is
    bumped (by the host $run calls first) BETWEEN the outermost entry and the
    leaf's loop. Before Fix B, InterpTierInvoke re-seeded EpochSnapshot on that
    nested re-entry to the just-bumped value, so the leaf's back-edge saw
    Epoch = Snapshot and the interrupt was LOST. Seeding only at the outermost
    entry makes the leaf inherit the pre-bump snapshot and trap 'interrupt' —
    identically to the fully interpreted oracle. }
  function RunOnce(const ACompileRun: Boolean): TCallOutcome;
  var
    Bytes: TWasmBytes;
    Module: TWasmModule;
    Ir: TWasmIrModule;
    Engine: TWasmEngine;
    Store: TWasmStore;
    Imports: TWasmImports;
    Instance: TWasmModuleInstance;
    Jit: TWasmJitContext;
    Canon, TypeIds: TWasmEngineTypeIds;
    HostAddr, LeafAddr, RunAddr: TWasmFuncAddr;
    Kind: TWasmExternKind;
    Addr: UInt32;
    Res: array[0 .. 0] of TWasmValue;
  begin
    Result.Trapped := False;
    Result.Msg := '';
    Result.Bits := 0;
    Bytes := EpochModuleBytes;
    Module := TWasmModule.Create;
    Engine := TWasmEngine.Create;
    Store := TWasmStore.Create(Engine);
    Ir := nil;
    Jit := nil;
    Imports.Funcs := nil;
    Imports.Tables := nil;
    Imports.Mems := nil;
    Imports.Globals := nil;
    Imports.Tags := nil;
    try
      DecodeModule(Bytes, Module);
      Ir := ValidateModule(Module, Bytes);
      Engine.InternModule(Ir, Canon, TypeIds);
      HostAddr := Store.AddHostFunc(TypeIds[0], @JitBumpEpochCallback, nil);
      SetLength(Imports.Funcs, 1);
      Imports.Funcs[0] := HostAddr;
      Instance := InstantiateModule(Store, Ir, @Bytes[0],
        NativeUInt(Length(Bytes)), Imports);
      RegisterInterpreter(Store);
      if not Instance.FindExport('leaf', Kind, Addr) then
        raise EWasmError.Create('no export named leaf');
      LeafAddr := Addr;
      if not Instance.FindExport('run', Kind, Addr) then
        raise EWasmError.Create('no export named run');
      RunAddr := Addr;

      if ACompileRun then
      begin
        Jit := RegisterJit(Store);
        { Only the CALLER is compiled; the leaf stays interpreted and is reached
          across the tier seam — the nested re-entry that must NOT re-seed. }
        Expect<Boolean>(Jit.ForceCompile(RunAddr)).ToBe(JIT_BACKEND_AVAILABLE);
        Expect<Boolean>(Store.Funcs[LeafAddr].CompiledEntry = nil).ToBe(True);
      end;

      Store.Epoch := 0;
      Store.EpochSnapshot := 0;
      Res[0].Bits := 0;
      try
        InterpInvoke(Store, RunAddr, nil, @Res[0]);
      except
        on E: EWasmTrap do
        begin
          Result.Trapped := True;
          Result.Msg := E.Message;
        end;
      end;
    finally
      FreeAndNil(Jit);
      FreeAndNil(Store);
      FreeAndNil(Engine);
      FreeAndNil(Ir);
      FreeAndNil(Module);
    end;
  end;

var
  InterpOut, JitOut: TCallOutcome;
begin
  InterpOut := RunOnce(False);
  Expect<Boolean>(InterpOut.Trapped).ToBe(True);
  Expect<Boolean>(Pos('interrupt', InterpOut.Msg) > 0).ToBe(True);

  JitOut := RunOnce(True);
  {$IFDEF WASM_JIT_BACKEND}
  Expect<Boolean>(JitOut.Trapped).ToBe(True);
  Expect<Boolean>(Pos('interrupt', JitOut.Msg) > 0).ToBe(True);
  Expect<string>(JitOut.Msg).ToBe(InterpOut.Msg);
  {$ELSE}
  Expect<Boolean>(JitOut.Trapped).ToBe(InterpOut.Trapped);
  Expect<string>(JitOut.Msg).ToBe(InterpOut.Msg);
  {$ENDIF}
end;


function TJitTests.TrapMessageOf(const ABytes: TWasmBytes;
  const AExport: string; const AParams: array of TWasmValue): string;
var
  Module: TWasmModule;
  Ir: TWasmIrModule;
  Engine: TWasmEngine;
  Store: TWasmStore;
  Imports: TWasmImports;
  Instance: TWasmModuleInstance;
  Canon, TypeIds: TWasmEngineTypeIds;
  Kind: TWasmExternKind;
  Addr: UInt32;
  P: array of TWasmValue;
  Res: array[0 .. 4] of TWasmValue;
  I: Integer;
begin
  Result := '';
  Module := TWasmModule.Create;
  Engine := TWasmEngine.Create;
  Store := TWasmStore.Create(Engine);
  Ir := nil;
  Imports.Funcs := nil;
  Imports.Tables := nil;
  Imports.Mems := nil;
  Imports.Globals := nil;
  Imports.Tags := nil;
  try
    DecodeModule(ABytes, Module);
    Ir := ValidateModule(Module, ABytes);
    if Assigned(FDiffHost) then
    begin
      Engine.InternModule(Ir, Canon, TypeIds);
      SetLength(Imports.Funcs, 1);
      Imports.Funcs[0] := Store.AddHostFunc(TypeIds[0], FDiffHost, nil);
    end;
    Instance := InstantiateModule(Store, Ir, @ABytes[0],
      NativeUInt(Length(ABytes)), Imports);
    RegisterInterpreter(Store);
    if not Instance.FindExport(AExport, Kind, Addr) then
      raise EWasmError.CreateFmt('no export named %s', [AExport]);
    SetLength(P, Length(AParams));
    for I := 0 to High(AParams) do
      P[I] := AParams[I];
    for I := 0 to High(Res) do
      Res[I].Bits := 0;
    try
      if Length(P) = 0 then
        InterpInvoke(Store, Addr, nil, @Res[0])
      else
        InterpInvoke(Store, Addr, @P[0], @Res[0]);
    except
      on E: EWasmTrap do
        Result := E.Message;
    end;
  finally
    FreeAndNil(Store);
    FreeAndNil(Engine);
    FreeAndNil(Ir);
    FreeAndNil(Module);
  end;
end;


{ --- Wave 3: the call family (jit-spec §12.3 Wave 3) --------------------

  Every one of these is the same differential contract as the rest of the
  suite: run interpreted, then force-compile the chosen participants and run
  again, and require the two outcomes to be bitwise identical (or to trap with
  the identical message). What varies is WHICH functions are compiled, which is
  how the three interop directions across the tier seam are each pinned down. }

procedure TJitTests.TestCallCompiledToCompiled;
begin
  { Both sides compiled: the caller's marshal -> helper -> unmarshal sequence
    feeds a callee reached through the store's compiled hook. }
  CompileExports(['helper', 'run']);
  Expect<Boolean>(DiffModule(CallPairModuleBytes, 'run',
    [MakeValueI32(10)])).ToBe(JIT_BACKEND_AVAILABLE);
end;

procedure TJitTests.TestCallCompiledToInterpreted;
begin
  { Only the caller is compiled, so the callee is reached through the
    interpreter — the compiled -> interpreted direction of the seam. }
  CompileExports(['run']);
  Expect<Boolean>(DiffModule(CallPairModuleBytes, 'run',
    [MakeValueI32(10)])).ToBe(JIT_BACKEND_AVAILABLE);
end;

procedure TJitTests.TestCallInterpretedToCompiled;
begin
  { Only the callee is compiled: the interpreter's own CompiledCall seam. }
  CompileExports(['helper']);
  Expect<Boolean>(DiffModule(CallPairModuleBytes, 'run',
    [MakeValueI32(10)])).ToBe(JIT_BACKEND_AVAILABLE);
end;

procedure TJitTests.TestCallIndirectHit;
begin
  CompileExports(['double', 'run']);
  Expect<Boolean>(DiffModule(CallIndirectModuleBytes, 'run',
    [MakeValueI32(21), MakeValueI32(0)])).ToBe(JIT_BACKEND_AVAILABLE);
end;

procedure TJitTests.TestCallIndirectTraps;
begin
  { The three call_indirect traps, in the order the resolution checks them
    (exec-call_indirect): a too-large index is 'undefined element' BEFORE any
    element is read; a null element is 'uninitialized element'; only a
    readable, non-null, wrongly-typed entry reaches 'indirect call type
    mismatch'. DiffModule asserts both tiers produce the SAME message, so a
    reordered check in the compiled path fails here. }
  CompileExports(['double', 'run']);
  DiffModule(CallIndirectModuleBytes, 'run',
    [MakeValueI32(21), MakeValueI32(9)]);        { index >= table size }
  CompileExports(['double', 'run']);
  DiffModule(CallIndirectModuleBytes, 'run',
    [MakeValueI32(21), MakeValueI32(2)]);        { null element }
  CompileExports(['double', 'run']);
  DiffModule(CallIndirectModuleBytes, 'run',
    [MakeValueI32(21), MakeValueI32(1)]);        { wrong type }

  { And the messages themselves, so the test names the behaviour rather than
    only asserting the two tiers agree on it. }
  Expect<string>(TrapMessageOf(CallIndirectModuleBytes, 'run',
    [MakeValueI32(21), MakeValueI32(9)])).ToBe('undefined element');
  Expect<Boolean>(Pos('uninitialized element',
    TrapMessageOf(CallIndirectModuleBytes, 'run',
    [MakeValueI32(21), MakeValueI32(2)])) = 1).ToBe(True);
  Expect<string>(TrapMessageOf(CallIndirectModuleBytes, 'run',
    [MakeValueI32(21), MakeValueI32(1)])).ToBe('indirect call type mismatch');
end;

procedure TJitTests.TestCallRef;
begin
  { $run — the compiled function — is entered from an interpreted wrapper that
    supplies the funcref, so the compiled body is exactly local.gets plus the
    iroCallRef template. }
  CompileExports(['double', 'run']);
  Expect<Boolean>(DiffModule(CallRefModuleBytes, 'mk',
    [MakeValueI32(21)])).ToBe(JIT_BACKEND_AVAILABLE);

  { A null funcref traps identically under both tiers. }
  CompileExports(['run']);
  Expect<Boolean>(DiffModule(CallRefModuleBytes, 'mknull', []))
    .ToBe(JIT_BACKEND_AVAILABLE);
  Expect<string>(TrapMessageOf(CallRefModuleBytes, 'mknull', []))
    .ToBe('null function reference');
end;

procedure TJitTests.TestMultiValueCall;
begin
  { Two results across the call: the unmarshal loop must place BOTH slots. }
  CompileExports(['pair', 'run']);
  Expect<Boolean>(DiffModule(MultiValueModuleBytes, 'run', []))
    .ToBe(JIT_BACKEND_AVAILABLE);
end;

procedure TJitTests.TestVecThroughCall;
var
  P: array[0 .. 1] of TWasmValue;
begin
  { A v128 rides the flat block as TWO consecutive slots, which the argument
    aux list already spells as two entries — so the marshaling needs no vector
    special case. With Wave 6 the v128 function 'run' (which passes a v128
    through a call) now COMPILES, so the differential assertion is joined by the
    compilation claim: both slots bit-identical AND run compiled. }
  P[0].Bits := UInt64($0123456789ABCDEF);
  P[1].Bits := UInt64($FEDCBA9876543210);
  FDiffResultSlots := 2;
  CompileExports(['run']);
  Expect<Boolean>(DiffModule(VecThroughCallModuleBytes, 'run', [P[0], P[1]]))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

procedure TJitTests.TestHostCallInterop;
begin
  { A compiled caller calling an IMPORTED HOST function: the helper takes the
    host arm of the same dispatch the interpreter's EnterCall takes. }
  FDiffHost := @JitIncCallback;
  CompileExports(['callhost']);
  Expect<Boolean>(DiffModule(HostCallModuleBytes, 'callhost',
    [MakeValueI32(5)])).ToBe(JIT_BACKEND_AVAILABLE);
end;

procedure TJitTests.TestTailCallSelfIsBounded;
begin
  { THE O(1) ACCEPTANCE TEST (jit-spec §4.5, §13 item 5). A million tail calls
    complete because the compiled body returns to the trampoline LOOP, which
    pops and re-pushes one frame per iteration in Pascal. Were the tail call a
    native call, the 8 MiB stack would be gone inside the first few tens of
    thousands of iterations and this would crash rather than fail. }
  CompileExports(['count']);
  Expect<Boolean>(DiffModule(TailSelfModuleBytes, 'count',
    [MakeValueI64(1000000)])).ToBe(JIT_BACKEND_AVAILABLE);
end;

procedure TJitTests.TestTailCallMutual;
begin
  { A -> B -> A ... 100000 deep, both compiled: the trampoline loop follows
    the chain across FUNCTIONS, not just around one. }
  CompileExports(['a', 'b']);
  Expect<Boolean>(DiffModule(TailMutualModuleBytes, 'a',
    [MakeValueI64(100000)])).ToBe(JIT_BACKEND_AVAILABLE);
end;

procedure TJitTests.TestTailCallCrossTierBounded;
begin
  { Fix A (Finding 1) — the CROSS-TIER O(1) acceptance test. Force-compile ONLY
    $a, so the alternating chain $a(compiled) -> $b(interpreted) -> $a(compiled)
    crosses the tier seam on EVERY tail. Before the fix each cross-tier tail
    NESTED a native invocation (the compiled trampoline running the interpreted
    callee to completion, whose own tail re-entered the compiled trampoline), so
    the 8 MiB native stack was exhausted within tens of thousands of iterations.
    With the shared pending-tail channel + the interpreter's entry-level BOUNCE
    back to the loop, a million alternating tails run in BOUNDED native stack —
    completing IS the proof — and yield the same result as the interpreter. }
  CompileExports(['a']);
  Expect<Boolean>(DiffModule(TailMutualModuleBytes, 'a',
    [MakeValueI64(1000000)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

procedure TJitTests.TestTailCallToHost;
begin
  { return_call to a HOST function: the host's results become this frame's
    results and flow to this frame's caller, adding no wasm frame — the
    interpreter's ReturnHostCall shape, reached through the trampoline. }
  FDiffHost := @JitIncCallback;
  CompileExports(['tailhost']);
  Expect<Boolean>(DiffModule(HostCallModuleBytes, 'tailhost',
    [MakeValueI32(5)])).ToBe(JIT_BACKEND_AVAILABLE);
end;

procedure TJitTests.TestNativeScalarSelfProofGate;
var
  Bytes: TWasmBytes;
  Module: TWasmModule;
  Ir: TWasmIrModule;
begin
  { The native recursive ABI is intentionally a closed one-node proof, not a
    general call optimization. This shape has one numeric parameter/result,
    no locals, references, helpers, memory, or cross-function escape. }
  Bytes := RecurseModuleBytes;
  Module := TWasmModule.Create;
  Ir := nil;
  try
    DecodeModule(Bytes, Module);
    Ir := ValidateModule(Module, Bytes);
    Expect<Boolean>(JitCanNativeScalarSelf(@Ir.Functions[0],
      Ir.FuncImportCount)).ToBe({$IFDEF WASM_JIT_ARM64}True{$ELSE}False{$ENDIF});
  finally
    Ir.Free;
    Module.Free;
  end;

  { A one-slot numeric leaf has no internal call to accelerate and must not pay
    the extended native frame merely because all of its operations are safe. }
  Bytes := OneFunc(BLit([$60, $01, $7F, $01, $7F]),
    BLit([$00, $20, $00, $0B]), 'id');
  Module := TWasmModule.Create;
  Ir := nil;
  try
    DecodeModule(Bytes, Module);
    Ir := ValidateModule(Module, Bytes);
    Expect<Boolean>(JitCanNativeScalarSelf(@Ir.Functions[0],
      Ir.FuncImportCount)).ToBe(False);
  finally
    Ir.Free;
    Module.Free;
  end;

  { Two parameters is also outside the one-slot ABI and must retain the generic
    logical/value/GC-frame path on every backend. }
  Bytes := AddModuleBytes;
  Module := TWasmModule.Create;
  Ir := nil;
  try
    DecodeModule(Bytes, Module);
    Ir := ValidateModule(Module, Bytes);
    Expect<Boolean>(JitCanNativeScalarSelf(@Ir.Functions[0],
      Ir.FuncImportCount)).ToBe(False);
  finally
    Ir.Free;
    Module.Free;
  end;
end;

procedure TJitTests.TestDeepRecursionExhausts;
var
  N: Integer;
begin
  { NON-tail recursion must exhaust at the same LOGICAL depth under both tiers
    (jit-spec §13 item 2), because both carve their frames through the same
    JitEnterFrame against the same caps. Sweeping the argument ACROSS the cap
    would catch a threshold that differed by even one: every n below it must
    return n under both tiers, every n above it must trap 'call stack
    exhausted' under both. The cap is shrunk so the sweep is cheap and so the
    trap is the depth counter rather than any host-stack limit. }
  WasmInterpMaxDepth := 64;
  try
    for N := 58 to 70 do
    begin
      CompileExports(['rec']);
      Expect<Boolean>(DiffModule(RecurseModuleBytes, 'rec',
        [MakeValueI32(N)])).ToBe(JIT_BACKEND_AVAILABLE);
    end;

    { And the message itself, at a depth well past the cap — still under the
      shrunk cap, which is read when each store's context is first created. }
    Expect<string>(TrapMessageOf(RecurseModuleBytes, 'rec',
      [MakeValueI32(4000)])).ToBe('call stack exhausted');
  finally
    WasmInterpMaxDepth := 256;
  end;
end;

procedure TJitTests.TestThrowAcrossCompiledFrameCaught;
begin
  { Fix A (Finding 3), the soundness regression test. $middle is a call-bearing
    function in a module that HAS a tag — exactly what fence 2 used to decline.
    Fence 2 is retired, so $middle COMPILES, and the throw raised by the inner
    (interpreted, iroThrow) callee must unwind ACROSS $middle's compiled seam
    frame to reach the interpreted try_table in $outer. DiffModule force-compiles
    $middle (True = it really compiled) and asserts the outcome is byte-identical
    under both tiers — which is what would fail if the compiled seam frame
    incorrectly swallowed the exception as 'uncaught'. }
  CompileExports(['middle']);
  Expect<Boolean>(DiffModule(ThrowAcrossCallModuleBytes, 'outer',
    [MakeValueI32(7)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});

  { The oracle: the exception really is caught (no trap), yielding the payload. }
  Expect<string>(TrapMessageOf(ThrowAcrossCallModuleBytes, 'outer',
    [MakeValueI32(7)])).ToBe('');
end;

{ --- Waves 4 & 5: memory / table / reference / global / GC -------------- }

procedure TJitTests.TestMemoryLoadStore;
begin
  { store arg1 at arg0, load it back: the round-trip through the chokepoint. }
  Expect<Boolean>(DiffFresh(MemBasicModuleBytes, 'sload',
    [MakeValueI32(16), MakeValueI32(Integer($DEADBEEF))])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  { a sign-extending narrow load: byte $FF at index 0 reads back as -1. }
  Expect<Boolean>(DiffFresh(MemBasicModuleBytes, 'load8s',
    [MakeValueI32(0)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

procedure TJitTests.TestForwardedMemoryLoadKeepsStoreEffect;
var
  Addr: UInt32;
  Kind: TWasmExternKind;
  Params, Results: array[0 .. 0] of TWasmValue;
  Stored: UInt32;
begin
  FBytes := MemForwardModuleBytes;
  DecodeModule(FBytes, FModule);
  FIr := ValidateModule(FModule, FBytes);
  FInstance := InstantiateModule(FStore, FIr, @FBytes[0],
    NativeUInt(Length(FBytes)), FImports);
  RegisterInterpreter(FStore);
  FJit := RegisterJit(FStore);
  if not FInstance.FindExport('run', Kind, Addr) then
    raise EWasmError.Create('no export named run');
  Expect<Boolean>(FJit.ForceCompile(Addr)).ToBe(JIT_BACKEND_AVAILABLE);
  Params[0] := MakeValueI32(2);
  Results[0].Bits := High(UInt64);
  InterpInvoke(FStore, Addr, @Params[0], @Results[0]);
  Expect<UInt64>(Results[0].Bits).ToBe(1);
  Move(FStore.MemAddressAt(FInstance.MemAddrs[0], 4, 0, 4)^,
    Stored, SizeOf(Stored));
  Expect<UInt32>(Stored).ToBe(1);
end;

procedure TJitTests.TestForwardedMemoryLoadKeepsStoreOobTrap;
var
  Bytes: TWasmBytes;
begin
  { With a zero-page memory, run(1)'s first exact store/load pair is out of
    bounds. The forwarding plan skips only the load and must leave the original
    store in place as the trapping access. }
  Bytes := MemForwardModuleBytes(0);
  Expect<Boolean>(DiffFresh(Bytes, 'run', [MakeValueI32(1)]))
    .ToBe(JIT_BACKEND_AVAILABLE);
  Expect<string>(TrapMessageOf(Bytes, 'run', [MakeValueI32(1)]))
    .ToBe('out of bounds memory access');
end;

procedure TJitTests.TestMemoryLocalAliasCodeShape;
{$IFDEF WASM_JIT_ARM64}
var
  Code: TWasmBytes;
  EntryOffset: NativeUInt;
  RegisterCount: UInt32;
{$ENDIF}
begin
  {$IFDEF WASM_JIT_ARM64}
  FBytes := MemForwardModuleBytes;
  DecodeModule(FBytes, FModule);
  FIr := ValidateModule(FModule, FBytes);
  Code := JitStageFunctionBytes(FStore, @FIr.Functions[0], EntryOffset,
    RegisterCount);
  { The bounded local aliases remove seven loop-body copies while every
    original IR label remains represented. Pin the resulting A64 shape so the
    transform cannot silently stop applying while differential behavior stays
    correct. }
  Expect<Integer>(Length(Code)).ToBe(196);
  Expect<NativeUInt>(EntryOffset).ToBe(0);
  Expect<UInt32>(RegisterCount).ToBe(FIr.Functions[0].RegisterCount);
  {$ELSE}
  Expect<Boolean>(True).ToBe(True);
  {$ENDIF}
end;

procedure TJitTests.TestMemoryLoopCache;
begin
  Expect<Boolean>(DiffFresh(MemLoopModuleBytes, 'run', [MakeValueI32(100)]))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

procedure TJitTests.TestMemoryLoopCarriedCache;
begin
  Expect<Boolean>(DiffFresh(MemLoopCarriedModuleBytes, 'run',
    [MakeValueI32(100)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

procedure TJitTests.TestMemoryOobTraps;
begin
  { an out-of-bounds load and store both trap 'out of bounds memory access'
    at the same access, same message, under both tiers. }
  DiffFresh(MemBasicModuleBytes, 'oobload', [MakeValueI32(Integer($10000))]);
  Expect<string>(TrapMessageOf(MemBasicModuleBytes, 'oobload',
    [MakeValueI32(Integer($10000))])).ToBe('out of bounds memory access');
  DiffFresh(MemBasicModuleBytes, 'sload',
    [MakeValueI32(Integer($1FFFF)), MakeValueI32(1)]);
  Expect<string>(TrapMessageOf(MemBasicModuleBytes, 'sload',
    [MakeValueI32(Integer($1FFFF)), MakeValueI32(1)]))
    .ToBe('out of bounds memory access');
  { A folded non-zero static offset uses the i32 guard reservation too: the
    final four bytes are valid, while advancing that effective address by four
    enters the guard and must produce the same trap as the interpreter. }
  Expect<Boolean>(DiffFresh(MemBasicModuleBytes, 'offsetload',
    [MakeValueI32(Integer($FFF8))])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  DiffFresh(MemBasicModuleBytes, 'offsetload',
    [MakeValueI32(Integer($FFFC))]);
  Expect<string>(TrapMessageOf(MemBasicModuleBytes, 'offsetload',
    [MakeValueI32(Integer($FFFC))])).ToBe('out of bounds memory access');
end;

procedure TJitTests.TestMemory64MaxOffset;
begin
  Expect<Boolean>(DiffFresh(Mem64MaxOffsetModuleBytes, 'load', []))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<string>(TrapMessageOf(Mem64MaxOffsetModuleBytes, 'load', []))
    .ToBe('out of bounds memory access');
end;

procedure TJitTests.TestMemorySizeGrow;
begin
  { size returns the initial page count; grow returns the OLD size (1) then
    fails (-1) for an impossible delta — fresh stores keep the two runs
    independent. }
  Expect<Boolean>(DiffFresh(MemBasicModuleBytes, 'size', [])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(MemBasicModuleBytes, 'grow',
    [MakeValueI32(1)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  DiffFresh(MemBasicModuleBytes, 'grow', [MakeValueI32(Integer($10000))]);
end;

procedure TJitTests.TestMemoryFillCopy;
begin
  { fill writes arg1&$FF over [arg0..arg0+arg2) then reads it back. }
  Expect<Boolean>(DiffFresh(MemBasicModuleBytes, 'fill',
    [MakeValueI32(20), MakeValueI32($AB), MakeValueI32(8)]))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  { copy from the data-initialised [0..) to [32..) then reads [32]. }
  Expect<Boolean>(DiffFresh(MemBasicModuleBytes, 'copy',
    [MakeValueI32(32), MakeValueI32(0), MakeValueI32(4)]))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  { a fill that runs off the end traps identically. }
  DiffFresh(MemBasicModuleBytes, 'fill',
    [MakeValueI32(Integer($FFFF)), MakeValueI32(1), MakeValueI32(8)]);
end;

procedure TJitTests.TestMemoryInitDrop;
begin
  { memory.init from a passive segment, then a load; and data.drop then a
    non-empty init, which must trap identically. }
  Expect<Boolean>(DiffFresh(MemInitModuleBytes, 'init',
    [MakeValueI32(8), MakeValueI32(0), MakeValueI32(4)]))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  DiffFresh(MemInitModuleBytes, 'dropinit',
    [MakeValueI32(0), MakeValueI32(0), MakeValueI32(1)]);
  Expect<string>(TrapMessageOf(MemInitModuleBytes, 'dropinit',
    [MakeValueI32(0), MakeValueI32(0), MakeValueI32(1)]))
    .ToBe('out of bounds memory access');
end;

procedure TJitTests.TestTableOps;
begin
  Expect<Boolean>(DiffFresh(TableModuleBytes, 'tsize', []))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(TableModuleBytes, 'tsetget',
    [MakeValueI32(2)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(TableModuleBytes, 'tgrow',
    [MakeValueI32(3)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(TableModuleBytes, 'tfill',
    [MakeValueI32(1), MakeValueI32(2)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

procedure TJitTests.TestTableOobTrap;
begin
  DiffFresh(TableModuleBytes, 'toobget', [MakeValueI32(99)]);
  Expect<string>(TrapMessageOf(TableModuleBytes, 'toobget',
    [MakeValueI32(99)])).ToBe('out of bounds table access');
end;

procedure TJitTests.TestGlobals;
begin
  Expect<Boolean>(DiffFresh(GlobalModuleBytes, 'gget', []))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(GlobalModuleBytes, 'gset',
    [MakeValueI32(4242)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  { a REFERENCE global write goes through the barriered store method. }
  Expect<Boolean>(DiffFresh(GlobalModuleBytes, 'grefset', []))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

procedure TJitTests.TestReferenceOps;
begin
  Expect<Boolean>(DiffFresh(RefModuleBytes, 'isnull_null', []))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(RefModuleBytes, 'isnull_func', []))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(RefModuleBytes, 'refeq', []))
    .ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  { ref.as_non_null on a null traps the BARE 'null reference' message. }
  DiffFresh(RefModuleBytes, 'asnonnull_trap', []);
  Expect<string>(TrapMessageOf(RefModuleBytes, 'asnonnull_trap', []))
    .ToBe('null reference');
end;

procedure TJitTests.TestStructRoundTrip;
begin
  { a struct.new/struct.get round-trip, plus packed get_s (sign) vs get_u
    (zero) on an i8 field — the exact extension the interpreter does. }
  Expect<Boolean>(DiffFresh(GcStructModuleBytes, 'rt',
    [MakeValueI32(Integer($12345678))])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(GcStructModuleBytes, 'gets',
    [MakeValueI32($FF)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(GcStructModuleBytes, 'getu',
    [MakeValueI32($FF)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  { struct.set (barriered) then read back. }
  Expect<Boolean>(DiffFresh(GcStructModuleBytes, 'setget',
    [MakeValueI32(777)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

procedure TJitTests.TestArrayRoundTrip;
begin
  Expect<Boolean>(DiffFresh(GcArrayModuleBytes, 'rt',
    [MakeValueI32(55), MakeValueI32(4)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(GcArrayModuleBytes, 'len',
    [MakeValueI32(7)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  { packed array get_s sign-extends the low byte. }
  Expect<Boolean>(DiffFresh(GcArrayModuleBytes, 'gets',
    [MakeValueI32($FF), MakeValueI32(2)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

procedure TJitTests.TestArrayOobTrap;
begin
  DiffFresh(GcArrayModuleBytes, 'oobget', [MakeValueI32(9)]);
  Expect<string>(TrapMessageOf(GcArrayModuleBytes, 'oobget',
    [MakeValueI32(9)])).ToBe('out of bounds array access');
end;

procedure TJitTests.TestI31;
begin
  { i31.get_s sign-extends the 31-bit payload; get_u zero-extends. }
  Expect<Boolean>(DiffFresh(I31ModuleBytes, 'gets',
    [MakeValueI32(Integer($7FFFFFFF))])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  Expect<Boolean>(DiffFresh(I31ModuleBytes, 'getu',
    [MakeValueI32(Integer($7FFFFFFF))])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  { i31.get_s on a null i31 traps 'null i31 reference'. }
  DiffFresh(I31ModuleBytes, 'null_trap', []);
  Expect<string>(TrapMessageOf(I31ModuleBytes, 'null_trap', []))
    .ToBe('null i31 reference');
end;

procedure TJitTests.TestGcMidBodyCollectionWalkable;
begin
  { THE §9 PROOF. Threshold 0 forces a collection inside the body's struct.new,
    while the freshly-allocated array is live ONLY in the frame's register file.
    A non-walkable compiled frame would free the array and array.len would fault
    or return garbage; returning arg0 (the length) under both tiers proves the
    compiled frame is GC-walkable exactly like the interpreter's. }
  FDiffThreshold := 0;
  Expect<Boolean>(DiffFresh(GcCollectModuleBytes, 'collect',
    [MakeValueI32(37)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
  { A second length, to exercise the walk at a different size. }
  Expect<Boolean>(DiffFresh(GcCollectModuleBytes, 'collect',
    [MakeValueI32(3)])).ToBe({$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF});
end;

{ --- Wave 6: v128 SIMD via the leaves ----------------------------------- }

const
  { A v128 function compiles now (Wave 6), so the differential driver should
    report True on the supported leg and the interpreter-only False elsewhere. }
  VEC_COMPILED = {$IFDEF WASM_JIT_BACKEND}True{$ELSE}False{$ENDIF};

procedure TJitTests.TestSimdCompute;
begin
  { const/splat/extract/replace, i32x4.add, i32x4.eq, shuffle, swizzle — pure
    compute, so a plain DiffModule proves each is bit-identical and compiled. }
  Expect<Boolean>(DiffModule(SimdComputeModuleBytes, 'dbl',
    [MakeValueI32(21)])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffModule(SimdComputeModuleBytes, 'cmp',
    [MakeValueI32(5)])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffModule(SimdComputeModuleBytes, 'rep',
    [MakeValueI32(0)])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffModule(SimdComputeModuleBytes, 'konst',
    [])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffModule(SimdComputeModuleBytes, 'shuf',
    [])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffModule(SimdComputeModuleBytes, 'swz',
    [])).ToBe(VEC_COMPILED);
end;

procedure TJitTests.TestSimdFloatNanPminRelaxed;
begin
  { THE IDENTITY PROPERTY. A NaN through f32x4.add must yield the interpreter's
    exact canonical-NaN bits per lane (both tiers call the same leaf); pmin/pmax
    preserve the payload-selection; relaxed_min is the deterministic R=0 result.
    DiffModule compares the result slot bitwise, so any per-lane divergence
    fails. }
  { a non-canonical NaN payload -> canonicalised identically by both tiers }
  Expect<Boolean>(DiffModule(SimdFloatModuleBytes, 'nanadd',
    [VBits(UInt64($7FA5A5A5))])).ToBe(VEC_COMPILED);
  { pmin/pmax with a NaN operand: the payload-preserving selection, identical }
  Expect<Boolean>(DiffModule(SimdFloatModuleBytes, 'pmin',
    [VBits(UInt64($7FC00003)), MakeValueF32(1.5)])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffModule(SimdFloatModuleBytes, 'pmax',
    [MakeValueF32(-2.0), VBits(UInt64($FF800000))])).ToBe(VEC_COMPILED);
  { ordinary finite operands, to prove the selection value itself matches }
  Expect<Boolean>(DiffModule(SimdFloatModuleBytes, 'pmin',
    [MakeValueF32(3.0), MakeValueF32(-4.0)])).ToBe(VEC_COMPILED);
  { relaxed op: the deterministic profile the interpreter fixes at R=0 }
  Expect<Boolean>(DiffModule(SimdFloatModuleBytes, 'relmin',
    [MakeValueF32(7.5), MakeValueF32(2.25)])).ToBe(VEC_COMPILED);
end;

procedure TJitTests.TestSimdMemory;
begin
  { v128.store then v128.load round-trip, and a byte load8_lane — each through
    the one memory chokepoint. Stateful, so two fresh stores (DiffFresh). }
  Expect<Boolean>(DiffFresh(SimdMemModuleBytes, 'rt', [])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffFresh(SimdMemModuleBytes, 'l8lane',
    [])).ToBe(VEC_COMPILED);
end;

procedure TJitTests.TestSimdMemoryOob;
begin
  { an out-of-bounds v128.load must trap 'out of bounds memory access' under
    both tiers, at the same access (DiffFresh compares the trap message). }
  Expect<Boolean>(DiffFresh(SimdMemModuleBytes, 'oob', [])).ToBe(VEC_COMPILED);
  { and the message itself is the chokepoint's, reached from compiled code. }
  Expect<string>(TrapMessageOf(SimdMemModuleBytes, 'oob', []))
    .ToBe('out of bounds memory access');
end;

procedure TJitTests.TestSimdMoveSelect;
begin
  { iroMoveVec (a v128 local copy) and iroSelectVec (typed select over v128). }
  Expect<Boolean>(DiffModule(SimdMoveSelectModuleBytes, 'mv',
    [MakeValueI32(1234)])).ToBe(VEC_COMPILED);
  { cond nonzero -> first (arg); cond zero -> second (99) }
  Expect<Boolean>(DiffModule(SimdMoveSelectModuleBytes, 'sel',
    [MakeValueI32(0)])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffModule(SimdMoveSelectModuleBytes, 'sel',
    [MakeValueI32(7)])).ToBe(VEC_COMPILED);
end;

procedure TJitTests.TestSimdGlobal;
begin
  { iroGlobalGetVec on a v128 global initialised by a const, and a set/get
    round-trip (iroGlobalSetVec). Stateful, so DiffFresh. }
  Expect<Boolean>(DiffFresh(SimdGlobalModuleBytes, 'gget', [])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffFresh(SimdGlobalModuleBytes, 'grt',
    [MakeValueI32(Integer($CAFEF00D))])).ToBe(VEC_COMPILED);
end;

procedure TJitTests.TestSimdStructArray;
begin
  { a v128 struct field (iroStructGetVec/SetVec) and a v128 array element
    (iroArrayGetVec/SetVec, iroArrayFillVec) round-trip. DiffFresh keeps the
    heap independent across the two stores; each returns an extracted lane. }
  Expect<Boolean>(DiffFresh(SimdStructArrayModuleBytes, 'srt',
    [MakeValueI32(555)])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffFresh(SimdStructArrayModuleBytes, 'sset',
    [MakeValueI32(Integer($ABCD1234))])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffFresh(SimdStructArrayModuleBytes, 'art',
    [MakeValueI32(99)])).ToBe(VEC_COMPILED);
  Expect<Boolean>(DiffFresh(SimdStructArrayModuleBytes, 'afill',
    [MakeValueI32(4242)])).ToBe(VEC_COMPILED);
end;

procedure TJitTests.SetupTests;
begin
  Test('slot stride matches the interpreter frame', TestSlotSizeMatchesInterp);
  Test('force-compile sets the compiled entry', TestForceCompileSetsEntry);
  Test('JIT i32.add is bitwise identical to the interpreter',
    TestMilestoneAddIdentical);
  Test('i32 arithmetic/logic/shift match the interpreter', TestI32Arith);
  Test('a bounded masked shift matches the interpreter',
    TestMaskedShiftFusion);
  Test('i64 arithmetic/logic/shift match the interpreter', TestI64Arith);
  Test('i32 compares and eqz match the interpreter', TestI32Compare);
  Test('f64 ops (incl. NaN) match the interpreter bitwise', TestF64Ops);
  Test('f32.sqrt (incl. canonical NaN) matches the interpreter',
    TestF32SqrtNan);
  Test('div/rem trap identically (zero, overflow, rem no-trap)',
    TestDivRemTraps);
  Test('consts and conversions match, incl. trunc traps',
    TestConstsAndConversions);
  Test('select matches the interpreter', TestSelect);
  Test('an if/else matches the interpreter', TestNestedIf);
  Test('a loop with a back-edge epoch safepoint matches', TestLoopSum);
  Test('br_table matches the interpreter', TestBrTable);
  Test('unreachable traps identically', TestUnreachable);
  Test('a shared epoch snapshot traps interrupt in a compiled leaf identically',
    TestEpochInterruptDifferential);
  Test('a compiled caller''s interrupt reaches an interpreted callee across the seam',
    TestEpochInterruptAcrossSeamToInterpCallee);

  Test('a compiled function calling a compiled function matches',
    TestCallCompiledToCompiled);
  Test('a compiled function calling an interpreted function matches',
    TestCallCompiledToInterpreted);
  Test('an interpreted function calling a compiled function matches',
    TestCallInterpretedToCompiled);
  Test('call_indirect dispatches identically', TestCallIndirectHit);
  Test('call_indirect traps identically in bounds/null/type order',
    TestCallIndirectTraps);
  Test('call_ref dispatches and traps on null identically', TestCallRef);
  Test('a multi-value call marshals every result slot', TestMultiValueCall);
  Test('a v128 rides a call as two flat slots', TestVecThroughCall);
  Test('a compiled function calling a host import matches', TestHostCallInterop);
  Test('1e6 self return_calls run in bounded native stack',
    TestTailCallSelfIsBounded);
  Test('mutual return_call recursion runs in bounded native stack',
    TestTailCallMutual);
  Test('1e6 alternating compiled<->interpreted return_calls run in bounded stack',
    TestTailCallCrossTierBounded);
  Test('return_call to a host function matches', TestTailCallToHost);
  Test('native scalar self-call proof accepts only its closed one-slot subset',
    TestNativeScalarSelfProofGate);
  Test('deep non-tail recursion exhausts at the same logical depth',
    TestDeepRecursionExhausts);
  Test('a throw crosses a compiled seam frame and is caught by the interp handler',
    TestThrowAcrossCompiledFrameCaught);

  Test('memory load/store round-trips identically', TestMemoryLoadStore);
  Test('a forwarded memory load keeps the store memory effect',
    TestForwardedMemoryLoadKeepsStoreEffect);
  Test('a forwarded memory load keeps the store out-of-bounds trap',
    TestForwardedMemoryLoadKeepsStoreOobTrap);
  Test('a scalar memory loop forwards bounded local aliases',
    TestMemoryLocalAliasCodeShape);
  Test('a scalar memory loop retains cached values identically',
    TestMemoryLoopCache);
  Test('a scalar memory loop reconciles dynamic loop-carried values',
    TestMemoryLoopCarriedCache);
  Test('out-of-bounds memory access traps identically', TestMemoryOobTraps);
  Test('memory64 maximum offset compiles and traps identically',
    TestMemory64MaxOffset);
  Test('memory.size/grow match the interpreter', TestMemorySizeGrow);
  Test('memory.fill/copy match the interpreter', TestMemoryFillCopy);
  Test('memory.init/data.drop match the interpreter', TestMemoryInitDrop);
  Test('table get/set/size/grow/fill match the interpreter', TestTableOps);
  Test('out-of-bounds table access traps identically', TestTableOobTrap);
  Test('global get/set (numeric and ref) match the interpreter', TestGlobals);
  Test('reference ops (null/is_null/eq/func/as_non_null) match',
    TestReferenceOps);
  Test('struct new/get/set incl. packed sign/zero extension match',
    TestStructRoundTrip);
  Test('array new/get/len incl. packed extension match', TestArrayRoundTrip);
  Test('out-of-bounds array access traps identically', TestArrayOobTrap);
  Test('i31 ref/get_s/get_u and null trap match', TestI31);
  Test('a mid-body collection keeps a live ref (compiled frame is GC-walkable)',
    TestGcMidBodyCollectionWalkable);

  Test('v128 const/splat/extract/replace/add/eq/shuffle/swizzle match',
    TestSimdCompute);
  Test('v128 NaN canonicalisation, pmin/pmax, and a relaxed op match per lane',
    TestSimdFloatNanPminRelaxed);
  Test('v128 load/store round-trip through the chokepoint matches',
    TestSimdMemory);
  Test('an out-of-bounds v128 load traps identically', TestSimdMemoryOob);
  Test('iroMoveVec and iroSelectVec (v128) match the interpreter',
    TestSimdMoveSelect);
  Test('a v128 global get and set/get round-trip match', TestSimdGlobal);
  Test('v128 struct field and array element/fill round-trips match',
    TestSimdStructArray);
end;

begin
  TestRunnerProgram.AddSuite(TJitTests.Create('Wasm.Jit'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
