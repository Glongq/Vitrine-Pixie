"""Build complete Pixie + Vitrine DEBs for the guarded Spotify 9.1.90 image.

The bootstrap is a dependency of Vitrine so its native patches/import bindings
run before Vitrine's audio constructors, just as in the IPA. No postinst writes
to Spotify, account material, or bundled copy of the hook framework.
"""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import struct
import subprocess
from zipfile import ZipFile

from build_vitrine_9190 import SOURCE_FILES
import patch_native_restrictions as quota
import patch_key_request_mode as key
import patch_native_trace as trace

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT.parent

def run(*args):
    subprocess.run([str(a) for a in args], check=True)

def generate_header(folder):
    folder.mkdir(parents=True, exist_ok=True)
    patched = bytearray(key.ORIGINAL)
    struct.pack_into('<I', patched, key.CALL_SITE - key.WINDOW, quota.branch(key.CALL_SITE,key.CAVE))
    static_mode_zero = bytearray(key.ORIGINAL)
    struct.pack_into('<I', static_mode_zero, key.CALL_SITE - key.WINDOW, 0x52800002)
    arrays = {'SupportedUUID': quota.UUID, 'SetterOriginal': quota.ORIGINAL,
              'KeyOriginal': key.ORIGINAL, 'KeyPatched': patched, 'KeyStaticZero': static_mode_zero,
              'ProviderOriginal': key.PROVIDER_HEAD, 'MappingOriginal': key.MAPPING_BYTES,
              'DLSymStubOriginal': key.DLSYM_STUB_HEAD,
              'SuccessOriginal': trace.POINTS[1][3], 'FailureOriginal': trace.POINTS[2][3]}
    offsets = {'SetterOffset': quota.SETTER, 'KeyWindowOffset': key.WINDOW,
               'KeyCallOffset': key.CALL_SITE, 'ProviderOffset': key.PROVIDER,
               'MappingOffset': key.MAPPING, 'DLSymStubOffset': key.DLSYM_STUB}
    text = '#pragma once\n#include <stdint.h>\n'
    for name, value in arrays.items():
        text += f'static const uint8_t SAPJB{name}[]={{' + ','.join(f'0x{b:02x}' for b in value) + '};\n'
    for name, value in offsets.items():
        text += f'static const uintptr_t SAPJB{name}=0x{value-quota.PREFERRED:x};\n'
    (folder / 'NativeKeyPatch.h').write_text(text)

def add_dependency(path, name):
    data = bytearray(path.read_bytes())
    assert struct.unpack_from('<I', data)[0] == 0xfeedfacf
    count, size = struct.unpack_from('<II', data, 16)
    at, first = 32, len(data)
    for _ in range(count):
        command, length = struct.unpack_from('<II', data, at)
        assert length >= 8 and at + length <= 32 + size
        if command == 0x19:
            for n in range(struct.unpack_from('<I', data, at + 64)[0]):
                offset = struct.unpack_from('<I', data, at + 72 + 80 * n + 48)[0]
                if offset: first = min(first, offset)
        at += length
    assert at == 32 + size
    raw = name.encode() + b'\0'
    length = (24 + len(raw) + 7) & ~7
    assert at + length <= first and not any(data[at:at+length]), 'No dylib load-command padding'
    data[at:at+length] = (struct.pack('<IIIIII', 0xc, length, 24, 0, 0, 0) + raw).ljust(length, b'\0')
    struct.pack_into('<II', data, 16, count + 1, size + length)
    path.write_bytes(data)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path, help='Original decrypted Vitrine Spotify 9.1.90 IPA')
    parser.add_argument('--vitrine-dylib', required=True, type=Path)
    parser.add_argument('--theos', type=Path, default=PROJECT / '.build-tools/theos')
    parser.add_argument('--output', type=Path, default=ROOT / 'outputs/pixie-9.1.90-v1.2-deb')
    args = parser.parse_args()
    build = ROOT / 'build/deb'
    generate_header(build)
    if (ROOT / 'src/NativeRestrictionsPatch.h').read_text() != quota.guard_header():
        raise RuntimeError('Native quota guard header is out of sync')
    if (ROOT / 'src/NativeTracePatch.h').read_text() != trace.header():
        raise RuntimeError('Native trace header is out of sync')
    if (ROOT / 'src/NativeKeyModePatch.h').read_text() != key.key_header():
        raise RuntimeError('Native key-mode header is out of sync')
    with ZipFile(args.ipa) as archive:
        original = archive.read('Payload/Spotify.app/Spotify')
    quota.patch(original)
    key.patch(original)
    fixture = build / 'Spotify.original'
    fixture.write_bytes(original)
    del original
    run('python3', ROOT / 'tests/jailbreak_patches.py', fixture, build)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    args.output.mkdir(parents=True, exist_ok=True)
    manifests = []
    for scheme, architecture, prefix in [('rootful', 'iphoneos-arm', ''), ('rootless', 'iphoneos-arm64', '/var/jb')]:
        stage = build / ('stage-' + scheme)
        if stage.exists(): shutil.rmtree(stage)
        libs = stage / (prefix.lstrip('/') + '/Library/MobileSubstrate/DynamicLibraries').lstrip('/')
        libs.mkdir(parents=True)
        companion = libs / 'SpotifyAudioProbe.dylib'
        framework = args.theos / ('vendor/lib/iphone/rootless' if prefix else 'vendor/lib')
        framework_path = prefix + '/Library/Frameworks'
        run('xcrun', 'clang', '-dynamiclib', '-arch', 'arm64', '-target', 'arm64-apple-ios16.1',
            '-isysroot', sdk, '-fobjc-arc', '-std=gnu11', '-O2', '-fvisibility=hidden',
            '-Wall', '-Wextra', '-Wno-unused-parameter', '-Wno-nullability-completeness',
            '-Werror=implicit-function-declaration', '-DSAP_JAILBREAK=1',
            '-DSG_DRIVER=0', '-DSGRebindImport=SAPJBRebindImport',
            '-I'+str(ROOT/'src'), '-I'+str(build), '-I'+str(PROJECT/'vitrine-upstream/tweak/Sources'),
            '-F'+str(framework), *(ROOT/'src'/name for name in SOURCE_FILES),
            ROOT/'src/JailbreakPatches.c', ROOT/'src/JailbreakSupport.m',
            PROJECT/'vitrine-upstream/tweak/Sources/Core/SGRebind.m',
            '-framework', 'AudioToolbox', '-framework', 'Foundation', '-framework', 'UIKit',
            '-framework', 'AVFAudio', '-framework', 'CoreGraphics', '-framework', 'AVFoundation',
            '-framework', 'CoreMedia', '-framework', 'Network', '-framework', 'ImageIO', '-framework', 'QuartzCore', '-framework', 'CydiaSubstrate',
            '-Wl,-rpath,'+framework_path, '-Wl,-install_name,@rpath/SpotifyAudioProbe.dylib', '-o', companion)
        companion_dependencies = subprocess.check_output(['otool', '-L', str(companion)], text=True)
        substrate = '/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate'
        if substrate in companion_dependencies:
            run('install_name_tool', '-change', substrate, '@rpath/CydiaSubstrate.framework/CydiaSubstrate', companion)
        vitrine = libs / 'spotifyglass.dylib'
        shutil.copy2(args.vitrine_dylib, vitrine)
        dependencies = subprocess.check_output(['otool', '-L', str(vitrine)], text=True)
        for line in dependencies.splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            if dependency.endswith('/CydiaSubstrate.framework/CydiaSubstrate'):
                run('install_name_tool', '-change', dependency, '@rpath/CydiaSubstrate.framework/CydiaSubstrate', vitrine)
        commands = subprocess.check_output(['otool', '-l', str(vitrine)], text=True)
        if 'path '+framework_path+' (offset' not in commands:
            run('install_name_tool', '-add_rpath', framework_path, vitrine)
        run('install_name_tool', '-id', '@rpath/spotifyglass.dylib', vitrine)
        add_dependency(vitrine, '@loader_path/SpotifyAudioProbe.dylib')
        for lib in [companion, vitrine]:
            lib.chmod(0o755)
            run('codesign', '--force', '--sign', '-', '--timestamp=none', lib)
            run('codesign', '--verify', '--strict', lib)
            run('xcrun', 'dyld_info', '-validate_only', lib)
        # Either filter can load Pixie; dyld initializes the shared dependency once.
        filter_data = plistlib.dumps({'Filter': {'Executables': ['Spotify']}})
        for name in ['spotifyglass.plist', 'SpotifyAudioProbe.plist']:
            (libs/name).write_bytes(filter_data)
        control = stage/'DEBIAN'
        control.mkdir()
        (control/'control').write_text(f'''Package: com.pixie.spotify
Name: Spotify Pixie
Version: 9.1.90-1.2
Architecture: {architecture}
Description: Vitrine UI and Pixie downloads for Spotify 9.1.90
Maintainer: Pixie
Author: Vitrine and Pixie contributors
Section: Tweaks
Depends: firmware (>= 16.1), mobilesubstrate
Conflicts: com.vitrine.tweak
Replaces: com.vitrine.tweak
''')
        documentation = stage/(prefix.lstrip('/')+'/usr/share/doc/com.pixie.spotify').lstrip('/')
        documentation.mkdir(parents=True)
        for license_name in ['LICENSE', 'LICENSE.md']:
            source = PROJECT/'vitrine-upstream'/license_name
            if source.is_file(): shutil.copy2(source, documentation/license_name)
        (documentation/'README').write_text('Spotify Pixie 9.1.90\nInstall exactly one DEB matching your jailbreak layout.\n'
            'Requires Spotify 9.1.90 (UUID fbce22c1-7e1b-3e0d-9be8-66ff9291943e).\n'
            'Use the original Spotify app, not an IPA with Vitrine/Pixie already injected.\n'
            'Restart Spotify after installation. This is a jailbreak tweak, not a LiveContainer import.\n'
            'Includes Vitrine, Pixie Download Manager (English), native offline patches, and the local artwork crash fix.\n'
            'Spotify files and account data are not modified on disk.\n'
            'On unsupported Spotify builds, Pixie keeps its menu/logs visible and reports the exact refusal. Download hooks remain disabled.\n'
            'Includes current detailed diagnostics (optional), single JSON export, Me links and the supplied GitHub artwork.\n'
            'Includes the menu interaction fix and Reset log; action/trace recording is disabled while Diagnostics is off.\n'
            'The custom Live Activity widget/App Intents extension requires IPA integration; it is not installed by this tweak DEB.\n')
        # Real payload sizes and root ownership; no maintainer scripts or account-specific data.
        installed_size = sum(p.stat().st_size for p in stage.rglob('*') if p.is_file())//1024 + 1
        with (control/'control').open('a') as file: file.write(f'Installed-Size: {installed_size}\n')
        package = args.output/f'Spotify-9.1.90-Vitrine-Pixie-v1.2-{scheme}.deb'
        run('dpkg-deb', '--root-owner-group', '-Zgzip', '--build', stage, package)
        run('dpkg-deb', '--info', package)
        manifests.append({'file':package.name, 'architecture':architecture, 'prefix':prefix or '/',
                          'sha256':hashlib.sha256(package.read_bytes()).hexdigest()})
    source_files = sorted(set((ROOT/'src').glob('*.[chm]')) | {Path(__file__).resolve()})
    (args.output/'manifest.json').write_text(json.dumps({'packages':manifests,'native_patch_tests_passed':True,
        'jailbreak_device_tested':False,'ipa_unchanged':True,
        'vitrine_input_sha256':hashlib.sha256(args.vitrine_dylib.read_bytes()).hexdigest(),
        'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}}, indent=2)+'\n')
    (args.output/'README.txt').write_text('Spotify 9.1.90 Pixie — jailbreak DEBs\n\n'
        'rootless: Spotify-9.1.90-Vitrine-Pixie-v1.2-rootless.deb (iphoneos-arm64, /var/jb)\n'
        'rootful: Spotify-9.1.90-Vitrine-Pixie-v1.2-rootful.deb (iphoneos-arm)\n'
        'Install ONE matching your jailbreak, then close and reopen Spotify.\n'
        'Use the original Spotify app, not an IPA with Vitrine/Pixie already injected.\n'
        'These are not IPA/LiveContainer installation files.\n'
        'Includes Vitrine + Pixie, English-only menu, downloads, fixed mode 0, one support log and local-cover fix.\n'
        'Latest v1.2 menu interaction fix, Reset log, optional detailed diagnostics and Me links are included.\n'
        'Targets the exact Spotify 9.1.90 executable. Newer versions need adaptation.\n'
        'The custom Live Activity widget/App Intents extension requires IPA integration and is not included.\n'
        'Package/signature/guard checks were run locally; execution on a jailbroken iPhone has not been tested.\n')
    run('python3', ROOT/'tools/verify_debs.py', args.output)
    print(json.dumps(manifests, indent=2))

if __name__ == '__main__': main()
