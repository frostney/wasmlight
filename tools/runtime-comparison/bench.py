#!/usr/bin/env python3
"""Reproducible command-level comparison of wasmlight and peer runtimes."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator


ROOT = Path(__file__).resolve().parents[2]
WORKLOAD_DIR = ROOT / "tools" / "runtime-comparison" / "workloads"
BUILD_DIR = ROOT / "build" / "runtime-comparison"
MODULE_DIR = BUILD_DIR / "modules"
ARTIFACT_DIR = BUILD_DIR / "artifacts"
WAZERO_CACHE = BUILD_DIR / "wazero-cache"
LOCK_PATH = Path("/tmp/wasmlight-perf-gate.lock")
ALL_RUNTIME_KEYS = frozenset(
    ("wasmlight", "wasmtime", "wasmer", "wasmedge", "wamr", "wazero", "wasm3")
)
GC_RUNTIME_KEYS = frozenset(("wasmlight", "wasmtime"))
SIMD_RUNTIME_KEYS = frozenset(
    ("wasmlight", "wasmtime", "wasmer", "wasmedge", "wazero")
)
HOST_CALL_RUNTIME_KEYS = frozenset(
    ("wasmlight", "wasmtime", "wasmer", "wasmedge", "wamr", "wazero")
)
PROFILE_RUNTIME_ORDER = {
    "best": (
        "wasmlight",
        "Wasmtime",
        "Wasmer",
        "WasmEdge",
        "WAMR",
        "wazero",
        "wasm3",
    ),
    "interpreter": ("wasmlight", "WasmEdge", "WAMR", "wazero", "wasm3"),
}


@dataclass(frozen=True)
class WorkloadSpec:
    description: str
    assembler: str = "wat2wasm"
    runtime_keys: frozenset[str] = ALL_RUNTIME_KEYS


WORKLOAD_SPECS = {
    "startup": WorkloadSpec("process, artifact load, instantiation, and tiny loop"),
    "loop": WorkloadSpec("300M dependent scalar integer loop iterations"),
    "fib": WorkloadSpec("recursive fib(35) direct calls"),
    "memory": WorkloadSpec("50M paired varying-address i32 stores and loads"),
    "memory-load": WorkloadSpec("100M cache-resident varying-address i32 loads"),
    "memory-store": WorkloadSpec("100M cache-resident varying-address i32 stores"),
    "call": WorkloadSpec("50M cross-function direct calls"),
    "memory-grow": WorkloadSpec("4,096 one-page linear-memory growth operations"),
    "gc": WorkloadSpec(
        "2M bounded-live-set GC struct allocations",
        assembler="wasm-tools",
        runtime_keys=GC_RUNTIME_KEYS,
    ),
    "simd": WorkloadSpec(
        "1M dependent i32x4 SIMD iterations", runtime_keys=SIMD_RUNTIME_KEYS
    ),
    "host-call": WorkloadSpec(
        "1M WASI monotonic-clock host calls", runtime_keys=HOST_CALL_RUNTIME_KEYS
    ),
}
DEFAULT_WORKLOADS = tuple(WORKLOAD_SPECS)


@dataclass(frozen=True)
class RuntimeConfig:
    key: str
    runtime: str
    profile: str
    tier: str
    command: tuple[str, ...]
    artifact: Path | None = None
    note: str = ""


def command_output(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return completed.stdout.strip()


def run_checked(command: tuple[str, ...] | list[str], timeout: int = 180) -> None:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=timeout,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip()
        raise RuntimeError(
            f"command exited {completed.returncode}: {' '.join(command)}"
            + (f"\n{detail}" if detail else "")
        )


def require_commands(wasmlight: Path) -> None:
    required = (
        "wat2wasm",
        "wasm-tools",
        "wasmtime",
        "wasmer",
        "wasmedge",
        "iwasm",
        "wazero",
        "wasm3",
    )
    missing = [name for name in required if shutil.which(name) is None]
    if not wasmlight.is_file():
        missing.append(f"{wasmlight} (run `lwpt build --mode release`)")
    if missing:
        raise RuntimeError("missing benchmark prerequisites: " + ", ".join(missing))


def assemble(workload: str) -> Path:
    source = WORKLOAD_DIR / f"{workload}.wat"
    module = MODULE_DIR / f"{workload}.wasm"
    spec = WORKLOAD_SPECS[workload]
    if spec.assembler == "wasm-tools":
        run_checked(["wasm-tools", "parse", str(source), "-o", str(module)])
    else:
        run_checked(["wat2wasm", str(source), "-o", str(module)])
    run_checked(["wasm-tools", "validate", "--features", "all", str(module)])
    return module


def prepare(
    workloads: tuple[str, ...], wasmlight: Path
) -> dict[str, dict[str, Path | None]]:
    MODULE_DIR.mkdir(parents=True, exist_ok=True)
    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    WAZERO_CACHE.mkdir(parents=True, exist_ok=True)
    outputs: dict[str, dict[str, Path | None]] = {}
    for workload in workloads:
        spec = WORKLOAD_SPECS[workload]
        module = assemble(workload)
        artifacts = {
            "module": module,
            "wasmlight": ARTIFACT_DIR / f"{workload}.waot",
            "wasmtime": ARTIFACT_DIR / f"{workload}.cwasm",
            "wasmer": ARTIFACT_DIR / f"{workload}.wasmu",
            "wasmedge": ARTIFACT_DIR / f"{workload}.aot.wasm",
            "wamr": ARTIFACT_DIR / f"{workload}.aot",
        }
        if "wasmlight" in spec.runtime_keys:
            run_checked([
                str(wasmlight),
                "aot",
                str(module),
                "-o",
                str(artifacts["wasmlight"]),
            ])
        else:
            artifacts["wasmlight"] = None
        if "wasmtime" in spec.runtime_keys:
            run_checked([
                "wasmtime",
                "compile",
                "-o",
                str(artifacts["wasmtime"]),
                str(module),
            ])
        else:
            artifacts["wasmtime"] = None
        if "wasmer" in spec.runtime_keys:
            run_checked([
                "wasmer",
                "compile",
                "-q",
                "--enable-simd",
                "-o",
                str(artifacts["wasmer"]),
                str(module),
            ])
        else:
            artifacts["wasmer"] = None
        if "wasmedge" in spec.runtime_keys:
            run_checked([
                "wasmedge",
                "compile",
                str(module),
                str(artifacts["wasmedge"]),
            ])
        else:
            artifacts["wasmedge"] = None
        if "wamr" in spec.runtime_keys and shutil.which("wamrc") is not None:
            wamr_targets = {
                "x86_64": "x86_64",
                "AMD64": "x86_64",
                "arm64": "aarch64",
                "aarch64": "aarch64",
            }
            wamr_target = wamr_targets.get(platform.machine())
            if wamr_target is None:
                raise RuntimeError(f"no WAMR AOT target mapping for {platform.machine()}")
            run_checked([
                "wamrc",
                f"--target={wamr_target}",
                "-o",
                str(artifacts["wamr"]),
                str(module),
            ])
        else:
            artifacts["wamr"] = None
        if "wazero" in spec.runtime_keys:
            run_checked([
                "wazero",
                "compile",
                "-cachedir",
                str(WAZERO_CACHE),
                str(module),
            ])
        outputs[workload] = artifacts
    return outputs


def configs(
    workload: str,
    artifacts: dict[str, Path | None],
    wasmlight: Path,
) -> tuple[RuntimeConfig, ...]:
    spec = WORKLOAD_SPECS[workload]
    assert artifacts["module"] is not None
    module = str(artifacts["module"])
    wamr_artifact = artifacts["wamr"]
    if wamr_artifact is not None:
        wamr_tier = "LLVM AOT"
        wamr_command = ("iwasm", str(wamr_artifact))
        wamr_note = "The module was precompiled with the pinned wamrc release."
    else:
        wamr_tier = "interpreter"
        wamr_command = ("iwasm", "--interp", module)
        wamr_note = (
            "No runnable wamrc was available on this host, so AOT is not represented."
        )
    selected = []
    if "wasmlight" in spec.runtime_keys:
        assert artifacts["wasmlight"] is not None
        selected.append(RuntimeConfig(
            "wasmlight-aot",
            "wasmlight",
            "best",
            "AOT",
            (
                str(wasmlight),
                "run",
                "--aot",
                str(artifacts["wasmlight"]),
                module,
            ),
            artifacts["wasmlight"],
        ))
    if "wasmtime" in spec.runtime_keys:
        assert artifacts["wasmtime"] is not None
        selected.append(RuntimeConfig(
            "wasmtime-aot",
            "Wasmtime",
            "best",
            "Cranelift AOT",
            ("wasmtime", "run", "--allow-precompiled", str(artifacts["wasmtime"])),
            artifacts["wasmtime"],
        ))
    if "wasmer" in spec.runtime_keys:
        assert artifacts["wasmer"] is not None
        selected.append(RuntimeConfig(
            "wasmer-aot",
            "Wasmer",
            "best",
            "Cranelift AOT",
            ("wasmer", "run", "-q", str(artifacts["wasmer"])),
            artifacts["wasmer"],
        ))
    if "wasmedge" in spec.runtime_keys:
        assert artifacts["wasmedge"] is not None
        selected.append(RuntimeConfig(
            "wasmedge-aot",
            "WasmEdge",
            "best",
            "LLVM AOT",
            ("wasmedge", "run", "--run-mode=aot", str(artifacts["wasmedge"])),
            artifacts["wasmedge"],
        ))
    if "wamr" in spec.runtime_keys:
        selected.append(RuntimeConfig(
            "wamr-best",
            "WAMR",
            "best",
            wamr_tier,
            wamr_command,
            wamr_artifact,
            note=wamr_note,
        ))
    if "wazero" in spec.runtime_keys:
        selected.append(RuntimeConfig(
            "wazero-compiler",
            "wazero",
            "best",
            "compiler cache",
            ("wazero", "run", "-cachedir", str(WAZERO_CACHE), module),
            note="The native-code cache was populated before measurement.",
        ))
    if "wasm3" in spec.runtime_keys:
        selected.append(RuntimeConfig(
            "wasm3-interp-best",
            "wasm3",
            "best",
            "interpreter",
            ("wasm3", module),
            note="wasm3 is interpreter-only.",
        ))
    if "wasmlight" in spec.runtime_keys:
        selected.append(RuntimeConfig(
            "wasmlight-interp",
            "wasmlight",
            "interpreter",
            "interpreter",
            (str(wasmlight), "run", "--no-aot", module),
        ))
    if "wasmedge" in spec.runtime_keys:
        selected.append(RuntimeConfig(
            "wasmedge-interp",
            "WasmEdge",
            "interpreter",
            "interpreter",
            ("wasmedge", "run", "--run-mode=interpreter", module),
        ))
    if "wamr" in spec.runtime_keys:
        selected.append(RuntimeConfig(
            "wamr-interp",
            "WAMR",
            "interpreter",
            "interpreter",
            ("iwasm", "--interp", module),
        ))
    if "wazero" in spec.runtime_keys:
        selected.append(RuntimeConfig(
            "wazero-interp",
            "wazero",
            "interpreter",
            "interpreter",
            ("wazero", "run", "-interpreter", module),
        ))
    if "wasm3" in spec.runtime_keys:
        selected.append(RuntimeConfig(
            "wasm3-interp",
            "wasm3",
            "interpreter",
            "interpreter",
            ("wasm3", module),
        ))
    return tuple(selected)


@contextlib.contextmanager
def performance_lock() -> Iterator[None]:
    LOCK_PATH.touch(exist_ok=True)
    with LOCK_PATH.open("r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def measure(command: tuple[str, ...]) -> float:
    started = time.perf_counter_ns()
    run_checked(command)
    return (time.perf_counter_ns() - started) / 1_000_000.0


def runtime_versions(wasmlight: Path) -> dict[str, str]:
    version_commands = {
        "wasmlight": [str(wasmlight), "--version"],
        "Wasmtime": ["wasmtime", "--version"],
        "Wasmer": ["wasmer", "--version"],
        "WasmEdge": ["wasmedge", "--version"],
        "WAMR": ["iwasm", "--version"],
        "wazero": ["wazero", "version"],
        "wasm3": ["wasm3", "--version"],
    }
    versions = {}
    for name, command in version_commands.items():
        output = command_output(command)
        versions[name] = output.splitlines()[0].strip()
    return versions


def host_metadata() -> dict[str, str]:
    if sys.platform == "darwin":
        cpu = command_output(["sysctl", "-n", "machdep.cpu.brand_string"])
        model = command_output(["sysctl", "-n", "hw.model"])
    else:
        cpu = platform.processor() or platform.machine()
        model = os.environ.get("ImageOS") or platform.node()
    return {
        "os": platform.platform(),
        "architecture": platform.machine(),
        "cpu": cpu,
        "model": model,
        "python": platform.python_version(),
    }


def git_metadata(source_commit: str | None) -> dict[str, str]:
    return {
        "commit": source_commit or command_output(["git", "rev-parse", "HEAD"]),
        "remote_default": command_output(["git", "rev-parse", "origin/main"]),
        "branch": command_output(["git", "branch", "--show-current"]),
    }


def summarize(samples: list[float]) -> dict[str, float | list[float]]:
    median = statistics.median(samples)
    minimum = min(samples)
    maximum = max(samples)
    return {
        "samples_ms": [round(value, 3) for value in samples],
        "median_ms": round(median, 3),
        "min_ms": round(minimum, 3),
        "max_ms": round(maximum, 3),
        "spread_percent": round((maximum - minimum) / median * 100.0, 2),
    }


def render_markdown(result: dict) -> str:
    lines = [
        "# Runtime comparison results",
        "",
        f"Measured `{result['measured_at']}` at `{result['git']['commit'][:12]}` on "
        f"{result['host']['model']} ({result['host']['cpu']}, {result['host']['architecture']}).",
        "",
        "Each cell is median wall-clock process time in milliseconds. Compilation is outside "
        "the timer. `x` is `wasmlight / runtime`: above 1 means the peer was faster; below 1 "
        "means wasmlight was faster.",
        "",
    ]
    for profile in result["profiles"]:
        lines.extend((f"## {profile.title()}", ""))
        rows = [row for row in result["results"] if row["profile"] == profile]
        runtime_order = PROFILE_RUNTIME_ORDER[profile]
        lines.append("| Workload | " + " | ".join(runtime_order) + " |")
        lines.append("| --- | " + " | ".join("---:" for _ in runtime_order) + " |")
        for workload in result["workloads"]:
            workload_rows = {row["runtime"]: row for row in rows if row["workload"] == workload}
            baseline = workload_rows["wasmlight"]["median_ms"]
            cells = []
            for runtime in runtime_order:
                row = workload_rows.get(runtime)
                if row is None:
                    cells.append("—")
                else:
                    ratio = baseline / row["median_ms"]
                    cells.append(f"{row['median_ms']:.3f} ({ratio:.2f}x)")
            lines.append(f"| {workload} | " + " | ".join(cells) + " |")
        lines.append("")
    lines.extend((
        "## Runtime versions",
        "",
        "| Runtime | Version |",
        "| --- | --- |",
    ))
    for runtime, version in result["versions"].items():
        lines.append(f"| {runtime} | `{version}` |")
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=7)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument(
        "--profile",
        action="append",
        choices=("best", "interpreter"),
        dest="profiles",
    )
    parser.add_argument(
        "--workload",
        action="append",
        choices=tuple(WORKLOAD_SPECS),
        dest="workloads",
    )
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument(
        "--wasmlight",
        type=Path,
        default=ROOT / "build" / "wasmlight",
        help="wasmlight executable to compile and run",
    )
    parser.add_argument(
        "--source-commit",
        help="commit recorded for --wasmlight (defaults to the checkout HEAD)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.samples < 1 or args.warmups < 0:
        raise RuntimeError("--samples must be positive and --warmups non-negative")
    profiles = tuple(args.profiles or ("best", "interpreter"))
    workloads = tuple(args.workloads or DEFAULT_WORKLOADS)
    wasmlight = args.wasmlight.resolve()
    require_commands(wasmlight)
    artifacts_by_workload = prepare(workloads, wasmlight)
    if args.prepare_only:
        print(f"prepared and validated {len(workloads)} workloads in {BUILD_DIR}")
        return 0

    result = {
        "schema_version": 1,
        "measured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "method": {
            "boundary": "process start through self-checking WASI proc_exit",
            "timer": "time.perf_counter_ns",
            "compilation_timed": False,
            "warmups": args.warmups,
            "samples": args.samples,
            "schedule": "rotated round-robin within each workload and profile",
            "lock": str(LOCK_PATH),
        },
        "host": host_metadata(),
        "git": git_metadata(args.source_commit),
        "versions": runtime_versions(wasmlight),
        "wasmlight_executable": str(wasmlight),
        "profiles": profiles,
        "workloads": workloads,
        "modules": {},
        "results": [],
    }
    for workload, artifacts in artifacts_by_workload.items():
        assert artifacts["module"] is not None
        module_bytes = artifacts["module"].read_bytes()
        result["modules"][workload] = {
            "path": str(artifacts["module"].relative_to(ROOT)),
            "bytes": len(module_bytes),
            "sha256": hashlib.sha256(module_bytes).hexdigest(),
            "description": WORKLOAD_SPECS[workload].description,
            "assembler": WORKLOAD_SPECS[workload].assembler,
            "supported_runtimes": sorted(WORKLOAD_SPECS[workload].runtime_keys),
        }

    with performance_lock():
        for profile in profiles:
            for workload in workloads:
                selected = [
                    config
                    for config in configs(
                        workload, artifacts_by_workload[workload], wasmlight
                    )
                    if config.profile == profile
                ]
                for config in selected:
                    for _ in range(args.warmups):
                        run_checked(config.command)
                samples_by_key = {config.key: [] for config in selected}
                for sample_index in range(args.samples):
                    offset = sample_index % len(selected)
                    ordered = selected[offset:] + selected[:offset]
                    for config in ordered:
                        samples_by_key[config.key].append(measure(config.command))
                for config in selected:
                    summary = summarize(samples_by_key[config.key])
                    result["results"].append({
                        "workload": workload,
                        "key": config.key,
                        "runtime": config.runtime,
                        "profile": config.profile,
                        "tier": config.tier,
                        "command": list(config.command),
                        "artifact_bytes": config.artifact.stat().st_size if config.artifact else None,
                        "note": config.note,
                        **summary,
                    })
                print(f"measured {profile}/{workload}", flush=True)

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    json_path = BUILD_DIR / "results.json"
    markdown_path = BUILD_DIR / "results.md"
    json_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    markdown_path.write_text(render_markdown(result), encoding="utf-8")
    print(markdown_path.read_text(encoding="utf-8"))
    print(f"raw results: {json_path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"runtime comparison: {error}", file=sys.stderr)
        raise SystemExit(1)
