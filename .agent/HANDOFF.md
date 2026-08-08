# Handoff

Updated: 2026-08-08

## Current state

- Repo audit: everything committed is green (`lwpt install --frozen`,
  `lwpt build`, `lwpt test`, `lwpt format --check`, `wasmlight inspect`
  smoke-tested on valid + malformed fixtures). Shipped surface = decode
  skeleton per docs/roadmap.md; roadmap's shipped table verified honest.
- A grilling session settled both open roadmap questions plus a
  cross-check of all ADRs against production runtimes (Wasmtime, V8,
  SpiderMonkey, JSC, WAMR, wasm3, wazero — research reports were
  session-only, conclusions are all recorded in the ADRs).

## Decisions taken (all recorded in docs/adr/)

- **ADR-0013 (new):** i64 memories take guard-assisted bounds checks;
  strategy static per memory by address type; 2×2 platform matrix;
  constants are wasmbench-tuned; Spectre hardening assigned to Track I.
- **ADR-0014 (new):** Component Model deferred to post-v1 (supersedes
  ADR-0002's component half); v1 host surface is WASI preview1 only;
  re-entry condition: post-rework canonical ABI landed + covered by the
  component-model WAST suite.
- Amendments: ADR-0001 (no OSR, tier-up at function entry only;
  differential tests compare traps + final memory/globals), ADR-0007
  (shared-IR cost recorded: 2–4× memory, instantiation latency;
  wasmbench obligation; lazy-emission escape hatch named), ADR-0012
  (register-IR precedents; risk concentrated in unreachable/multi-value/
  br_table), ADR-0011 (allocation sites are safepoints too), ADR-0009
  (siglongjmp-skipped frames must hold no managed Pascal state;
  sigsetjmp cost measured), ADR-0003 (lifetime rule in doc comments;
  WAMR-style freeability query later), ADR-0008 (threads ⇒ separate
  synchronised SharedMemory type, never store locks), ADR-0005 +
  AGENTS.md chokepoint bullet updated for the address-type matrix.
- roadmap.md: "Open questions" → "Settled questions"; Track K removed
  (moved to After 3.0); Track F cites ADR-0014.

## Open questions

- None from the grilling — frontier emptied, user confirmed.

## Next steps

1. Commit the doc changes (13 modified + 2 new files, all lint-clean;
   nothing committed yet).
2. Start Track A (section body decoding) — no prerequisites; the
   recursive type section is the biggest sub-piece.
3. Stand up Track C's harness skeleton early (assert_malformed can judge
   the decoder before any tier exists).
4. **User decision:** do NOT file GitHub issues until everything in the
   roadmap is implemented.
