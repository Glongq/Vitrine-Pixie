"""Observe the 16-byte result of the native protected-key unsealing operation.

Input is the exact experiment-14 snapshot layout. The new observation executes
before `str q0,[sp]`, after native code has loaded its unsealed 16-byte result.
The helper never invokes the VM or changes its arguments, result or lifetime.
"""
import struct
import patch_export14 as previous

legacy=previous.legacy
BASE=previous.BASE
SYMBOL=previous.SYMBOL
POINT=('UnsealedMediaKey',0x103cc61f8,0x10001f400,bytes.fromhex('e003803d'),10)
POINTS=[*previous.POINTS,POINT]
GUARD_OFFSET=0x3cc61f0
GUARD=bytes.fromhex('857b7995c04af83ce003803d')
CALLER_OFFSET=0x20fd5c0
CALLER=bytes.fromhex('000540f9080040f9081540f921510091e20313aa00013fd6')

new_point=previous.new_point
trampoline=previous.trampoline


def patch(data):
    end,first,segments,uuid=previous.legacy.layout(data)
    if uuid!=previous.legacy.UUID:raise ValueError('Unsupported media-unseal UUID')
    previous.legacy._verify_dlsym_binding(data)
    _,vm,_,fo,size,protection=next(s for s in segments if s[0]==b'__TEXT')
    def at(address,length):
        if not vm<=address or address+length>vm+size:raise ValueError('Unseal address outside text')
        return fo+address-vm
    for old in previous.POINTS:
        name,entry,cave,original,kind=previous.new_point(old)
        code=previous.trampoline(old)
        if data[at(entry,len(original)):at(entry,len(original))+len(original)]!=struct.pack('<I',previous.legacy.branch(entry,cave))+original[4:]:
            raise ValueError(f'Unrecognised experiment-14 {name} entry')
        start=at(cave,len(code))
        if data[start:start+len(code)]!=code:raise ValueError(f'Unrecognised experiment-14 {name} cave')
    for offset,expected in [(GUARD_OFFSET,GUARD),(CALLER_OFFSET,CALLER)]:
        start=at(BASE+offset,len(expected))
        if data[start:start+len(expected)]!=expected:raise ValueError('Media unsealing instruction guard differs')
    name,entry,cave,original,kind=previous.new_point(POINT)
    code=previous.trampoline(POINT);dest=at(cave,len(code));entry_at=at(entry,4)
    if protection&5!=5 or dest<end or dest+len(code)>first or any(data[dest:dest+len(code)]):
        raise ValueError('Media-unseal cave unavailable')
    out=bytearray(data);out[dest:dest+len(code)]=code
    out[entry_at:entry_at+4]=struct.pack('<I',previous.legacy.branch(entry,cave))
    return bytes(out),{'abi':2,'boundary':name,'address':hex(entry),'cave':hex(cave),'bytes':len(code),
                       'source':'q0 after native unsealing, before stored-record encryption',
                       'file_association':'saved caller x20, exact key-store return address',
                       'existing_native_probes_preserved':True,'per_block_hooks_added':False}


def header():
    name,entry,cave,original,kind=previous.new_point(POINT)
    values=lambda b:','.join(f'0x{x:02x}' for x in b)
    return '\n'.join(['// Generated native media-unsealing observation for Spotify 9.1.90.',
        '#pragma once','#include <stdint.h>',
        f'static const uintptr_t SAPExportV2{name}Offset=0x{entry-BASE:x};',
        f'static const uintptr_t SAPExportV2{name}CaveOffset=0x{cave-BASE:x};',
        f'static const uint8_t SAPExportV2{name}Head[]={{{values(struct.pack("<I",previous.legacy.branch(entry,cave)))}}};',
        f'static const uint8_t SAPExportV2{name}Code[]={{{values(previous.trampoline(POINT))}}};',
        f'static const uintptr_t SAPMediaUnsealCodeOffset=0x{GUARD_OFFSET:x};',
        f'static const uint8_t SAPMediaUnsealCode[]={{{values(GUARD[:8])}}};',
        f'static const uintptr_t SAPMediaUnsealCallerOffset=0x{CALLER_OFFSET:x};',
        f'static const uint8_t SAPMediaUnsealCallerCode[]={{{values(CALLER)}}};',''])
