"""Run focused artist metadata/queue tests and optionally the tiny simulator picker."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ui', action='store_true')
parser.add_argument('--output', type=Path, default=ROOT.parent / 'outputs/artist-downloads-2026-10-23')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)


def run(*command, check=True, timeout=45):
    result = subprocess.run(list(map(str, command)), cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=check, timeout=timeout)
    return result.stdout


test = output / 'artist-downloads-tests'
run('xcrun', 'clang', '-arch', 'arm64', '-std=gnu11', '-O1', '-g', '-fobjc-arc',
    '-fsanitize=address,undefined', '-Isrc', 'src/ArtistMetadata.m',
    'src/WireProto.m', 'tests/artist_downloads.m', '-framework', 'Foundation', '-o', test)
result = run(test)
(output / 'artist-downloads-foundation.log').write_text(result)
(output / 'metadata-tested-source-sha256.json').write_text(json.dumps({name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in ['src/ArtistMetadata.m', 'src/ArtistMetadata.h', 'src/WireProto.m', 'tests/artist_downloads.m']}, indent=2) + '\n')
print(result, end='', flush=True)
if not args.ui:
    raise SystemExit(0)

devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', '--json'))['devices']
booted = [device for group in devices.values() for device in group
          if device['state'] == 'Booted' and device.get('isAvailable') and 'iPhone' in device['name']]
if not booted:
    raise SystemExit('No existing booted iPhone simulator; picker fixture was not run')
udid = booted[0]['udid']
app = output / 'ArtistPickerFixture.app'
app.mkdir(exist_ok=True)
sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path').strip()
run('xcrun', 'clang', '-target', 'arm64-apple-ios27.0-simulator', '-isysroot', sdk,
    '-fobjc-arc', '-std=gnu11', '-g', '-DSAP_TESTING', '-Isrc', 'src/ArtistDownloadsUI.m', 'src/WireProto.m',
    'tests/ArtistDownloadsUIFixture.m', '-framework', 'UIKit', '-framework', 'CoreGraphics', '-framework', 'Foundation', '-framework', 'ImageIO', '-framework', 'QuartzCore',
    '-o', app / 'ArtistPickerFixture', timeout=120)
(output / 'ui-tested-source-sha256.json').write_text(json.dumps({name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in ['src/ArtistDownloadsUI.m', 'src/ArtistMetadata.h', 'src/PlaylistArtwork.h', 'src/WireProto.m', 'tests/ArtistDownloadsUIFixture.m']}, indent=2) + '\n')
bundle = 'local.pixie.artistpickerfixture'
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'ArtistPickerFixture',
    'CFBundleName': 'Artist Picker Fixture', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1',
    'CFBundlePackageType': 'APPL', 'LSRequiresIPhoneOS': True, 'UIDeviceFamily': [1],
    'UILaunchScreen': {}, 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait'],
    'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
        'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
            'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': 'ArtistPickerFixtureScene'}]}}}))
run('codesign', '--force', '--sign', '-', '--timestamp=none', app)
run('xcrun', 'simctl', 'install', udid, app)
run('xcrun', 'simctl', 'terminate', udid, bundle, check=False)
folder = Path(run('xcrun', 'simctl', 'get_app_container', udid, bundle, 'data').strip())
result_file = folder / 'Documents/artist-picker-result.log'
result_file.unlink(missing_ok=True)
print(run('xcrun', 'simctl', 'launch', udid, bundle), end='', flush=True)
deadline = time.monotonic() + 35
while time.monotonic() < deadline:
    if result_file.exists():
        result = result_file.read_text()
        (output / 'artist-picker-ui.log').write_text(result)
        shutil.copy2(folder / 'Documents/artist-picker.png', output / 'artist-picker.png')
        print(result, end='', flush=True)
        if not result.startswith('PASS:'):
            raise RuntimeError('Artist picker cover fixture reported a failure')
        break
    time.sleep(.2)
else:
    raise RuntimeError('Artist picker fixture did not finish its assertions')
