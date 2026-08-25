# Deployment

## Executive Summary

- `0.1.0` is wasmlight's first release: the completed pinned-Core-3 runtime,
  its three execution tiers on 64-bit UNIX, the interpreter on every supported
  target, and the current deny-by-default WASI Preview 1 subset. That
  release has no binary assets.
- Releases go through the `create-release` skill: changelog first, then
  an unprefixed SemVer tag matching `[package].version` in `lwpt.toml`.
  There is no second publisher.
- Downstream lwpt projects still consume the runtime as source. The 0.2.0
  compiler archives and Homebrew formula are drafted here; they are not
  live until `/create-release` publishes the assets and the tap copies
  [packaging/homebrew/wasmlight.rb](../packaging/homebrew/wasmlight.rb).

## Consuming wasmlight

Once released, a downstream lwpt project depends on it through its
manifest:

```toml
[dependencies]
wasmlight = "frostney/wasmlight@^0.1.0"
```

The runtime compiles into the host binary. There is no shared library, no
runtime installation step, and no dependency beyond the platform.

`brew install frostney/tap/wasmlight` is the planned macOS/Linux install
for the 0.2.0 compiler and shell catalog. It is not a live tap formula
today: the draft lives in this repository, and its SHA-256 values are
sentinels until the 0.2.0 archives exist.

## Release archives

The 0.2.0 distribution is four checksum-pinned Unix tarballs, one per
compiler host, each carrying that host's compiler and every 0.2.0 runtime
shell. Windows `.zip` archives are a later release.

| Host triple | Archive display name |
| --- | --- |
| `aarch64-linux` | `linux-arm64` |
| `x86_64-linux` | `linux-x64` |
| `aarch64-darwin` | `macos-arm64` |
| `x86_64-darwin` | `macos-x64` |

Archive name: `wasmlight-<version>-<display>.tar.gz`. Checksum manifest:
`wasmlight-<version>-checksums.txt`, GNU `sha256sum` syntax (`<digest>`
two spaces `<basename>`), matching lwpt. Homebrew pins those SHA-256
values ([Checksum Requirements](https://docs.brew.sh/Checksum-Requirements)).

Unpacked layout:

```text
wasmlight-<version>-<display>/
  wasmlight
  MANIFEST
  README.md
  share/wasmlight/shells/<triple>/shell
  share/wasmlight/shells/<triple>/META
```

`MANIFEST` records version, host triple, display name, catalog kind
(`live` or `fixture`), the four shell triples, and per-file SHA-256
digests. Catalog `fixture` is the CI structural placeholder set; a
published 0.2.0 archive must be `live`.

The 0.2.0 shell triples are `aarch64-linux`, `x86_64-linux`,
`aarch64-darwin`, and `x86_64-darwin`. Each `shell` file must be a 64-bit
little-endian ELF or Mach-O image for that triple. AppleDouble names
(`._*`, `.DS_Store`) are forbidden.

Pack and verify from the repo root (InstantFPC, `Wasm.Distro` on the unit
path):

```bash
instantfpc -Fusource/units -Fisource/units scripts/pack-release.pas \
  --compiler ./build/wasmlight --out dist --catalog build/shells
instantfpc -Fusource/units -Fisource/units scripts/verify-archive.pas \
  --archive dist/wasmlight-<version>-<display>.tar.gz \
  --checksums dist/wasmlight-<version>-checksums.txt
```

Same-host verify runs `--version` (and compile gates, when present) on the
packed compiler. `--compiler` is only a foreign-host fallback.
`--synthesize-catalog` builds structural placeholder shells so the packer
and verifier can run before live shells exist. `--require-compile` makes
the compile gates mandatory.

CI on each Unix host packs that host's archive and verifies version,
manifest, checksums, and shell structure. When `wasmlight compile` can
emit a native executable, the same job also compiles one no-import
module for every target and checks image magic, then executes only the
host-native output. That is four structural emissions plus one native
run per host — not a 16-cell execution matrix. Until native emission
ships, verify records that the compile CLI is present and defers those
gates.

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
6. On each of the four Unix compiler hosts, pack a live-catalog archive
   and merge the four lines into `wasmlight-<version>-checksums.txt`.
   Attach the four tarballs and the checksums file to the GitHub Release
   created by `/create-release`. Do not add a second tag-triggered
   publisher.
7. After the assets exist, copy
   [packaging/homebrew/wasmlight.rb](../packaging/homebrew/wasmlight.rb)
   into `frostney/homebrew-tap` with the checksums from that manifest.
   Until then the formula is a draft and `brew install frostney/tap/wasmlight`
   is not a supported install.

## Versioning

SemVer, with the tier seam and the embedding API as the compatibility
surface. Which execution tier ran a function is an implementation detail
and never a breaking change — that is the point of
[ADR-0001](adr/0001-tiered-execution-seam.md). A behavioural difference
between tiers is a bug fix, not a compatibility event.

Pre-1.0, the minor version may break the embedding API; the changelog
says so explicitly when it does.
