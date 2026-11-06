"""Install the experiment-15 export observations in the current 1.3 executable.

The exact 9.1.90 identity, original instructions, imports and zero-filled caves
are required. Current Pixie/Vitrine patches are not restored or replaced.
"""
import struct
import patch_export15 as export


def patch(data):
    legacy=export.legacy
    end,first,segments,uuid=legacy.layout(data)
    if uuid!=legacy.UUID:raise ValueError('Unsupported export target UUID')
    legacy._verify_dlsym_binding(data)
    _,vm,_,fo,size,protection=next(s for s in segments if s[0]==b'__TEXT')
    def offset(address,length):
        if not(vm<=address and address+length<=vm+size):raise ValueError('Export observation outside text')
        return fo+address-vm
    for at,expected in [(export.GUARD_OFFSET,export.GUARD),(export.CALLER_OFFSET,export.CALLER)]:
        start=offset(export.BASE+at,len(expected))
        if data[start:start+len(expected)]!=expected:raise ValueError('Native media-unsealing guard differs')
    out=bytearray(data);changes=[]
    for old in export.POINTS:
        name,entry,cave,original,kind=export.new_point(old)
        code=export.trampoline(old)
        start,dest=offset(entry,len(original)),offset(cave,len(code))
        if data[start:start+len(original)]!=original:raise ValueError(f'Original {name} instructions differ')
        if protection&5!=5 or dest<end or dest+len(code)>first or any(data[dest:dest+len(code)]):
            raise ValueError(f'{name} export cave unavailable')
        out[dest:dest+len(code)]=code
        out[start:start+len(original)]=struct.pack('<I',legacy.branch(entry,cave))+original[4:]
        changes.append({'boundary':name,'kind':kind,'entry':hex(entry),'cave':hex(cave),'size':len(code)})
    return bytes(out),{'uuid':uuid.hex(),'snapshot_abi':2,'boundaries':changes,
                       'existing_pixie_and_vitrine_patches_preserved':True,
                       'per_block_hooks':False,'native_methods_invoked_by_observers':False}
