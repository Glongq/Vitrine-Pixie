"""Guarded observations of native cache-key mapping and stream key success.

Both original functions retain arguments, ownership, return values and flow.
No executable memory is written at runtime.
"""
from functools import cache
from pathlib import Path
import struct,subprocess,tempfile
from patch_native_restrictions import layout,branch,UUID
from patch_key_request_mode import DLSYM_STUB,_verify_dlsym_binding
SYMBOL=b'SAPObserveExportBoundary\0'
POINTS=[('CacheKey',0x101daf0d0,0x100022100,bytes.fromhex('ff0301d1fd7b03a9fdc30091e20308aa'),0),
        ('StreamKey',0x1012e2658,0x100022300,bytes.fromhex('ff0302d1f65705a9f44f06a9fd7b07a9'),1),
        ('CacheCipher',0x1046ff01c,0x100022500,bytes.fromhex('f657bda9f44f01a9fd7b02a9fd830091'),2),
        ('CacheCipherApple',0x1003dfb38,0x100022700,bytes.fromhex('fa67bba9f85f01a9f65702a9f44f03a9'),3)]
@cache
def template(kind):
    stores='\n'.join(f' stp x{i}, x{i+1}, [sp, #{i*8}]' for i in range(0,18,2))+'\n stp x18, x30, [sp, #144]'
    loads=stores.replace('stp','ldp')
    vectors='\n'.join(f' stp q{i}, q{i+1}, [sp, #{160+i*16}]' for i in range(0,8,2))
    asm=f'''.text
.p2align 2
.globl _export_boundary
_export_boundary:
 sub sp,sp,#320
{stores}
{vectors}
 mrs x17,nzcv
 str x17,[sp,#288]
 mrs x17,fpcr
 str x17,[sp,#296]
 mrs x17,fpsr
 str x17,[sp,#304]
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
 ldr x17,[sp,#296]
 msr fpcr,x17
 ldr x17,[sp,#304]
 msr fpsr,x17
 ldr x17,[sp,#288]
 msr nzcv,x17
{vectors.replace('stp','ldp')}
{loads}
 add sp,sp,#320
 .long 0x14000000
Lname:
 .asciz "SAPObserveExportBoundary"
'''
    with tempfile.TemporaryDirectory(prefix='pixie-export-thunk-') as tmp:
        source=Path(tmp)/'export.S';obj=Path(tmp)/'export.o';source.write_text(asm)
        sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
        subprocess.run(['xcrun','clang','-c','-arch','arm64','-target','arm64-apple-ios15.0','-isysroot',sdk,str(source),'-o',str(obj)],check=True)
        raw=obj.read_bytes()
    cursor=32
    for _ in range(struct.unpack_from('<I',raw,16)[0]):
        cmd,size=struct.unpack_from('<II',raw,cursor)
        if cmd==0x19:
            for n in range(struct.unpack_from('<I',raw,cursor+64)[0]):
                s=cursor+72+n*80
                if raw[s:s+16].split(b'\0')[0]!=b'__text':continue
                count=struct.unpack_from('<Q',raw,s+40)[0];offset=struct.unpack_from('<I',raw,s+48)[0]
                if struct.unpack_from('<I',raw,s+60)[0]:raise ValueError('Unresolved export thunk relocation')
                return raw[offset:offset+count]
        cursor+=size
    raise ValueError('Export thunk code not found')
def trampoline(point):
    name,address,cave,original,kind=point;out=bytearray(template(kind));symbol=out.index(SYMBOL)
    words=[struct.unpack_from('<I',out,i)[0] for i in range(0,symbol,4)];at=words.index(0x90000010)*4
    delta=(DLSYM_STUB>>12)-((cave+at)>>12)
    if not -(1<<20)<=delta<(1<<20):raise ValueError('Export resolver out of ADRP range')
    struct.pack_into('<I',out,at,0x90000010|((delta&3)<<29)|(((delta>>2)&0x7ffff)<<5))
    struct.pack_into('<I',out,at+4,0x91000210|((DLSYM_STUB&4095)<<10))
    final=(len(words)-1)*4
    adr=next(i*4 for i,w in enumerate(words) if w&0x9f00001f==0x10000001)
    word=struct.unpack_from('<I',out,adr)[0];imm=(((word>>5)&0x7ffff)<<2)|((word>>29)&3);imm+=len(original)
    struct.pack_into('<I',out,adr,0x10000001|((imm&3)<<29)|(((imm>>2)&0x7ffff)<<5))
    out[final:final]=original;final+=len(original);struct.pack_into('<I',out,final,branch(cave+final,address+len(original)))
    if len(out)>512:raise ValueError('Export thunk too large')
    return bytes(out)
def patch(data):
    end,first,segments,uuid=layout(data)
    if uuid!=UUID:raise ValueError('Unsupported export observation UUID')
    _verify_dlsym_binding(data);out=bytearray(data);reports=[]
    _,vm,_,fo,size,protection=next(s for s in segments if s[0]==b'__TEXT')
    for point in POINTS:
        name,address,cave,expected,kind=point;stub=trampoline(point);at=fo+address-vm;dest=fo+cave-vm
        if not (vm<=address and address+len(expected)<=vm+size and vm<=cave and cave+len(stub)<=vm+size):raise ValueError('Export observation outside text')
        if protection&5!=5 or dest<end or dest+len(stub)>first or any(data[dest:dest+len(stub)]):raise ValueError('Export header padding unavailable')
        if data[at:at+len(expected)]!=expected:raise ValueError(f'Export {name} entry differs')
        out[dest:dest+len(stub)]=stub;struct.pack_into('<I',out,at,branch(address,cave))
        reports.append({'boundary':name,'address':hex(address),'cave':hex(cave),'bytes':len(stub),'original_arguments_results_preserved':True})
    return bytes(out),{'uuid':UUID.hex(),'helper':SYMBOL[:-1].decode(),'boundaries':reports}
def header():
    lines=['// Generated guarded native export observation boundaries for Spotify 9.1.90.','#pragma once','#include <stdint.h>']
    for point in POINTS:
        name,address,cave,expected,kind=point;code=trampoline(point)
        values=lambda b:','.join(f'0x{x:02x}' for x in b)
        lines += [f'static const uintptr_t SAPExport{name}Offset=0x{address-0x100000000:x};',f'static const uintptr_t SAPExport{name}CaveOffset=0x{cave-0x100000000:x};',f'static const uint8_t SAPExport{name}Head[]={{{values(struct.pack("<I",branch(address,cave)))}}};',f'static const uint8_t SAPExport{name}Code[]={{{values(code)}}};']
    return '\n'.join(lines)+'\n'
