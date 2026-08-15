# Deployment

## Executive Summary

- `0.1.0` is wasmlight's first release: the completed pinned-Core-3 runtime,
  its three execution tiers on 64-bit UNIX, the interpreter on every supported
  target, and the current deny-by-default WASI Preview 1 subset.
- Releases go through the `create-release` skill: changelog first, then
  an unprefixed SemVer tag matching `[package].version` in `lwpt.toml`.
- wasmlight is consumed as an lwpt dependency, not as a distributed
  binary — the CLI (`inspect` / `validate` / `run`, the last running a
  WASI preview1 command) is a development and inspection tool, not the
  product.

## Consuming wasmlight

Once released, a downstream lwpt project depends on it through its
manifest:

```toml
[dependencies]
wasmlight = "frostney/wasmlight@^0.1.0"
```

The runtime compiles into the host binary. There is no shared library, no
runtime installation step, and no dependency beyond the platform.

## Release checklist

The gates are in [DEFINITION_OF_DONE.md](../DEFINITION_OF_DONE.md); the
mechanics are:

1. `ci.yml` is green on the release commit — the full platform matrix.
2. Set and verify `[package].version` in `lwpt.toml`. That is the single source
   of truth: the `prebuild` hook restamps `source/units/Version.inc`, so
   `wasmlight --version` follows automatically.
3. Regenerate the changelog with git-cliff and land it **before** the tag,
   so the tag's notes are published from a committed section.
4. Tag with unprefixed SemVer matching the manifest version (`0.1.0`, not
   `v0.1.0`).
5. Release builds stamp the tag into the binary via
   `$WASMLIGHT_VERSION_OVERRIDE`; verify `wasmlight --version` on the
   built artifact before publishing.

## Versioning

SemVer, with the tier seam and the embedding API as the compatibility
surface. Which execution tier ran a function is an implementation detail
and never a breaking change — that is the point of
[ADR-0001](adr/0001-tiered-execution-seam.md). A behavioural difference
between tiers is a bug fix, not a compatibility event.

Pre-1.0, the minor version may break the embedding API; the changelog
says so explicitly when it does.
