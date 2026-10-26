"""Run the native artist download-button fixture in an already booted iPhone simulator."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
OUTPUT = parser.parse_args().output.resolve()
OUTPUT.mkdir(parents=True, exist_ok=True)


def run(*command, check=True):
    try:
        result = subprocess.run(
            list(map(str, command)), cwd=PROJECT, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=check, timeout=45,
        )
    except subprocess.CalledProcessError as error:
        print(error.stdout, end="")
        raise
    return result.stdout


devices = json.loads(run("xcrun", "simctl", "list", "devices", "--json"))["devices"]
booted = [device for group in devices.values() for device in group
          if device["state"] == "Booted" and device.get("isAvailable") and "iPhone" in device["name"]]
if not booted:
    raise SystemExit("No existing booted iPhone simulator; native artist fixture was not run")
udid = booted[0]["udid"]

source = PROJECT / "vitrine-upstream/tweak/Sources/Native/Artist/ArtistDownloads.m"
if not source.is_file():
    raise SystemExit(f"Native helper source is missing: {source}")

app = OUTPUT / "NativeArtistDownloadsFixture.app"
app.mkdir(parents=True, exist_ok=True)
sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path").strip()
run(
    "xcrun", "clang", "-target", "arm64-apple-ios27.0-simulator", "-isysroot", sdk,
    "-fobjc-arc", "-std=gnu11", "-g", "-Wl,-export_dynamic",
    "-I", PROJECT / "vitrine-upstream/tweak/Sources",
    source,
    ROOT / "tests/NativeArtistDownloadsFixture.m",
    "-framework", "UIKit", "-framework", "Foundation", "-framework", "QuartzCore",
    "-framework", "CoreGraphics",
    "-o", app / "NativeArtistDownloadsFixture",
)

bundle = "local.pixie.nativeartistdownloadsfixture"
(app / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": bundle,
    "CFBundleExecutable": "NativeArtistDownloadsFixture",
    "CFBundleName": "Native Artist Downloads Fixture",
    "CFBundleVersion": "1",
    "CFBundleShortVersionString": "1",
    "CFBundlePackageType": "APPL",
    "LSRequiresIPhoneOS": True,
    "UIDeviceFamily": [1],
    "UILaunchScreen": {},
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    "UIApplicationSceneManifest": {
        "UIApplicationSupportsMultipleScenes": False,
        "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{
            "UISceneConfigurationName": "Default",
            "UISceneDelegateClassName": "NativeArtistDownloadsFixtureScene",
        }]},
    },
}))
run("codesign", "--force", "--sign", "-", "--timestamp=none", app)
run("xcrun", "simctl", "install", udid, app)
run("xcrun", "simctl", "terminate", udid, bundle, check=False)
container = Path(run("xcrun", "simctl", "get_app_container", udid, bundle, "data").strip())
documents = container / "Documents"
result_file = documents / "native-artist-downloads-result.log"
result_file.unlink(missing_ok=True)
print(run("xcrun", "simctl", "launch", udid, bundle), end="", flush=True)

deadline = time.monotonic() + 20
while time.monotonic() < deadline:
    if result_file.exists():
        result = result_file.read_text()
        (OUTPUT / "native-artist-downloads.log").write_text(result)
        screenshot = documents / "native-artist-downloads.png"
        if screenshot.exists():
            shutil.copy2(screenshot, OUTPUT / screenshot.name)
        print(result, end="", flush=True)
        if not result.startswith("PASS:"):
            raise RuntimeError("Native artist fixture reported a failure")
        break
    time.sleep(0.2)
else:
    raise RuntimeError("Native artist fixture did not finish its assertions")
