#!/usr/bin/env python3
"""Pack a temporary WSH1 runtime-shell image for CI audits.

Matches Wasm.Shell.Payload.WriteShellPayload: magic WSH1, format version 1,
flags 0, four little-endian u32 section lengths, then the section bytes.
This helper leaves the connector-plan and capability-set sections empty.

  scripts/write-wshl-payload.py [--write-fixture-wasm] WASM NATIVE WSHL

NATIVE may be '-' for an empty native section.
"""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys

# (module (memory 1) (func (export "_start")) (export "memory" (memory 0)))
FIXTURE_WASM = bytes.fromhex(
    "0061736d01000000010401600000030201000503010001"
    "071302066d656d6f72790200065f737461727400000a040102000b"
)

WSHL_MAGIC = b"WSH1"
WSHL_FORMAT_VERSION = 1
WSHL_FLAGS = 0


def pack(module: bytes, native: bytes) -> bytes:
    return (
        WSHL_MAGIC
        + struct.pack(
            "<HHIIII",
            WSHL_FORMAT_VERSION,
            WSHL_FLAGS,
            len(module),
            len(native),
            0,
            0,
        )
        + module
        + native
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write-fixture-wasm",
        action="store_true",
        help="write the audit's empty-_start module to WASM before packing",
    )
    parser.add_argument("wasm", type=pathlib.Path)
    parser.add_argument("native")
    parser.add_argument("wshl", type=pathlib.Path)
    args = parser.parse_args(argv)

    if args.write_fixture_wasm:
        args.wasm.write_bytes(FIXTURE_WASM)
        module = FIXTURE_WASM
    else:
        module = args.wasm.read_bytes()

    if args.native == "-":
        native = b""
    else:
        native = pathlib.Path(args.native).read_bytes()

    args.wshl.write_bytes(pack(module, native))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
