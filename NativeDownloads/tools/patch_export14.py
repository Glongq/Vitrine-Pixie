"""Replace reviewed export probes with a complete, versioned register snapshot.

Recognise every old entry and cave byte before replacing anything. Old patch
generators stay unchanged so their historical inputs remain reproducible.
"""
from functools import cache
from pathlib import Path
import struct
import subprocess
import tempfile

import patch_export_boundaries as legacy
import patch_export13
import patch_media_context
import patch_media_record
import patch_media_output
import patch_aesctr
import patch_aesblock

BASE = 0x100000000
SYMBOL = b"SAPObserveExportBoundaryV2\0"
POINTS = [*legacy.POINTS, patch_export13.PATH_POINT, patch_export13.BLOB_POINT,
          ("MediaContext", patch_media_context.ENTRY, patch_media_context.CAVE,
           patch_media_context.EXPECTED, 6), patch_media_record.POINT]


@cache
def template(kind):
    stores = '\n'.join(f' stp x{i},x{i+1},[sp,#{i*8}]' for i in range(0, 30, 2))
    stores += '\n str x30,[sp,#240]'
    vectors = '\n'.join(f' stp q{i},q{i+1},[sp,#{256+i*16}]' for i in range(0, 32, 2))
    assembly = f'''.text
.p2align 2
.globl _export_snapshot_v2
_export_snapshot_v2:
 sub sp,sp,#800
{stores}
 add x17,sp,#800
 str x17,[sp,#248]
{vectors}
 mrs x17,nzcv
 str x17,[sp,#768]
 mrs x17,fpcr
 str x17,[sp,#776]
 mrs x17,fpsr
 str x17,[sp,#784]
 movn x0,#1
 adr x1,Lname
 .long 0x90000010
 add x16,x16,#0
 blr x16
 cbz x0,Ldone
 mov x16,x0
 mov w0,#{kind}
 mov x1,sp
 blr x16
Ldone:
 ldr x17,[sp,#776]
 msr fpcr,x17
 ldr x17,[sp,#784]
 msr fpsr,x17
 ldr x17,[sp,#768]
 msr nzcv,x17
{vectors.replace('stp', 'ldp')}
{stores.replace('stp', 'ldp').replace('str', 'ldr')}
 add sp,sp,#800
 .long 0x14000000
Lname:
 .asciz "SAPObserveExportBoundaryV2"
'''
    with tempfile.TemporaryDirectory(prefix='pixie-frame-v2-') as temp:
        source, obj = Path(temp)/'frame.S', Path(temp)/'frame.o'
        source.write_text(assembly)
        sdk = subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
        subprocess.run(['xcrun', 'clang', '-c', '-arch', 'arm64', '-target',
                        'arm64-apple-ios15.0', '-isysroot', sdk, str(source), '-o', str(obj)], check=True)
        raw = obj.read_bytes()
    cursor = 32
    for _ in range(struct.unpack_from('<I', raw, 16)[0]):
        command, size = struct.unpack_from('<II', raw, cursor)
        if command == 0x19:
            for n in range(struct.unpack_from('<I', raw, cursor+64)[0]):
                at = cursor+72+n*80
                if raw[at:at+16].split(b'\0')[0] == b'__text':
                    length = struct.unpack_from('<Q', raw, at+40)[0]
                    offset = struct.unpack_from('<I', raw, at+48)[0]
                    if struct.unpack_from('<I', raw, at+60)[0]:
                        raise ValueError('Unresolved snapshot relocation')
                    return raw[offset:offset+length]
        cursor += size
    raise ValueError('Snapshot text not found')


def new_point(point):
    name, entry, _, displaced, kind = point
    # Separate 512-byte caves; no overlap with historical 0x22100+ probes.
    return name, entry, BASE+0x1e000+kind*512, displaced, kind


def trampoline(point):
    name, entry, cave, displaced, kind = new_point(point)
    code = bytearray(template(kind))
    symbol = code.index(SYMBOL)
    words = [struct.unpack_from('<I', code, i)[0] for i in range(0, symbol, 4)]
    at = words.index(0x90000010)*4
    delta = (legacy.DLSYM_STUB>>12)-((cave+at)>>12)
    if not -(1<<20) <= delta < (1<<20):
        raise ValueError('Snapshot resolver out of range')
    struct.pack_into('<I', code, at, 0x90000010|((delta&3)<<29)|(((delta>>2)&0x7ffff)<<5))
    struct.pack_into('<I', code, at+4, 0x91000210|((legacy.DLSYM_STUB&4095)<<10))
    adr = next(i*4 for i, word in enumerate(words) if word&0x9f00001f == 0x10000001)
    word = struct.unpack_from('<I', code, adr)[0]
    imm = (((word>>5)&0x7ffff)<<2)|((word>>29)&3)
    imm += len(displaced)
    struct.pack_into('<I', code, adr, 0x10000001|((imm&3)<<29)|(((imm>>2)&0x7ffff)<<5))
    final = (len(words)-1)*4
    code[final:final] = displaced
    final += len(displaced)
    struct.pack_into('<I', code, final, legacy.branch(cave+final, entry+len(displaced)))
    if len(code)>512:
        raise ValueError('Snapshot exceeds its cave')
    return bytes(code)


def old_code(point):
    if point[4] == 6:
        return patch_media_context.trampoline()
    return legacy.trampoline(point)


def patch(data):
    end, first, segments, uuid = legacy.layout(data)
    if uuid != legacy.UUID:
        raise ValueError('Unsupported export snapshot UUID')
    legacy._verify_dlsym_binding(data)
    _, vm, _, fo, size, protection = next(s for s in segments if s[0]==b'__TEXT')
    def offset(address, length):
        at = fo+address-vm
        if not (vm<=address and address+length<=vm+size):
            raise ValueError('Snapshot outside text')
        return at
    out = bytearray(data)
    changes = []
    for old in POINTS:
        name, entry, cave, displaced, kind = old
        code = old_code(old)
        head = struct.pack('<I', legacy.branch(entry,cave))
        at, dest = offset(entry,len(displaced)), offset(cave,len(code))
        # Core AES probes were optional in historical experiment-13 variants.
        absent = kind in (8,9) and data[at:at+len(displaced)]==displaced and not any(data[dest:dest+len(code)])
        if not absent:
            expected = head+displaced[4:]
            if data[at:at+len(displaced)]!=expected or data[dest:dest+len(code)]!=code:
                raise ValueError(f'Unrecognised old {name} probe')
            out[dest:dest+len(code)] = bytes(len(code))
        _, _, new_cave, _, _ = new_point(old)
        new_code = trampoline(old)
        new_dest = offset(new_cave,len(new_code))
        if protection&5!=5 or new_dest<end or new_dest+len(new_code)>first or any(data[new_dest:new_dest+len(new_code)]):
            raise ValueError(f'New {name} cave unavailable')
        out[new_dest:new_dest+len(new_code)] = new_code
        out[at:at+len(displaced)] = struct.pack('<I',legacy.branch(entry,new_cave))+displaced[4:]
        changes.append({'boundary':name,'kind':kind,'address':hex(entry),'cave':hex(new_cave),'bytes':len(new_code)})
    # Per-block AES instrumentation resolves a helper on every hot-loop pass.
    # Restore those optional probes instead of shipping that playback overhead.
    for old in [patch_aesctr.POINT,patch_aesblock.POINT]:
        name,entry,cave,displaced,kind=old
        code=legacy.trampoline(old)
        at,dest=offset(entry,len(displaced)),offset(cave,len(code))
        head=struct.pack('<I',legacy.branch(entry,cave))+displaced[4:]
        if data[at:at+len(displaced)]==displaced and not any(data[dest:dest+len(code)]):continue
        if data[at:at+len(displaced)]!=head or data[dest:dest+len(code)]!=code:
            raise ValueError(f'Unrecognised old {name} core probe')
        out[at:at+len(displaced)]=displaced
        out[dest:dest+len(code)]=bytes(len(code))
    # Historical output probe sampled x20 after the epilogue restored caller x20.
    # Its 32-byte interpretation was also not a proven media IV. Remove it.
    output = patch_media_output.trampoline()
    at = offset(patch_media_output.ENTRY,4)
    dest = offset(patch_media_output.CAVE,len(output))
    if data[at:at+4]!=struct.pack('<I',legacy.branch(patch_media_output.ENTRY,patch_media_output.CAVE)) or data[dest:dest+len(output)]!=output:
        raise ValueError('Unrecognised old media-output probe')
    out[at:at+4] = patch_media_output.EXPECTED
    out[dest:dest+len(output)] = bytes(len(output))
    return bytes(out), {'abi':2,'all_31_gprs_and_32_vectors':True,'boundaries':changes,
                       'unproven_media_output_probe_removed':True,'per_block_aes_probes_removed':True}


def header():
    lines = ['// Generated version-2 export observations for Spotify 9.1.90.',
             '#pragma once', '#include <stdint.h>']
    for old in POINTS:
        name, entry, cave, _, _ = new_point(old)
        values = lambda b: ','.join(f'0x{x:02x}' for x in b)
        lines += [f'static const uintptr_t SAPExportV2{name}Offset=0x{entry-BASE:x};',
                  f'static const uintptr_t SAPExportV2{name}CaveOffset=0x{cave-BASE:x};',
                  f'static const uint8_t SAPExportV2{name}Head[]={{{values(struct.pack("<I",legacy.branch(entry,cave)))}}};',
                  f'static const uint8_t SAPExportV2{name}Code[]={{{values(trampoline(old))}}};']
    return '\n'.join(lines)+'\n'
