{ Wasm.Wat.Names — identifier and symbol resolution for the `wat` text-format
  assembler (Track C, .agent/design/wat-assembler.md §2(b), §2(c.1), §7).

  This unit owns the twelve identifier contexts the module grammar names, the
  label stack, the per-type field namespaces, duplicate detection, and — the
  single highest-risk piece of the whole format — the implicit-typeuse
  dedup/insert table (text-typeuse-abbrev).

  The twelve contexts (text-idx):

    type func table mem global tag elem data   — module scope, FORWARD refs
    local                                       — function scope, no forward
    label                                       — a shadowing STACK
    field                                       — per resolved type index

  Two rules from the corpus drive the shape here and both are load-bearing:

  - Duplicate ids in a space are TEXT errors spelled `duplicate <space>`
    (func.wast:978-986, struct.wast:17, imports duplicate-memory cases). The
    message names the space, and `memory` is spelled `duplicate memory`, not
    `duplicate mem`.

  - The implicit typeuse (a `(param)(result)` with no `(type $x)`) must find
    the SMALLEST existing type index whose rectype is a SINGULAR, FINAL
    function type structurally matching, else APPEND a new type at the end of
    the module — and explicit types keep their textual slots and are NEVER
    deduped (text-typeuse-abbrev; the oracle cases are func.wast:422-433,
    func_ptrs.wast:2-4, type-rec.wast:45-61). "Singular, final" has teeth: a
    member of a multi-member `(rec …)` group, or a member carrying `(sub …)`,
    is not reusable even when its shape matches.

  Spec citations against wasm-mcp pinned core spec, commit
  d7b37e4170d8315f2f1283aed4e8076591a9a333:
    - identifier contexts / index spaces:
      https://webassembly.github.io/spec/core/text/modules.html#text-idx
    - labels (a shadowing stack, innermost first):
      https://webassembly.github.io/spec/core/text/instructions.html#text-label
    - type uses and implicit type insertion:
      https://webassembly.github.io/spec/core/text/modules.html#text-typeuse-abbrev

  Depends only on Wasm.Core, per the unit layout in §6. }
unit Wasm.Wat.Names;

{$I Shared.inc}

interface

uses
  Generics.Collections,
  SysUtils,

  Wasm.Core;

type
  { EWasmTextError (with its Line/Column fields) now lives in Wasm.Core
    (design §1): promoted from the per-unit local copies so every
    Wasm.Wat.* unit and the runner share one type. Reachable here through
    the Wasm.Core in this unit's uses. }

  { The eight module-scope index spaces (all with forward references). local,
    label, and field are handled by dedicated methods below because their
    scope and lookup differ. }
  TWatSpace = (
    wnsType, wnsFunc, wnsTable, wnsMem, wnsGlobal, wnsTag, wnsElem, wnsData);

const
  { The name-resolution vocabulary. These prefixes belong to Names because
    this is the unit that OWNS name resolution — even though the assembler
    is the caller that reaches a failing lookup and raises them. Keeping
    them here (rather than at the raise site) keeps the resolution
    diagnostics in one place. }
  MSG_UNKNOWN_LABEL    = 'unknown label';
  MSG_UNKNOWN_TYPE     = 'unknown type';
  MSG_INLINE_FUNC_TYPE = 'inline function type';
  MSG_MISMATCHING_LABEL = 'mismatching label';

{ Structural equality of two value types — the `syntactically equal` relation
  the implicit-typeuse reuse and the inline-declaration match both need. No
  subtyping or substitution is considered (text-typeuse: "possible type
  substitutions … are not taken into account"). }
function WatValueTypeEquals(const A, B: TWasmValueType): Boolean;

{ Structural equality of a stored function type against candidate param/result
  lists. }
function WatFuncTypeEquals(const AFunc: TWasmFuncType;
  const AParams, AResults: array of TWasmValueType): Boolean;

type
  TWatNames = class
  private
    FDict: array[TWatSpace] of TDictionary<string, Integer>;
    FCount: array[TWatSpace] of Integer;

    { Type space: the emitted groups, plus a flattened per-member view keyed
      by type index (each group contributes one index per subtype). }
    FGroups: array of TWasmRecType;
    FMemberComp: array of TWasmCompType;   { the member's composite type }
    FMemberReusable: array of Boolean;     { singular + final + func => reusable }
    FTypeCount: Integer;                   { total member type indices }
    FPreBoundTypeCount: Integer;           { indices consumed by PreBindType }

    { Field namespaces, keyed by resolved type index. FFieldCount advances for
      EVERY field (named or not) so ordinals stay right; FFieldNames records
      only the named ones. }
    FFieldNames: array of TDictionary<string, Integer>;
    FFieldCount: array of Integer;

    FLocals: TDictionary<string, Integer>;
    FLocalCount: Integer;

    FLabels: array of string;              { High = innermost }

    procedure RaiseDuplicate(const AWhat: string);
    procedure EnsureTypeCapacity;
    procedure AppendMember(const AComp: TWasmCompType;
      const AReusable: Boolean; const AName: string);
  public
    constructor Create;
    destructor Destroy; override;

    { The canonical `duplicate <space>` word for a space. }
    class function SpaceWord(const ASpace: TWatSpace): string; static;

    { --- module index spaces ------------------------------------------- }
    { Reserve the next index in ASpace, binding AName (skip when empty). A
      repeated non-empty name raises `duplicate <space>`. Returns the index. }
    function Bind(const ASpace: TWatSpace; const AName: string): Integer;
    { The index bound to AName, or -1 when unbound. }
    function LookupName(const ASpace: TWatSpace; const AName: string): Integer;
    function SpaceCount(const ASpace: TWatSpace): Integer;

    { --- types --------------------------------------------------------- }
    { Pre-bind a single type member's identifier to its module type index
      WITHOUT parsing its body, so a type body may forward-reference any type
      by name — inside its own rec group (a self-reference), or a group defined
      later (text-typeidx; type-subtyping.wast, type-rec.wast). Called once per
      member, in module order, before any type body is parsed. A '' name still
      consumes an index so ordinals stay aligned with AddTypeGroup. }
    procedure PreBindType(const AName: string);
    { Append one whole rec group (already parsed). When ABindNames is True the
      member names are bound here; when the names were already registered by
      PreBindType, pass False so they are not re-bound (which would look like a
      duplicate). A single-member group whose subtype is final, has no
      supertypes, and is a function type becomes reusable by a later implicit
      typeuse. AMemberNames is one entry per subtype ('' for anonymous). }
    procedure AddTypeGroup(const ARec: TWasmRecType;
      const AMemberNames: array of string; const ABindNames: Boolean = True);
    { The implicit-typeuse rule: the smallest reusable matching type index, or
      a freshly appended one. THE §7 risk. }
    function InternFuncType(const AParams, AResults: array of TWasmValueType):
      Integer;
    function TypeGroupCount: Integer;
    function TypeGroup(const AIndex: Integer): TWasmRecType;
    function TypeMemberCount: Integer;
    function LookupType(const AName: string): Integer;
    function MemberIsFunc(const AIndex: Integer): Boolean;
    function MemberFunc(const AIndex: Integer): TWasmFuncType;
    function MemberFuncParamCount(const AIndex: Integer): Integer;

    { --- fields (per type index) --------------------------------------- }
    { Advance the field ordinal of ATypeIndex and bind AName when non-empty.
      A repeated name raises `duplicate field`. }
    procedure BindField(const ATypeIndex: Integer; const AName: string);
    function LookupField(const ATypeIndex: Integer;
      const AName: string): Integer;

    { --- locals (function scope) --------------------------------------- }
    procedure ResetLocals;
    function BindLocal(const AName: string): Integer;
    function LookupLocal(const AName: string): Integer;
    function LocalCount: Integer;

    { --- labels (a shadowing stack) ------------------------------------ }
    procedure PushLabel(const AName: string);
    procedure PopLabel;
    { The de Bruijn depth of the innermost label named AName (0 = innermost),
      or -1 when no such label is on the stack. }
    function LabelDepth(const AName: string): Integer;
    function LabelCount: Integer;
    function InnermostLabelName: string;
  end;

implementation

function WatValueTypeEquals(const A, B: TWasmValueType): Boolean;
begin
  if A.Kind <> B.Kind then
    Exit(False);
  case A.Kind of
    wvkNum: Result := A.Num = B.Num;
    wvkVec: Result := True;
    wvkRef:
      begin
        if A.Ref.Nullable <> B.Ref.Nullable then
          Exit(False);
        if A.Ref.Heap.IsAbstract <> B.Ref.Heap.IsAbstract then
          Exit(False);
        if A.Ref.Heap.IsAbstract then
          Result := A.Ref.Heap.Abs = B.Ref.Heap.Abs
        else
          Result := A.Ref.Heap.TypeIndex = B.Ref.Heap.TypeIndex;
      end;
  else
    Result := False;
  end;
end;

function WatFuncTypeEquals(const AFunc: TWasmFuncType;
  const AParams, AResults: array of TWasmValueType): Boolean;
var
  I: Integer;
begin
  if Length(AFunc.Params) <> Length(AParams) then
    Exit(False);
  if Length(AFunc.Results) <> Length(AResults) then
    Exit(False);
  for I := 0 to High(AParams) do
    if not WatValueTypeEquals(AFunc.Params[I], AParams[I]) then
      Exit(False);
  for I := 0 to High(AResults) do
    if not WatValueTypeEquals(AFunc.Results[I], AResults[I]) then
      Exit(False);
  Result := True;
end;

{ --- TWatNames ---------------------------------------------------------- }

constructor TWatNames.Create;
var
  S: TWatSpace;
begin
  inherited Create;
  for S := Low(TWatSpace) to High(TWatSpace) do
  begin
    FDict[S] := TDictionary<string, Integer>.Create;
    FCount[S] := 0;
  end;
  FLocals := TDictionary<string, Integer>.Create;
  FLocalCount := 0;
  FTypeCount := 0;
end;

destructor TWatNames.Destroy;
var
  S: TWatSpace;
  I: Integer;
begin
  for S := Low(TWatSpace) to High(TWatSpace) do
    FDict[S].Free;
  FLocals.Free;
  for I := 0 to High(FFieldNames) do
    if FFieldNames[I] <> nil then
      FFieldNames[I].Free;
  inherited Destroy;
end;

class function TWatNames.SpaceWord(const ASpace: TWatSpace): string;
begin
  case ASpace of
    wnsType:   Result := 'type';
    wnsFunc:   Result := 'func';
    wnsTable:  Result := 'table';
    wnsMem:    Result := 'memory';
    wnsGlobal: Result := 'global';
    wnsTag:    Result := 'tag';
    wnsElem:   Result := 'elem';
    wnsData:   Result := 'data';
  else
    Result := '?';
  end;
end;

procedure TWatNames.RaiseDuplicate(const AWhat: string);
begin
  raise EWasmTextError.Create('duplicate ' + AWhat);
end;

function TWatNames.Bind(const ASpace: TWatSpace; const AName: string): Integer;
begin
  Result := FCount[ASpace];
  if AName <> '' then
  begin
    if FDict[ASpace].ContainsKey(AName) then
      RaiseDuplicate(SpaceWord(ASpace));
    FDict[ASpace].Add(AName, Result);
  end;
  Inc(FCount[ASpace]);
end;

function TWatNames.LookupName(const ASpace: TWatSpace;
  const AName: string): Integer;
begin
  if not FDict[ASpace].TryGetValue(AName, Result) then
    Result := -1;
end;

function TWatNames.SpaceCount(const ASpace: TWatSpace): Integer;
begin
  Result := FCount[ASpace];
end;

{ --- types -------------------------------------------------------------- }

procedure TWatNames.EnsureTypeCapacity;
begin
  if FTypeCount >= Length(FMemberComp) then
  begin
    if Length(FMemberComp) = 0 then
    begin
      SetLength(FMemberComp, 8);
      SetLength(FMemberReusable, 8);
    end
    else
    begin
      SetLength(FMemberComp, Length(FMemberComp) * 2);
      SetLength(FMemberReusable, Length(FMemberReusable) * 2);
    end;
  end;
  if FTypeCount >= Length(FFieldNames) then
  begin
    SetLength(FFieldNames, Length(FMemberComp));
    SetLength(FFieldCount, Length(FMemberComp));
  end;
end;

procedure TWatNames.AppendMember(const AComp: TWasmCompType;
  const AReusable: Boolean; const AName: string);
begin
  EnsureTypeCapacity;
  FMemberComp[FTypeCount] := AComp;
  FMemberReusable[FTypeCount] := AReusable;
  FFieldNames[FTypeCount] := nil;
  FFieldCount[FTypeCount] := 0;
  if AName <> '' then
  begin
    if FDict[wnsType].ContainsKey(AName) then
      RaiseDuplicate('type');
    FDict[wnsType].Add(AName, FTypeCount);
  end;
  Inc(FTypeCount);
  Inc(FCount[wnsType]);
end;

procedure TWatNames.PreBindType(const AName: string);
begin
  if AName <> '' then
  begin
    if FDict[wnsType].ContainsKey(AName) then
      RaiseDuplicate('type');
    FDict[wnsType].Add(AName, FPreBoundTypeCount);
  end;
  Inc(FPreBoundTypeCount);
end;

procedure TWatNames.AddTypeGroup(const ARec: TWasmRecType;
  const AMemberNames: array of string; const ABindNames: Boolean = True);
var
  I: Integer;
  Reusable: Boolean;
  Sub: TWasmSubType;
  Name: string;
begin
  SetLength(FGroups, Length(FGroups) + 1);
  FGroups[High(FGroups)] := ARec;
  { A group is reusable-as-implicit only when it is SINGULAR: exactly one
    member, final, no declared supertypes, a function type. }
  for I := 0 to High(ARec.SubTypes) do
  begin
    Sub := ARec.SubTypes[I];
    Reusable := (Length(ARec.SubTypes) = 1) and Sub.IsFinal
      and (Length(Sub.SuperTypes) = 0) and (Sub.Comp.Kind = wckFunc);
    if ABindNames and (I <= High(AMemberNames)) then
      Name := AMemberNames[I]
    else
      Name := '';
    AppendMember(Sub.Comp, Reusable, Name);
  end;
end;

function TWatNames.InternFuncType(
  const AParams, AResults: array of TWasmValueType): Integer;
var
  I: Integer;
  Rec: TWasmRecType;
  Func: TWasmFuncType;
  Empty: array of string;
begin
  { Smallest reusable matching index wins — a linear scan from 0 over every
    known type (explicit + previously inserted implicit). }
  for I := 0 to FTypeCount - 1 do
    if FMemberReusable[I]
      and WatFuncTypeEquals(FMemberComp[I].Func, AParams, AResults) then
      Exit(I);

  { None: append a fresh singular final func type at the module end. }
  SetLength(Func.Params, Length(AParams));
  for I := 0 to High(AParams) do
    Func.Params[I] := AParams[I];
  SetLength(Func.Results, Length(AResults));
  for I := 0 to High(AResults) do
    Func.Results[I] := AResults[I];

  SetLength(Rec.SubTypes, 1);
  Rec.SubTypes[0].IsFinal := True;
  Rec.SubTypes[0].SuperTypes := nil;
  Rec.SubTypes[0].Comp := MakeFuncCompType(Func);

  Result := FTypeCount;
  Empty := nil;
  AddTypeGroup(Rec, Empty);
end;

function TWatNames.TypeGroupCount: Integer;
begin
  Result := Length(FGroups);
end;

function TWatNames.TypeGroup(const AIndex: Integer): TWasmRecType;
begin
  Result := FGroups[AIndex];
end;

function TWatNames.TypeMemberCount: Integer;
begin
  Result := FTypeCount;
end;

function TWatNames.LookupType(const AName: string): Integer;
begin
  if not FDict[wnsType].TryGetValue(AName, Result) then
    Result := -1;
end;

function TWatNames.MemberIsFunc(const AIndex: Integer): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex < FTypeCount)
    and (FMemberComp[AIndex].Kind = wckFunc);
end;

function TWatNames.MemberFunc(const AIndex: Integer): TWasmFuncType;
begin
  Result := FMemberComp[AIndex].Func;
end;

function TWatNames.MemberFuncParamCount(const AIndex: Integer): Integer;
begin
  if MemberIsFunc(AIndex) then
    Result := Length(FMemberComp[AIndex].Func.Params)
  else
    Result := 0;
end;

{ --- fields ------------------------------------------------------------- }

procedure TWatNames.BindField(const ATypeIndex: Integer;
  const AName: string);
var
  Ordinal: Integer;
begin
  if (ATypeIndex < 0) or (ATypeIndex >= FTypeCount) then
    Exit;
  Ordinal := FFieldCount[ATypeIndex];
  if AName <> '' then
  begin
    if FFieldNames[ATypeIndex] = nil then
      FFieldNames[ATypeIndex] := TDictionary<string, Integer>.Create;
    if FFieldNames[ATypeIndex].ContainsKey(AName) then
      RaiseDuplicate('field');
    FFieldNames[ATypeIndex].Add(AName, Ordinal);
  end;
  Inc(FFieldCount[ATypeIndex]);
end;

function TWatNames.LookupField(const ATypeIndex: Integer;
  const AName: string): Integer;
begin
  Result := -1;
  if (ATypeIndex < 0) or (ATypeIndex >= FTypeCount) then
    Exit;
  if FFieldNames[ATypeIndex] = nil then
    Exit;
  if not FFieldNames[ATypeIndex].TryGetValue(AName, Result) then
    Result := -1;
end;

{ --- locals ------------------------------------------------------------- }

procedure TWatNames.ResetLocals;
begin
  FLocals.Clear;
  FLocalCount := 0;
end;

function TWatNames.BindLocal(const AName: string): Integer;
begin
  Result := FLocalCount;
  if AName <> '' then
  begin
    { Params and locals share ONE namespace, so a param/local clash is a
      `duplicate local` (func.wast:978-986). }
    if FLocals.ContainsKey(AName) then
      RaiseDuplicate('local');
    FLocals.Add(AName, Result);
  end;
  Inc(FLocalCount);
end;

function TWatNames.LookupLocal(const AName: string): Integer;
begin
  if not FLocals.TryGetValue(AName, Result) then
    Result := -1;
end;

function TWatNames.LocalCount: Integer;
begin
  Result := FLocalCount;
end;

{ --- labels ------------------------------------------------------------- }

procedure TWatNames.PushLabel(const AName: string);
begin
  SetLength(FLabels, Length(FLabels) + 1);
  FLabels[High(FLabels)] := AName;
end;

procedure TWatNames.PopLabel;
begin
  if Length(FLabels) > 0 then
    SetLength(FLabels, Length(FLabels) - 1);
end;

function TWatNames.LabelDepth(const AName: string): Integer;
var
  I: Integer;
begin
  { Innermost first, with shadowing: the first match scanning from the top is
    the reachable one (text-label). Anonymous labels ('') never match by name. }
  if AName = '' then
    Exit(-1);
  for I := High(FLabels) downto 0 do
    if FLabels[I] = AName then
      Exit(High(FLabels) - I);
  Result := -1;
end;

function TWatNames.LabelCount: Integer;
begin
  Result := Length(FLabels);
end;

function TWatNames.InnermostLabelName: string;
begin
  if Length(FLabels) > 0 then
    Result := FLabels[High(FLabels)]
  else
    Result := '';
end;

end.
