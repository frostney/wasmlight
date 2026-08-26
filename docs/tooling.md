# Tooling

## Executive Summary

- FPC **3.2.2** (Delphi mode) is the pinned compiler; the
  [lwpt](https://github.com/frostney/lwpt) **0.6.0 release binary** is the
  single toolchain entry point for install / build / test / format.
- Lefthook runs `lwpt format` and `lwpt agents` pre-commit; markdownlint and
  the PR workflow are the blocking gates.
- CI: `pr.yml` is the pre-merge gate, `ci.yml` (push to main) adds the
  full platform matrix.
- Changelog generation is git-cliff from Conventional Commits
  (`cliff.toml`).

## Toolchain

| Tool | Version / source | Role |
| --- | --- | --- |
| FPC | 3.2.2 (brew / apt / choco) | compiler, Delphi mode via `source/units/Shared.inc` |
| lwpt | 0.6.0 (`brew install frostney/tap/lwpt`, or the checksum-verified release tarball; pinned as `LWPT_VERSION` in CI) | build, test discovery, formatter, dependency install |
| InstantFPC | ships with FPC | runs `scripts/stamp-version.pas` as a build hook |
| Lefthook | ≥ 1.5 | pre-commit formatter + agent-reference hooks (`lefthook install`) |
| markdownlint-cli2 | latest | blocking docs gate |
| git-cliff | latest | changelog generation from Conventional Commits |
| wabt | 1.0.41 (`brew install wabt`) | assembles the `tests/fixtures/` corpus from `.wat`; **regeneration only** — the `.wasm` files are committed |
| wasm-tools | 1.255.0 (`brew install wasm-tools`) | independent validator used as the oracle when regenerating fixtures |
| wasm-mcp | 0.2.16 (`.mcp.json`) | MCP server serving the WebAssembly spec from a pinned commit — how agents check spec behaviour instead of recalling it |

## Commands

```bash
lwpt install           # resolve deps, regenerate lwpt.cfg + lwpt.lock
lwpt install --frozen  # CI mode: verify lockfile + committed modules, refuse network
lwpt format            # rewrite Pascal sources in place
lwpt format --check    # CI / hook form: exit non-zero on drift
lwpt agents             # refresh the machine-owned AGENTS.md command block
lwpt agents --check     # CI form: exit non-zero when the block is stale
lwpt build [target]    # binaries land under build/
lwpt test              # discovers source/units/*.Test.pas
./build/wasmlight inspect <module.wasm>
./build/wasmlight compile <module.wasm> -o <executable> [--target <triple>] [--connector <file.wlc>]...
# native WASI executable onto a catalog or sibling wasmlight-shell
# never a .waot/JIT/interpreter fallback
./build/wasmlight-shell [<payload.wshl> [guest-args...]]  # runtime-shell template
./build/wasmbench      # execution workloads and tiers (measurement only)
# isolate with --workload loop|fib|memory|numeric|simd|startup and --tier
npx markdownlint-cli2 "**/*.md"   # docs gate, config .markdownlint-cli2.jsonc
```

## Generated files and who owns them

Never hand-edit any of these; change the input and re-run the owner.

| File | Owner |
| --- | --- |
| `lwpt.cfg`, `lwpt.lock`, `.lwpt/modules/` | `lwpt install` |
| `source/units/Version.inc` | `scripts/stamp-version.pas` (build/test hook) |
| `.agents/skills/<imported skill>/`, `skills-lock.json` | the `skills` CLI (`npx skills@1.5.17`) |
| `.agents/skills/<repository skill>/` | repository maintainers |
| `CHANGELOG.md` | `git-cliff` |
| `build/` | `lwpt build` — and never committed |

## CI

- **`.github/workflows/pr.yml`** — every PR: `install --frozen` →
  `format --check` + `agents --check` → `build` → `test` on Linux, macOS,
  and Windows runners, plus blocking markdownlint and runtime-comparison jobs.
  The comparison builds base and PR release binaries, measures both on one
  runner against checksum-pinned cached peers, uploads raw samples, and updates
  a sticky PR comment. Execution is required; timing deltas are informational
  and never become CI assertions. This is the authoritative pre-merge signal.
- **`.github/workflows/ci.yml`** — push to `main` only: the full per-arch
  platform matrix. PRs do not trigger it, so the same commit is not built
  twice pre-merge.

Both install lwpt from its published release, checksum-verified, and
resolve dependencies from the same release tag.

## Spec lookup (MCP)

`.mcp.json` (mirrored by `.mcp.example.json`) registers
[wasm-mcp](https://github.com/xyzzylabs/wasm-mcp) over stdio, pinned to an
exact version:

```json
{
  "mcpServers": {
    "wasm": { "command": "npx", "args": ["-y", "wasm-mcp@0.2.16"] }
  }
}
```

It is read-only, deterministic over a pinned upstream spec commit, and
never executes WebAssembly or reaches the network at request time. This is
the same arrangement the sibling GocciaScript project uses with
`tc39-mcp`, from the same publisher.

Bump the pin deliberately, the way any other dependency is bumped — an
unpinned `npx wasm-mcp` would silently change what the spec says between
runs, which defeats the point of citing it.

## Agent skills

Imported project skills are lock-managed under `.agents/skills/`, with
`.claude/skills` symlinked to it. Refresh imported skills with the `skills`
CLI rather than editing their generated trees:

```bash
npx -y skills@1.5.17 update --project --yes
npx -y skills@1.5.17 list --json
```

Repository-authored skills also live under `.agents/skills/`, but are committed
directly and intentionally absent from `skills-lock.json`: the repository is
their source of truth. A skills update leaves these local folders in place.
Use `$optimize-runtime` for benchmark-gated runtime optimization waves.
