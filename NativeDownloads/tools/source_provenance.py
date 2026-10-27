"""Record the current checked source snapshot after reviewing source changes."""
from pathlib import Path
import hashlib
import json
from pixie_target import PROFILE, ROOT


def snapshot():
    project = ROOT.parent
    paths = []
    for base in [ROOT / "src", ROOT / "tools", ROOT / "targets", ROOT / "tests",
                 project / "vitrine-upstream/tweak/Sources", project / "Tests"]:
        paths.extend(path for path in base.rglob("*") if path.is_file()
                     and "__pycache__" not in path.parts
                     and "Generated/RepoSlug.swift" not in path.as_posix())
    paths.extend(project / name for name in (
        "Makefile", "BUILD-pixie-v1.3.md", "build-release.sh",
        "tools/verify-release.py", "tools/test-audio-coexistence.py",
        ".github/workflows/native-downloads.yml", "vitrine-upstream/tweak/Makefile",
        "vitrine-upstream/tweak/control", "vitrine-upstream/version.txt",
        "vitrine-upstream/scripts/extract-flags.py") if (project / name).is_file())
    return {str(path.relative_to(project)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(paths)}


def main():
    value = {"release": PROFILE["id"], "spotify_version": PROFILE["spotify_version"],
             "spotify_build": PROFILE["spotify_build"], "spotify_uuid": PROFILE["uuid"],
             "vitrine_version": PROFILE["vitrine_version"], "pixie_version": PROFILE["pixie_version"],
             "source_sha256_by_file": snapshot()}
    (ROOT / "provenance-pixie-v1.3.json").write_text(json.dumps(value, indent=2) + "\n")
    print(f'Recorded {len(value["source_sha256_by_file"])} source files')


if __name__ == "__main__":
    main()
