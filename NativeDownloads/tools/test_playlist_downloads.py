"""Exercise the production playlist workflow and shared context scheduler on host stubs."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
manifest = {}
for name, sources in [
    ('playlists', ['src/PlaylistDownloads.m', 'src/WireProto.m', 'tests/playlist_downloads.m']),
    ('streaming', ['src/PlaylistDownloads.m', 'src/WireProto.m', 'tests/playlist_streaming.m']),
    ('session', ['src/ArtistDownloadSession.m', 'src/WireProto.m', 'tests/artist_session.m']),
]:
    binary = output / name
    compiled = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-std=gnu11', '-O1', '-g',
        '-DSAP_TESTING', '-fsanitize=address,undefined', '-Isrc', *sources,
        '-framework', 'Foundation', '-o', str(binary)], cwd=ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=45)
    (output / (name + '-compile.log')).write_text(compiled.stdout)
    if compiled.returncode:
        print(compiled.stdout, end='')
        raise SystemExit(compiled.returncode)
    result = subprocess.run([str(binary)], cwd=ROOT, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, timeout=45)
    (output / (name + '-run.log')).write_text(result.stdout)
    print(result.stdout, end='', flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
    manifest[name] = {s: hashlib.sha256((ROOT / s).read_bytes()).hexdigest() for s in sources + (["src/PlaylistArtwork.h"] if name == "playlists" else [])}
(output / 'tested-source-sha256.json').write_text(json.dumps(manifest, indent=2) + '\n')
