# Deployment

## Executive Summary

- `0.1.0` is wasmlight's first release: the completed pinned-Core-3 runtime,
  its three execution tiers on 64-bit UNIX, the interpreter on every supported
  target, and the current deny-by-default WASI Preview 1 subset. That
  release has no binary assets.
- Releases go through the `create-release` skill: changelog first, then
  an unprefixed SemVer tag matching `[package].version` in `lwpt.toml`.
  There is no second publisher.
- Downstream lwpt projects still consume the runtime as source. From 0.2.0
  the compiler also ships as four checksum-pinned host archives, built by the
  manually dispatched [release-assets.yml](../.github/workflows/release-assets.yml)
  workflow, and through a Homebrew formula that `/create-release` publishes
  to `frostney/homebrew-tap` from
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

`brew install frostney/tap/wasmlight` installs the compiler and its shell
catalog on macOS and Linux once `/create-release` has published a release's
archives and copied the formula into the tap. The formula in this repository
is the template for that step; its SHA-256 values are 64-zero placeholders
filled from the release's checksums file.

## Release archives

The 0.2.0 distribution is four checksum-pinned Unix tarballs, one per
compiler host. Each carries that host's compiler and the runtime shells it
can emit: its own architecture, for both Linux and macOS. Cross-architecture
emission, and with it all-to-all archives, follows in 0.3.0 (#148). Windows
`.zip` archives are a later release.

| Host triple | Archive display name | Shells |
| --- | --- | --- |
| `aarch64-linux` | `linux-arm64` | `aarch64-linux`, `aarch64-darwin` |
| `x86_64-linux` | `linux-x64` | `x86_64-linux`, `x86_64-darwin` |
| `aarch64-darwin` | `macos-arm64` | `aarch64-linux`, `aarch64-darwin` |
| `x86_64-darwin` | `macos-x64` | `x86_64-linux`, `x86_64-darwin` |

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
  share/wasmlight/shells/catalog
  share/wasmlight/shells/<triple>/shell
  share/wasmlight/shells/<triple>/META
```

`MANIFEST` records version, host triple, display name, catalog kind
(`live` or `fixture`), the host's two shell triples, and per-file SHA-256
digests. Catalog `fixture` is the CI structural placeholder set; a
published archive must be `live`. A shell of another architecture, or a
catalog that indexes one, is rejected: the archive would promise a target
its compiler refuses. Each `shell` file must be a 64-bit little-endian ELF
or Mach-O image for its triple. AppleDouble names (`._*`, `.DS_Store`) are
forbidden.

Pack and verify from the repo root (InstantFPC, `Wasm.Distro` on the unit
path). `pack-release` takes exactly one shell source: `--shell
TRIPLE=PATH` once per host shell (live shells, the release path),
`--catalog DIR` (the host shells of an existing live catalog), or
`--synthesize-catalog` (structural placeholders, never a release):

```bash
instantfpc -Fusource/units -Fisource/units scripts/pack-release.pas \
  --compiler ./build/wasmlight --out dist \
  --shell x86_64-linux=./build/wasmlight-shell \
  --shell x86_64-darwin=<x86_64-darwin runner>/wasmlight-shell
instantfpc -Fusource/units -Fisource/units scripts/verify-archive.pas \
  --archive dist/wasmlight-<version>-<display>.tar.gz \
  --checksums dist/wasmlight-<version>-checksums.txt --require-compile
```

`verify-archive` always checks the checksum line, layout, catalog, shell
structure, and every `MANIFEST` hash. On the archive's own host it also
runs the packed compiler: `--version` must match, and a live archive
(or `--require-compile`) runs the compile gates against the packed
catalog. For each shell it compiles a probe whose `_start` calls
`proc_exit(37)`, and checks that the output is that target's ELF or
Mach-O and that its native
payload parses, names that target, and is bound to the archive's shell.
An `aarch64-darwin` image must carry a verifying ad-hoc signature,
because arm64 macOS runs no unsigned code. The Intel `wasmlight-shell` is
linked without a signature, so its `x86_64-darwin` output carries the
appended payload trailer unsigned, which x86-64 macOS runs; any signature
that is present must still verify. Only the host-native output runs, and it must exit 37, so a placeholder
that exits zero cannot pass. The other-OS output is checked structurally
and never executed: four host legs, not a 16-cell execution matrix. A
foreign-architecture `--target` must be refused. On a foreign host the
packed compiler cannot run, so only structure is verified, and
`--require-compile` fails instead. `--complete-set` also requires the
checksums file to list exactly the four host archives.

CI on each Unix host packs a fixture archive and verifies its structure on
every PR and `main` push. That proves the packer, not a release.

### Building the assets

[release-assets.yml](../.github/workflows/release-assets.yml) is the only
asset builder. It is `workflow_dispatch` only, with `ref`, `version`, and
`attach` inputs; there is no tag trigger and no second publisher.

1. `resolve` pins `ref` to one commit and fails unless `version` is
   unprefixed SemVer equal to `[package].version` at that commit.
2. `build` runs on the four native runners (`ubuntu-latest`,
   `ubuntu-24.04-arm`, `macos-latest`, `macos-15-intel`) and builds the
   release-mode compiler and runtime shell with
   `$WASMLIGHT_VERSION_OVERRIDE` set to `version`.
3. `pack` runs on the same four runners. Each packs its host archive from
   its own compiler and shell plus the same-architecture shell built on the
   other OS's runner, then runs `verify-archive --require-compile`.
4. `gather` merges the four checksum lines into
   `wasmlight-<version>-checksums.txt`, checks every archive against it
   with `--complete-set`, and uploads the five files as the
   `wasmlight-<version>-release` workflow artifact.
5. `attach`, only when `attach` is true, uploads those files to the
   existing GitHub release `<version>`. It fails if the release does not
   exist, if the tag names another commit than the one built, or if an
   asset of the same name is already attached; it never replaces an asset.

A dry run against a branch (`attach` false, `version` equal to that
branch's manifest version) exercises the whole pipeline without touching a
release.

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
5. After `/create-release` has created the GitHub release, dispatch
   [release-assets.yml](../.github/workflows/release-assets.yml) with
   `ref` and `version` set to the tag and `attach` true. Its build legs
   stamp the version via `$WASMLIGHT_VERSION_OVERRIDE` and check
   `wasmlight --version`; confirm the run is green and the release lists
   the four archives and `wasmlight-<version>-checksums.txt`.
6. Publish the formula: copy
   [packaging/homebrew/wasmlight.rb](../packaging/homebrew/wasmlight.rb)
   to `Formula/wasmlight.rb` in `frostney/homebrew-tap`, set `version` and
   the four URLs to the release, and replace each placeholder `sha256`
   with that archive's line from the attached checksums file. Then run
   `brew install frostney/tap/wasmlight` and `brew test wasmlight` on
   macOS and Linux; the formula test compiles and runs the exit-37 probe
   and packages the other-OS target.

## Versioning

SemVer, with the tier seam and the embedding API as the compatibility
surface. Which execution tier ran a function is an implementation detail
and never a breaking change — that is the point of
[ADR-0001](adr/0001-tiered-execution-seam.md). A behavioural difference
between tiers is a bug fix, not a compatibility event.

Pre-1.0, the minor version may break the embedding API; the changelog
says so explicitly when it does.
