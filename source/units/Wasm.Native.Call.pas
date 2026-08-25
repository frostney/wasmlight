{ Wasm.Native.Call — apply a Unix C-ABI plan through a precompiled gate.

  The planner (Wasm.Abi) is host-independent. This unit is the host-gated
  half: one precompiled thunk per ABI, baked as machine-code constants and
  installed once into RX memory. No TinyCC, no libffi, no JIT unit, and no
  per-signature compiler. The gate's meta-ABI is cdecl; the callee sees
  the planned AAPCS64 or SysV register/stack placement.

  An incompatible plan, a missing function pointer, or a host/target
  mismatch is EWasmLinkError. Guest memory is not touched here — that is
  issue #44. }
unit Wasm.Native.Call;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Abi,
  Wasm.Core;

type
  TWasmAbiValue = record
    Data: array of Byte;
  end;

function AbiValueI32(const AValue: Int32): TWasmAbiValue;
function AbiValueI64(const AValue: Int64): TWasmAbiValue;
function AbiValueU32(const AValue: UInt32): TWasmAbiValue;
function AbiValueU64(const AValue: UInt64): TWasmAbiValue;
function AbiValueF32(const AValue: Single): TWasmAbiValue;
function AbiValueF64(const AValue: Double): TWasmAbiValue;
function AbiValuePointer(const AValue: Pointer): TWasmAbiValue;
function AbiValueBytes(const ABytes: array of Byte): TWasmAbiValue;
function AbiValueAsI32(const AValue: TWasmAbiValue): Int32;
function AbiValueAsI64(const AValue: TWasmAbiValue): Int64;
function AbiValueAsU64(const AValue: TWasmAbiValue): UInt64;
function AbiValueAsF32(const AValue: TWasmAbiValue): Single;
function AbiValueAsF64(const AValue: TWasmAbiValue): Double;
function AbiValueAsPointer(const AValue: TWasmAbiValue): Pointer;

function NativeCallSupported: Boolean;
procedure ApplyNativeCall(const APlan: TWasmAbiPlan; const AFn: Pointer;
  const AArgs: array of TWasmAbiValue; var AResult: TWasmAbiValue);

implementation

{$IFDEF WASM_NATIVE_CALL}
uses
  BaseUnix;
{$ENDIF}

type
  TWasmAbiGateFn = procedure(
    const AFn: Pointer;
    const AIntRegs: PUInt64;
    const AFloatRegs: PUInt64;
    const AStack: Pointer;
    const AStackSize: NativeUInt;
    const AHidden: Pointer;
    const AResultInt: PUInt64;
    const AResultFloat: PUInt64); cdecl;

  TCopyHold = record
    Bytes: array of Byte;
  end;

{$IFDEF WASM_NATIVE_CALL}
const
  NATIVE_PROT_EXEC = $4;
  {$IFDEF DARWIN}
  NATIVE_MAP_JIT = $0800;
  NATIVE_WP_WRITABLE = 0;
  NATIVE_WP_EXECUTABLE = 1;
  {$ENDIF}

{$IFDEF CPUAARCH64}
  { ldp d0..d7 / stp d0..d3: 8-byte slots, not 16-byte q-registers. }
  AAPCS64_GATE: array[0..40] of UInt32 = (
    $A9BB7BFD, $910003FD, $A90153F3, $A9025BF5,
    $A90363F7, $A9041FE6, $AA0003F3, $AA0103F4,
    $AA0203F5, $AA0303F6, $AA0403F7, $AA0503F8,
    $CB3763FF, $AA1603E9, $910003EA, $AA1703EB,
    $B40000AB, $F840852C, $F800854C, $D100216B,
    $17FFFFFC, $A9400680, $A9410E82, $A9421684,
    $A9431E86, $AA1803E8, $6D4006A0, $6D410EA2,
    $6D4216A4, $6D431EA6, $D63F0260, $8B3763FF,
    $A9442BE9, $A9000520, $6D000540, $6D010D42,
    $A94153F3, $A9425BF5, $A94363F7, $A8C57BFD,
    $D65F03C0
  );
{$ELSE}
  { clang -arch x86_64; SysV meta-ABI in rdi..r9 plus two stack results. }
  SYSV_GATE: array[0..187] of Byte = (
    $55, $48, $89, $E5, $53, $41, $54, $41,
    $55, $41, $56, $41, $57, $48, $89, $FB,
    $49, $89, $F4, $49, $89, $D5, $49, $89, $CE, $4D, $89, $C7, $41, $51, $4C, $29,
    $FC, $4C, $89, $F6, $48, $89, $E7, $4C, $89, $F9, $48, $C1, $E9, $03, $74, $13,
    $48, $8B, $06, $48, $89, $07, $48, $83, $C6, $08, $48, $83, $C7, $08, $48, $FF,
    $C9, $75, $ED, $F2, $41, $0F, $10, $45, $00, $F2, $41, $0F, $10, $4D, $08, $F2,
    $41, $0F, $10, $55, $10, $F2, $41, $0F, $10, $5D, $18, $F2, $41, $0F, $10, $65,
    $20, $F2, $41, $0F, $10, $6D, $28, $F2, $41, $0F, $10, $75, $30, $F2, $41, $0F,
    $10, $7D, $38, $49, $8B, $3C, $24, $49, $8B, $74, $24, $08, $49, $8B, $54, $24,
    $10, $49, $8B, $4C, $24, $18, $4D, $8B, $44, $24, $20, $4D, $8B, $4C, $24, $28,
    $FF, $D3, $4C, $01, $FC, $41, $59, $4C, $8B, $55, $10, $4C, $8B, $5D, $18, $49,
    $89, $02, $49, $89, $52, $08, $F2, $41, $0F, $11, $03, $F2, $41, $0F, $11, $4B,
    $08, $41, $5F, $41, $5E, $41, $5D, $41, $5C, $5B, $5D, $C3
  );
{$ENDIF}

function NativePageSize: LongInt; cdecl; external 'c' name 'getpagesize';

{$IFDEF DARWIN}
procedure NativeWriteProtect(const AEnabled: LongInt); cdecl;
  external 'c' name 'pthread_jit_write_protect_np';
procedure NativeFlushICache(const AStart: Pointer; const ALen: NativeUInt); cdecl;
  external 'c' name 'sys_icache_invalidate';
{$ELSE}
{$IFDEF CPUAARCH64}
procedure NativeClearCache(const ABegin, AEnd: Pointer); cdecl;
  {$IFDEF LINUX}
  external 'gcc_s' name '__clear_cache';
  {$ELSE}
  external 'c' name '__clear_cache';
  {$ENDIF}
{$ENDIF}
{$ENDIF}

var
  GGateMem: Pointer = nil;
  GGateSize: NativeUInt = 0;
  GGate: TWasmAbiGateFn = nil;

function RoundUpPage(const ABytes: NativeUInt): NativeUInt;
var
  Page: NativeUInt;
begin
  Page := NativeUInt(NativePageSize);
  if Page = 0 then
    Page := 4096;
  Result := (ABytes + Page - 1) and not (Page - 1);
end;

procedure InstallGate;
var
  Prot: LongInt;
  Flags: LongInt;
  Src: Pointer;
  Len: NativeUInt;
begin
  if Assigned(GGate) then
    Exit;

  {$IFDEF CPUAARCH64}
  Src := @AAPCS64_GATE[0];
  Len := SizeOf(AAPCS64_GATE);
  {$ELSE}
  Src := @SYSV_GATE[0];
  Len := SizeOf(SYSV_GATE);
  {$ENDIF}

  GGateSize := RoundUpPage(Len);
  {$IFDEF DARWIN}
  Prot := PROT_READ or PROT_WRITE or NATIVE_PROT_EXEC;
  Flags := MAP_PRIVATE or MAP_ANONYMOUS or NATIVE_MAP_JIT;
  {$ELSE}
  Prot := PROT_READ or PROT_WRITE;
  Flags := MAP_PRIVATE or MAP_ANONYMOUS;
  {$ENDIF}

  GGateMem := Fpmmap(nil, GGateSize, Prot, Flags, -1, 0);
  if GGateMem = Pointer(-1) then
  begin
    GGateMem := nil;
    raise EWasmLinkError.Create(string(MSG_LINK_INCOMPATIBLE_PLAN) +
      ': executable gate');
  end;

  {$IFDEF DARWIN}
  NativeWriteProtect(NATIVE_WP_WRITABLE);
  Move(Src^, GGateMem^, Len);
  NativeWriteProtect(NATIVE_WP_EXECUTABLE);
  {$ELSE}
  Move(Src^, GGateMem^, Len);
  if Fpmprotect(GGateMem, GGateSize, PROT_READ or NATIVE_PROT_EXEC) <> 0 then
  begin
    Fpmunmap(GGateMem, GGateSize);
    GGateMem := nil;
    raise EWasmLinkError.Create(string(MSG_LINK_INCOMPATIBLE_PLAN) +
      ': executable gate');
  end;
  {$ENDIF}

  {$IFDEF CPUAARCH64}
  {$IFDEF DARWIN}
  NativeFlushICache(GGateMem, Len);
  {$ELSE}
  NativeClearCache(GGateMem, Pointer(NativeUInt(GGateMem) + Len));
  {$ENDIF}
  {$ENDIF}

  GGate := TWasmAbiGateFn(GGateMem);
end;
{$ENDIF}

function BytesOf(const APtr: Pointer; const ASize: Integer): TWasmAbiValue;
begin
  Result.Data := nil;
  SetLength(Result.Data, ASize);
  if ASize > 0 then
    Move(APtr^, Result.Data[0], ASize);
end;

function AbiValueI32(const AValue: Int32): TWasmAbiValue;
begin
  Result := BytesOf(@AValue, SizeOf(AValue));
end;

function AbiValueI64(const AValue: Int64): TWasmAbiValue;
begin
  Result := BytesOf(@AValue, SizeOf(AValue));
end;

function AbiValueU32(const AValue: UInt32): TWasmAbiValue;
begin
  Result := BytesOf(@AValue, SizeOf(AValue));
end;

function AbiValueU64(const AValue: UInt64): TWasmAbiValue;
begin
  Result := BytesOf(@AValue, SizeOf(AValue));
end;

function AbiValueF32(const AValue: Single): TWasmAbiValue;
begin
  Result := BytesOf(@AValue, SizeOf(AValue));
end;

function AbiValueF64(const AValue: Double): TWasmAbiValue;
begin
  Result := BytesOf(@AValue, SizeOf(AValue));
end;

function AbiValuePointer(const AValue: Pointer): TWasmAbiValue;
begin
  Result := BytesOf(@AValue, SizeOf(AValue));
end;

function AbiValueBytes(const ABytes: array of Byte): TWasmAbiValue;
var
  I: Integer;
begin
  Result.Data := nil;
  SetLength(Result.Data, Length(ABytes));
  for I := 0 to High(ABytes) do
    Result.Data[I] := ABytes[I];
end;

function ReadSized(const AValue: TWasmAbiValue; const ASize: Integer): UInt64;
var
  N: Integer;
begin
  Result := 0;
  N := Length(AValue.Data);
  if N > ASize then
    N := ASize;
  if N > 0 then
    Move(AValue.Data[0], Result, N);
end;

function AbiValueAsI32(const AValue: TWasmAbiValue): Int32;
begin
  Result := Int32(ReadSized(AValue, 4));
end;

function AbiValueAsI64(const AValue: TWasmAbiValue): Int64;
begin
  Result := Int64(ReadSized(AValue, 8));
end;

function AbiValueAsU64(const AValue: TWasmAbiValue): UInt64;
begin
  Result := ReadSized(AValue, 8);
end;

function AbiValueAsF32(const AValue: TWasmAbiValue): Single;
var
  Bits: UInt32;
begin
  Bits := UInt32(ReadSized(AValue, 4));
  Move(Bits, Result, 4);
end;

function AbiValueAsF64(const AValue: TWasmAbiValue): Double;
var
  Bits: UInt64;
begin
  Bits := ReadSized(AValue, 8);
  Move(Bits, Result, 8);
end;

function AbiValueAsPointer(const AValue: TWasmAbiValue): Pointer;
begin
  Result := Pointer(NativeUInt(ReadSized(AValue, SizeOf(Pointer))));
end;

function NativeCallSupported: Boolean;
begin
  {$IFDEF WASM_NATIVE_CALL}
  Result := True;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function SliceU64(const AValue: TWasmAbiValue; const AOffset, ASize: UInt32): UInt64;
var
  N: Integer;
  Avail: Integer;
begin
  Result := 0;
  if ASize = 0 then
    Exit;
  Avail := Length(AValue.Data) - Integer(AOffset);
  if Avail <= 0 then
    Exit;
  N := Integer(ASize);
  if N > Avail then
    N := Avail;
  if N > 8 then
    N := 8;
  Move(AValue.Data[AOffset], Result, N);
end;

procedure PlaceU64(var ADest: array of Byte; const AOffset, ASize: UInt32;
  const ABits: UInt64);
var
  N: Integer;
  Avail: Integer;
begin
  if ASize = 0 then
    Exit;
  Avail := Length(ADest) - Integer(AOffset);
  if Avail <= 0 then
    Exit;
  N := Integer(ASize);
  if N > Avail then
    N := Avail;
  if N > 8 then
    N := 8;
  Move(ABits, ADest[AOffset], N);
end;

procedure ApplyNativeCall(const APlan: TWasmAbiPlan; const AFn: Pointer;
  const AArgs: array of TWasmAbiValue; var AResult: TWasmAbiValue);
var
  IntRegs: array[0..7] of UInt64;
  FloatRegs: array[0..7] of UInt64;
  ResultInt: array[0..1] of UInt64;
  ResultFloat: array[0..3] of UInt64;
  Stack: array of Byte;
  Hidden: Pointer;
  Copies: array of TCopyHold;
  I, J, C, N: Integer;
  Piece: TWasmAbiPiece;
  PtrBits: UInt64;
begin
  if (not APlan.Compatible) or (APlan.Target <> AbiHostTarget) or (AFn = nil) then
    raise EWasmLinkError.Create(string(MSG_LINK_INCOMPATIBLE_PLAN));
  if Length(AArgs) <> Length(APlan.Args) then
    raise EWasmLinkError.Create(string(MSG_LINK_INCOMPATIBLE_PLAN) +
      ': argument count');
  {$IFNDEF WASM_NATIVE_CALL}
  raise EWasmLinkError.Create(string(MSG_LINK_INCOMPATIBLE_PLAN) +
    ': native calls are 64-bit Unix only');
  {$ELSE}

  InstallGate;
  FillChar(IntRegs, SizeOf(IntRegs), 0);
  FillChar(FloatRegs, SizeOf(FloatRegs), 0);
  FillChar(ResultInt, SizeOf(ResultInt), 0);
  FillChar(ResultFloat, SizeOf(ResultFloat), 0);
  SetLength(Stack, Integer(APlan.StackSize));
  if APlan.StackSize > 0 then
    FillChar(Stack[0], Integer(APlan.StackSize), 0);
  Hidden := nil;
  Copies := nil;

  if APlan.HiddenReturn then
  begin
    C := Length(Copies);
    SetLength(Copies, C + 1);
    SetLength(Copies[C].Bytes, Integer(APlan.Result.Size));
    if APlan.Result.Size > 0 then
      FillChar(Copies[C].Bytes[0], Integer(APlan.Result.Size), 0);
    Hidden := @Copies[C].Bytes[0];
    if APlan.Target = wabSysvX64 then
      IntRegs[0] := UInt64(NativeUInt(Hidden));
  end;

  for I := 0 to High(APlan.Args) do
    for J := 0 to High(APlan.Args[I].Pieces) do
    begin
      Piece := APlan.Args[I].Pieces[J];
      case Piece.Kind of
        wapIntReg:
          IntRegs[Piece.Reg] := SliceU64(AArgs[I], Piece.Offset, Piece.Size);
        wapFloatReg:
          FloatRegs[Piece.Reg] := SliceU64(AArgs[I], Piece.Offset, Piece.Size);
        wapStack:
          begin
            { Offset is the outgoing stack slot, not a byte offset inside
              the argument. Each stack argument is one piece covering the
              value from Data[0]. }
            N := Integer(Piece.Size);
            if N > Length(AArgs[I].Data) then
              N := Length(AArgs[I].Data);
            if (N > 0) and
              (Integer(Piece.Offset) + N <= Length(Stack)) then
              Move(AArgs[I].Data[0], Stack[Piece.Offset], N);
          end;
        wapIndirect:
          begin
            C := Length(Copies);
            SetLength(Copies, C + 1);
            SetLength(Copies[C].Bytes, Integer(Piece.Size));
            if (Piece.Size > 0) and (Length(AArgs[I].Data) > 0) then
            begin
              N := Integer(Piece.Size);
              if N > Length(AArgs[I].Data) then
                N := Length(AArgs[I].Data);
              Move(AArgs[I].Data[0], Copies[C].Bytes[0], N);
            end;
            PtrBits := UInt64(NativeUInt(@Copies[C].Bytes[0]));
            if Piece.Reg = $FF then
              PlaceU64(Stack, Piece.Offset, 8, PtrBits)
            else
              IntRegs[Piece.Reg] := PtrBits;
          end;
      else
        ;
      end;
    end;

  if Length(Stack) = 0 then
    GGate(AFn, @IntRegs[0], @FloatRegs[0], nil, 0, Hidden,
      @ResultInt[0], @ResultFloat[0])
  else
    GGate(AFn, @IntRegs[0], @FloatRegs[0], @Stack[0], APlan.StackSize, Hidden,
      @ResultInt[0], @ResultFloat[0]);

  SetLength(AResult.Data, Integer(APlan.Result.Size));
  if APlan.Result.Size > 0 then
    FillChar(AResult.Data[0], Integer(APlan.Result.Size), 0);

  if APlan.HiddenReturn and (Hidden <> nil) and (APlan.Result.Size > 0) then
    Move(Hidden^, AResult.Data[0], Integer(APlan.Result.Size))
  else
    for J := 0 to High(APlan.Result.Pieces) do
    begin
      Piece := APlan.Result.Pieces[J];
      case Piece.Kind of
        wapIntReg:
          PlaceU64(AResult.Data, Piece.Offset, Piece.Size, ResultInt[Piece.Reg]);
        wapFloatReg:
          PlaceU64(AResult.Data, Piece.Offset, Piece.Size, ResultFloat[Piece.Reg]);
      else
        ;
      end;
    end;
  {$ENDIF}
end;

{$IFDEF WASM_NATIVE_CALL}
finalization
  if GGateMem <> nil then
    Fpmunmap(GGateMem, GGateSize);
{$ENDIF}

end.
