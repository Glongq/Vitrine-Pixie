"""Guarded observation of the verified native key-store derivation output.

The single `ret` of the 24-byte-key derivation function is redirected to a
small cave that calls the companion helper with the output pointer in x20 and
then returns. No key bytes are read by this thunk; the helper copies only the
32-byte result into bounded process memory.
"""
import struct, subprocess, tempfile
from pathlib import Path
from patch_native_restrictions import layout, branch
from patch_key_request_mode import DLSYM_STUB, _verify_dlsym_binding

UUID = bytes.fromhex("fbce22c17e1b3e0d9be866ff9291943e")
ENTRY = 0x107971180
CAVE = 0x100022f00
EXPECTED = bytes.fromhex("c0035fd6")
SYMBOL = b"SAPObserveMediaOutput\0"


def template():
    asm = f'''.text
.p2align 2
.globl _media_output
_media_output:
 stp x0, x1, [sp, #-0x20]!
 stp x20, x30, [sp, #0x10]
 movn x0, #1
 adr x1, Lname
 .long 0x90000010
 add x16, x16, #0
 blr x16
 cbz x0, Ldone
 mov x16, x0
 mov x0, x20
 blr x16
Ldone:
 ldp x20, x30, [sp, #0x10]
 ldp x0, x1, [sp], #0x20
 ret
Lname:
 .asciz "SAPObserveMediaOutput"
'''
    with tempfile.TemporaryDirectory(prefix='pixie-media-output-') as tmp:
        source = Path(tmp) / 'out.S'
        obj = Path(tmp) / 'out.o'
        source.write_text(asm)
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', 'clang', '-c', '-arch', 'arm64', '-target', 'arm64-apple-ios15.0',
                        '-isysroot', sdk, str(source), '-o', str(obj)], check=True)
        raw = obj.read_bytes()
    cursor = 32
    for _ in range(struct.unpack_from('<I', raw, 16)[0]):
        cmd, size = struct.unpack_from('<II', raw, cursor)
        if cmd == 0x19:
            for n in range(struct.unpack_from('<I', raw, cursor + 64)[0]):
                s = cursor + 72 + n * 80
                if raw[s:s + 16].split(b'\0')[0] != b'__text':
                    continue
                count = struct.unpack_from('<Q', raw, s + 40)[0]
                offset = struct.unpack_from('<I', raw, s + 48)[0]
                if struct.unpack_from('<I', raw, s + 60)[0]:
                    raise ValueError('Unresolved media-output relocation')
                return raw[offset:offset + count]
        cursor += size
    raise ValueError('Media-output code not found')


def trampoline():
    out = bytearray(template())
    symbol = out.index(SYMBOL)
    words = [struct.unpack_from('<I', out, i)[0] for i in range(0, symbol, 4)]
    at = words.index(0x90000010) * 4
    delta = (DLSYM_STUB >> 12) - ((CAVE + at) >> 12)
    if not -(1 << 20) <= delta < (1 << 20):
        raise ValueError('Media-output resolver out of ADRP range')
    struct.pack_into('<I', out, at, 0x90000010 | ((delta & 3) << 29) | (((delta >> 2) & 0x7ffff) << 5))
    struct.pack_into('<I', out, at + 4, 0x91000210 | ((DLSYM_STUB & 4095) << 10))
    if len(out) > 256:
        raise ValueError('Media-output thunk too large')
    return bytes(out)


def patch(data):
    end, first, segments, uuid = layout(data)
    if uuid != UUID:
        raise ValueError('Unsupported media-output UUID')
    _verify_dlsym_binding(data)
    _, vm, _, fo, size, protection = next(s for s in segments if s[0] == b'__TEXT')
    at = fo + ENTRY - vm
    dest = fo + CAVE - vm
    stub = trampoline()
    if not (vm <= ENTRY and ENTRY + 4 <= vm + size and vm <= CAVE and CAVE + len(stub) <= vm + size):
        raise ValueError('Media-output point outside text')
    if protection & 5 != 5 or data[at:at + 4] != EXPECTED:
        raise ValueError('Media-output entry differs')
    if dest < end or dest + len(stub) > first or any(data[dest:dest + len(stub)]):
        raise ValueError('Media-output cave unavailable')
    out = bytearray(data)
    out[dest:dest + len(stub)] = stub
    struct.pack_into('<I', out, at, branch(ENTRY, CAVE))
    return bytes(out), {'boundary': 'MediaOutput', 'address': hex(ENTRY), 'cave': hex(CAVE),
                        'bytes': len(stub), 'displaced_instruction': hex(struct.unpack_from('<I', EXPECTED)[0])}


def header():
    stub = trampoline()
    values = lambda b: ','.join(f'0x{x:02x}' for x in b)
    return '\n'.join([
        '// Generated guarded media-output boundary for Spotify 9.1.90.',
        '#pragma once',
        '#include <stdint.h>',
        f'static const uintptr_t SAPExportMediaOutputOffset=0x{ENTRY-0x100000000:x};',
        f'static const uintptr_t SAPExportMediaOutputCaveOffset=0x{CAVE-0x100000000:x};',
        f'static const uint8_t SAPExportMediaOutputHead[]={{{values(struct.pack("<I", branch(ENTRY, CAVE)))}}};',
        f'static const uint8_t SAPExportMediaOutputCode[]={{{values(stub)}}};',
        '',
    ])
