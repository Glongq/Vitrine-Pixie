#!/usr/bin/env python3
"""Verify the isolated beta-16 release and record its active source hashes."""
import argparse
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "NativeDownloads/tools"))
from patch_native_restrictions import layout
import patch_native_restrictions as restriction
import patch_native_trace as trace
from signing_metadata import embedded_entitlements


def digest(data):
    return hashlib.sha256(data).hexdigest()


def text_sections(data):
    assert struct.unpack_from("<I", data)[0] == 0xFEEDFACF
    offset = 32
    result = {}
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, offset)
        if command == 0x19:
            count = struct.unpack_from("<I", data, offset + 64)[0]
            for index in range(count):
                section = offset + 72 + index * 80
                name, segment = struct.unpack_from("<16s16s", data, section)
                if segment.rstrip(b"\0") != b"__TEXT":
                    continue
                length, start = struct.unpack_from("<QI", data, section + 40)
                result[name.rstrip(b"\0").decode()] = data[start:start + length]
        offset += size
    assert result
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path)
    parser.add_argument("--ipa-only", action="store_true", help="Verify the IPA without requiring an outer ZIP")
    parser.add_argument("--release-dir", type=Path, default=ROOT / "release")
    parser.add_argument("--vitrine-dylib", type=Path, default=ROOT / "research/b16/spotifyglass-b16-pixie.dylib")
    args = parser.parse_args()
    release = args.release_dir.resolve()
    source = args.source.resolve() if args.source else ROOT / "inputs/Spotify 9.1.90 (Vitrine 1.0.0-b16) With Plugins.ipa"
    ipa = release / "Spotify-9.1.90-Vitrine-b16-Pixie-v1.3.ipa"
    outer = ipa.with_suffix(".zip")
    native = "Payload/Spotify.app/Spotify"
    glass = "Payload/Spotify.app/Frameworks/spotifyglass.dylib"
    pixie = "Payload/Spotify.app/Frameworks/SpotifyAudioProbe.dylib"
    with ZipFile(source) as original, ZipFile(ipa) as archive:
        assert archive.testzip() is None
        names, old_names = archive.namelist(), original.namelist()
        assert len(names) == len(set(names)), "Duplicate IPA members"
        changed = sorted(name for name in set(names) & set(old_names)
                         if archive.read(name) != original.read(name))
        added = sorted(set(names) - set(old_names))
        removed = sorted(set(old_names) - set(names))
        assert changed == sorted([native, glass]), changed
        assert added == [pixie] and not removed, (added, removed)
        executable = archive.read(native)
        _, _, segments, uuid = layout(executable)
        assert uuid.hex() == "fbce22c17e1b3e0d9be866ff9291943e"
        text = next(segment for segment in segments if segment[0] == b"__TEXT")
        def at(address, size):
            start = text[3] + address - text[1]
            assert text[1] <= address and address + size <= text[1] + text[4]
            return executable[start:start + size]
        stub = restriction.trampoline()
        assert at(restriction.CAVE, len(stub)) == stub
        assert at(restriction.SETTER, len(restriction.ORIGINAL)) == (
            struct.pack("<I", restriction.branch(restriction.SETTER, restriction.CAVE)) + restriction.ORIGINAL[4:])
        for point in trace.POINTS:
            _, address, cave, displaced, _ = point
            code = trace.trampoline(point)
            assert at(cave, len(code)) == code
            assert at(address, 4) == struct.pack("<I", restriction.branch(address, cave))
            if len(displaced) > 4:
                assert at(address + 4, len(displaced) - 4) == displaced[4:]
        assert at(trace.POINTS[0][1] + 4, 4) == bytes.fromhex("20013fd6")
        extension_names = sorted(name for name in old_names if ".appex/" in name)
        assert extension_names == sorted(name for name in names if ".appex/" in name)
        assert all(original.read(name) == archive.read(name) for name in extension_names)
        widget = "Payload/Spotify.app/PlugIns/WidgetExtension.appex/WidgetExtension"
        assert widget in names, "Home-screen widget is missing"
        source_entitlements = embedded_entitlements(original.read(native))
        main_entitlements = embedded_entitlements(executable)
        assert main_entitlements == source_entitlements, "Host entitlements changed"
        widget_entitlements = embedded_entitlements(archive.read(widget))
        shared_groups = sorted(set(main_entitlements.get("com.apple.security.application-groups", [])) &
                               set(widget_entitlements.get("com.apple.security.application-groups", [])))
        assert shared_groups, "Host and widget have no common input App Group"
        app_groups_helper = "Payload/Spotify.app/Frameworks/SpotifyGlassAppGroups.dylib"
        assert original.read(app_groups_helper) == archive.read(app_groups_helper)
        assert not any(name.endswith("embedded.mobileprovision") for name in names)
        validation = release / "validation-machos"
        validation.mkdir(parents=True, exist_ok=True)
        for member in (native, glass, pixie):
            path = validation / Path(member).name
            path.write_bytes(archive.read(member))
            subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True)
            signing = subprocess.run(["codesign", "-d", "--verbose=4", str(path)],
                                     capture_output=True, text=True, check=True)
            assert "Signature=adhoc" in signing.stderr, path
            subprocess.run(["xcrun", "dyld_info", "-validate_only", str(path)], check=True)
        assert text_sections(archive.read(glass)) == text_sections(
            args.vitrine_dylib.read_bytes())
        dependencies = subprocess.check_output(
            ["xcrun", "dyld_info", "-dependents", str(validation / "spotifyglass.dylib")], text=True)
        assert "@loader_path/CydiaSubstrate.framework/CydiaSubstrate" in dependencies
        symbols = subprocess.check_output(["nm", "-g", str(validation / "SpotifyAudioProbe.dylib")], text=True)
        for forbidden in ("SpotifyAudioProbeBeginCapture", "SpotifyAudioProbeReadCapture",
                          "SpotifyAudioProbeEndCapture", "SAPRecorder", "CaptureRing"):
            assert forbidden not in symbols, forbidden
        binary = archive.read(pixie)
        for forbidden in (b"Start WAV recording", b"Export last WAV", b"wav-writer",
                          b"wav_capture_supported", b"last_wav_available"):
            assert forbidden not in binary, forbidden
        assert b"9.1.90-v1.3\0" in binary
        footer = "Spotify 9.1.90 · Vitrine-Pixie v1.3."
        assert footer.encode("utf-8") + b"\0" in binary or footer.encode("utf-16-le") + b"\0\0" in binary
        assert b"9.1.90-v1.2\0" not in binary
        assert b"vitrine-b16-pixie-1.3-refactor-9190" in binary
        assert "_SAPShowArtistDownloads" in symbols
    if not args.ipa_only:
        with ZipFile(outer) as archive:
            assert archive.testzip() is None
            assert archive.namelist() == [ipa.name]
            assert archive.read(ipa.name) == ipa.read_bytes()
    report = {
        "spotify_version": "9.1.90", "vitrine_version": "1.0.0-beta.16",
        "pixie_version": "1.3", "revision": "vitrine-b16-pixie-1.3-refactor-9190",
        "source_commit": "36d3b38ec39c0b8b696f1d2db026ca9e9939bf14",
        "input_sha256": digest(source.read_bytes()), "ipa_sha256": digest(ipa.read_bytes()),
        "zip_sha256": None if args.ipa_only else digest(outer.read_bytes()), "changed_input_members": changed,
        "outer_zip_verified": not args.ipa_only,
        "added_members": added, "removed_members": removed,
        "wav_recording_code_present": False, "signatures": "ad_hoc_machos_verified",
        "personal_certificate_included": False, "requires_installer_resigning": True,
        "optimization_changes_applied": True, "physical_device_tested": False,
        "automatic_phone_install_or_launch": False,
        "fixed_mode_zero_boundary_verified": True, "restriction_guard_verified": True,
        "extensions_unchanged": True, "extension_member_count": len(extension_names),
        "host_entitlements_preserved": True, "home_screen_widget_present": True,
        "shared_input_app_groups": shared_groups, "app_groups_helper_unchanged": True,
        "widget_physical_device_tested": False,
    }
    (release / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    files = [ROOT / "build-release.sh", Path(__file__).resolve(), ROOT / "tools/test-audio-coexistence.py"]
    for folder in ("NativeDownloads/src", "NativeDownloads/tools", "NativeDownloads/tests",
                   "vitrine-upstream/tweak/Sources", "docs"):
        files.extend(path for path in (ROOT / folder).rglob("*") if path.is_file()
                     and "__pycache__" not in path.parts and path.suffix != ".pyc")
    files.extend(ROOT / name for name in ("vitrine-upstream/tweak/Makefile",
                 "vitrine-upstream/tweak/control", "vitrine-upstream/version.txt",
                 "vitrine-upstream/scripts/extract-flags.py") if (ROOT / name).is_file())
    manifest = {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in sorted(set(files))}
    (release / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("PASS: IPA, " + ("" if args.ipa_only else "outer ZIP, ") + "signatures, source identity, WAV absence and active source manifest")


if __name__ == "__main__":
    main()
