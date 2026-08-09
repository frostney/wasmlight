# The `wat` text-format assembler — design contract

Status: design, not yet implemented. Track C (docs/roadmap.md).
Spec citations are against `wasm-mcp` pinned `spec/main`
`d7b37e4170d8315f2f1283aed4e8076591a9a333`; corpus tallies against
`WebAssembly/testsuite@de54fd27ecf3e68dfd16b6199c548df77b6a2cc1`
(288 scripts, the checkout under `tests/spec/testsuite/`).

This file is persisted in-repo deliberately: the implementation spans
sessions and the decisions below are the thing that must survive a
context reset. It is **not to be committed** — it is working state, like
`.agent/HANDOFF.md` is working state, and unlike `.agent/HANDOFF.md` it
has no audience outside the implementing agent.

## Executive summary

The harness can judge 1,034 of 67,125 corpus commands today. Everything
else is skipped, and **the single largest reason is that we cannot read
the text format**: 2,376 top-level modules, 2,995 `assert_invalid`
assertions, and 1,278 `assert_malformed` assertions carry a `(module ...)`
or `(module quote ...)` operand and are skipped with
`text format not yet assembled`. That is **≈6,649 commands**, and every
one of them is judgeable against layers that are already shipped — no
execution tier required.

The assembler produces **binary bytes** and hands them to the existing
`DecodeModule` → `ValidateModule` pipeline. It does not produce the module
model and it does not produce IR. Text-level malformedness is raised by
the assembler with upstream's canonical text prefixes; binary-level
malformedness cannot arise from a correct assembler, and if it does, that
is our bug and the harness must report it as one.

---

## 1. Architecture decision — assemble to binary bytes

### The decision

```text
.wat / (module quote …) source bytes
        │
        ▼
  Wasm.Wat.Assembler  ──raises──▶  EWasmTextError   ("unknown operator", …)
        │
        ▼
   binary module bytes  (TWasmBytes)
        │
        ▼
  DecodeModule  ──raises──▶ EWasmDecodeError   ← MUST NOT happen on our own output
        │
        ▼
  ValidateModule ──raises──▶ EWasmValidationError
        │
        ▼
      TWasmIrModule
```

Text is lowered to the binary encoding and re-enters the shipped pipeline
at its normal front door. No new entry point into validation is created.

### Why, in three arguments

**1. ADR-0007 says validation happens once, and the validator reads the
raw binary.** This is not a stylistic preference here — it is a
mechanical constraint. `ValidateModule(AModule, ABytes)` takes the byte
buffer, and `Wasm.Validator.Body` performs a *fused* decode/type-check/
emit walk over the raw code-section bytes. There is no code path that
type-checks a function body from anything other than bytes. An assembler
that produced `TWasmModule` directly would have to either (a) re-encode
bodies to bytes anyway — the same work, done less honestly — or (b) grow
a second body walk, which is precisely the "no tier may re-derive a spec
rule" failure that ADR-0007 exists to prevent. Text→bytes is therefore
not one option among several; it is the only shape consistent with what
is already built.

**2. The binary encoder is mechanical and differentially testable.**
`Wasm.Decoder.Types`, `.Entities`, `.Segments`, `.Expr` already enumerate
every shape of every one of the 13 sections. The encoder is that
decoder's mirror image, and the mirror gives a free oracle: assemble →
`DecodeModule` → compare against the expected model, and round-trip the
22 committed fixtures in `tests/fixtures/`. Nothing about the encoder
requires judgement calls; it requires a LEB128 writer and section framing
that we can test without the grammar being finished (see wave 3).

**3. `assert_malformed` over text expects a TEXT-level error, so
malformedness splits — cleanly, and in our favour.** The corpus asserts
2,208 `assert_malformed` commands. 930 carry `(module binary …)` and are
already judged against `Wasm.Binary`/`Wasm.Decoder`. The other 1,278
carry `(module quote …)`, and every expected string in that set is a
*text-format* diagnostic: `unknown operator`, `unexpected token`,
`mismatching label`, `duplicate func`, `constant out of range`. Not one
of them is a binary-grammar diagnostic. The two error surfaces do not
overlap.

### The consequence, stated plainly

**Our assembler must be a faithful grammar implementation, not a
permissive one.** This is the inversion that makes the assembler harder
than it looks. A decoder is judged mostly on what it accepts; a
permissive decoder only embarrasses itself on adversarial input. An
assembler in this harness is judged on 1,278 commands that are *nothing
but* adversarial input. Every convenience — accepting `(result i32)`
before `(param i32)`, tolerating an unknown mnemonic, letting `align=7`
through, silently ignoring a trailing `$l` on an `end` — converts a
would-be pass into a failure. The permissive assembler and the faithful
one differ by roughly 1,278 commands, which is more than the harness
judges in total today.

Two invariants follow, and both are testable:

- **INV-1 — a text error never reaches the decoder.** If the assembler
  returns bytes, those bytes decode. If `DecodeModule` raises on
  assembler output, the assembler mis-assembled; that is an internal
  defect, not a conformance verdict, and the runner must report it as
  `internal` rather than quietly scoring it as `malformed`. This
  invariant is what makes the error split load-bearing instead of
  decorative.
- **INV-2 — the assembler never rejects a module the reference parser
  accepts.** Unmeasurable directly, but its proxy is the corpus: the
  2,376 top-level text modules and the 262 `assert_unlinkable` modules
  are all well-formed by construction, so any assembler failure on them
  is a false rejection. Wave 6 turns that proxy into a gate.

### The error class

`Wasm.Core` grows one class:

```pascal
EWasmTextError = class(EWasmError);
```

A sibling of `EWasmDecodeError`, not a subclass. AGENTS.md is explicit
that the hierarchy is load-bearing and that `EWasmDecodeError` means
"these binary bytes are not a module". Text-format syntax is a different
claim about a different artefact. The harness maps both to
`assert_malformed` because *the script's* verb is `assert_malformed`, but
the harness is where that collapsing belongs — the library must keep them
apart so INV-1 can be checked at all.

---

## 2. Pipeline stages

### (a) Front end: lex fresh, do not reuse the script tree

**Decision: `Wasm.Wat.Lexer` is a new, strict tokenizer, and the
assembler parses a token stream directly rather than building an
s-expression tree.** `Wasm.Wast` keeps its job unchanged: it parses the
*script*.

`Wasm.Wast`'s lexer is deliberately lossy in five ways, each of which is
fatal for the module grammar:

- **Annotations are skipped as trivia and never reach the tree.**
  `SkipAnnotation` exists so `annotations.wast` parses at all. But the
  corpus asserts, under the *reference-grammar* `assert_malformed`
  directive (not the `_custom` one the runner already skips), that
  malformed annotations are malformed modules: `empty annotation id` (7),
  `unclosed annotation` (4), `illegal character` (32). The assembler must
  scan annotations with full validation and then discard them.
  `annotations.wast:72-84` is the whole specification of that behaviour.
- **Atoms are undifferentiated text.** The `unknown operator` bucket —
  **555 commands, the single largest error class in the corpus** — is not
  an "unknown mnemonic" rule. It is the spec's *reserved token* rule
  (`text-reserved`): "Any token that does not fall into any of the other
  categories is considered reserved, and cannot occur in source text
  … `0$x` is a single reserved token". That is why `const.wast:12`
  spells `(i32.const 0x)` and expects `unknown operator` rather than
  `constant out of range`. Implementing it requires the lexer to classify
  tokens into keyword / id / number / string / reserved, which
  `TWastToken.wtkAtom` cannot express.
- **Any byte ≥ 0x20 is accepted inside an atom.** The text format
  requires source characters to be valid UTF-8 and identifier characters
  to come from a restricted set. `annotations.wast:67` spells
  `(@a Heiße Würstchen)` and expects `illegal character` (valid UTF-8,
  not an idchar); `annotations.wast:57` spells `(@a \80)` and expects
  `malformed UTF-8 encoding` (not valid UTF-8 at all). The lexer must
  decode UTF-8 and then check the codepoint.
- **`$"quoted id"` is not handled.** `text-id` admits an identifier of
  the form `$` followed by a quoted name. `LexAtom` breaks at `"`, so
  `token.wast:109`'s `$"l"0` would lex as three tokens instead of one
  reserved token, and the expected `unknown operator` becomes
  unreachable.
- **Its messages are script-input prose.** `EWastParseError` messages
  read `unterminated string literal opened at (line 3, column 12)`. The
  assembler's messages must *begin* with upstream's canonical string
  because the match is a prefix match. Re-tuning `Wasm.Wast`'s messages
  would perturb the currently-passing 1,034 commands for no gain.

The counter-argument worth acknowledging: the string-literal decoder
(escapes, `\hh`, `\u{…}`) gets written twice. That is accepted. The two
lexers lex different languages — one is a command soup that can afford to
treat annotations as whitespace, the other is the module grammar and must
be exact. A later consolidation (make `Wasm.Wast` delegate to
`Wasm.Wat.Lexer` for strings) is left as an open door, explicitly not
taken in this track, because it would move error messages that are
currently green.

**No generic tree.** The assembler is a recursive-descent parser over the
token stream with one-token lookahead plus a `PeekListHead(keyword)`
helper. Three reasons: `unexpected token` (175 commands) must fire at the
exact token where the grammar diverges, and a tree defers that decision
past the divergence point; folded and flat instruction forms interleave
freely inside one instruction sequence, so a tree buys no structure the
parser does not immediately have to undo; and a `TWastNode` per token
over 192,500 lines is allocation the harness does not need.

#### Entry points

```pascal
{ Primary. ASource is the module's source BYTES. }
function AssembleWat(const ASource: TWasmBytes): TWasmBytes;

{ Convenience for .wat files and unit tests. }
function AssembleWatText(const ASource: string): TWasmBytes;
```

Bytes are primary, not a convenience: UTF-8 validity of the source is a
*rule the assembler enforces* (`annotations.wast:57-66`,
`utf8-invalid-encoding.wast`, 186 commands), so the assembler must be
handed bytes and must not be given a string that some earlier layer
already assumed was decodable.

#### Feeding the two module forms

`(module quote "…" "…")` is easy and already right: the payload is the
concatenation of the form's string literals with escapes decoded, which
is exactly what `Wasm.Wast.Runner.ModuleBinaryBytes` already computes. It
gathers `wnkString` children by node kind rather than position, so it
works unchanged for the quote form. Rename it `ModuleLiteralBytes` and
use it for both.

`(module … fields …)` (2,367 top-level occurrences, plus 2,989
`assert_invalid` operands) is the trap. Its tree is *already parsed* by
`Wasm.Wast`, with annotations dropped and atoms undifferentiated — every
lossy property listed above. Two options:

1. Assemble from the `TWastNode` tree. Rejected: it gives the assembler
   two front ends with different fidelity, and permanently forfeits the
   annotation, reserved-token, and `$"id"` cases.
2. **Re-lex from the original source span. Chosen.** `Wasm.Wast` records
   the byte offsets of each command's opening and closing parenthesis;
   `TWastScript` retains the source it was parsed from. The runner then
   calls `AssembleWat(SourceSpan(cmd))`.

Option 2 is a small, surgical change (two integers on `TWastNode` or
`TWastCommand`, one retained string on `TWastScript` — FPC strings are
refcounted, so retention is free), and it collapses the text path and the
quote path into **one** path: both hand a byte range to `AssembleWat`.
It also preserves laziness by construction — a span is two integers, and
nothing is assembled until the command executes.

### (b) Identifier and symbol resolution

`text-idx` names twelve index spaces. All twelve are in scope:

| Space | Bound by | Scope | Forward refs |
| --- | --- | --- | --- |
| type | `(type $x …)`, `(rec (type $x …))` | module | yes |
| func | `(func $x …)`, `(import … (func $x …))` | module | yes |
| table | `(table $x …)` | module | yes |
| mem | `(memory $x …)` | module | yes |
| global | `(global $x …)` | module | yes |
| tag | `(tag $x …)` | module | yes |
| elem | `(elem $x …)` | module | yes |
| data | `(data $x …)` | module | yes |
| local | `(param $x …)`, `(local $x …)` | function | no |
| label | `block $l`, `loop $l`, `if $l`, `try_table $l` | instruction | no |
| field | `(field $x …)` inside a struct type | per type index | yes |

**Two passes over the module fields.** Pass 1 ("declare") walks the
top-level fields in order, binds every identifier into its space, and
computes each entity's final index. Pass 2 ("emit") re-walks and
assembles bodies, at which point every module-level identifier is
resolvable. This is what makes forward references work, and the corpus
requires them:

```wat
;; struct.wast:24-31 — $forward is used before it is defined
(module
  (rec
    (type $s0 (struct (field (ref 0) (ref 1) (ref $s0) (ref $s1))))
    (type $s1 (struct (field (ref 0) (ref 1) (ref $s0) (ref $s1))))
  )
  (func (param (ref $forward)))
  (type $forward (struct))
)
```

That example also pins a second rule: inside a `(rec …)` group, numeric
type references are **absolute module type indices**, not group-relative
— `(ref 0)` and `(ref $s0)` denote the same type in the same field list.

Rules that fall out of the corpus and must be implemented explicitly:

- **Locals and params share one namespace.** `func.wast:982` —
  `(func (param $foo i32) (local $foo i32))` is `duplicate local`. So is
  param/param (`:978`) and local/local (`:986`).
- **Labels are a stack with shadowing, innermost-first.** `text-label`:
  "The new label entry is inserted at the beginning of the label list …
  If a label with the same name already exists, then it is shadowed and
  the earlier label becomes inaccessible." `labels.wast:281-288` exercises
  three nested `$l1` bindings and requires `br $l1` to reach the
  innermost.
- **Symbolic and numeric label failures land in different stages.** An
  unresolved *symbolic* label is a text error — `token.wast:103`,
  `(br_table $l0)` where only `$l` is bound, expects `assert_malformed`
  `unknown label`. An out-of-range *numeric* label is a validation error
  — `br.wast:647`, `(br 1)`, expects `assert_invalid` `unknown label`.
  Same string, different class. The assembler must not range-check
  numeric labels; the validator already does, correctly.
- **`unknown type` splits the same way.** `(func (type 42))` alone is
  `assert_invalid` (`func_ptrs.wast:48`). `(func (type 2) (param i32))`
  is `assert_malformed` `unknown type` (`func.wast:454`), because the
  assembler must *read* the referenced type to check the inline
  declarations against it, and cannot.
- **Field names are per-type namespaces, resolved after the type operand.**
  `struct.wast:82-106` requires all four combinations —
  `struct.get 0 0`, `struct.get $vec 0`, `struct.get 0 $y`,
  `struct.get $vec $y`. So `struct.get 0 $y` must resolve `$y` against the
  field table of *type index 0*: field-name tables are keyed by resolved
  type index, and the lookup is sequenced after the first operand.
- **Duplicate ids in a space are text errors**, spelled
  `duplicate <space>`: `duplicate func` (3), `duplicate local` (3),
  `duplicate global` (3), `duplicate table` (3), `duplicate memory` (6),
  `duplicate field` (1). The corpus has no `duplicate type` / `elem` /
  `data` / `tag` case; implement them uniformly anyway.
- **Duplicate *export names* stay in the validator.**
  `MSG_DUPLICATE_EXPORT_NAME` already exists in `Wasm.Validator.Types` and
  the corpus asserts it via `assert_invalid`. Do not move it.
- **Import ordering is a text rule.** `imports.wast:674-741`, 32 commands:
  an explicit `(import …)` field after a *definition* of a func, global,
  table, or memory is malformed, and the message names the kind of the
  preceding **definition**, not of the import — `(func) (import "" "" (memory 0))`
  is `import after function`. Implementation: track a "first defined
  kind" per module; on an explicit `(import …)` field, if any of the four
  spaces holds a non-imported definition, raise `import after <kind>` for
  the earliest such kind in field order. **Open item:** whether the
  *inline* import abbreviation (`(func (import "m" "n") …)`) after a
  definition is likewise malformed is not tested by the corpus. Take the
  narrow reading — apply the check to the explicit field only — and let
  the wave 6 run settle it, in the same spirit as Track B's `UNCONFIRMED`
  markers.

### (c) The abbreviation and sugar catalog

This is the big surface. `text-abbreviations` fixes the expansion
discipline for all of it: "These expansions are assumed to be applied,
**recursively and in order of appearance**, before applying the core
grammar rules." Order of appearance is not decoration — it is what makes
the implicit-typeuse table deterministic.

#### c.1 Type uses and implicit type insertion — `text-typeuse`, `text-typeuse-abbrev`

The highest-risk abbreviation in the whole format, because it silently
determines type indices that other parts of the module name numerically.

The rule, quoted from `text-typeuse-abbrev`:

> a type index is automatically inserted … where `x` is the **smallest
> existing type index** whose recursive type definition parses into a
> **singular, final** function type with the same parameters and results.
> If no such index exists, then a new recursive type of the same form is
> inserted **at the end of the module**. Abbreviations are expanded in the
> order they appear, such that previously inserted type definitions are
> reused by consecutive expansions.

Four separate obligations hide in that paragraph:

1. **Explicit types keep their textual slots; implicit types append after
   all of them.** `func.wast:422-433` is the test and it is brutal:

   ```wat
   (module
     (func $f (result f64) (f64.const 0))  ;; adds implicit type definition
     (func $g (param i32))                 ;; reuses explicit type definition
     (type $t (func (param i32)))
     (func $i32->void (type 0))                ;; (param i32)
     (func $void->f64 (type 1) (f64.const 0))  ;; (result f64)
   )
   ```

   `$t` is declared *third* and is type index **0**; the implicit
   `(result f64)` from `$f` is index **1**. An assembler that appended
   implicit types in textual encounter order swaps them and the module
   fails to validate. `func.wast:442` confirms the count: `(func (type 2))`
   is `unknown type` — there are exactly two types.

2. **Reuse means "smallest matching index", not "most recent".** So the
   search is a linear scan from index 0 over the *already-known* type
   space, which at expansion time means all explicit types plus every
   implicit type inserted so far.

3. **"Singular, final" is a GC-era side condition with teeth.**
   `type-rec.wast:45-61`:

   ```wat
   (rec (type $ft (func)))
   (func $f)                              ;; implicit type of $f IS $ft
   ;; but:
   (rec (type $ft (func)) (type (func)))
   (func $f)                              ;; implicit type of $f is NOT $ft → "type mismatch"
   ```

   A candidate is only reusable if its rec group has exactly one member
   *and* the subtype is final with no declared supertypes. A bare
   `(type $x (func …))` desugars to exactly that; anything inside a
   multi-member `(rec …)` or carrying `(sub …)` does not qualify.

4. **Explicit types are never deduplicated against each other.**
   `func_ptrs.wast:2-4` declares three distinct void→void types at indices
   0, 1, 2 and references index 6 later. Dedup applies only to *implicit*
   insertion.

Matching-versus-declaration (`text-typeuse`): when a typeuse gives both
`(type $x)` and inline `(param …)`/`(result …)`, the inline declarations
exist to *name locals* and must be **syntactically equal** to the
referenced type — the spec says so explicitly: "possible type
substitutions from other definitions that might make them equal are not
taken into account. This is to simplify syntactic pre-processing." A
mismatch is `inline function type` (24 commands; `func.wast:601-606`,
`call_indirect.wast:757`). A *match* is legal and used for naming
(`func_ptrs.wast:20`).

Clause order inside a typeuse is fixed: `(type …)` then `(param …)*` then
`(result …)*`. Any other order is `unexpected token` — `type.wast:43`
(`(func (result i32) (param i32))`), `block.wast:421-455` (five
permutations), `if.wast:735-778` (five more).

#### c.2 Inline import and export — `text-func-abbrev`, `text-table-abbrev`, `text-mem-abbrev`, `text-global-abbrev`, `text-tag-abbrev`

`text-func-abbrev`: "Functions can be defined as imports or exports
inline … The latter abbreviation can be applied repeatedly … Consequently,
a function declaration can contain any number of exports, possibly
followed by an import."

| Form | Expands to | Corpus |
| --- | --- | --- |
| `(func $f (export "x") …)` | `(func $f …)` + `(export "x" (func $f))` | `array.wast:67` |
| `(func (import "m" "n") (param i64))` | `(import "m" "n" (func (param i64)))` | `imports.wast:42` |
| `(func $p (import "m" "n") (type 6))` | ditto, id preserved | `func_ptrs.wast:10` |
| `(memory (export "a") 0)` | `(memory …)` + `(export …)` | `exports.wast:195` |
| `(table (export "a") 0 funcref)` | ditto | `exports.wast:139` |
| `(global $a (export "a") i32 (i32.const 0))` | ditto | `exports.wast:84` |
| `(global (import "m" "n") i32)` | `(import … (global i32))` | `data.wast:68` |
| `(memory (import "m" "n") 1 2)` | `(import … (memory 1 2))` | `imports.wast:508` |
| `(tag (export "t2") (param i32))` | `(tag …)` + `(export "t2" (tag …))` | `tag.wast:6` |
| `(tag $t (import "m" "n") (param i32))` | `(import … (tag …))` | `tag.wast:14` |

Note the ordering interaction: exports may repeat and precede an import
on the same declaration, and the import expansion places the entity in
the *import* index range — which is what makes the "import after
function" rule (c.2 above, §b) a rule about desugared index spaces even
though the corpus only tests the explicit-field spelling.

#### c.3 Folded instructions — `text-foldedinstr`

`text-foldedinstr`: "an instruction is wrapped in parentheses and
optionally includes nested folded instructions to indicate its operands …
In the case of block instructions, the folded form omits the `end`
delimiter. For IF instructions, both branches have to be wrapped into
nested S-expressions, headed by the keywords `then` and `else`." And:
"Folded instructions are solely syntactic sugar, no additional syntactic
or type-based checking is implied" — the unfold is purely positional and
must not consult types.

The unfold rules, recursively:

```text
( plaininstr  folded* )        →  unfold(folded)…  plaininstr
( block  label? blocktype instr* )
                               →  block label? blocktype  instr*  end
( loop   label? blocktype instr* )
                               →  loop  label? blocktype  instr*  end
( if     label? blocktype folded* (then instr₁*) (else instr₂*)? )
                               →  unfold(folded)…
                                  if label? blocktype
                                    instr₁*
                                  else
                                    instr₂*
                                  end
( try_table label? blocktype catch* instr* )
                               →  try_table label? blocktype catch*  instr*  end
```

The `if` arm ordering is where implementations break: the *condition*
operands come out **before** the `if` opcode, the `then` body **after**
it. `if.wast:10-29` is the full matrix — label present/absent, blocktype
present/absent, `else` present/absent, empty `then`. The `else` arm may
be omitted entirely; an empty `(then)` is legal and still emits `if … end`.

The corpus contains **no** folded `if` without a `(then …)` — an
exhaustive scan of all 265 root scripts plus `legacy/` found only prose
comments. And the *unfolded* condition inside a folded `if` is explicitly
malformed: `if.wast:1562`, `(func (if i32.const 0 (then) (else)))` →
`unexpected token`.

#### c.4 Multi-value and clause merging

`(param i32 i64)` is `(param i32) (param i64)`. `(param)` and `(result)`
with no types are legal and contribute nothing. Repeated and empty groups
concatenate in order: `type.wast:29-31` spells
`(func (param) (param $x f32) (param) (param) (param f64 i32) (param))`,
and `call_indirect.wast:69` spells
`(call_indirect (param i64) (param) (param f64 i32 i64) …)`. Only a group
with **exactly one** type may carry an identifier — `(param $x i32)` is
fine, `(param $x i32 i64)` is not. Anonymous locals merge the same way
(`text-func-abbrev`, "Multiple anonymous locals may be combined into a
single declaration").

#### c.5 Element and data segment sugar — `text-elem`, `text-datastring`

`elem.wast:1-79` is a deliberate enumeration of every legal spelling; it
is the acceptance test for this sub-area.

- **Table-use omission.** `text-elem`: "Element segments allow for an
  optional table index." `(elem (offset …) …)` and `(elem (i32.const 0) …)`
  both mean table 0. `(elem (table $t) …)` and `(elem (table 0) …)` name
  it.
- **Offset abbreviation.** `(offset (i32.const 0))` may be written as the
  bare folded instruction `(i32.const 0)`.
- **Element-list forms.** `func $f $g` (funcidx list, elemkind 0),
  `funcref (ref.func $f) (ref.null func)` (expression list), `(item …)`
  wrapping an expression, and the bare `$f $f` list with the `func`
  keyword itself elided (`elem.wast:39`).
- **Passive / declarative / active** are distinguished by the absence of
  an offset, the `declare` keyword, and the presence of an offset
  respectively. Each has an optional `$id`.
- **Inline segment in a table declaration.**
  `(table $t funcref (elem $f $g))` (`call_indirect.wast:626`) expands to a
  table with `min = max = 2` **and** an active elem segment at offset
  `(i32.const 0)`. `(table funcref (elem (ref.func $f) …))`
  (`elem.wast:84`) is the expression-list variant.
- **Inline data in a memory declaration.** `(memory (data "\aa\bb\cc\dd"))`
  (`bulk.wast:58`) expands to a memory whose `min = max = ceil(len/65536)`
  plus an active data segment at offset `(i32.const 0)`.
- **Memory-use omission** in `(data …)` mirrors table-use omission, and
  `text-datastring` notes the payload "may be split up into a possibly
  empty sequence of individual string literals".

#### c.6 Memory arguments

`memarg` is `offset=<u64>? align=<u32>?`, in that order, both optional,
and — for multi-memory — preceded by an optional memory index:
`(i32.load8_u $mem1 offset=4294967295 …)` (`address0.wast:89`).

| Property | Rule | Evidence |
| --- | --- | --- |
| default `offset` | 0 | — |
| default `align` | natural alignment of the instruction | — |
| encoding | `align` is written as **log₂**; `offset` follows | — |
| memory index | flag bit 6 of the align field, then the memidx | `align.wast:966-983` (`malformed memop flags`) |
| `offset` width | full `u64`, hex and underscores permitted | `align64.wast:873`: `offset=0xFFFF_FFFF_FFFF_FFFF` |
| `align=0` / `align=7` | text error: `alignment` | `align.wast:26-37` |
| `align=-1` | text error: `unknown operator` (not a `u32` token) | `simd_align.wast:110` |
| `align` > natural | **validation** error, already shipped | `align.wast:305` |
| `offset` > 2³²−1 on an i32 memory | **validation** error | `address.wast:210` |

The last two rows matter: the assembler range-checks neither. `align.wast:873`
and `align.wast:1017` are the *same literal* — valid text in an i64-memory
module, invalid at validation in a 32-bit one.

Natural alignment is per-opcode data and therefore belongs in
`Wasm.Wat.Opcodes` alongside the opcode bytes, not in the grammar.

#### c.7 Everything else, briefly

- **`(start $f)` / `(start 2)`** — `start.wast:41`, `:70`. Two start
  sections is a text error, `multiple start sections` (1 command,
  `start.wast`).
- **id-versus-index equivalence** is total: everywhere an index is
  accepted, a `$id` is accepted (`text-idx`), including inside `(ref $t)`,
  `(table $t)`, `(export "x" (tag 3))`, and both operands of
  `struct.get`.
- **`(module $id …)`** — named modules exist and later commands reference
  them across intervening modules (`exports.wast:16-26`). That is the
  *runner's* registry, not the assembler's; the assembler ignores the
  module id. Noted here so it is not mistaken for assembler scope.

### (d) Numeric literals

This is the acknowledged bug farm and it gets its own unit and its own
wave. Budget it honestly: **the float parser is the largest single piece
of the assembler outside the abbreviation catalog.**

#### d.1 Integers — `text-sign`

Token grammar: optional sign, then either decimal digits or `0x` +
hex digits, with underscores permitted **only between digits**.
`text-sign`: "Uninterpreted integers can be written as either signed or
unsigned, and are normalized to unsigned in the abstract syntax."

Two range classes, and conflating them is the classic defect:

- **`uN`** (memarg `align`/`offset`, limits, lane indices, all indices):
  `[0, 2^N − 1]`, **no sign accepted**. This is why `align=-1` is
  `unknown operator` rather than a range error — with a sign it is not a
  `u32` token at all, so the longest-match rule makes the whole thing one
  reserved token.
- **`iN`** (`i32.const`, `i64.const`): the **union** `[−2^(N−1), 2^N − 1]`.
  `const.wast:286-304` pins every boundary:

  | Literal | Verdict |
  | --- | --- |
  | `i64.const 0xffffffffffffffff` | accepted |
  | `i64.const -0x8000000000000000` | accepted |
  | `i64.const 0x10000000000000000` | `constant out of range` |
  | `i64.const -0x8000000000000001` | `constant out of range` |
  | `i64.const 18446744073709551615` | accepted |
  | `i64.const -9223372036854775808` | accepted |
  | `i64.const 18446744073709551616` | `constant out of range` |
  | `i64.const -9223372036854775809` | `constant out of range` |

Algorithm (avoids the `Int64` negation trap entirely):

1. Accumulate the **magnitude** into a `UInt64`, checking overflow before
   each multiply-add: reject when `Acc > (High(UInt64) − d) div Base`.
   `18446744073709551616` must be caught here, not after a silent wrap.
2. If the literal is negative, require `Magnitude <= 2^(N−1)`; the result
   bits are `UInt64(0) − Magnitude`, which is well-defined two's-complement
   wraparound on an unsigned type and yields the correct bits for
   `−2^63` without ever forming `Int64(−2^63)` by negation.
3. If positive, require `Magnitude <= 2^N − 1`.
4. Emit as sLEB128 of the resulting bit pattern reinterpreted as signed.

Malformed integer *tokens* are `unknown operator`, not range errors:
`0x` (`const.wast:12`), `1x` (`:16`), `0xg` (`:20`). `010` is decimal ten,
not octal (`int_literals.wast:10`), and `+42` is legal (`:12`).

#### d.2 Floats — `text-frac`

**Decision: parse to bits ourselves. `Val` / `StrToFloat` are not usable.**

Six reasons, any one of which is disqualifying:

1. The hex-float grammar (`0x1p-149`, `0x1.fffffep+127`, `0x1.p10`) has no
   RTL support.
2. `nan:0x…` payload literals have no RTL analogue.
3. `inf` is not an RTL spelling.
4. Underscores inside literals (`nan:0x7f_ffff`, `const.wast:406`) are not.
5. `Val` and `StrToFloat` consult `DefaultFormatSettings` for the decimal
   separator — a locale dependency in a conformance path.
6. Rounding is unspecified. `const.wast:2` carries a 309-digit decimal
   literal, and `const.wast:316` versus `:327` distinguishes
   `0x1.fffffefffffffffffffp127` (accepted, rounds **down** to max finite)
   from `0x1.ffffffp127` (`constant out of range`, rounds **up** past it).
   Those two differ only in the rounding decision. The corpus is
   *designed* to catch a not-quite-correct rounder.

`text-frac` also fixes the range rule precisely, and it is not the obvious
one: "The value of a literal **must not lie outside the representable
range** of the corresponding IEEE754 type (that is, a numeric value must
not overflow to ±infinity), **but it may be rounded** to the nearest
representable value." So: **round first, then check.** If the
correctly-rounded result is infinite, the literal is out of range.
Checking the pre-rounding magnitude against the max finite value gets
`0x1.fffffefffffffffffffp127` wrong.

**Hex floats — exact, and the easy half.** Parse `hexmant` into a `UInt64`
significand accumulating from the most significant hex digit, tracking a
sticky OR of everything that falls off the bottom; each hex digit after
the point subtracts 4 from the exponent. Normalize so the leading 1 sits
at bit 63, derive the unbiased exponent, then round to the target
mantissa width (24 for f32, 53 for f64) using guard/round/sticky with
**round-half-to-even**. Subnormals: when the exponent falls below the
minimum, shift right by the shortfall, OR the lost bits into sticky, then
round. Overflow after rounding → `constant out of range`.

**Decimal floats — the expensive half.** Chosen approach: **exact
rational comparison with a small bignum**, not a floating-point
approximation with a fallback. Represent the literal as `D × 10^E` where
`D` is the digit string as a base-10⁹ bignum and `E` the decimal exponent
after the point and any `p`/`e` exponent. Form
`Num = D × 10^max(E,0)` and `Den = 10^max(−E,0)`, then long-divide to
produce the target significand bits plus a sticky remainder, and round
half-to-even. The corpus's worst case is ~310 significant digits with
`|E| ≲ 350`, so the operands stay under ~2,300 bits — small, bounded, and
on a **cold** path. AGENTS.md's RTL policy is explicit that cold paths
favour clarity; the driver here is correctness, not speed.

Rejected alternative: a 128-bit scaled fast path with a slow fallback.
It is strictly more code than the exact path (you need the exact path
anyway for the fallback) and buys speed nobody measured a need for.

**NaN literals.** `nan` alone is the canonical NaN — payload `2^(m−1)`.
`nan:0x<hexnum>` supplies an explicit payload, with two range rules
pinned by the corpus:

| Literal | Verdict | Evidence |
| --- | --- | --- |
| `f32.const nan:0x7f_ffff` | accepted (underscores legal) | `const.wast:406` |
| `f32.const nan:1` | `unknown operator` — payload must be **hex** | `const.wast:410` |
| `f32.const nan:0x0` | `constant out of range` — payload must be > 0 | `const.wast:419` |
| `f32.const nan:0x80_0000` | `constant out of range` — must fit the mantissa | `const.wast:428` |
| `f64.const nan:0x10_0000_0000_0000` | `constant out of range` | `const.wast:432` |

Sign is independent (`-nan:0x7fffff`, `+nan:0x304050` —
`float_literals.wast:10,12`). Bits are `sign | all-ones exponent | payload`.

**`nan:canonical` and `nan:arithmetic` are NOT literals.** They are
`assert_return` result *patterns* and belong to the runner's matcher
(Track E). Inside a `const` they are `unexpected token` (`i64.wast:488`).
Keep them out of `Wasm.Wat.Numbers` entirely; a parser that accepts them
in a const position silently converts a malformed case into a pass.

#### d.3 Strings

Already solved in `Wasm.Wast`'s `LexString` and reimplemented strictly in
`Wasm.Wat.Lexer`: plain characters contribute their UTF-8 bytes, `\hh`
contributes a raw byte, `\u{…}` contributes the UTF-8 encoding of a
scalar value (surrogates and > U+10FFFF rejected), control characters
must be escaped.

One addition the script lexer does not need: **UTF-8 validity when a
string is used as a name.** `utf8-invalid-encoding.wast` spells 186
commands of the shape
`(assert_malformed (module quote "(func (export \"\\80\"))") "malformed UTF-8 encoding")`.
So import/export module and field names are checked for UTF-8 validity at
assembly time. Data strings and `(module binary …)` payloads are **raw
bytes with no UTF-8 requirement** — do not check them.

### (e) Binary emission

`Wasm.Wat.Emit` owns a growable byte buffer plus:

- LEB128 writers: `WriteU32`, `WriteU64`, `WriteS32`, `WriteS64`,
  `WriteS33` — canonical (shortest) encodings only.
- Value-type, heap-type, reference-type, limits, and blocktype encoders,
  mirroring `Wasm.Decoder.Types`. Value types are signed LEB128 small
  negatives, not raw bytes — the mistake AGENTS.md records as already
  shipped once.
- `BeginSection(id)` / `EndSection`, with size backpatching.

**Backpatching strategy: build each section body into its own buffer,
then write `id`, `LEB(size)`, `body`.** The alternative — reserve five
bytes and rewrite a padded LEB in place — is rejected outright, because a
padded five-byte LEB for a small value is exactly the over-long encoding
our own `Wasm.Binary` correctly rejects as
`integer representation too long`. We would be emitting bytes we reject.
The extra copy per section is irrelevant on a cold path. The same applies
per code entry, which is independently size-prefixed.

**Section order is the prescribed encoding order, and the text field
order is free.** A `.wat` module may spell `(func …)` before `(type …)`
(`func.wast:422-425` does exactly that). The declare pass therefore
collects entities into per-section lists and the emitter writes them in
`Wasm.Core`'s prescribed order. This is a defect class that stays
invisible until the corpus runs, so it gets a direct unit test:
scramble the field order, assemble, decode, assert the section table.

**Data count section: emit it whenever a data section is emitted.** The
binary grammar requires it when `memory.init`/`data.drop` occur;
emitting it unconditionally alongside a data section is legal, simpler,
and already accepted by our decoder's cross-section check.

#### The name section: do not emit it

Four reasons:

1. **No corpus verdict depends on it.** The name section is a custom
   section; `Wasm.Decoder` skips it as custom. Emitting it cannot change
   any `assert_malformed`, `assert_invalid`, or module-acceptance
   outcome.
2. **The cases that look like they need it do not.** The `@name` and
   `@custom` annotation assertions — `misplaced @custom annotation`,
   `@custom annotation: missing section name`, `@name annotation: multiple module`
   — are all under `assert_malformed_custom` / `assert_invalid_custom`
   (20 commands total), which are testsuite-local directives outside the
   reference grammar. The runner already skips them as
   `directive not in the reference grammar`, and should continue to.
3. **It is pure new surface for zero conformance value**: a UTF-8-encoded,
   ordered, index-keyed subsection format with its own well-formedness
   rules.
4. **Diagnostics do not need the round trip.** Identifier tables live in
   `Wasm.Wat.Names`; anything that wants to print `$myfunc` can read them
   directly.

Revisit only if Track F's `wasmlight run` wants named frames in a trap
trace — and then as a Track F decision, with its own justification.

---

## 3. Rec groups and the GC text forms

`text-rectype` / `text-comptype`. These map onto Track A's decoded shapes
one-for-one, which is the point: the emitter is `Wasm.Decoder.Types`
run backwards.

| Text | Abstract | Notes |
| --- | --- | --- |
| `(rec (type …)*)` | one rectype, N subtypes | `type-rec.wast:11,13` |
| `(type $x …)` at module level | a rectype with **one** subtype | the singleton wrapping is what `text-typeuse-abbrev`'s "singular" clause refers to |
| `(type $x (sub $s* ct))` | subtype, declared supertypes, `final = false` | `type-subtyping.wast:5,11` |
| `(type $x (sub final $s* ct))` | subtype, `final = true` | `type-subtyping.wast:346,807,957` |
| `(type $x ct)` bare | subtype, no supertypes, **`final = true`** | why a bare type qualifies for implicit reuse |
| `(func …)` / `(struct …)` / `(array ft)` | comptype | `struct.wast`, `array.wast` |
| `(field $id? st*)` | N fields | see below |
| `(mut st)` | mutable field | `struct.wast:71,161`; `array.wast:14` |
| `i8` / `i16` | packed storage types | `struct.wast:9` |

Field groups have three rules the corpus pins directly:

- `(field i8 i8 i8 i8)` (`struct.wast:7`) expands to **four** fields.
- `(field)` with zero types (`struct.wast:5,10`) is legal and contributes
  nothing.
- Only a **single-type** group may carry an id (`(field $x1 i32)`,
  `struct.wast:8`). Ids bind into the owning type's field namespace at the
  field's ordinal, and `duplicate field` (`struct.wast:17`) is a text
  error.

Reference types: `(ref null? heaptype)` plus the absheaptype keywords
(`any eq i31 struct array none func nofunc extern noextern exn noexn`), a
typeidx or `$id`, and the shorthand reftypes from `text-reftype`'s
abbreviations (`anyref eqref i31ref structref arrayref nullref funcref
nullfuncref externref nullexternref exnref nullexnref`). Packed accessors
carry a signedness suffix on the *instruction*, not the type
(`struct.get_s`, `array.get_s` — `struct.wast:167`, `array.wast:173`).

Tags reuse the function typeuse machinery in full, including implicit
type insertion: `(tag $t (import "m" "n") (type $x))` mirrors the func
import shape (`tag.wast:14`), and `tag` is a valid exportdesc keyword
(`(export "t3" (tag 3))`, `tag.wast:8`).

`try_table`'s catch clauses (`catch`, `catch_ref`, `catch_all`,
`catch_all_ref`) are instruction immediates, not module fields, and
`Wasm.Validator.Body` already emits their IR shape — the assembler only
has to encode them.

The legacy `try`/`catch`/`delegate`/`rethrow` encoding is out of scope
(roadmap Track H); it lives under `testsuite/legacy/`.

---

## 4. Error message canon

The match is a **prefix** match: the script's expected string must be a
prefix of ours. Two consequences that shape the canon:

**A longer message satisfies a shorter expectation.** Where the corpus
asks for both a short and a long form of the same condition, emit the
long one and both match:

- `alignment` (92) and `alignment must be a power of two` (22) are the
  same condition — emit the long form, satisfy 114 commands.
- `malformed UTF-8` (2) and `malformed UTF-8 encoding` (186) likewise —
  emit the long form, satisfy 188.

**The offending token must be appended, not prefixed.**
`obsolete-keywords.wast` expects `unknown operator current_memory`,
`unknown operator get_local`, `unknown operator i32.wrap/i64`, and eight
more. So the literal `unknown operator`, a space, then the token text —
exactly the shape
`Wasm.Validator.Types` already uses for `unknown memory <index>`. The 555
bare `unknown operator` expectations still match, because the prefix is
intact.

### The tallied canon

Every `assert_malformed` expected string carrying a `(module quote …)`
operand under the **reference-grammar** directive, all 288 scripts,
1,278 commands. This is the implementation checklist.

| Count | Expected prefix | Raised by | Notes |
| ---: | --- | --- | --- |
| 555 | `unknown operator` | Lexer / Assembler | the reserved-token rule (`text-reserved`) plus unknown mnemonics; **append the token** |
| 186 | `malformed UTF-8 encoding` | Lexer / Names | source bytes, and names used as import/export strings |
| 175 | `unexpected token` | Assembler | grammar divergence: clause order, stray `)`, unfolded `if` condition |
| 92 | `alignment` | Assembler | subsumed by the line below |
| 55 | `constant out of range` | Numbers | int width, float overflow-after-rounding, NaN payload |
| 32 | `illegal character` | Lexer | control chars and non-idchar codepoints outside strings/comments |
| 32 | `import after {function,global,table,memory}` | Assembler | 8 each; names the **preceding definition's** kind |
| 24 | `inline function type` | Names | typeuse inline declarations not syntactically equal to the referenced type |
| 22 | `alignment must be a power of two` | Assembler | emit this spelling for all 114 |
| 15 | `i8 constant out of range` | Numbers | SIMD lane literals — wave 7 |
| 14 | `mismatching label` | Assembler | trailing id at `else`/`end` not equal to the block's id |
| 8 | `wrong number of lane literals` | Assembler | SIMD — wave 7 |
| 7 | `empty annotation id` | Lexer | `(@)`, `(@ )`, `(@ x)`, `(@"")` |
| 7 | `empty identifier` | Lexer | `$`, `$""`, `$ "a"`, `$"a\nb"` |
| 6 | `duplicate memory` | Names | |
| 5 | `wrong number of lane indices` | Assembler | SIMD — wave 7 |
| 4 | `unclosed annotation` | Lexer | |
| 3 | `duplicate func` | Names | incl. import/definition collision |
| 3 | `duplicate local` | Names | params and locals share one namespace |
| 3 | `duplicate global` | Names | |
| 3 | `duplicate table` | Names | |
| 3 | `i32 constant out of range` | Numbers | `proposals/threads/` only |
| 3 | `invalid custom page size` | — | `proposals/custom-page-sizes/`; outside ADR-0004's target |
| 2 | `malformed UTF-8` | Lexer | subsumed by `malformed UTF-8 encoding` |
| 2 | `unclosed string` | Lexer | |
| 2 | `unknown label` | Names | **symbolic** label unresolved (numeric is the validator's) |
| 1 | `unknown type` | Names | `(type N)` with inline declarations, N unresolvable |
| 1 | `multiple start sections` | Assembler | |
| 1 | `duplicate field` | Names | |
| 1 | `i64 constant out of range` | Numbers | `proposals/custom-page-sizes/` |
| 11 | `unknown operator <token>` | Lexer / Assembler | `obsolete-keywords.wast`; proves the append rule |

Constants live as `MSG_*` in the unit that raises them, matching the
existing convention (`Wasm.Binary` for decode, `Wasm.Validator.Types` for
validation). Add `Wasm.Wat.Lexer` and `Wasm.Wat.Names` as the two new
homes; the assembler reuses both.

**Follow Track B's discipline:** where the exact upstream spelling cannot
be confirmed against spec text, mark the site `UNCONFIRMED` and let the
wave 6 corpus run settle it. That worked twice; the first Track C run
went from `pass=218 fail=851` to `pass=1034 fail=35` almost entirely by
settling prefixes.

### Runner taxonomy change

`WAST_REASON_TEXT_FORMAT` **disappears**. Concretely:

| Command | Today | After |
| --- | --- | --- |
| `(module …)` / `(module quote …)` top level | skip | assemble, decode, validate — pass or fail |
| `assert_malformed` + text/quote operand | skip | expect `EWasmTextError` with a matching prefix |
| `assert_invalid` + text/quote operand | skip | assemble must **succeed**, then expect `EWasmValidationError` |
| `assert_unlinkable` + text operand | skip | assemble+decode+validate must succeed; then skip `needs an execution tier` |
| `assert_trap` + module operand | skip | same pre-check, then skip |
| `register`, `invoke`, `assert_return`, `assert_exception`, `assert_exhaustion` | skip | unchanged — `needs an execution tier` |
| `assert_*_custom` | skip | unchanged — `directive not in the reference grammar` |

`TWastErrorKind` gains `wekText`. For `assert_malformed`, the accepted
kind depends on the operand form: `binary` → `wekDecode`, text/quote →
`wekText`. A `wekDecode` on assembler output is **INV-1 violated** and
must be reported as a failure with kind `internal`, never scored as a
pass. That is the only mechanism that catches a mis-assembly that happens
to trip a decode rule with a matching message.

The `assert_unlinkable` / `assert_trap` pre-check is worth the two extra
rows: those 319 modules are well-formed and valid by construction, so an
assembler failure on them is a false rejection (INV-2). The command still
reports `skip`, because we cannot judge linking — a skip stays a skip.
The *failure* path is what is new.

After wave 6 the skip column holds only execution-tier commands (≈59,400)
plus the 20 `_custom` directives.

---

## 5. Module-quote nuance: reassembly at command time

The roadmap's hard requirement — "`(module quote …)` and `(module binary …)`
must be parsed or decoded at *command execution* time, not script-parse
time" — is already honoured by construction, and the assembler must not
break it.

The contract, restated so it survives:

- **`Wasm.Wast` never assembles.** It records the command's source span
  and its string-literal bytes. Adding spans (§2a) adds two integers, not
  a phase.
- **`AssembleWat` is called inside `ExecuteCommand`**, in the same
  `try/except` that already brackets `DecodeModule` and `ValidateModule`.
- **No caching, ever.** Not across commands and not within one. The same
  quoted text may appear in one command that expects it to fail and
  another that expects it to succeed, and a memoised assembler would
  return a cached *success* for the second reading of text whose failure
  is the point. The cost is irrelevant: 1,312 quote payloads across the
  whole corpus.
- **Escapes are already decoded when the assembler sees them, and that
  changes the source alphabet.** `(module quote "(@a \00)")` delivers a
  real NUL byte in the module source. The assembler must treat it as an
  illegal source character — `annotations.wast:23` expects
  `illegal character` — and specifically must **not** treat it as
  end-of-input. A lexer that trusts a NUL terminator turns a malformed
  case into a silent accept.

---

## 6. Unit layout and wave plan

### Units

All flat under `source/units/` in the `Wasm.Wat.*` namespace, each with a
co-located `*.Test.pas`, per AGENTS.md's fixed layout and code-style's
"one namespace, flat until a sub-area earns nesting". `Wasm.Wat` is
deliberately distinct from `Wasm.Wast`: `.Wast` is the *script* format,
`.Wat` is the *module* text format. They are different languages.

| Unit | Owns | Depends on |
| --- | --- | --- |
| `Wasm.Wat.Lexer` | strict tokenizer: token classes, UTF-8 source decoding, identifiers incl. `$"…"`, strings, annotation scanning **with validation**, the reserved-token rule | `Wasm.Core` |
| `Wasm.Wat.Numbers` | integer and float literals → bits; hex floats, decimal-float bignum, NaN payloads, range checks | `Wasm.Core` |
| `Wasm.Wat.Emit` | byte buffer, LEB128 writers, type/limits encoders, section builder with size backpatching | `Wasm.Core` |
| `Wasm.Wat.Opcodes` | mnemonic → opcode bytes + immediate shape + natural alignment; the mirror of `Wasm.Decoder.Expr`'s table | `Wasm.Core` |
| `Wasm.Wat.Names` | the twelve identifier contexts, label stack, field namespaces, duplicate detection, implicit-typeuse dedup/insert table | `Wasm.Core` |
| `Wasm.Wat.Assembler` | the grammar: module fields, abbreviation expansion, folded-instruction unfolding, `AssembleWat` | all five above |

Splitting `Opcodes` out of `Assembler` is deliberate: Track G appends
~256 vector mnemonics to a table without touching the grammar.

Modified elsewhere: `Wasm.Core` (`EWasmTextError`), `Wasm.Wast` (source
spans, retained source), `Wasm.Wast.Runner` (taxonomy, `wekText`,
pre-checks), plus `docs/roadmap.md`, `docs/testing.md`,
`tests/spec/README.md`, and AGENTS.md's code-organization table.

### Waves

Each wave is independently gate-green
(`lwpt format --check && lwpt build && lwpt test`) and independently
testable. Waves 1–3 unlock **no** corpus commands by design — they are
the pieces whose defects are cheapest to find in isolation and most
expensive to find through the assembler.

**Wave 1 — `Wasm.Wat.Numbers`.** No dependencies. Integers across both
range classes with the `−2^63` and `2^64 − 1` boundaries; hex floats with
subnormals, round-half-to-even, and overflow-after-rounding; the decimal
bignum; NaN payloads. Tests spell the literal next to its expected bit
pattern, drawn from `const.wast` and `float_literals.wast` — the same
discipline AGENTS.md already requires for malformed byte cases. *Corpus
unlock: 0. Retires the biggest fidelity risk first.*

**Wave 2 — `Wasm.Wat.Lexer`.** Token classes, the reserved-token rule,
UTF-8 source decoding, strict identifiers, annotation validation. Owns
six error prefixes outright (`illegal character`, `empty annotation id`,
`empty identifier`, `unclosed annotation`, `unclosed string`, and most of
`malformed UTF-8 encoding`). *Corpus unlock: 0.*

**Wave 3 — `Wasm.Wat.Emit` + `Wasm.Wat.Opcodes`.** Differential testing
against the shipped decoder: hand-build a module structure, emit, run
`DecodeModule`, compare against the expected model; and round-trip the 22
fixtures in `tests/fixtures/`. This is the wave that proves section
ordering and size backpatching without a single line of grammar.
*Corpus unlock: 0.*

**Wave 4 — `Wasm.Wat.Names` + assembler skeleton.** Module fields: types
(rec/sub/final/struct/array, field names), imports and exports including
the inline abbreviations, memories, tables, globals, tags, elem and data
with all sugar forms, start, funcs with locals — and a **minimal**
instruction set (`unreachable nop drop end return`, the `*.const`
family, `local.*`, `global.*`, `call`) so the skeleton is exercised
end-to-end. *Corpus unlock: partial and not usefully predictable in
advance — measure it by running `wasmspec` rather than estimating.*

**Wave 5 — the instruction grammar.** All non-vector instructions,
folded-instruction unfolding, blocktypes, labels, memarg, typeuse in
`call_indirect`/`block`/`loop`/`if`, GC instruction immediates including
`struct.get $t $f`, `try_table` catch clauses. *This is the wave that
lands the bulk.*

**Wave 6 — harness integration and the message run.** `EWasmTextError`,
`wekText`, the taxonomy change, the `assert_unlinkable`/`assert_trap`
pre-check, docs. Then run the corpus and **settle the prefixes**. Budget
two passes explicitly: expect the first run to show many message-prefix
divergences and few wrong-class verdicts, because that is exactly what
happened the first time (218 → 1,034).

*Corpus unlock, waves 4–6 together, from the command tally:*

| Newly judged | Count |
| --- | ---: |
| `(module …)` text, top level | 2,367 |
| `(module quote …)` text, top level | 9 |
| `assert_invalid` with a text operand | 2,989 |
| `assert_invalid` with a quote operand | 6 |
| `assert_malformed` with a quote operand | 1,278 |
| **Total** | **6,649** |

Judged rises from 1,075 to ≈7,724 of ≈67,125; skip falls from 66,050 to
≈59,400. `assert_return` (53,294) and `assert_trap` (5,252) keep
skipping until Track E, and no amount of assembler work changes that —
which is the roadmap's own warning that a majority of assertions is not a
majority of features.

**Wave 7 — vector text forms (with Track G).** `v128.const i32x4 …`,
lane literals, `i8x16.shuffle` lane indices. Cheap and table-driven.
Worth doing *in the assembler* even though the validator stages `$FD`:
the assembler emitting vector instructions correctly is what keeps the
`STAGED` marker a validator concern rather than an assembler excuse. It
unlocks the SIMD-specific error prefixes (`i8 constant out of range` 15,
`wrong number of lane literals` 8, `wrong number of lane indices` 5,
`alignment must be a power of two` 22).

---

## 7. Fidelity risks and their test strategies

| Risk | Why it bites | Test strategy |
| --- | --- | --- |
| **Hex-float rounding** | Round-half-to-even at the exact tie, subnormal shift-with-sticky, and overflow that only appears *after* rounding. `const.wast:316` vs `:327` differ only in the rounding decision. | Unit assertions with exact bit patterns for every boundary literal in `const.wast`/`float_literals.wast`. Plus a round-trip property test: for pseudorandom f32/f64 bit patterns, format as a hex float and re-parse — hex round-trips exactly, so any mismatch is a parser bug. |
| **Decimal-float correct rounding** | The 309-digit literal at `const.wast:2` and a bignum long-division that must produce a correct sticky bit. | Fixed expected bit patterns taken from the corpus's own literals; a table of known-hard cases at the tie. No round-trip oracle here — shortest-decimal formatting is not being built. |
| **NaN payload handling in *literals*** | Easy to conflate with the runner's `nan:canonical`/`nan:arithmetic` result classes, which are a *different feature in a different track*. Accepting `nan:arithmetic` in a const turns `i64.wast:488` from a pass into a failure. | One suite covering both spellings side by side: payload `0`, payload `2^m`, decimal payload, signs, canonical `nan`, and an explicit assertion that `nan:canonical` in a const position raises `unexpected token`. |
| **`i64` `INT64_MIN` edge** | Negating `Int64(-2^63)` overflows; parsing `0x8000000000000000` as signed overflows the other way. Both spellings are in the corpus (`const.wast:287,298`; `int_literals.wast:19`). | Assert the emitted sLEB128 bytes for all four boundary literals plus the two just-out-of-range ones. |
| **Typeuse dedup order sensitivity** | Wrong dedup silently shifts type indices, and `func.wast:427-428` names them numerically. Failures appear as unrelated validation errors far from the cause. | `func.wast:422-433` lifted verbatim into a unit test: assemble, decode, assert the type section has exactly two entries in the stated order. Plus `type-rec.wast:45-61` — an implicit typeuse must **not** reuse a member of a multi-member rec group. Plus `func_ptrs.wast:2-4` — explicit types are never deduped. |
| **Folded-`if` arm ordering** | The condition operands belong *before* the `if` opcode; the classic bug emits them after. Silent — it produces a valid-looking module that computes the wrong thing, so only `assert_return` would catch it, and `assert_return` is skipped until Track E. | Assert the exact opcode byte sequence for `if.wast:19`'s form. This one must be tested at the byte level precisely because no later stage catches it in this track. |
| **Label shadowing** | Innermost-first resolution with re-binding; an outer-first implementation passes most tests and fails `labels.wast:281-288`. | Assemble `labels.wast:281-288` and assert the emitted `br` depth immediates. |
| **`mismatching label`** | The trailing id at `else` and at `end` must each independently equal the block's id, and an id on an *unlabelled* block is an error rather than a silent accept (`if.wast:1520`, `if else $l end $l`). | The 14 corpus cases as unit tests; they are one-liners. |
| **Reserved tokens** | `unknown operator` is 555 commands and is *not* an unknown-mnemonic check. `0x`, `1x`, `0xg`, `0$x`, `$"l"0`, `$l$l` each lex as one reserved token. | Lexer-level assertions that each of those inputs produces exactly one token of class reserved, plus assembler assertions on the resulting message including the appended token. |
| **NUL and control bytes in quote payloads** | Escapes are decoded before the assembler sees them, so `\00` is a real NUL in module source. A NUL-terminated scan turns `annotations.wast:23` into a silent accept. | Feed `(@a \00)` as decoded bytes directly to `AssembleWat` and assert `illegal character`. |
| **Section ordering in the emitter** | Text field order is free; section order is fixed. Invisible until a real module round-trips. | Assemble a module whose fields are deliberately scrambled, decode it, assert the section table. |
| **Memarg defaults and flags** | Natural alignment is per-opcode data; `align` encodes as log₂; the memory index rides in flag bit 6. Three independent ways to be wrong. | One assertion per load/store family for the omitted-`align` default, plus the multi-memory form from `address0.wast:89`. |
| **Import-after-definition, inline form** | The corpus tests only the explicit `(import …)` field; the inline abbreviation's behaviour is unverified. | Ship the narrow reading, mark the site `UNCONFIRMED`, and let the wave 6 run decide — the established practice for exactly this situation. |
| **INV-1 regressions** | A mis-assembly that happens to trip a decode rule with a matching message would score as a *pass* under a naive harness. | The runner reports `wekDecode` on assembler output as `internal`, and the corpus run's `internal` count is a gate: it must be zero. |

---

## Open items to settle empirically in wave 6

1. Whether inline `(func (import …))` after a definition is
   `import after function` (§2b).
2. Whether all 92 bare `alignment` expectations are power-of-two/zero
   failures, so the long spelling subsumes them (§4).
3. The exact spelling for duplicate ids in spaces the corpus does not
   test (`type`, `elem`, `data`, `tag`).
4. Whether any `assert_invalid` text case reaches a *decode* error in our
   pipeline that upstream reaches at validation — INV-1 says no; the run
   is the proof.
