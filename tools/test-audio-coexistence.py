#!/usr/bin/env python3
"""Run Vitrine's real audio handoff fixture through Pixie's import wrappers."""
import argparse
import json
from datetime import datetime
import os
import plistlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "NativeDownloads/tools"))
from patch_imports import patch
from pixie_target import include_directories, resolve_source

OUT = None
APP = None
SRC = ROOT / "vitrine-upstream/tweak/Sources"
HARNESS = ROOT / "vitrine-upstream/harness/lossless"
PIXIE = ROOT / "NativeDownloads/src"
BUNDLE = "dev.vitrine.pixie-audio-handoff"


def run(*args):
    try:
        return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as error:
        print(error.output, file=sys.stderr)
        raise


def main():
    global OUT, APP
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Explicitly install/run on an already booted simulator; default only compiles")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "outputs" / datetime.now().strftime("audio-coexistence-%Y%m%d-%H%M%S-%f"))
    args = parser.parse_args()
    OUT = args.output_dir.resolve()
    OUT.mkdir(parents=True, exist_ok=False)
    APP = OUT / "PixieVitrineHandoff.app"
    APP.mkdir()
    frameworks = APP / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path").strip()
    flags = ["xcrun", "clang", "-target", "arm64-apple-ios17.0-simulator", "-fobjc-arc", "-O1", "-g", "-isysroot", sdk]
    shim = OUT / "control.m"
    shim.write_text('#import "Diagnostics.h"\nvoid PixieTestSetDiagnostics(bool enabled) { SAPDiagnosticsSetEnabled(enabled); }\n')
    library = frameworks / "SpotifyAudioProbe.dylib"
    run(*flags, "-dynamiclib", *("-I" + str(p) for p in include_directories()), *(resolve_source(n) for n in ("AudioProbe.c", "DiagnosticsPreferences.m", "Localization.m", "DiagnosticTrace.m", "NativeKeyTrace.m", "WireProto.m")),
        ROOT / "NativeDownloads/tests/trace_platform_stub.m", shim,
        "-framework", "AudioToolbox", "-framework", "Foundation",
        "-Wl,-install_name,@rpath/SpotifyAudioProbe.dylib", "-o", library)
    run("codesign", "--force", "--sign", "-", "--timestamp=none", library)
    logos = Path(os.environ["THEOS"]) / "bin/logos.pl"
    speed = OUT / "SpeedPitch.m"
    speed.write_text(run(logos, "-c", "generator=internal", SRC / "Shared/Player/SpeedPitch.x"))
    source = (HARNESS / "handoff.m").read_text()
    source = '#import "AudioProbe.h"\n#import <dlfcn.h>\n@protocol SGPlayerStateObserver;\n' + source
    # The handoff fixture has no Spotify player-state registry. Preserve that
    # existing test boundary when the newer SpeedPitch ctor registers an observer.
    source = source.replace("void *SGPlayerState(void) { return NULL; }", "void *SGPlayerState(void) { return NULL; }\nvoid SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) {}", 1)
    source = source.replace("static int failures;", """static int failures;
static atomic_uint_fast64_t pixieObservedFrames;
static BOOL pixieDiagnostics;
static void (*pixieSnapshot)(SAPSnapshot *);
static void pixieObserve(const AudioStreamBasicDescription *format, AudioBufferList *buffers, UInt32 frames) {
    atomic_fetch_add(&pixieObservedFrames, frames);
}
""", 1)
    marker = "    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];"
    assert source.count(marker) == 1
    source = source.replace(marker, """    void (*observer)(SAPPCMObserver)=dlsym(RTLD_DEFAULT,"SpotifyAudioProbeSetObserver");
    void (*diagnostics)(bool)=dlsym(RTLD_DEFAULT,"PixieTestSetDiagnostics");
    pixieSnapshot=dlsym(RTLD_DEFAULT,"SpotifyAudioProbeReadSnapshot");
    expect(observer && diagnostics && pixieSnapshot,"Pixie dependency loaded beside Vitrine audio");
    if(!observer || !diagnostics || !pixieSnapshot)exit(2);
    pixieDiagnostics=[NSProcessInfo.processInfo.arguments containsObject:@"diagnostics-on"];
    diagnostics(pixieDiagnostics);observer(pixieObserve);
""" + marker, 1)
    marker = '        printf("RESULT failures=%d nativeFrames='
    assert source.count(marker) == 1
    source = source.replace(marker, """        SAPSnapshot snapshot={0};pixieSnapshot(&snapshot);
        expect(snapshot.backendReady && snapshot.registrations>0 && atomic_load(&pixieObservedFrames)>0,
               "Pixie observes PCM through Vitrine without taking its stage/source slots");
        expect(!snapshot.poolExhausted && snapshot.callbackErrors==0,"Pixie callback registry remains valid");
        expect(pixieDiagnostics ? snapshot.frames>0 && snapshot.callbacks>0 : snapshot.frames==0 && snapshot.callbacks==0,
               "diagnostics counters match the selected ON/OFF state");
""" + marker, 1)
    main_source = OUT / "handoff-with-pixie.m"
    main_source.write_text(source)
    executable = APP / "PixieVitrineHandoff"
    run(*flags, "-I" + str(SRC), "-I" + str(SRC / "Shared/Player"), *("-I" + str(p) for p in include_directories()),
        "-Wno-deprecated-declarations", main_source, ROOT / "vitrine-upstream/harness/scene.m", speed,
        *(SRC / name for name in ["Shared/Lossless/SGPreparedPCM.m", "Shared/Lossless/SGPCMReplacement.m",
          "Shared/Player/SGTimePitch.m", "Core/SGRebind.m", "Core/SGLog.m", "Core/SGPrefs.m", "Core/SGUIMode.m", "Core/SGFlagForce.m"]),
        "-framework", "UIKit", "-framework", "Foundation", "-framework", "AVFoundation",
        "-framework", "AudioToolbox", "-framework", "QuartzCore", "-Wl,-headerpad,0x1000", "-o", executable)
    changed, manifest = patch(executable.read_bytes())
    executable.write_bytes(changed)
    run("ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "aevalsrc=0.08*sin(2*PI*440*t)|0.06*sin(2*PI*997*t):s=44100:d=12",
        "-c:a", "flac", "-sample_fmt", "s16", APP / "fixture.flac")
    run("ffmpeg", "-v", "error", "-y", "-i", APP / "fixture.flac", "-c:a", "alac", "-sample_fmt", "s32p", APP / "fixture.m4a")
    info = {"CFBundleExecutable": executable.name, "CFBundleIdentifier": BUNDLE, "CFBundleName": "Audio coexistence",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "UILaunchScreen": {},
            "UIApplicationSceneManifest": {"UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [
                {"UISceneConfigurationName": "Default", "UISceneDelegateClassName": "SGRHarnessScene"}]}}}
    (APP / "Info.plist").write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", "-", "--timestamp=none", APP)
    if not args.run:
        (OUT / "result.json").write_text(json.dumps({"compiled":True,"runtime_tested":False,"app":str(APP)},indent=2)+"\n")
        print("PASS: Vitrine audio coexistence fixture compiled; no simulator queried, installed or launched")
        return
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "--json"))["devices"]
    booted = [device for group in devices.values() for device in group
              if device["state"] == "Booted" and device.get("isAvailable") and "iPhone" in device["name"]]
    assert len(booted) == 1, "Select exactly one already booted iPhone simulator"
    udid = booted[0]["udid"]
    run("xcrun", "simctl", "install", udid, APP)
    for mode in ["diagnostics-off", "diagnostics-on"]:
        with (OUT / (mode + ".log")).open("w") as log:
            result = subprocess.run(["xcrun", "simctl", "launch", "--console", udid, BUNDLE, mode],
                                    stdout=log, stderr=subprocess.STDOUT, timeout=45)
        output = (OUT / (mode + ".log")).read_text()
        assert result.returncode == 0 and "RESULT failures=0" in output, output[-9000:]
        print("PASS: real Vitrine source replacement, stage, speed, pause/resume and Pixie import chain: " + mode)
    (OUT / "result.json").write_text(json.dumps({"passed": True, "simulator": udid,
        "diagnostics_off": True, "diagnostics_on": True, "imports": manifest,
        "source": "production SpeedPitch/PCMReplacement and Pixie AudioProbe; generated local test audio only",
        "physical_device_tested": False}, indent=2) + "\n")


if __name__ == "__main__":
    main()
