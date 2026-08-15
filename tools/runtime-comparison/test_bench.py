#!/usr/bin/env python3

import unittest
from pathlib import Path

from bench import (
    ALL_RUNTIME_KEYS,
    DEFAULT_WORKLOADS,
    GC_RUNTIME_KEYS,
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


if __name__ == "__main__":
    unittest.main()
