"""Build the current Vitrine/Pixie IPA in one fresh output directory."""
import argparse
from datetime import datetime
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from pixie_target import PROFILE, ROOT, validate_sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--theos", type=Path, default=os.environ.get("THEOS"))
    parser.add_argument("--vitrine-dylib", type=Path, help="Use a reviewed current Vitrine library instead of rebuilding unchanged Vitrine sources")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    source = args.ipa.resolve()
    if not source.is_file():
        parser.error("Input IPA not found")
    if not args.vitrine_dylib and (not args.theos or not args.theos.is_dir()):
        parser.error("Supply --theos /path/to/theos, set THEOS, or supply --vitrine-dylib")
    validate_sources()
    output = (args.output_dir or ROOT.parent / "outputs" / datetime.now().strftime("build-%Y%m%d-%H%M%S-%f")).resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ)
    env.pop("MAKELEVEL", None)
    if args.vitrine_dylib:
        library = args.vitrine_dylib.resolve()
        if not library.is_file():
            parser.error("Supplied Vitrine library not found")
    else:
        env.update(THEOS=str(args.theos.resolve()), SG_DRIVER="0")
        upstream = ROOT.parent / "vitrine-upstream"
        with (output / "vitrine-build.log").open("w") as log:
            subprocess.run([sys.executable, str(upstream / "scripts/extract-flags.py"), str(source)], cwd=upstream, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            # Theos sees a path without spaces; all outputs remain in this source copy.
            with tempfile.TemporaryDirectory(prefix="pixie-vitrine-project-") as temporary:
                alias = Path(temporary) / "project"
                alias.symlink_to(upstream, target_is_directory=True)
                env["THEOS_PROJECT_DIR"] = str(alias / "tweak")
                subprocess.run(["gmake", "-C", str(alias / "tweak"), f"-j{args.jobs}", "all", f"THEOS_PROJECT_DIR={alias / 'tweak'}"], env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        library = upstream / "tweak/.theos/obj/spotifyglass.dylib"
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(library)], check=True)
    archive = output / f'Spotify-{PROFILE["spotify_version"]}-Vitrine-b16-Pixie-v{PROFILE["pixie_version"]}.ipa'
    with (output / "ipa-build.log").open("w") as log:
        subprocess.run([sys.executable, str(ROOT / "tools/build_vitrine_9190.py"), str(source), "--vitrine-dylib", str(library), "--output", str(archive)], cwd=ROOT.parent, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run([sys.executable, str(ROOT.parent / "tools/verify-release.py"), str(source), "--release-dir", str(output), "--vitrine-dylib", str(library), "--ipa-only"], cwd=ROOT.parent, env=env, check=True)
    print(archive)


if __name__ == "__main__":
    main()
