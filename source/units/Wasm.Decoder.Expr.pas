{ Wasm.Decoder.Expr — the expression skipper: walks one `expr` (instr*
  terminated by `end`) without interpreting anything, and reports its
  extent as a span into the module buffer.

  Global and table initialisers, element offsets and init expressions,
  and data offsets carry no size prefix, so the only way the decoder can
  find where they stop is to walk the instruction grammar itself. That
  is ALL this unit does: it consumes each instruction's immediates and
  tracks block nesting until the matching `end`. It never asks whether
  an instruction is allowed where it stands — constness, typing, and
  index bounds are validation rules, so a `nop` inside a global init
  skips fine here and is rejected later. What DOES fail here is exactly
  what the binary grammar rejects: an unassigned opcode or prefixed
  subopcode, a truncated immediate, an unterminated expression — all
  malformed, all EWasmDecodeError with offset context.

  The immediate shapes below are the full 3.0 instruction grammar at the
  skip level: the single-byte core space plus the three u32-subopcode
  prefixed spaces $FB (aggregate/GC), $FC (saturating truncation + bulk
  memory/table), and $FD (vector). Every group cites its clause.
  https://webassembly.github.io/spec/core/binary/instructions.html }
unit Wasm.Decoder.Expr;

{$I Shared.inc}

interface

uses
  SysUtils,

  Wasm.Binary,
  Wasm.Core,
  Wasm.Decoder.Common,
  Wasm.Module;

{ Skips one expr starting at AReader's current position and returns its
  span INCLUDING the terminating `end` byte. ABase is the absolute
  buffer offset of the reader's byte 0, so Result.Offset is absolute
  per ADR-0003.
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-expr }
function SkipExpr(var AReader: TWasmReader;
  const ABase: NativeUInt): TWasmSpan;

implementation

const
  OP_END  = $0B;
  OP_ELSE = $05;

{ Block type: the byte $40 (empty), a value type, or a non-negative s33
  type index. The first two are literal single-byte productions (and the
  long-form reference value types, which start with the $63/$64 marker
  bytes), so a padded sLEB spelling of their codes matches nothing; the
  index arm is a genuine s33 and admits padded encodings like any uN/sN.
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-blocktype }
procedure SkipBlockType(var AReader: TWasmReader);
const
  BLOCKTYPE_EMPTY = -64; { the byte $40 in the signed code space }
var
  Marker: Byte;
  Start: NativeUInt;
  Code: Int64;
  Value: TWasmValueType;
begin
  Marker := AReader.PeekByte;
  if (Marker = BYTE_REF_NULL) or (Marker = BYTE_REF) then
  begin
    ReadRefType(AReader);
    Exit;
  end;

  Start := AReader.Position;
  Code := AReader.ReadS33;
  if Code >= 0 then
    Exit; { type index }

  if (AReader.Position - Start = 1)
     and ((Code = BLOCKTYPE_EMPTY) or TryDecodeValueType(Code, Value)) then
    Exit;

  raise EWasmDecodeError.CreateFmt(
    'malformed block type (code %d) at offset %u', [Code, Start]);
end;

{ Memory argument. The 3.0 grammar is
    memarg ::= n:u32 m:u64                    (if n < 2^6)
             | n:u32 x:memidx m:u64           (if 2^6 <= n < 2^7)
  — bit 6 of the align field signals an explicit memory index between
  the align and the offset (it defaults to 0 otherwise), and the OFFSET
  IS A u64, not a u32, because 64-bit memories are in the 3.0 grammar.
  Both side conditions are on the VALUE of n: a flags value of 2^7 or
  above matches neither production and is malformed, however encoded.
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-memarg
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-instr-memory }
procedure SkipMemarg(var AReader: TWasmReader);
const
  MEMARG_FLAG_MEMIDX = $40;
var
  Start: NativeUInt;
  Flags: UInt32;
begin
  Start := AReader.Position;
  Flags := AReader.ReadU32;
  if Flags >= $80 then
    raise EWasmDecodeError.CreateFmt(
      'malformed memarg flags %u at offset %u', [Flags, Start]);

  if (Flags and MEMARG_FLAG_MEMIDX) <> 0 then
    AReader.ReadU32; { memidx }
  AReader.ReadU64;   { offset — u64, see above }
end;

{ The catch clause vector that follows try_table's block type. Each
  clause is a kind byte with exactly four assigned values, then the
  clause's immediates — the tag-carrying kinds take a tagidx before the
  labelidx every kind ends with.
    catch ::= 0x00 x:tagidx l:labelidx   (catch)
            | 0x01 x:tagidx l:labelidx   (catch_ref)
            | 0x02 l:labelidx            (catch_all)
            | 0x03 l:labelidx            (catch_all_ref)
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-catch }
procedure SkipCatchVector(var AReader: TWasmReader);
var
  Count: UInt32;
  I: UInt32;
  Start: NativeUInt;
  Kind: Byte;
begin
  Count := AReader.ReadU32;
  I := 0;
  while I < Count do
  begin
    Start := AReader.Position;
    Kind := AReader.ReadByte;
    case Kind of
      $00, $01:
        begin
          AReader.ReadU32; { tagidx }
          AReader.ReadU32; { labelidx }
        end;
      $02, $03:
        AReader.ReadU32;   { labelidx }
    else
      raise EWasmDecodeError.CreateFmt(
        'malformed catch clause kind $%.2x at offset %u', [Kind, Start]);
    end;
    Inc(I);
  end;
end;

{ br_table: a vector of label indices plus the default label.
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-br_table }
procedure SkipBrTable(var AReader: TWasmReader);
var
  Count: UInt32;
  I: UInt32;
begin
  Count := AReader.ReadU32;
  I := 0;
  while I < Count do
  begin
    AReader.ReadU32; { labelidx }
    Inc(I);
  end;
  AReader.ReadU32;   { default labelidx }
end;

{ The $FB-prefixed aggregate (GC) space: a u32 subopcode, then the
  instruction's immediates. Assigned subopcodes are 0..30; anything else
  matches no production.
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-instr-aggr }
procedure SkipAggrInstr(var AReader: TWasmReader;
  const APrefixOffset: NativeUInt);
var
  Sub: UInt32;
  Start: NativeUInt;
  CastFlags: Byte;
begin
  Sub := AReader.ReadU32;
  case Sub of
    { One typeidx: struct.new, struct.new_default, array.new,
      array.new_default, array.get, array.get_s, array.get_u, array.set,
      array.len takes none but is grouped below, array.fill.
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-struct.new }
    0, 1, 6, 7, 11, 12, 13, 14, 16:
      AReader.ReadU32;

    { Two u32 indices: struct.get/get_s/get_u/set (typeidx fieldidx),
      array.new_fixed (typeidx count), array.new_data (typeidx dataidx),
      array.new_elem (typeidx elemidx), array.copy (typeidx typeidx),
      array.init_data (typeidx dataidx), array.init_elem
      (typeidx elemidx).
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-struct.get }
    2, 3, 4, 5, 8, 9, 10, 17, 18, 19:
      begin
        AReader.ReadU32;
        AReader.ReadU32;
      end;

    { No immediates: array.len, any.convert_extern, extern.convert_any,
      ref.i31, i31.get_s, i31.get_u.
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-array.len }
    15, 26, 27, 28, 29, 30:;

    { One heap type: ref.test / ref.cast, plain (20/22) and null
      (21/23) variants.
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-ref.test }
    20, 21, 22, 23:
      ReadHeapType(AReader);

    { br_on_cast / br_on_cast_fail: a castop flags byte with four
      assigned values ($00..$03 — which of the two reference types are
      nullable), then labelidx and TWO heap types.
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-br_on_cast
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-castop }
    24, 25:
      begin
        Start := AReader.Position;
        CastFlags := AReader.ReadByte;
        if CastFlags > $03 then
          raise EWasmDecodeError.CreateFmt(
            'malformed cast flags $%.2x at offset %u', [CastFlags, Start]);
        AReader.ReadU32;         { labelidx }
        ReadHeapType(AReader);
        ReadHeapType(AReader);
      end;
  else
    raise EWasmDecodeError.CreateFmt(
      'unknown $FB subopcode %u at offset %u', [Sub, APrefixOffset]);
  end;
end;

{ The $FC-prefixed space: saturating truncations (0..7, no immediates)
  and the bulk memory/table instructions. All immediates are u32
  indices, so only their COUNT matters to a skipper: memory.init
  (dataidx memidx), memory.copy (memidx memidx), table.init (elemidx
  tableidx), and table.copy (tableidx tableidx) take two; data.drop,
  memory.fill, table.grow/size/fill, and elem.drop take one.
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-cvtop-trunc-sat
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-memory.init
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-instr-table }
procedure SkipMiscInstr(var AReader: TWasmReader;
  const APrefixOffset: NativeUInt);
var
  Sub: UInt32;
begin
  Sub := AReader.ReadU32;
  case Sub of
    0..7:;

    { memory.init, memory.copy, table.init, table.copy }
    8, 10, 12, 14:
      begin
        AReader.ReadU32;
        AReader.ReadU32;
      end;

    { data.drop, memory.fill, table.grow, elem.drop, table.size,
      table.fill }
    9, 11, 13, 15, 16, 17:
      AReader.ReadU32;
  else
    raise EWasmDecodeError.CreateFmt(
      'unknown $FC subopcode %u at offset %u', [Sub, APrefixOffset]);
  end;
end;

{ The $FD-prefixed vector space: a u32 subopcode, then the immediates.
  The assigned set is NOT contiguous: twenty values inside 0..255 are
  unassigned in the 3.0 grammar, and the relaxed operations sit at
  256..275 — both facts below are spelled from the pinned spec's
  instruction tables, not assumed.
  https://webassembly.github.io/spec/core/binary/instructions.html#binary-instr-vec }
procedure SkipVecInstr(var AReader: TWasmReader;
  const APrefixOffset: NativeUInt);
var
  Sub: UInt32;
begin
  Sub := AReader.ReadU32;
  case Sub of
    { Loads and stores of the whole v128, the packed/splat load family,
      and load32/64_zero: one memarg.
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-load }
    0..11, 92, 93:
      SkipMemarg(AReader);

    { v128.const and i8x16.shuffle: 16 literal bytes — an immediate
      vector value and 16 lane indices respectively.
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-vshuffle }
    12, 13:
      AReader.Skip(16);

    { extract_lane / replace_lane for every shape: one laneidx byte.
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-vextract_lane
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-laneidx }
    21..34:
      AReader.Skip(1);

    { load8/16/32/64_lane and store8/16/32/64_lane: memarg, THEN the
      laneidx byte.
      https://webassembly.github.io/spec/core/binary/instructions.html#binary-instr-vec }
    84..91:
      begin
        SkipMemarg(AReader);
        AReader.Skip(1);
      end;

    { Everything else assigned takes no immediates. The gaps carved out
      of these ranges (154, 162, 165, 166, 175, 176, 178..180, 187,
      194, 197, 198, 207, 208, 210..212, 226, 238) are unassigned in
      the pinned 3.0 grammar and fall to the error arm; 256..275 are
      the relaxed operations. }
    14..20, 35..83, 94..153, 155..161, 163, 164, 167..174, 177,
    181..186, 188..193, 195, 196, 199..206, 209, 213..225, 227..237,
    239..275:;
  else
    raise EWasmDecodeError.CreateFmt(
      'unknown $FD subopcode %u at offset %u', [Sub, APrefixOffset]);
  end;
end;

{ One entry of SkipExpr's nesting stack. IsIf marks a frame opened by
  the `if` opcode — the only construct whose production admits an
  `else` delimiter — and SawElse records that its (at most one) else
  has been seen. }
type
  TBlockFrame = record
    IsIf: Boolean;
    SawElse: Boolean;
  end;

function SkipExpr(var AReader: TWasmReader;
  const ABase: NativeUInt): TWasmSpan;
var
  Start, OpOffset: NativeUInt;
  Op: Byte;
  { A stack of open structured instructions, not a bare depth counter:
    the grammar allows $05 only inside an `if`, and only once, so the
    skipper must know what kind of frame it is inside. Grown
    geometrically; Depth is the live count. }
  Frames: array of TBlockFrame;
  Depth: NativeUInt;
  Count: UInt32;

  procedure PushFrame(const AIsIf: Boolean);
  begin
    if Depth = NativeUInt(Length(Frames)) then
      SetLength(Frames, (Length(Frames) * 2) + 8);
    Frames[Depth].IsIf := AIsIf;
    Frames[Depth].SawElse := False;
    Inc(Depth);
  end;

begin
  Start := AReader.Position;
  Frames := nil;
  Depth := 0;

  repeat
    OpOffset := AReader.Position;
    Op := AReader.ReadByte;

    case Op of
      { `end` closes the innermost structured instruction, or at depth 0
        the expr itself.
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-expr }
      OP_END:
        begin
          if Depth = 0 then
            Break;
          Dec(Depth);
        end;

      { `else` is a delimiter, not an instruction, and the grammar
        admits it in exactly one place: the `if` production
        0x04 bt in1* (0x05 in2*)? 0x0B, at most once — "The ELSE opcode
        0x05 in the encoding of an IF instruction can be omitted if the
        following instruction sequence is empty." An else at expr top
        level, inside a non-if construct, or repeated within one if
        matches no production and is MALFORMED — and init/offset exprs
        are only ever walked here, so nothing downstream would catch
        it.
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-if }
      OP_ELSE:
        begin
          if (Depth = 0) or (not Frames[Depth - 1].IsIf)
             or Frames[Depth - 1].SawElse then
            raise EWasmDecodeError.CreateFmt(
              'misplaced else opcode at offset %u', [ABase + OpOffset]);
          Frames[Depth - 1].SawElse := True;
        end;

      { Structured instructions: a block type, then a nested instruction
        sequence closed by `end`. Only `if` ($04) opens a frame that may
        carry an else.
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-block }
      $02, $03:
        begin
          SkipBlockType(AReader);
          PushFrame(False);
        end;
      $04:
        begin
          SkipBlockType(AReader);
          PushFrame(True);
        end;

      { try_table adds its catch clause vector between the block type
        and the nested body.
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-try_table }
      $1F:
        begin
          SkipBlockType(AReader);
          SkipCatchVector(AReader);
          PushFrame(False);
        end;

      { No immediates: unreachable, nop, throw_ref, return, drop,
        select (untyped), the whole numeric test/rel/un/bin/cvt block
        $45..$C4, ref.is_null, ref.eq, ref.as_non_null.
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-nop
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-testop }
      $00, $01, $0A, $0F, $1A, $1B, $45..$C4, $D1, $D3, $D4:;

      { One u32 index immediate: throw (tagidx), br/br_if (labelidx),
        call/return_call (funcidx), call_ref/return_call_ref (typeidx),
        the local/global/table accessors ($20..$26), memory.size and
        memory.grow — which take a memidx in the 3.0 grammar, not a
        fixed zero byte — ref.func (funcidx), and br_on_null /
        br_on_non_null (labelidx).
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-br
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-memory.size
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-br_on_null }
      $08, $0C, $0D, $10, $12, $14, $15, $20..$26, $3F, $40, $D2,
      $D5, $D6:
        AReader.ReadU32;

      { call_indirect / return_call_indirect: typeidx, then tableidx.
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-call_indirect }
      $11, $13:
        begin
          AReader.ReadU32;
          AReader.ReadU32;
        end;

      $0E:
        SkipBrTable(AReader);

      { Typed select: a vector of value types.
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-select }
      $1C:
        begin
          Count := AReader.ReadU32;
          while Count > 0 do
          begin
            ReadValueType(AReader);
            Dec(Count);
          end;
        end;

      { All plain loads and stores: one memarg.
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-load }
      $28..$3E:
        SkipMemarg(AReader);

      { Constants: i32/i64 are sLEB128 of the value's width, f32/f64 are
        4 and 8 literal little-endian bytes.
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-const }
      $41: AReader.ReadI32;
      $42: AReader.ReadI64;
      $43: AReader.Skip(4);
      $44: AReader.Skip(8);

      { ref.null: a heap type.
        https://webassembly.github.io/spec/core/binary/instructions.html#binary-ref.null }
      $D0:
        ReadHeapType(AReader);

      { The prefix offset handed down is ABSOLUTE (ABase applied), so
        the prefixed-space error messages report buffer offsets like
        every other decoder message. }
      $FB: SkipAggrInstr(AReader, ABase + OpOffset);
      $FC: SkipMiscInstr(AReader, ABase + OpOffset);
      $FD: SkipVecInstr(AReader, ABase + OpOffset);
    else
      raise EWasmDecodeError.CreateFmt(
        'unknown opcode $%.2x at offset %u', [Op, ABase + OpOffset]);
    end;
  until False;

  Result := MakeSpan(ABase + Start, AReader.Position - Start);
end;

end.
