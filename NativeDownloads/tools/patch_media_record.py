"""Guarded observation after the native media-key record is appended.

The displaced instruction is `ldp x29, x30, [sp, #0x20]`; after the thunk the
original instruction and the original tail branch are executed. The cave reads
only bounded process memory and never changes native arguments or results.
"""
import struct
from pathlib import Path

import patch_export_boundaries as original

# x21 points at the key-record vector, x22 is the previous byte size, and x20
# is the 20-byte file identifier. The record is [20-byte derived IV][16-byte
# key] and starts at [x21] + x22.
POINT = ('MediaRecord', 0x1020fd5f0, 0x100023100,
         bytes.fromhex('fd7b42a9'), 7)


def patch(data):
    saved = original.POINTS
    try:
        original.POINTS = [POINT]
        return original.patch(data)
    finally:
        original.POINTS = saved


def header():
    saved = original.POINTS
    try:
        original.POINTS = [POINT]
        return original.header()
    finally:
        original.POINTS = saved
