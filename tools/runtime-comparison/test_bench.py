#!/usr/bin/env python3

import unittest
from pathlib import Path

from bench import (
    ALL_RUNTIME_KEYS,
    DEFAULT_WORKLOADS,
    GC_RUNTIME_KEYS,
    INTERRUPT_DEADLINE_SECONDS,
    INTERRUPTION_MECHANISMS,
    INTERRUPTION_UNAVAILABLE,
    PROFILE_RUNTIME_ORDER,
    WAZERO_INTERRUPTIBLE_CACHE,
    WORKLOAD_DIR,
    WORKLOAD_SPECS,
    configs,
    render_markdown,
)


class WorkloadRegistryTests(unittest.TestCase):
    def test_every_registered_workload_has_a_source_and_wasmlight_support(self) -> None:
        self.assertEqual(tuple(WORKLOAD_SPECS), DEFAULT_WORKLOADS)
        for workload, spec in WORKLOAD_SPECS.items():
            self.assertTrue((WORKLOAD_DIR / f"{workload}.wat").is_file())
            self.assertIn("wasmlight", spec.runtime_keys)

    def test_gc_uses_current_parser_and_only_verified_runtimes(self) -> None:
        spec = WORKLOAD_SPECS["gc"]
        self.assertEqual("wasm-tools", spec.assembler)
        self.assertEqual(GC_RUNTIME_KEYS, spec.runtime_keys)
        self.assertNotEqual(ALL_RUNTIME_KEYS, spec.runtime_keys)

    def test_gc_configs_omit_unsupported_runtimes(self) -> None:
        artifacts = {
            "module": Path("gc.wasm"),
            "wasmlight": Path("gc.waot"),
            "wasmtime": Path("gc.cwasm"),
            "wasmer": None,
            "wasmedge": None,
            "wamr": None,
        }
        self.assertEqual(
            ("wasmlight-aot", "wasmtime-aot", "wasmlight-interp"),
            tuple(config.key for config in configs("gc", artifacts, Path("wasmlight"))),
        )

    def test_markdown_marks_capability_gaps_as_unavailable(self) -> None:
        result = {
            "measured_at": "2026-08-15T00:00:00Z",
            "git": {"commit": "1" * 40},
            "host": {"model": "test", "cpu": "test", "architecture": "arm64"},
            "profiles": ("best",),
            "workloads": ("startup", "gc"),
            "versions": {"wasmlight": "test", "Wasmtime": "test", "Wasmer": "test"},
            "results": [
                {
                    "profile": "best",
                    "workload": "startup",
                    "runtime": "wasmlight",
                    "median_ms": 2.0,
                },
                {
                    "profile": "best",
                    "workload": "startup",
                    "runtime": "Wasmtime",
                    "median_ms": 3.0,
                },
                {
                    "profile": "best",
                    "workload": "startup",
                    "runtime": "Wasmer",
                    "median_ms": 4.0,
                },
                {
                    "profile": "best",
                    "workload": "gc",
                    "runtime": "wasmlight",
                    "median_ms": 20.0,
                },
                {
                    "profile": "best",
                    "workload": "gc",
                    "runtime": "Wasmtime",
                    "median_ms": 10.0,
                },
            ],
        }
        markdown = render_markdown(result)
        self.assertIn("| gc | 20.000 (1.00x) | 10.000 (2.00x) | — |", markdown)


def loop_artifacts(interruptible: bool) -> dict:
    artifacts = {
        "module": Path("loop.wasm"),
        "wasmlight": Path("loop.waot"),
        "wasmtime": Path("loop.cwasm"),
        "wasmer": Path("loop.wasmu"),
        "wasmedge": Path("loop.aot.wasm"),
        "wamr": Path("loop.aot"),
    }
    if interruptible:
        artifacts["wasmtime-epoch"] = Path("loop.epoch.cwasm")
        artifacts["wasmedge-interruptible"] = Path("loop.interruptible.aot.wasm")
    return artifacts


class InterruptibleProfileTests(unittest.TestCase):
    def interruptible(self, workload: str, artifacts: dict) -> dict:
        return {
            config.key: config
            for config in configs(workload, artifacts, Path("wasmlight"))
            if config.profile == "interruptible"
        }

    def test_peers_run_with_their_interruption_checks_armed(self) -> None:
        selected = self.interruptible("loop", loop_artifacts(True))
        self.assertEqual(
            ["wasmlight-aot-interruptible", "wasmtime-aot-epoch",
             "wasmedge-aot-interruptible", "wazero-compiler-timeout"],
            list(selected),
        )
        deadline = str(INTERRUPT_DEADLINE_SECONDS)
        self.assertEqual(
            ("wasmtime", "run", "--allow-precompiled", "-W",
             f"epoch-interruption=y,timeout={deadline}s", "loop.epoch.cwasm"),
            selected["wasmtime-aot-epoch"].command,
        )
        self.assertEqual(
            ("wasmedge", "run", "--run-mode=aot", "--time-limit",
             str(INTERRUPT_DEADLINE_SECONDS * 1000), "loop.interruptible.aot.wasm"),
            selected["wasmedge-aot-interruptible"].command,
        )
        self.assertEqual(
            ("wazero", "run", "-cachedir", str(WAZERO_INTERRUPTIBLE_CACHE),
             "-timeout", f"{deadline}s", "loop.wasm"),
            selected["wazero-compiler-timeout"].command,
        )
        # wasmlight is measured exactly as in the best profile.
        best = {c.key: c for c in configs("loop", loop_artifacts(True), Path("wasmlight"))}
        self.assertEqual(
            best["wasmlight-aot"].command,
            selected["wasmlight-aot-interruptible"].command,
        )

    def test_profile_order_matches_the_measured_runtimes(self) -> None:
        runtimes = {c.runtime for c in self.interruptible("loop", loop_artifacts(True)).values()}
        self.assertEqual(set(PROFILE_RUNTIME_ORDER["interruptible"]), runtimes)
        self.assertEqual(set(INTERRUPTION_MECHANISMS), runtimes)
        self.assertFalse(runtimes & set(INTERRUPTION_UNAVAILABLE))

    def test_gc_measures_only_its_verified_runtimes(self) -> None:
        artifacts = {
            "module": Path("gc.wasm"),
            "wasmlight": Path("gc.waot"),
            "wasmtime": Path("gc.cwasm"),
            "wasmer": None,
            "wasmedge": None,
            "wamr": None,
            "wasmtime-epoch": Path("gc.epoch.cwasm"),
            "wasmedge-interruptible": None,
        }
        self.assertEqual(
            ["wasmlight-aot-interruptible", "wasmtime-aot-epoch"],
            list(self.interruptible("gc", artifacts)),
        )

    def test_absent_when_the_profile_was_not_prepared(self) -> None:
        self.assertEqual({}, self.interruptible("loop", loop_artifacts(False)))

    def test_markdown_names_each_mechanism_and_each_gap(self) -> None:
        result = {
            "measured_at": "2026-09-27T00:00:00Z",
            "git": {"commit": "1" * 40},
            "host": {"model": "test", "cpu": "test", "architecture": "x86_64"},
            "profiles": ("interruptible",),
            "workloads": ("loop",),
            "versions": {"wasmlight": "test"},
            "results": [
                {"profile": "interruptible", "workload": "loop",
                 "runtime": "wasmlight", "median_ms": 30.0},
                {"profile": "interruptible", "workload": "loop",
                 "runtime": "Wasmtime", "median_ms": 60.0},
            ],
        }
        markdown = render_markdown(result)
        self.assertIn("## Interruptible", markdown)
        self.assertIn("| loop | 30.000 (1.00x) | 60.000 (0.50x) | — | — |", markdown)
        for runtime in (*INTERRUPTION_MECHANISMS, *INTERRUPTION_UNAVAILABLE):
            self.assertIn(f"- {runtime}:", markdown)


if __name__ == "__main__":
    unittest.main()
