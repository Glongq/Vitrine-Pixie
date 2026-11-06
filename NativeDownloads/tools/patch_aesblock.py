"""Guarded observation at Spotify's native block-AES core."""
import patch_export_boundaries as original
POINT=('AesBlock',0x106d3e9ec,0x100023400,bytes.fromhex('a10a40ad'),9)
def patch(data):
    saved=original.POINTS
    try:
        original.POINTS=[POINT]
        return original.patch(data)
    finally: original.POINTS=saved
def header():
    saved=original.POINTS
    try:
        original.POINTS=[POINT]
        return original.header()
    finally: original.POINTS=saved
