"""Compile and run the real library-first artist download queue with host stubs."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path,
                    default=ROOT.parent / 'outputs/artist-library-downloads-2026-10-24/queue-check-001')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
binary = output / 'artist-native-queue-tests'
command = [
    'xcrun', 'clang', '-arch', 'arm64', '-std=gnu11', '-O1', '-g', '-fobjc-arc',
    '-DSAP_TESTING', '-fsanitize=address,undefined', '-Isrc',
    'src/ArtistDownloadQueue.m', 'src/WireProto.m',
    'tests/artist_native_queue.m', '-framework', 'Foundation', '-o', str(binary),
]
compiled = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=45)
(output / 'compile.log').write_text(compiled.stdout)
if compiled.returncode:
    print(compiled.stdout, end='')
    raise SystemExit(compiled.returncode)
result = subprocess.run([str(binary)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, timeout=45)
(output / 'run.log').write_text(result.stdout)
print(result.stdout, end='')
raise SystemExit(result.returncode)
