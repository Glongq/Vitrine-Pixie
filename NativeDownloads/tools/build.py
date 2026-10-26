import hashlib
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from zipfile import ZipFile

from patch_imports import patch
from patch_offline import patch_reminder
from patch_native_restrictions import patch as patch_native_restrictions, guard_header, limits_header
from patch_key_request_mode import patch as patch_key_request_mode

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "outputs"
BUILD = ROOT / "build"


def run(*args):
    subprocess.run([str(x) for x in args], check=True)


def main():
    parser = argparse.ArgumentParser(description="Build the UI release and native-download overlay for the guarded Spotify 9.1.88 binary.")
    parser.add_argument("ipa", type=Path, help="An unmodified EeveeSpotify 7.0.0 / Spotify 9.1.88 IPA supplied by you")
    parser.add_argument("--output-dir", type=Path, default=OUTPUT)
    parser.add_argument("--provenance", type=Path, default=ROOT / "provenance-ui-v7.json")
    parser.add_argument("--eevee-dylib", type=Path, help="EeveeSpotify.dylib compiled from the current UI sources; otherwise use the input IPA's Eevee library")
    args = parser.parse_args()
    source = args.ipa.expanduser().resolve()
    output = args.output_dir.expanduser().resolve()
    if not source.is_file():
        parser.error("Input IPA does not exist")
    provenance = json.loads(args.provenance.expanduser().resolve().read_text())
    for name, expected in provenance["source_sha256_by_file"].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"Source differs from {provenance['release']} provenance: {name}. Review before building a changed release.")
    for name, expected in provenance.get("eevee_source_sha256_by_file", {}).items():
        if hashlib.sha256((ROOT.parent / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"Eevee UI source differs from release provenance: {name}")
    eevee_input = args.eevee_dylib.expanduser().resolve().read_bytes() if args.eevee_dylib else None
    import os
    os.chdir(ROOT)
    with ZipFile(source) as check:
        import plistlib
        plist = next(n for n in check.namelist() if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist"))
        info = plistlib.loads(check.read(plist))
        if info.get("CFBundleShortVersionString") != "9.1.88":
            raise RuntimeError("Only the checked Spotify 9.1.88 binary is supported")
        # Validate all native guards and the Eevee target before compilation.
        app = plist.rsplit("/", 1)[0]
        patch_key_request_mode(patch_native_restrictions(check.read(f"{app}/{info['CFBundleExecutable']}"))[0])
        if eevee_input is None:
            eevee_input = check.read(f"{app}/Frameworks/EeveeSpotify.dylib")
        for marker in provenance.get("eevee_required_markers", []):
            if marker.encode() not in eevee_input:
                raise RuntimeError("The Eevee library lacks the new UI. Rebuild Eevee and pass --eevee-dylib /path/to/EeveeSpotify.dylib")
        patch_reminder(eevee_input)
    output.mkdir(parents=True, exist_ok=True)
    BUILD.mkdir(exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    if (ROOT / "src/NativeRestrictionsPatch.h").read_text() != guard_header():
        raise RuntimeError("Native restriction guard header differs from the binary patch")
    if (ROOT / "src/OfflineLimits.h").read_text() != limits_header():
        raise RuntimeError("Offline limit constants differ from the binary patch")
    library = output / "SpotifyAudioProbe.dylib"
    run("xcrun", "clang", "-dynamiclib", "-arch", "arm64", "-target", "arm64-apple-ios15.0",
        "-isysroot", sdk, "-fobjc-arc", "-std=gnu11", "-O2", "-fvisibility=hidden",
        "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-nullability-completeness",
        "-Werror=implicit-function-declaration", "-Isrc",
        "src/AudioProbe.c", "src/Diagnostics.m", "src/Localization.m", "src/AVAudioHooks.m", "src/SourceGraph.c", "src/OfflineFlags.m", "src/WireProto.m", "src/OfflineConfig.m", "src/TrackJournal.m", "src/NativeErrorLog.m", "src/PlayerTrace.m", "src/NativeOffline.m", "src/NativeAlbumCommand.m", "src/TrackDownload.m", "src/AudioProbeUI.m", "src/DownloadSettingsUI.m", "src/SupportLog.m", "src/DownloadCompatibility.m", "src/OfflineDevices.m", "src/DiagnosticTrace.m", "src/TracePlatform.m", "src/NativeKeyTrace.m",
        "-framework", "AudioToolbox", "-framework", "Foundation", "-framework", "UIKit", "-framework", "AVFAudio", "-framework", "CoreGraphics", "-framework", "AVFoundation", "-framework", "CoreMedia", "-framework", "Network", "-framework", "ImageIO", "-framework", "QuartzCore",
        "-Wl,-install_name,@rpath/SpotifyAudioProbe.dylib", "-o", library)
    run("codesign", "--force", "--sign", "-", "--timestamp=none", library)
    with ZipFile(source) as original:
        plist = next(n for n in original.namelist() if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist"))
        import plistlib
        info = plistlib.loads(original.read(plist))
        app = plist.rsplit("/", 1)[0]
        executable = f"{app}/{info['CFBundleExecutable']}"
        binary, manifest = patch(original.read(executable))
        binary, native_patch = patch_native_restrictions(binary)
        manifest["native_restriction_guard"] = native_patch
        binary, key_patch = patch_key_request_mode(binary)
        manifest["native_key_request_mode"] = key_patch
        staged = BUILD / info["CFBundleExecutable"]
        staged.write_bytes(binary)
        staged.chmod(0o755)
        run("codesign", "--force", "--sign", "-", "--timestamp=none", staged)
        run("xcrun", "dyld_info", "-validate_only", staged)
        imports = subprocess.check_output(["xcrun", "dyld_info", "-imports", str(staged)], text=True)
        for change in manifest["changes"]:
            matches = [line for line in imports.splitlines() if change["symbol"] in line]
            if not matches or not all("SpotifyAudioProbe" in line for line in matches):
                raise RuntimeError(f"dyld does not resolve {change['symbol']} through the probe: {matches}")
        eevee_entry = f"{app}/Frameworks/EeveeSpotify.dylib"
        eevee_data, reminder = patch_reminder(eevee_input)
        patched_eevee = BUILD / "EeveeSpotify-offline.dylib"
        patched_eevee.write_bytes(eevee_data)
        run("codesign", "--force", "--sign", "-", "--timestamp=none", patched_eevee)
        run("codesign", "--verify", "--strict", patched_eevee)
        run("xcrun", "dyld_info", "-validate_only", patched_eevee)
        manifest["offline_reminder_patch"] = reminder
        archive = output / (provenance["release"] + ".ipa")
        if archive.resolve() == source:
            raise RuntimeError("Output must differ from the input IPA")
        with ZipFile(archive, "w", allowZip64=True) as updated:
            for item in original.infolist():
                replacement = staged.read_bytes() if item.filename == executable else patched_eevee.read_bytes() if item.filename == eevee_entry else original.read(item.filename)
                updated.writestr(item, replacement)
            updated.write(library, f"{app}/Frameworks/SpotifyAudioProbe.dylib")
    with ZipFile(archive) as result, ZipFile(source) as original:
        if result.testzip() is not None:
            raise RuntimeError("Archive integrity check failed")
        changed = [entry.filename for entry in original.infolist() if (entry.CRC, entry.file_size) !=
                   (result.getinfo(entry.filename).CRC, result.getinfo(entry.filename).file_size)]
        if set(changed) != {executable, eevee_entry}:
            raise RuntimeError(f"Unexpected modified original entries: {changed}")
    manifest.update({"source_ipa": source.name, "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                     "output": archive.name, "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                     "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest(), "changed_entries": changed,
                     "ui_release": provenance["release"],
                     "source_sha256_by_file": provenance["source_sha256_by_file"],
                     "eevee_source_sha256_by_file": provenance.get("eevee_source_sha256_by_file", {}),
                     "eevee_input_sha256": hashlib.sha256(eevee_input).hexdigest(),
                     "eevee_output_sha256": hashlib.sha256(patched_eevee.read_bytes()).hexdigest()})
    (output / "build-manifest.json").write_text(json.dumps(manifest, indent=2))
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
