"""wasi-testsuite runtime adapter for wasmlight.

Loaded as a module by the upstream test runner (tests/spec/wasi/test-runner),
following its adapter protocol (get_name, get_version, get_wasi_versions,
get_wasi_worlds, compute_argv, get_timeout_seconds).

$WASMLIGHT selects the binary (default: build/wasmlight relative to the repo
root). $WASI_TESTSUITE_TIMEOUT sets the per-test timeout in seconds (default
30); the runner records an expired timeout as a test failure.

Every test that declares a fixture root gets a fresh scratch copy of it, so
no test can change the fixtures another test sees, and the fetched corpus is
never written to.
"""

import atexit
import os
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[2]
WASMLIGHT = shlex.split(
    os.getenv("WASMLIGHT", str(_REPO_ROOT / "build" / "wasmlight")),
    posix=os.name != "nt",
)

_SCRATCH_PARENT = Path(tempfile.mkdtemp(prefix="wasmlight-wasi-testsuite-"))
atexit.register(shutil.rmtree, _SCRATCH_PARENT, ignore_errors=True)


def get_name() -> str:
    return "wasmlight"


def get_version() -> str:
    result = subprocess.run(WASMLIGHT[0:1] + ["--version"],
                            encoding="UTF-8", capture_output=True, check=True)
    # "wasmlight 0.2.1"
    return result.stdout.split()[1]


def get_wasi_versions() -> List[str]:
    return ["wasm32-wasip1"]


def get_wasi_worlds() -> List[str]:
    return ["wasi:cli/command"]


def get_timeout_seconds() -> float:
    return float(os.getenv("WASI_TESTSUITE_TIMEOUT", "30"))


def scratch_copy(root: Path) -> Path:
    """Copy a fixture root into a fresh, private directory for one test."""
    dest = Path(tempfile.mkdtemp(dir=_SCRATCH_PARENT)) / root.name
    shutil.copytree(root, dest, symlinks=True)
    return dest


def compute_argv(test_path: str,
                 args_env_root: Tuple[List[str], Dict[str, str], Optional[Path]],
                 proposals: List[str],
                 wasi_world: str,
                 wasi_version: str) -> List[str]:
    del proposals, wasi_world, wasi_version  # P1 command modules only
    args, env, root = args_env_root
    argv = list(WASMLIGHT) + ["run"]
    for key, value in env.items():
        argv += ["--env", f"{key}={value}"]
    if root:
        argv += ["--dir", f"/={scratch_copy(Path(root))}"]
    argv += ["--", test_path]
    argv += args
    return argv
