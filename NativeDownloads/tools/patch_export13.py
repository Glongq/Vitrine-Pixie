"""Guarded observation at the native cached-media-key setter.

This build is applied on top of experimental12, which already contains the
MediaKeyPath entry observation. Only the new 28-byte key-record boundary is
installed here; both constants are still emitted for the compiled companion.
"""
import patch_export_boundaries as original

PATH_POINT = ('MediaKeyPath', 0x103594d70, 0x100022900,
              bytes.fromhex('ff4305d1fc6f0fa9fa6710a9f85f11a9'), 4)
BLOB_POINT = ('MediaKeyBlob', 0x1020fd560, 0x100022b00,
              bytes.fromhex('f657bda9f44f01a9fd7b02a9fd830091'), 5)


def patch(data):
    saved = original.POINTS
    try:
        original.POINTS = [BLOB_POINT]
        return original.patch(data)
    finally:
        original.POINTS = saved


def header():
    saved = original.POINTS
    try:
        original.POINTS = [PATH_POINT, BLOB_POINT]
        return original.header()
    finally:
        original.POINTS = saved
