{ Pascal cdecl twin of wasmlightabi.c — a stable C ABI from FreePascal. }
library libwasmlightabi;

{$mode delphi}
{$H+}

function AddI32(A, B: Int32): Int32; cdecl;
begin
  Result := A + B;
end;

function AddI64(A, B: Int64): Int64; cdecl;
begin
  Result := A + B;
end;

function AddF64(A, B: Double): Double; cdecl;
begin
  Result := A + B;
end;

function Sum9(A, B, C, D, E, F, G, H, I: Int32): Int32; cdecl;
begin
  Result := A + B + C + D + E + F + G + H + I;
end;

type
  TPairI32 = record
    A: Int32;
    B: Int32;
  end;

  TPairF32 = record
    A: Single;
    B: Single;
  end;

  TBig24 = record
    A: Int64;
    B: Int64;
    C: Int64;
  end;

function AddPair(X, Y: TPairI32): TPairI32; cdecl;
begin
  Result.A := X.A + Y.A;
  Result.B := X.B + Y.B;
end;

function AddHfa(X, Y: TPairF32): TPairF32; cdecl;
begin
  Result.A := X.A + Y.A;
  Result.B := X.B + Y.B;
end;

function LoadPtr(const P: PInt32): Int32; cdecl;
begin
  Result := P^;
end;

function SumBig(S: TBig24): Int64; cdecl;
begin
  Result := S.A + S.B + S.C;
end;

{$IFDEF DARWIN}
{ Darwin's C ABI prefixes exported symbols with `_`; dlsym("add_i32")
  looks up `_add_i32`. }
exports
  AddI32 name '_add_i32',
  AddI64 name '_add_i64',
  AddF64 name '_add_f64',
  Sum9 name '_sum9',
  AddPair name '_add_pair',
  AddHfa name '_add_hfa',
  LoadPtr name '_load_ptr',
  SumBig name '_sum_big';
{$ELSE}
exports
  AddI32 name 'add_i32',
  AddI64 name 'add_i64',
  AddF64 name 'add_f64',
  Sum9 name 'sum9',
  AddPair name 'add_pair',
  AddHfa name 'add_hfa',
  LoadPtr name 'load_ptr',
  SumBig name 'sum_big';
{$ENDIF}

end.
