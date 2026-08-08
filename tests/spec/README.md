# Spec testsuite

This directory will hold the configuration for the upstream
[WebAssembly/testsuite](https://github.com/WebAssembly/testsuite)
conformance harness. **Nothing is wired up yet** — there is no execution
tier to point it at. See [../../docs/testing.md](../../docs/testing.md)
for the intended shape and [../../docs/roadmap.md](../../docs/roadmap.md)
for where it sits in the order of work.

The corpus is fetched, never vendored: `tests/spec/testsuite/` is
gitignored, and only harness configuration is committed here.
