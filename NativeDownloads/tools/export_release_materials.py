"""Bundle third-party notices and complete companion relink source, without runtime data."""
from pathlib import Path
import shutil
ROOT=Path(__file__).resolve().parents[1]

def notices():
    return {
        'Payload/Spotify.app/PixieExportLicenses/M4A-NOTICES.md':(ROOT/'vendor/M4A-NOTICES.md').read_bytes(),
    }

def retain_relink_sources(output):
    destination=Path(output).with_suffix('.relink-sources')
    destination.mkdir()
    for name in ['src','tools','targets','vendor']:
        shutil.copytree(ROOT/name,destination/'NativeDownloads'/name,ignore=shutil.ignore_patterns('__pycache__','*.pyc','.DS_Store'))
    (destination/'README.md').write_text('''# Pixie companion relink source

Complete companion source and the stb_vorbis decoder source are included. No phone data or keys are included.

Requires macOS, Xcode command-line tools and Python 3. Rebuild using the original Spotify 9.1.90 Vitrine/Pixie base IPA:

    python3 NativeDownloads/tools/build_export_port.py /path/to/base.ipa --output /path/to/new.ipa

The builder compiles the provided application source and Swift bridge. M4A/AAC uses Apple system frameworks; Ogg decoding uses the bundled stb_vorbis source. See NativeDownloads/vendor/M4A-NOTICES.md.
''')
    return str(destination)
