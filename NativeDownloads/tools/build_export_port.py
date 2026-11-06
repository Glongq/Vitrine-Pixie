from export_release_materials import notices,retain_relink_sources
from build_native_share import build_native_share
"""Build current Pixie with the experimental15 audio exporter on Vitrine 9.1.90.

Input is the preserved refactored Pixie 1.3 IPA. Only the main executable and
Pixie companion are replaced. Extensions and Vitrine libraries are preserved.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
from zipfile import ZipFile

from pixie_target import ROOT,PROFILE,validate_sources,include_directories,resolve_source
from signing_metadata import sign_preserving_entitlements
import patch_export_port
import patch_export14
import patch_export15

MAIN='Payload/Spotify.app/Spotify'
COMPANION='Payload/Spotify.app/Frameworks/SpotifyAudioProbe.dylib'


def run(*args):subprocess.run([str(arg) for arg in args],check=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();sources=validate_sources()
    if args.output.exists():raise ValueError('Choose a fresh output path')
    for name,expected in [('ExportObservationV2Patch.h',patch_export14.header()),
                          ('ExportMediaUnsealPatch.h',patch_export15.header())]:
        if resolve_source(name).read_text()!=expected:raise ValueError(f'Stale {name}')
    with ZipFile(args.ipa) as archive:
        info=plistlib.loads(archive.read('Payload/Spotify.app/Info.plist'))
        if info.get('CFBundleShortVersionString')!=PROFILE['spotify_version']:raise ValueError('Spotify version mismatch')
        if b'9.1.90-v1.3' not in archive.read(COMPANION):raise ValueError('Expected refactored Pixie 1.3 input')
        original=archive.read(MAIN);patched,observations=patch_export_port.patch(original)
    sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='pixie-export-port-') as temp:
        temp=Path(temp);library=temp/'SpotifyAudioProbe.dylib';executable=temp/'Spotify'
        swift=build_native_share(temp/'NativeShareBridge.o',sdk)
        run('xcrun','clang','-dynamiclib','-arch','arm64','-target','arm64-apple-ios15.0','-isysroot',sdk,
            '-fobjc-arc','-std=gnu11','-O2','-fvisibility=hidden','-Wall','-Wextra','-Wno-unused-parameter',
            '-Wno-nullability-completeness','-Werror=implicit-function-declaration',
            '-DSAP_RESEARCH_DUMP=0','-DSAP_ENABLE_WAV_CAPTURE=0',
            *('-I'+str(path) for path in include_directories()),*sources,'-lm','-lsqlite3','-lz',*swift['link_args'],
            '-framework','Foundation','-framework','UIKit','-framework','AudioToolbox','-framework','AVFAudio',
            '-framework','CoreGraphics','-framework','AVFoundation','-framework','CoreMedia','-framework','Network',
            '-framework','ImageIO','-framework','QuartzCore','-framework','LinkPresentation','-framework','Security','-framework','MessageUI','-framework','UniformTypeIdentifiers',
            '-Wl,-install_name,@rpath/SpotifyAudioProbe.dylib','-o',library)
        run('codesign','--force','--sign','-','--timestamp=none',library)
        executable.write_bytes(patched)
        signing=sign_preserving_entitlements(executable,original,temp/'entitlements.plist')
        for binary in [library,executable]:
            run('codesign','--verify','--strict',binary)
            run('xcrun','dyld_info','-validate_only',binary)
        replacement=library.read_bytes();patched=executable.read_bytes()
        if b'live.bin' in replacement or b'SAPObserveExportBoundaryV2' not in replacement:
            raise ValueError('Research dumping leaked or export boundary is missing')
        additions=notices()
        with ZipFile(args.ipa) as source,ZipFile(args.output,'w',allowZip64=True) as result:
            for item in source.infolist():
                result.writestr(item,replacement if item.filename==COMPANION else
                                patched if item.filename==MAIN else source.read(item.filename))
            for name,data in additions.items():
                if name in source.namelist():raise ValueError("Unexpected preexisting export license path")
                result.writestr(name,data)
        with ZipFile(args.ipa) as source,ZipFile(args.output) as result:
            assert result.testzip() is None
            assert result.namelist()==source.namelist()+list(additions)
            changed=[name for name in source.namelist() if source.getinfo(name).CRC!=result.getinfo(name).CRC]
            assert set(changed)=={MAIN,COMPANION},changed
    snapshot=[*sources,*(ROOT/'src').rglob('*.h'),*(ROOT/'src').rglob('*.swift'),*(ROOT/'vendor').iterdir(),ROOT/'targets/spotify-9.1.90.json']
    report={'ipa':str(args.output.resolve()),'input':str(args.ipa.resolve()),
            'sha256':hashlib.sha256(args.output.read_bytes()).hexdigest(),
            'input_sha256':hashlib.sha256(args.ipa.read_bytes()).hexdigest(),
            'pixie_version':PROFILE['pixie_version'],'vitrine_version':PROFILE['vitrine_version'],
            'export_implementation':'experimental15-native-unseal','audio_export_formats':['m4a','ogg'],'audio_encoder':'Apple AAC-LC','changed_entries':changed,
            'additional_entries':list(additions),'relink_sources':retain_relink_sources(args.output),
            'native_observations':observations,'signing':signing,
            'research_key_dump_compiled_out':True,'wav_capture':False,
            'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in snapshot},
            'phone_launched':False,'ported_ipa_device_export_verified':False}
    args.output.with_suffix('.build.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['ipa','sha256','changed_entries','pixie_version','ported_ipa_device_export_verified']},indent=2))


if __name__=='__main__':main()
