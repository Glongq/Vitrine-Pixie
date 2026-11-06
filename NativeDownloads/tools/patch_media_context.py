"""One guarded observation immediately after the native 24-byte media key setter.

The displaced instruction is a single non-PC-relative load. The cave preserves
all caller-saved registers, vectors and condition/FP state, calls the existing
export boundary helper with kind 6, then executes the displaced load and jumps
back to the original next instruction.
"""
from pathlib import Path
import struct, subprocess, tempfile
from patch_native_restrictions import layout, branch
from patch_key_request_mode import DLSYM_STUB, _verify_dlsym_binding

UUID = bytes.fromhex("fbce22c17e1b3e0d9be866ff9291943e")
ENTRY = 0x107970fe8
CAVE = 0x100022d00
EXPECTED = bytes.fromhex("a15e4039")
SYMBOL = b"SAPObserveExportBoundary\0"


def template():
    stores = '\n'.join(f' stp x{i}, x{i+1}, [sp, #{i*8}]' for i in range(0, 18, 2)) + '\n stp x18, x30, [sp, #144]'
    stores += '\n stp x19, x20, [sp, #160]\n stp x21, x22, [sp, #176]'
    loads = stores.replace('stp', 'ldp')
    vectors = '\n'.join(f' stp q{i}, q{i+1}, [sp, #{192+i*16}]' for i in range(0, 8, 2))
    asm = f'''.text
.p2align 2
.globl _media_context
_media_context:
 sub sp,sp,#352
{stores}
{vectors}
 mrs x17,nzcv
 str x17,[sp,#320]
 mrs x17,fpcr
 str x17,[sp,#328]
 mrs x17,fpsr
 str x17,[sp,#336]
 movn x0,#1
 adr x1,Lname
 .long 0x90000010
 add x16,x16,#0
 blr x16
 cbz x0,Ldone
 mov x16,x0
 mov w0,#6
 mov x1,sp
 blr x16
Ldone:
 ldr x17,[sp,#328]
 msr fpcr,x17
 ldr x17,[sp,#336]
 msr fpsr,x17
 ldr x17,[sp,#320]
 msr nzcv,x17
{vectors.replace('stp','ldp')}
{loads}
 add sp,sp,#352
 ldrb w1,[x21,#0x17]
 b .Lreturn
.Lreturn:
 .long 0x12345678
Lname:
 .asciz "SAPObserveExportBoundary"
'''
    with tempfile.TemporaryDirectory(prefix='pixie-media-context-') as tmp:
        source = Path(tmp) / 'ctx.S'
        obj = Path(tmp) / 'ctx.o'
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
                    raise ValueError('Unresolved media-context relocation')
                return raw[offset:offset + count]
        cursor += size
    raise ValueError('Media-context code not found')


def trampoline():
    out = bytearray(template())
    symbol = out.index(SYMBOL)
    words = [struct.unpack_from('<I', out, i)[0] for i in range(0, symbol, 4)]
    at = words.index(0x90000010) * 4
    marker = words.index(0x12345678) * 4
    struct.pack_into('<I', out, marker, branch(CAVE + marker, ENTRY + 4))
    delta = (DLSYM_STUB >> 12) - ((CAVE + at) >> 12)
    if not -(1 << 20) <= delta < (1 << 20):
        raise ValueError('Media-context resolver out of ADRP range')
    struct.pack_into('<I', out, at, 0x90000010 | ((delta & 3) << 29) | (((delta >> 2) & 0x7ffff) << 5))
    struct.pack_into('<I', out, at + 4, 0x91000210 | ((DLSYM_STUB & 4095) << 10))
    if len(out) > 512:
        raise ValueError('Media-context thunk too large')
    return bytes(out)


def patch(data):
    end, first, segments, uuid = layout(data)
    if uuid != UUID:
        raise ValueError('Unsupported media-context UUID')
    _verify_dlsym_binding(data)
    _, vm, _, fo, size, protection = next(s for s in segments if s[0] == b'__TEXT')
    at = fo + ENTRY - vm
    dest = fo + CAVE - vm
    stub = trampoline()
    if not (vm <= ENTRY and ENTRY + 4 <= vm + size and vm <= CAVE and CAVE + len(stub) <= vm + size):
        raise ValueError('Media-context point outside text')
    if protection & 5 != 5 or data[at:at + 4] != EXPECTED:
        raise ValueError('Media-context entry differs')
    if dest < end or dest + len(stub) > first or any(data[dest:dest + len(stub)]):
        raise ValueError('Media-context cave unavailable')
    out = bytearray(data)
    out[dest:dest + len(stub)] = stub
    struct.pack_into('<I', out, at, branch(ENTRY, CAVE))
    return bytes(out), {'boundary': 'MediaContext', 'address': hex(ENTRY), 'cave': hex(CAVE),
                        'bytes': len(stub), 'displaced_instruction': hex(struct.unpack_from('<I', EXPECTED)[0])}


def header():
    stub = trampoline()
    values = lambda b: ','.join(f'0x{x:02x}' for x in b)
    return '\n'.join([
        '// Generated guarded media-context boundary for Spotify 9.1.90.',
        '#pragma once',
        '#include <stdint.h>',
        f'static const uintptr_t SAPExportMediaContextOffset=0x{ENTRY-0x100000000:x};',
        f'static const uintptr_t SAPExportMediaContextCaveOffset=0x{CAVE-0x100000000:x};',
        f'static const uint8_t SAPExportMediaContextHead[]={{{values(struct.pack("<I", branch(ENTRY, CAVE)))}}};',
        f'static const uint8_t SAPExportMediaContextCode[]={{{values(stub)}}};',
        '',
    ])
