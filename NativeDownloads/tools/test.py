import os
from pathlib import Path
import subprocess
import sys

from patch_imports import patch

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
build = ROOT / "build/tests"
build.mkdir(parents=True, exist_ok=True)


def run(*args):
    args=list(args)
    if args[:2]==["xcrun","clang"] and "-c" not in args:
        paths=[Path(str(x)) for x in args if str(x).endswith((".m",".c"))]
        needs_trace=any(p.is_file() and ('"DiagnosticTrace.h"' in p.read_text() or p.name=="Diagnostics.m") for p in paths)
        if needs_trace and 'tests/artist_downloads.m' not in args:
            if "-fobjc-arc" not in args:args.insert(2,"-fobjc-arc")
            for source in ["src/DiagnosticTrace.m","src/NativeKeyTrace.m","src/WireProto.m","tests/trace_platform_stub.m"]:
                if source not in args:args.insert(2,source)
    subprocess.run([str(x) for x in args], check=True)


flags = ["xcrun", "clang", "-arch", "arm64", "-std=gnu11", "-O1", "-g", "-Isrc", "-framework", "AudioToolbox", "-framework", "Foundation"]
run(*flags, "-fobjc-arc", "-fsanitize=address,undefined", "tests/process_scope.m", "-o", build / "process_scope")
run(build / "process_scope")
run(*flags, "-fobjc-arc", "-fsanitize=address,undefined", "tests/native_setup_status.m", "-o", build / "native_setup_status")
run(build / "native_setup_status")
run(*flags, "-DSAP_TESTING", "-fsanitize=address,undefined", "src/AudioProbe.c", "tests/test_probe.c", "src/Diagnostics.m", "src/Localization.m", "-o", build / "test_probe")
run(build / "test_probe")
frameworks = build / "Frameworks"
frameworks.mkdir(exist_ok=True)
run(*flags, "-dynamiclib", "-fvisibility=hidden", "src/AudioProbe.c", "-Wl,-install_name,@rpath/SpotifyAudioProbe.dylib", "src/Diagnostics.m", "src/Localization.m", "-o", frameworks / "SpotifyAudioProbe.dylib")
run(*flags, "tests/offline_unit.c", "-Wl,-headerpad,0x1000", "-o", build / "offline-original")
data, manifest = patch((build / "offline-original").read_bytes())
patched = build / "offline-patched"
patched.write_bytes(data); patched.chmod(0o755)
run("codesign", "--force", "--sign", "-", "--timestamp=none", patched)
run("xcrun", "dyld_info", "-validate_only", patched)
run(patched)
print("PASS: all five import ordinals redirected and runnable on the host")

run(*flags, "-fobjc-arc", "-fsanitize=address,undefined", "src/AudioProbe.c",
    "src/AVAudioHooks.m", "tests/av_hooks.m", "-framework", "AVFoundation", "-framework", "CoreMedia",
    "-framework", "Foundation", "src/Diagnostics.m", "src/Localization.m", "-o", build / "av_hooks")
run(build / "av_hooks")

run(*flags, "tests/converter_graph.c", "-Wl,-headerpad,0x1000", "-o", build / "converter-original")
data, manifest = patch((build / "converter-original").read_bytes())
patched = build / "converter-patched"
patched.write_bytes(data); patched.chmod(0o755)
run("codesign", "--force", "--sign", "-", "--timestamp=none", patched)
run(patched)

run("xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-std=gnu11", "-O1", "-g", "-Isrc",
    "-fsanitize=address,undefined", "src/OfflineFlags.m", "tests/offline_flags.m", "-framework", "Foundation",
    "src/Diagnostics.m", "src/Localization.m", "-o", build / "offline_flags")
run(build / "offline_flags")
run("xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-std=gnu11", "-O1", "-g", "-Isrc",
    "-fsanitize=address,undefined", "src/WireProto.m", "src/OfflineConfig.m", "tests/offline_config.m", "-framework", "Foundation",
    "src/Diagnostics.m", "src/Localization.m", "-o", build / "offline_config")
run(build / "offline_config")
run("xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-std=gnu11", "-O1", "-g", "-Isrc", "-DSAP_TESTING",
    "-fsanitize=address,undefined", "src/WireProto.m", "src/PlayerTrace.m", "tests/player_trace.m", "-framework", "Foundation",
    "src/Diagnostics.m", "src/Localization.m", "-o", build / "player_trace")
run(build / "player_trace")
from patch_offline import patch_reminder, TARGET, DISABLED
from zipfile import ZipFile
test_ipa = os.environ.get("SPOTIFY_TEST_IPA")
if test_ipa:
    with ZipFile(test_ipa) as ipa:
        original = ipa.read("Payload/Spotify.app/Frameworks/EeveeSpotify.dylib")
    changed, reminder = patch_reminder(original)
    assert len(original) == len(changed)
    assert sum(a != b for a, b in zip(original, changed)) == 1
    assert TARGET not in changed and changed.count(DISABLED) == 1
    print("PASS: supplied Eevee reminder target disabled with exactly one byte changed")
else:
    print("SKIP: real-IPA reminder check (set SPOTIFY_TEST_IPA to enable)")

run("xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-std=gnu11", "-O1", "-g", "-Isrc", "-DSAP_TESTING",
    "-fsanitize=address,undefined", "src/WireProto.m", "src/PlayerTrace.m", "src/TrackDownload.m", "tests/track_download.m", "-framework", "Foundation",
    "src/Diagnostics.m", "src/Localization.m", "-o", build / "track_download")
run(build / "track_download", "-AppleLanguages", "(ru)")
run(build / "track_download", "-AppleLanguages", "(en)")

run("xcrun", "clang", "-arch", "arm64", "-fobjc-arc", "-std=gnu11", "-O1", "-g", "-Isrc", "-DSAP_TESTING",
    "-fsanitize=address,undefined", "src/WireProto.m", "src/PlayerTrace.m", "src/TrackJournal.m", "src/NativeErrorLog.m", "tests/track_journal.m", "-framework", "Foundation",
    "src/Diagnostics.m", "src/Localization.m", "-o", build / "track_journal")
# SAP_TESTING keeps the journal's files inside TMPDIR instead of the real Documents directory.
journal_home = build / "journal-home"
journal_home.mkdir(exist_ok=True)
subprocess.run([str(build / "track_journal"), "-AppleLanguages", "(ru)"], check=True, env={**os.environ, "TMPDIR": str(journal_home)})
subprocess.run([str(build / "track_journal"), "-AppleLanguages", "(en)"], check=True, env={**os.environ, "TMPDIR": str(journal_home)})

run(sys.executable, ROOT / "tools/test_native_restrictions.py")

run("xcrun", "clang", "-fobjc-arc", "-Isrc", "src/Localization.m", "tests/localization.m", "-framework", "Foundation", "-o", build / "localization")
run(build / "localization", "English", "-AppleLanguages", "(en-GB)")
run(build / "localization", "English", "-AppleLanguages", "(ru-RU)")

for name,sources in [
    ("artist_downloads", ["src/ArtistMetadata.m", "src/WireProto.m", "tests/artist_downloads.m"]),
    ("artist_native_queue", ["src/ArtistDownloadQueue.m", "src/NativeAlbumCommand.m", "src/WireProto.m", "tests/artist_native_queue.m"]),
    ("support_log", ["src/SupportLog.m", "tests/support_log.m"]),
    ("download_compatibility", ["src/DownloadCompatibility.m", "src/WireProto.m", "tests/download_compatibility.m"]),
    ("offline_devices", ["src/OfflineDevices.m", "src/WireProto.m", "tests/offline_devices.m"]),
]:
    run("xcrun", "clang", "-fobjc-arc", "-std=gnu11", "-Isrc", "-DSAP_TESTING",
        "-fsanitize=address,undefined", *sources, "-framework", "Foundation", "-o", build/name)
    run(build/name)
run("xcrun", "clang", "-std=gnu11", "-Isrc", "tests/key_mode_policy.c", "-o", build/"key_mode_policy")
run(build/"key_mode_policy")

run("xcrun","clang","-fobjc-arc","-std=gnu11","-Isrc","-DSAP_TESTING",
    "-fsanitize=address,undefined","src/DiagnosticTrace.m","src/NativeKeyTrace.m","src/WireProto.m",
    "tests/diagnostic_trace.m","-framework","Foundation","-o",build/"diagnostic_trace")
for scenario in ["normal","rotation","loss","write_error","reset","off_reset"]:
    run(build/"diagnostic_trace",scenario)
run(sys.executable,ROOT/"tests/native_trace_patch.py")
run(sys.executable,ROOT/"tests/signing_metadata.py")
