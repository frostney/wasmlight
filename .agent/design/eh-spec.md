# Track H — exception handling (`try_table` / `throw` / `throw_ref`)

Design spec. **Not source.** Scratchpad only — never commit. The deliverable
is this document; implementation spans a few waves and agents (§8). It builds
on the shipped source of `Wasm.Ir`, `Wasm.Validator.Body`, `Wasm.Runtime.*`,
`Wasm.Interp`, and `Wasm.Wast.*`, and on the design docs `ir-spec.md`,
`runtime-spec.md`, and `interp-spec.md`, which it may not contradict.

Spec pin (every anchor below): `wasm-mcp` 0.2.16, `spec/main`
`d7b37e4170d8315f2f1283aed4e8076591a9a333` (ADR-0004), `proposals/main`
`e007b5c9f2e510573869985cbc635c7f4fc0b566`, verified via `spec_version` at
authoring time. Confidence markers follow the repo convention: facts read
from the MCP at the pin are unmarked; anything the served text under-reports
or leaves to the corpus carries **UNCONFIRMED**, and Track C's runner (the
`assert_exception` corpus) is what promotes it.

Scope is the **3.0 exception-handling proposal that landed in the 3.0 draft**:
`try_table` (`0x1F`), `throw` (`0x08`), `throw_ref` (`0x0A`), the tag section
(id 13), the `exn` heap type and `exnref`. The **legacy** `try` / `catch` /
`delegate` / `rethrow` encoding is **out of scope** — it lives in
`tests/spec/testsuite/legacy/` and stays failing/skipped, which is correct per
the roadmap (§9).

---

## 0. What already exists, and the one thing that does not

The static half is **done** and this document does not redesign it. Verified
in the current tree:

- **Decode.** `Wasm.Decoder.Expr` skips the catch-clause vector
  (`SkipCatchVector`, the four kinds `0x00..0x03`); the tag section (id 13)
  decodes into the module model; tags carry a `syntax-tagtype` type index.
- **IR.** `Wasm.Ir` has `iroThrow` (`0x08`, `Dest ifkUnused`, `A ifkAuxIndex`
  = payload regs, `Imm` = tagidx) and `iroThrowRef` (`0x0A`, `A ifkSrcReg` =
  the exnref). `try_table` emits **no** instruction; it contributes:
  - `TWasmIrHandler { StartInstr, EndInstr, ClauseStart, ClauseCount }` in
    `TWasmIrFunction.Handlers`, appended at the try_table's `end` so
    **inner-before-outer** (a linear scan from index 0 finds the innermost —
    do not sort);
  - `TWasmIrCatchClause { Kind, TagIndex, TargetInstr, PayloadAux }` in
    `TWasmIrFunction.HandlerClauses`, where `Kind ∈ {wickCatch, wickCatchRef,
    wickCatchAll, wickCatchAllRef}` (ordinals coupled to the `binary-catch`
    bytes `0x00..0x03`), `TargetInstr` is the resolved target label
    instruction, and **`PayloadAux` is an `AuxU32` block holding the target
    label's merge registers, in order** — the payload destination IS the
    label's merge-register vector (`ir-spec.md` §4.12; the validator's
    `HandleTryTable` builds exactly this).
- **Validation.** `Wasm.Validator.Body`:
  - `HandleThrow`: reads the tagidx, `CheckTag` resolves the tag's functype,
    pops the tag's param types off the stack, appends them as the `iroThrow`
    payload aux block, `MarkUnreachable` (throw is stack-polymorphic,
    `valid-throw`).
  - `HandleThrowRef`: pops one `(ref null exn)` (`PopValExpect(MakeAbsRef(True,
    wahExn))`), emits `iroThrowRef`, `MarkUnreachable` (`valid-throw_ref`).
  - `HandleTryTable`: the `appendix/algorithm-validation` `try_table` rule —
    resolves each clause's label **before** the try_table frame is pushed,
    checks that the clause payload (`tag.params` for `catch`/`catch_ref`, plus
    `exnref` for the `_ref` kinds, nothing for `catch_all`, `exnref` for
    `catch_all_ref`) matches the target label's types, and records the clause
    with `PayloadAux` = the target label's `MergeRegs`.
  - `CheckTag` enforces `MSG_UNKNOWN_TAG` and **empty results** (`valid-tag`
    /`syntax-tagtype`: a tag's defined type expands to a function type; the
    corpus wants `"non-empty tag result type"` from module validation and
    `"unknown tag N"` from the body).
- **Runtime state (Track D).** `Wasm.Runtime.Store.TWasmTagInst { TypeId:
  TWasmEngineTypeId }` — engine-global id, so import matching and cross-module
  identity work; `AddTag`, `MatchTagImport` (subtyping on the tag's defined
  type). `Wasm.Runtime.Gc` reserves `wokExn` with a **fixed layout**
  (`[header:8][tagaddr:4][argc:4][args: TWasmValue…]`, offsets
  `WASM_EXN_TAG_OFFSET=8`, `WASM_EXN_ARGC_OFFSET=12`, `WASM_EXN_ARGS_OFFSET=16`),
  `AllocExn`, `ExnTagAddr`/`ExnArgCount`/`ExnArg`/`ExnSetArg`, and the
  collector traces `wokExn` args as roots. `Wasm.Core` has the `exn`/`noexn`
  heap types (`wahExn = -23`, `wahNoExn = -12`) and `exnref`/`nullexnref`
  spellings.

**What is absent is the dynamic half:** throwing, matching a handler, and
unwinding to it. Today `Wasm.Interp` maps both `iroThrow` and `iroThrowRef`
to `StageException`, which raises `EWasmError('exception handling is not
implemented')`; `Wasm.Wast.Runner` skips `assert_exception` with
`WAST_REASON_EXCEPTIONS` and stages any execution that trips that message
(`IsStagedMessage`). Retiring both is Track H.

---

## 1. The exception model — execution semantics

Anchors: `exec-throw` (`Step/throw`), `exec-throw_ref`
(`Step_read/throw_ref`, `Step_read/throw_ref-*` — two reduction cases),
`exec-try_table` (`Step_read/try_table`), `valid-throw`, `valid-throw_ref`,
`valid-try_table`, `syntax-taginst`, `syntax-reftype` (`exnref`). The
SpecTec prose for the `exec-*` clauses is empty at the pin; the semantics
below are reconstructed from the formal-rule names, the validation
signatures, and the corpus, and every claim is checkable against
`try_table.wast` / `throw.wast` / `throw_ref.wast` / `tag.wast`.

### 1.1 `try_table bt catch* instr*` (`exec-try_table`)

Enters a block of type `bt` with a **list of catch clauses installed over its
body**. A clause is one of:

| clause | matches | delivers to its label |
| --- | --- | --- |
| `catch x l` | thrown tag == tag `x` | the exception's payload values |
| `catch_ref x l` | thrown tag == tag `x` | payload values **+ the exnref** |
| `catch_all l` | any thrown tag | nothing |
| `catch_all_ref l` | any thrown tag | the exnref only |

While no exception is in flight the body runs as an ordinary block — this
already works; `try_table` acts as a regular block for `br` (`as-br-target`,
`as-value-provider` in `try_table.wast`). On a throw, the **innermost enclosing
`try_table` whose clause list contains a matching clause** transfers control
to that clause's label, pushing the delivered values as the label's arriving
operands (§1.4). Clauses are tested **in listed order**; the first matching
clause wins (`duplicated-catches`, `catch-all-before-catch`). A `try_table`
whose clause list contains no matching clause is transparent — the exception
propagates past it to an outer handler (`catchless-try`: an inner clauseless
`try_table` lets the throw reach the outer `catch $e0`).

`bt` may take params (`try-with-param`); those are ordinary block operands and
have nothing to do with catching.

### 1.2 `throw x` (`exec-throw`, `valid-throw`)

`x` is a tag index. Execution:

1. Resolve the tag **address** `a = frame.module.tagaddrs[x]`.
2. Pop the tag's param values `t_x*` off the stack (the validator guarantees
   they are present and correctly typed; `throw` is stack-polymorphic in its
   results, `valid-throw`).
3. Allocate an **exception instance** holding `(a, vals)` (§3) — a GC
   allocation, hence a safepoint.
4. Throw it: search outward for the innermost handler in the current
   activation whose clause matches tag address `a` (or is `catch_all*`); if
   found, transfer to it (§1.4). **If none exists in the current activation,
   the exception propagates to the caller**, frame by frame, and so on
   (§2). Reaching the top of the activation with no match is an *uncaught*
   exception (§2.4).

`throw` never traps (`can_trap:false`). Matching is by **tag address**, not
tag type: two imports of the same exported tag alias one address and catch
each other (`catch-imported`, `catch-imported-alias`, `imported-mismatch` in
`try_table.wast` — the imported tag's alias is caught by a `catch` naming the
other alias; a *different* module's structurally-identical tag is a different
address and is **not** caught, so `imported-mismatch` falls through to
`catch_all` and returns 3).

### 1.3 `throw_ref` (`exec-throw_ref`, `valid-throw_ref`)

Pops one `exnref` and **re-throws the existing exception object** it names.
The tag address is read from the object itself (not from an immediate), so the
same outward search as §1.2 step 4 runs. `throw_ref` is how a caught-and-bound
exception is re-raised (`catch_ref`/`catch_all_ref` bind the exnref; a later
`throw_ref` reactivates it — `throw_ref-nested`, `throw_ref-recatch`,
`catch-throw_ref-0/1`). Like `throw` it is stack-polymorphic in its results.

**Null.** `exnref` is nullable (`ref null exn`). The two-case formal structure
(`Step_read/throw_ref` + `Step_read/throw_ref-*`) is the null-vs-proper split:
a `throw_ref` of `ref.null exn` **traps**. Deliver it through the trap path
(§2.5) as `wtkNullReference` (message UNCONFIRMED — propose `'null reference'`;
reuse the existing null-reference trap kind, do not invent a new message).

> **UNCONFIRMED** — that `throw_ref null` traps, and the trap's message. The
> served `instruction_get throw_ref` reports `can_trap:false, traps:[]`, which
> is a known gap in the extractor for administrative instructions (the null
> case reduces to `trap` in the formal rules but is not tagged as a numbered
> trap). The corpus does **not** exercise `throw_ref null` (every `throw_ref`
> in `throw_ref.wast` is fed a non-null exnref from a `catch_ref`/local), so
> Track C cannot settle it. Implement the trap defensively and mark the site;
> if a future corpus proves it does not trap, the fix is one branch.

### 1.4 The payload push, exactly

When a clause matches, the delivered operands become the target label's
arriving operands — i.e. they are written into the **target label's merge
registers**, which the validator has already recorded as the clause's
`PayloadAux` block (§0, `ir-spec.md` §4.12). Per clause kind, with
`argc = tag.params` length and `dest = PayloadAux` registers (label arity
= `argc` for `catch`, `argc+1` for `catch_ref`, `0` for `catch_all`, `1` for
`catch_all_ref`):

- `wickCatch`: `dest[i] := exn.arg[i]` for `i in [0, argc)`.
- `wickCatchRef`: as `wickCatch`, then `dest[argc] := exnref(exn)`.
- `wickCatchAll`: nothing written.
- `wickCatchAllRef`: `dest[0] := exnref(exn)`.

Then resume dispatch at the clause's `TargetInstr`. No stub, no merge moves —
the merge registers ARE the destinations, which is the whole reason the
validator resolved clause payloads against label types (`HandleTryTable`
comment 2). The exnref written is the exception object's `TWasmRef` verbatim
(a `wokExn` pointer, low bits clear).

### 1.5 The `exn` heap type and `exnref`

`exn` is its **own** subtyping hierarchy, disjoint from func / aggregate /
extern (`syntax-reftype`; `Wasm.Runtime.Store` and `Wasm.Validator.Types`
already model four disjoint hierarchies with `exn` top and `noexn` bottom —
`wahExn`/`wahNoExn`, "EXN has no concrete subtypes"). The forms:

- `exnref` = `ref null exn`; `(ref exn)` non-null; `nullexnref` = `ref null
  noexn`; `(ref noexn)` uninhabited.
- `ref.null exn` produces the null exnref (encoding `0`, §1.3 runtime rep).

No new value representation is needed: an exnref is a `TWasmRef` like any other
reference — `0` = null, otherwise a pointer to a `wokExn` object. It is not an
unboxed i31 and never carries the i31 tag bit. The corpus stores exnrefs in
locals (`throw_ref-nested`) and block results (`catch_ref $e $h` with `(result
… exnref)`), and drops them (`catch_all_ref1`); it never marshals an exnref
across the host boundary as an `assert_return` expected value, so `Wast.Values`
needs **no** exn matcher (§7).

---

## 2. The unwind mechanism (ADR-0009 — the crux)

### 2.1 Why exceptions cannot reuse the trap path

A trap is **not resumable**: it unwinds the whole activation to the trampoline
(ADR-0009), which is why traps are delivered by `siglongjmp` / explicit
`TrapNow` and surface as one `EWasmTrap`. A wasm exception **is resumable**: a
handler catches it and execution continues at the handler's label with the
payload. Reusing the trap's `siglongjmp` would blow past every handler to the
host. ADR-0009 says so directly: "Wasm exceptions are resumable in a way traps
are not, so they need their own path through the same entry point — not a
reuse of this one." The corpus proves the split: `trap-in-callee` puts an
`i32.div_u` divide-by-zero **inside** a `try_table (catch_all $h)` and expects
`assert_trap "integer divide by zero"` — `catch_all` does **not** catch the
trap. Traps and exceptions must stay on separate routes, identically, in every
tier.

### 2.2 There is no runtime handler stack — it is (activation stack) × (static handler table)

The decisive consequence of the IR design (`ir-spec.md`): **`try_table` emits
no instruction and pushes nothing at run time.** Handlers are a *static*
per-function table (`TWasmIrFunction.Handlers`) indexed by instruction range.
So the "exception-handler stack the roadmap mentions" is not a separate mutable
stack the interpreter maintains alongside frames — it is *implicit* in the
cross product of:

- the **explicit activation stack** (`interp-spec.md` §1: `Ctx.Acts[0..Depth)`,
  no Pascal recursion), and
- each frame's **static `Handlers` table**, scanned by the frame's current
  instruction pointer.

Entering a `try_table` costs nothing; a throw *reconstructs* the enclosing
handlers by scanning tables. This is simpler and strictly cheaper than a
bytecode interpreter's push/pop handler frames, and it is why Track H adds no
per-instruction cost to the non-throwing path (which is ~all code).

The unwind is therefore **explicit interpreter control flow over `Ctx.Acts`,
not a Pascal `raise` and not a `siglongjmp`** — except for the single uncaught
case (§2.4), which leaves the interpreter and so must become a real exception.

### 2.3 The unwind algorithm (normative)

`throw` and `throw_ref` both funnel into one procedure. Preconditions: the
throwing frame's `IP` has been written back to `Act^.IP` (a throw is a control
transfer; store the top before unwinding, exactly as `iroCall` does), and
`exn` is a live `wokExn` ref (freshly allocated by `throw`, or the operand of
`throw_ref`).

```
procedure UnwindException(Ctx: PWasmInterpContext; Exn: TWasmRef);
var Top: PWasmActivation; ip, h, c: UInt32; TagAddr, ClauseTag: UInt32;
    matched: Boolean;
begin
  TagAddr := Store.Heap.ExnTagAddr(Exn);      { the thrown tag's ADDRESS }
  while True do
  begin
    Top := @Ctx^.Acts[Ctx^.Depth - 1];
    ip  := Top^.IP;   { throwing frame: the throw's own index; an unwound-
                        through caller: its saved resume IP = callsite+1 }

    { Scan the frame's static handler table IN ORDER. Because inner handlers
      are appended before outer ones, the first covering entry is the
      innermost; a non-matching covering entry does NOT stop the scan — keep
      going to the next-outer covering entry in the same frame. }
    for h := 0 to High(Top^.Fn^.Handlers) do
      if (ip >= Top^.Fn^.Handlers[h].StartInstr) and
         (ip <  Top^.Fn^.Handlers[h].EndInstr) then
        for c := 0 to Top^.Fn^.Handlers[h].ClauseCount - 1 do
        begin
          Clause := Top^.Fn^.HandlerClauses[Top^.Fn^.Handlers[h].ClauseStart + c];
          case Clause.Kind of
            wickCatch, wickCatchRef:
              begin
                ClauseTag := Top^.Instance.TagAddrs[Clause.TagIndex];
                matched := ClauseTag = TagAddr;      { ADDRESS identity }
              end;
            wickCatchAll, wickCatchAllRef:
              matched := True;
          end;
          if matched then
          begin
            ResumeAtClause(Ctx, Top, Clause, Exn);   { §2.3.1 }
            Exit;                                     { back to the dispatch loop }
          end;
        end;

    { No clause in this frame matched. Pop the frame and continue in the
      caller. Popping unregisters the GC frame and reclaims its registers. }
    if Top^.RetKind = rtEntry then
    begin
      { Uncaught in this invocation: pop the entry frame and leave the
        interpreter as a real Pascal exception (§2.4). }
      Store.Heap.PopFrame; Ctx^.ValueTop := Top^.Base; Dec(Ctx^.Depth);
      RaiseUncaught(Exn, TagAddr);                   { raises EWasmException }
    end;
    Store.Heap.PopFrame;
    Ctx^.ValueTop := Top^.Base;
    Dec(Ctx^.Depth);
  end;
end;
```

Notes tying this to shipped code:

- **`ip` for an unwound-through caller is the call site.** `iroCall` stores
  `Act^.IP := IP + 1` before descending (verified in `Wasm.Interp`), so a
  caller's saved IP is `callsite+1`. That still lies within the enclosing
  `try_table`'s `[StartInstr, EndInstr)`: the validator sets `EndInstr` at the
  try_table's `end` **after** its own merge moves (`HandleEnd` comment: "the
  protected range ends after the frame's own merge moves"), so both the call
  instruction and the instruction after it are inside the range. A `call`
  inside a `try_table` body is therefore correctly covered.
- **Innermost-first, matching-aware.** Multiple table entries can cover one
  `ip` (nested `try_table`s in one function). The scan must try each covering
  entry's clauses and only fall through to the caller when *no* covering entry
  in the frame matches — this is `catchless-try` (clauseless inner) and
  `catch-complex-1/2` (nested and multi-clause).
- **Address identity.** The clause's `TagIndex` is a *module* tag index;
  resolve it through the *unwinding frame's own* `Instance.TagAddrs`, because a
  handler in frame F names F's tags, and compare the resulting address with the
  thrown `TagAddr`. This is what makes `catch-imported-alias` catch and
  `imported-mismatch` not.

#### 2.3.1 `ResumeAtClause`

```
procedure ResumeAtClause(Ctx; Top: PWasmActivation;
  const Clause: TWasmIrCatchClause; Exn: TWasmRef);
var Dest: ^UInt32; argc, i: UInt32; Reg: PWasmValue;
begin
  Reg  := PWasmValue(Ctx^.Values) + Top^.Base;
  Dest := @Top^.Fn^.AuxU32[Clause.PayloadAux + 1];   { first merge reg }
  argc := Store.Heap.ExnArgCount(Exn);
  case Clause.Kind of
    wickCatch:
      for i := 0 to argc - 1 do Reg[Dest[i]] := Store.Heap.ExnArg(Exn, i);
    wickCatchRef:
      begin
        for i := 0 to argc - 1 do Reg[Dest[i]] := Store.Heap.ExnArg(Exn, i);
        Reg[Dest[argc]].Bits := 0; Reg[Dest[argc]].Ref := Exn;   { canonical ref write }
      end;
    wickCatchAll: ;                                  { nothing delivered }
    wickCatchAllRef:
      begin Reg[Dest[0]].Bits := 0; Reg[Dest[0]].Ref := Exn; end;
  end;
  { EPOCH obligation (ADR-0006; ir-spec TWasmIrHandlers comment). Resuming at
    TargetInstr bypasses the safepoint-flagged iroJump that every other path
    to a loop header runs, so poll here. }
  if Store.Epoch <> Ctx^.EpochCache then TrapNow(wtkEpochInterrupt);
  Top^.IP := Clause.TargetInstr;   { dispatch loop LoadTop's and continues }
end;
```

The ref writes go through the whole-slot `.Bits := 0; .Ref :=` canonical form
(`runtime-spec.md` §1.1) so the collector's root scan never reads a stale high
half. `argc` from `ExnArgCount(Exn)` equals the tag's param count and equals
the clause's non-`_ref` label arity by construction (validator-checked), so the
loop and the `PayloadAux` block agree.

### 2.4 The uncaught case — `EWasmException`, a distinct route through the trampoline

When the unwind pops the entry frame (`RetKind = rtEntry`) with no match, the
exception is uncaught in this invocation. It must leave the interpreter — but
**not** as an `EWasmTrap** and **not** by `siglongjmp`. It becomes a real Pascal
exception raised from `Run` (ordinary Pascal ground; `Run`'s locals are all
unmanaged pointers/scalars, so a normal `raise` unwinds cleanly and runs
`WasmInvoke`'s `finally`).

Add to the load-bearing hierarchy in `Wasm.Core` (beside `EWasmTrap =
class(EWasmError)`):

```pascal
{ An uncaught WebAssembly exception that reached the invocation boundary.
  A SIBLING of EWasmTrap, not a trap: the host distinguishes "the guest
  threw and nothing caught it" from "the guest trapped". Carries the raw
  exn handle so an embedder (Track F) can inspect tag + payload; the corpus
  only needs the class. Fields are raw scalars so Wasm.Core keeps its
  no-runtime-dependency rule (TWasmRef is NativeUInt; a tag address is u32). }
EWasmException = class(EWasmError)
public
  ExnRef: NativeUInt;   { the wokExn handle, as a raw NativeUInt }
  TagAddr: UInt32;
  constructor CreateExn(const AExn: NativeUInt; const ATag: UInt32);
end;
```

`RaiseUncaught` sets a fixed message (propose `'uncaught exception'`,
UNCONFIRMED — the corpus's `assert_exception` checks only *that* an exception
escaped, never a message) and raises `EWasmException`.

**Reconciliation with ADR-0009.** The trampoline (`WasmInvoke`) is untouched.
Its structure is `sigsetjmp; if 0 then <guest> else raise EWasmTrap`. A
normally-raised `EWasmException` propagates out of the `=0` branch like any
Pascal exception, through the `try/finally` that resets the frame chain
(`Heap.ResetFrames` — a belt; the unwind already popped every wasm GC frame),
to the host. So exceptions and traps enter the host through the *same* entry
point (`WasmInvoke`) by *different* mechanisms — the trap by `siglongjmp` +
re-raise, the exception by ordinary propagation — which is precisely ADR-0009's
"their own path through the same entry point."

**Nesting.** `RetKind = rtEntry` is the boundary of *this* invocation. In a
host→guest→host→guest chain, an inner uncaught exception pops only the inner
invocation's frames (down to its entry) and raises `EWasmException` to the
inner `WasmInvoke`, which propagates to the enclosing host frame — symmetric
with how an inner trap raises `EWasmTrap` to the inner trampoline. The corpus's
`$imported-throw` is a wasm function exported and imported, so it stays inside
one interpreter activation stack and never crosses a real Pascal host frame;
cross-host-frame propagation is a Track F concern, specified the same way as
trap propagation.

### 2.5 GC, epoch, and rooting obligations during the unwind

- **The unwind performs no allocation.** Popping frames, scanning tables,
  reading `ExnArg`, and writing merge registers never allocate, so **no
  safepoint occurs inside the unwind** and no collection can run mid-unwind.
  The thrown `Exn` therefore survives in a bare machine local safely.
- **`throw`'s allocate-then-copy is allocation-free after the allocation.**
  `iroThrow` (§6.1) calls `AllocExn` (the one safepoint — at that moment the
  tag args are still in the throwing frame's live, rooted registers), then
  copies args in and enters `UnwindException` with no intervening safepoint,
  so `Exn` is never exposed to a collection while unrooted.
- **Popped frames are unregistered.** Every popped activation calls
  `Store.Heap.PopFrame`, so the collector's frame chain never dangles a
  reclaimed register file. `ValueTop` is reset to the popped frame's `Base`
  so the value stack is consistent for the resuming (or next) invocation.
- **The exnref is rooted the instant a handler catches.** `ResumeAtClause`
  writes it into a ref-typed merge register (for `_ref` clauses) before normal
  dispatch — with its allocating instructions — resumes. For the uncaught
  case, `EWasmException.ExnRef` holds it and `assert_exception` observes it in
  the same `try/except`, before the next invoke's first allocation. (Once
  execution has left `Run`, the frame chain is empty, so a *subsequent* invoke
  could collect it — acceptable, because the exception has already been
  observed. Track F, if it hands exnrefs back to embedders across invokes, must
  register them as host roots; note it, do not build it here.)
- **Epoch on resume.** `ResumeAtClause` polls the epoch (§2.3.1) because a
  resume may land on a loop header, bypassing the back-edge safepoint.

---

## 3. Exception objects in the GC (`Wasm.Runtime.Gc`)

Already shipped in Track D; Track H is a **consumer**, and this section only
states the contract it relies on and the one obligation on `throw`.

Layout (fixed in Track D, `syntax-exninst`): `wokExn` cell =
`[header:8][tagaddr:u32 @8][argc:u32 @12][arg_0 @16][arg_1]…`, each arg a full
8-byte `TWasmValue`. The header's engine type id is the **tag's functype id**,
so `GcAbsKindOf` returns `wahExn` and `ref.test`/`ref.cast` against the exn
hierarchy behave. Accessors: `AllocExn(tagAddr, tagFuncTypeId, argc)`,
`ExnTagAddr`, `ExnArgCount`, `ExnArg(i)`, `ExnSetArg(i, v)`.

- **Allocation is a safepoint.** `AllocExn` goes through `Allocate` and may
  collect; `iroThrow` treats it as such (§2.5).
- **Tracing.** The collector already walks `wokExn` args as roots
  (`MarkRoot` over `[ARGS_OFFSET + i]`), so a ref-typed payload (e.g.
  `(param (ref $t))` in `try_table.wast`'s `catch`/`catch_ref1/2`) keeps its
  referent alive while the exception is in flight or bound to an exnref. Track
  H adds nothing here; verify it with a throw whose payload is a struct/func
  ref that outlives a collection.
- **No sixth object kind.** exnref reuses the universal `TWasmRef` pointer
  encoding; `wokExn` is the kind. The Track D header comment ("discovering in
  Track H that exnref needs a sixth kind would mean changing the header enum")
  is discharged: it does not.

`exn` subtype hierarchy (verify, do not extend): `exn` is top, `noexn` bottom,
disjoint from func/extern/aggregate; `ExnTagAddr` identity — not type — drives
matching. `Wasm.Validator.Types`' abstract-subtyping matrix already has the
`exn`/`noexn` rows.

---

## 4. Tags (store + validation)

Both halves are shipped; Track H **uses** them and adds nothing structural.

- **Instances.** `TWasmTagInst { TypeId: TWasmEngineTypeId }` — the engine
  id of the tag's functype (`syntax-taginst`: "records the defined type of the
  tag"). `Instantiate` links tags: imports resolve to the supplied address,
  defined tags call `AddTag(CanonIds[…])` (verified in
  `Wasm.Runtime.Instantiate` §tags).
- **Index space.** imports first, then defined — `Instance.TagAddrs[x]` maps a
  module tag index to a store tag address. `throw x` and a clause's `TagIndex`
  both resolve through it (§2.3, §6.1).
- **Identity is the address.** Matching compares `TagAddrs[x]` values, so an
  imported shared tag matches across the modules that import it, and a distinct
  module's identical-typed tag does not (`tag.wast` link-time typing;
  `try_table.wast` `imported-mismatch`). `MatchTagImport` (subtyping on the
  defined type) governs *linking*; *execution* matching is pure address
  equality.
- **`valid-tag`: empty results.** `CheckTag` enforces it in the body walk
  ("tag %u has %d result(s); an exception tag has none") and module validation
  owns the section-level `"non-empty tag result type"` (`tag.wast`
  `assert_invalid`). This guarantees `throw`'s stack effect: the tag's params
  are consumed, nothing is produced, and the instruction is stack-polymorphic.

---

## 5. IR + validation — confirmed present, nothing to add

Verified against the current tree; recorded so an implementer does not
re-derive it:

- `iroThrow` payload aux (`A`) = the tag's param registers in order; `Imm` =
  module tagidx. `iroThrowRef` `A` = the exnref source register.
- Per-function `Handlers` (range table, inner-before-outer) and
  `HandlerClauses` (kind, tag index, resolved `TargetInstr`, `PayloadAux` =
  target label's merge registers). Non-loop clause targets are patched at the
  target frame's `end` via `AddClausePatch`/`ResolveClausePatches`; loop
  targets resolve at push time to `LoopHeader`.
- Catch payload typing already checks arity and per-value matching against the
  target label types, so the interpreter delivers into `PayloadAux` blindly.

The only IR/validator "change" is **removing the staging** at the interpreter
(§6) — the emission side needs no edit. `IR_FORMAT_VERSION` is **unchanged**
(2): Track H emits no new op and no new record; the handler tables have been in
the format since Track B.

---

## 6. Interpreter execution — un-staging (`Wasm.Interp`)

Replace the single `iroThrow, iroThrowRef: StageException;` arm with two arms,
and add the `UnwindException` / `ResumeAtClause` helpers (§2.3). Delete
`StageException` and its message.

### 6.1 `iroThrow`

```
iroThrow:
begin
  Act^.IP := IP;                                      { publish the throw site }
  TagAddr := Act^.Instance.TagAddrs[UInt32(Ins^.Imm)];
  TagTypeId := Store.Tags[TagAddr].TypeId;
  ArgAux := Ins^.A;
  ArgN := IrAuxBlockCount(Fn^.AuxU32, ArgAux);
  Exn := Store.Heap.AllocExn(TagAddr, TagTypeId, ArgN);   { SAFEPOINT }
  for i := 0 to ArgN - 1 do
    Store.Heap.ExnSetArg(Exn, i,
      Reg[IrAuxBlockItem(Fn^.AuxU32, ArgAux, i)]);         { args still rooted }
  UnwindException(ACtx, Exn);   { never returns to here }
  LoadTop;                      { reached only if a handler in-frame resumed }
end;
```

`UnwindException` either resumes (sets some frame's `IP`, returns) or raises
`EWasmException`. On resume, `LoadTop` re-syncs `Act/Fn/Reg/IP/Code` because
the catching frame may be an ancestor. (Even when the catch is in the *same*
frame, `LoadTop` is correct and cheap.)

### 6.2 `iroThrowRef`

```
iroThrowRef:
begin
  Act^.IP := IP;
  Exn := Reg[Ins^.A].Ref;
  if RefIsNull(Exn) then TrapNow(wtkNullReference);   { §1.3 — UNCONFIRMED }
  UnwindException(ACtx, Exn);
  LoadTop;
end;
```

### 6.3 Observational identity and TRAP-1

- **The unwind is explicit interpreter control flow, not a Pascal `raise`** —
  for the *caught* case it never leaves `Run`. Only the *uncaught* case (§2.4)
  raises `EWasmException`, from ordinary ground, with proper stack unwinding.
  So TRAP-1 (no managed state on siglongjmp-skippable frames) is untouched:
  the unwind neither `siglongjmp`s nor allocates, and the one `raise` is a
  normal one.
- **Traps stay on the trap route.** `iroThrowRef null` and the resume epoch
  poll both use `TrapNow` (siglongjmp), so they surface as `EWasmTrap`,
  distinct from the `EWasmException` a wasm throw produces. `trap-in-callee`
  (a callee div-by-zero inside `catch_all`) therefore stays an `assert_trap`,
  never caught.
- **`return_call` erases the current frame's handlers.** Frame replacement
  (`DoReturnCall`) overwrites `Top^.Fn` (and thus its `Handlers`), so a throw
  in the tail-callee is not covered by the replaced frame's `try_table` —
  `return-call-in-try-catch` / `return-call-indirect-in-try-catch` are
  `assert_exception`. No new code: this falls out of the existing replacement,
  and the design records it so a future tier does not "helpfully" preserve the
  handler.

---

## 7. Harness (`Wasm.Wast.Runner`, `Wasm.Wast.Values`)

### 7.1 `assert_exception` judging (`Wasm.Wast.Runner`)

`assert_exception (invoke …)` asserts the action **throws an uncaught wasm
exception** (the corpus has 41 such commands; `throw.wast`, `throw_ref.wast`,
`try_table.wast` are the EH ones). Changes:

- Add `wakException` to `TWastActionKind`.
- In `RunInvoke`'s `try/except`, add `on E: EWasmException do Result.Kind :=
  wakException;` **before** the existing `on E: EWasmError` clause (Pascal
  matches in order; `EWasmException` is a more-derived `EWasmError`, so it must
  be listed first or the generic clause would swallow it as `wakError`). Keep
  `on E: EWasmTrap` first as today — a trap must never satisfy
  `assert_exception`, and an exception must never satisfy `assert_trap`.
- In `ExecuteCommand`, replace `wcAssertException: Skipped(…, 
  WAST_REASON_EXCEPTIONS)` with a real judge: run the action; **pass** iff
  `Act.Kind = wakException`; otherwise **fail** (a returned value, a trap, or a
  staged/error result all fail the assertion). Mirror `RunAssertTrap`'s shape.

### 7.2 Staging retires to zero

The interpreter no longer raises `'exception handling is not implemented'`, so
the staged path for EH goes dead naturally. Clean up: delete
`WAST_REASON_EXCEPTIONS`, delete the `'exception handling is not implemented'`
special-case in `IsStagedMessage` (and, if that leaves the function with no
remaining staged message, delete `IsStagedMessage`, the `wrsStaged` handling
threaded through `RunInvoke`/instantiate/malformed judging, and the `wakStaged`
action kind — confirm no other feature still stages before removing the plumbing;
per the roadmap SIMD already unstaged, so EH is the last one). The corpus's
`staged` column (38) becomes **0**.

### 7.3 `Wast.Values` — no change

The corpus never presents an exnref as an `assert_return` expected value or as
an `invoke` argument: every exnref is produced by a `catch_ref`/`catch_all_ref`
and is then dropped, stored in a local, or re-thrown. `ref.func` / `ref.null`
results (`try_table.wast`'s `catch`/`catch_ref1/2` returning `(ref null $t)`)
are the existing reference matchers (`wvcRefFunc`, `wvcRefNull`). So
`Wasm.Wast.Values` needs **no** new matcher and no `(ref.exn)` form. State this
explicitly so an implementer does not build a dead code path; revisit only if a
future corpus adds an exnref-valued `assert_return`.

---

## 8. Unit layout and wave plan

Track H is small and concentrated (one execution feature, static half done), so
parallelism is limited; the partition below keeps file ownership disjoint where
it can. Gates each wave: `lwpt format --check`, `lwpt build`, `lwpt test`.

| unit | change |
| --- | --- |
| `Wasm.Ir` | **none** (handler tables, `iroThrow`/`iroThrowRef`, `IR_FORMAT_VERSION=2` already present) |
| `Wasm.Validator.Body` / `.Types` | **none** (throw/throw_ref/try_table/tag validation + emission already correct) |
| `Wasm.Core` | add `EWasmException = class(EWasmError)` with `ExnRef`/`TagAddr` |
| `Wasm.Runtime.Store` | **verify** tag address resolution + `Store.Tags[a].TypeId`; expose nothing new unless a helper for tag param count is wanted |
| `Wasm.Runtime.Gc` | **verify** `AllocExn` + accessors + `wokExn` arg tracing; no structural change |
| `Wasm.Interp` | un-stage `iroThrow`/`iroThrowRef`; add `UnwindException` + `ResumeAtClause`; epoch-on-resume; raise `EWasmException` on uncaught; delete `StageException` |
| `Wasm.Runtime.Traps` | **none** to the trampoline; `EWasmException` flows through `WasmInvoke` unchanged (document why) |
| `Wasm.Wast.Runner` | `wakException`; catch `EWasmException`; judge `assert_exception`; retire EH staging |
| `Wasm.Wast.Values` | **none** (§7.3) |

**Waves.**

- **H1 — the class + verification (foundation).** `Wasm.Core` `EWasmException`.
  Confirm (with targeted `Wasm.Runtime.*.Test` cases if missing) tag-address
  resolution, `AllocExn`/accessors, and `wokExn` arg tracing. Unblocks H2/H3.
  Files: `Wasm.Core`, and read-only verification of `Store`/`Gc`.
- **H2 — interpreter throw + unwind (the crux).** `Wasm.Interp` exclusively:
  `iroThrow`/`iroThrowRef`, `UnwindException`, `ResumeAtClause`, epoch-on-
  resume, uncaught `EWasmException`; delete `StageException`. Co-located
  `Wasm.Interp.Test` cases driving each clause kind, nesting, `catchless`,
  `return_call` erasure, and `throw_ref null`. Depends on H1.
- **H3 — harness judging.** `Wasm.Wast.Runner` (+ `.Test`): `wakException`,
  the `EWasmException` catch, the `assert_exception` judge, staging retirement.
  Depends on H2 (needs a real `EWasmException` to observe). Can be scaffolded
  in parallel with H2 once H1 fixes the `EWasmException` signature.

**What each unlocks in corpus terms.** After H2+H3, run `wasmspec` over
`WebAssembly/testsuite@de54fd27`:

- `try_table.wast`, `throw.wast`, `throw_ref.wast` execute end to end — the
  `assert_exception` cases (`throw.wast` ×5, `throw_ref.wast` ×6,
  `try_table.wast` ×4: `catch-complex-1/2 (i32.const 2)`,
  `return-call*-in-try-catch`) **pass** rather than skip, and their
  `assert_return` cases (`simple-throw-catch`, the `throw-catch-param-*`
  family, `catch-imported*`, `catch/catch_ref1/2/catch_all_ref1/2`, etc.)
  **pass**.
- `tag.wast` was already passing its validity/link cases; nothing regresses.
- **`staged` falls 38 → 0.** The ~38 staged residue is exactly the EH
  executions the interpreter used to stub.
- The **legacy** EH fails (`testsuite/legacy/`) remain failing/skipped — out of
  scope, correct (§9).

---

## 9. Observational identity and the scope fence

**Track I/J must match, bit for bit:**

- **The unwind semantics** — which handler catches (innermost-first, listed-
  clause order, address matching), and where control resumes (the label's
  merge registers, the exact payload). A baseline JIT / AOT tier reconstructs
  the same static handler tables (they are in the IR) and must implement the
  same outward search; a divergence in *which* clause fires is a bug, not a
  tier characteristic (ADR-0001, `interp-spec.md` §8).
- **Tag-address matching**, not tag-type matching — the same
  `TagAddrs`-identity rule in every tier.
- **`throw` allocates an exn object at a safepoint** — the allocation is
  observable through GC/OOM timing, so every tier allocates at the same point,
  with the same layout, and keeps ref-typed payload args traced.
- **Traps and exceptions on separate routes** — `catch_all` never catches a
  trap; `throw_ref null` traps; the epoch poll on resume fires an interrupt
  trap, not an exception. Every tier keeps the two delivery mechanisms
  distinct and identical.
- **`return_call` erases the frame's handlers** — the tail-call frame
  replacement drops the enclosing `try_table`'s handlers in every tier.

**Scope fence (restated).** The **legacy** exception-handling encoding — `try`
/ `catch` / `catch_all` (the block form) / `delegate` / `rethrow` — is **not**
in the 3.0 target. It lives in `tests/spec/testsuite/legacy/` (`try_catch.wast`,
`try_delegate.wast`, `rethrow.wast`, legacy `throw.wast`) and remains failing or
skipped after Track H; that is the roadmap's intended state, not a Track H gap.
Track H implements only the 3.0 `try_table` / `throw` / `throw_ref` /
`exnref` / tag surface. Do not add legacy opcodes to the IR, the validator, or
the interpreter to "finish" those files.
