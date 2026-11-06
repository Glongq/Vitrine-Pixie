"""Guarded observation at Spotify's native AES-CTR block core."""
import patch_export_boundaries as original
POINT=('AesCtr',0x1045abc28,0x100023300,bytes.fromhex('c00640ad'),8)
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
