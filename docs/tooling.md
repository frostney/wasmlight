# Tooling

## Executive Summary

- FPC **3.2.2** (Delphi mode) is the pinned compiler; the
  [lwpt](https://github.com/frostney/lwpt) **0.4.0 release binary** is the
  single toolchain entry point for install / build / test / format.
- Lefthook runs `lwpt format` pre-commit; markdownlint and the PR workflow
  are the blocking gates.
- CI: `pr.yml` is the pre-merge gate, `ci.yml` (push to main) adds the
  full platform matrix.
- Changelog generation is git-cliff from Conventional Commits
  (`cliff.toml`).

## Toolchain

| Tool | Version / source | Role |
| --- | --- | --- |
| FPC | 3.2.2 (brew / apt / choco) | compiler, Delphi mode via `source/units/Shared.inc` |
| lwpt | 0.4.0 (`brew install frostney/tap/lwpt`, or the checksum-verified release tarball; pinned as `LWPT_VERSION` in CI) | build, test discovery, formatter, dependency install |
| InstantFPC | ships with FPC | runs `scripts/stamp-version.pas` as a build hook |
| Lefthook | ≥ 1.5 | pre-commit formatter hook (`lefthook install`) |
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
lwpt build [target]    # binaries land under build/
lwpt test              # discovers source/units/*.Test.pas
./build/wasmlight inspect <module.wasm>
./build/wasmbench      # execution workloads and tiers (measurement only)
# isolate profiling with --workload loop|fib|memory|startup --tier interp|jit|aot
npx markdownlint-cli2 "**/*.md"   # docs gate, config .markdownlint-cli2.jsonc
```

## Generated files and who owns them

Never hand-edit any of these; change the input and re-run the owner.

| File | Owner |
| --- | --- |
| `lwpt.cfg`, `lwpt.lock`, `.lwpt/modules/` | `lwpt install` |
| `source/units/Version.inc` | `scripts/stamp-version.pas` (build/test hook) |
| `.agents/skills/`, `skills-lock.json` | the `skills` CLI (`npx skills@1.5.17`) |
| `CHANGELOG.md` | `git-cliff` |
| `build/` | `lwpt build` — and never committed |

## CI

- **`.github/workflows/pr.yml`** — every PR: `install --frozen` →
  `format --check` → `build` → `test` on Linux, macOS, and Windows
  runners, plus a blocking markdownlint job. This is the authoritative
  pre-merge signal.
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

Project skills are lock-managed under `.agents/skills/`, with
`.claude/skills` symlinked to it. They are generated — refresh them with
the `skills` CLI rather than editing the tree:

```bash
npx -y skills@1.5.17 update --project --yes
npx -y skills@1.5.17 list --json
```
