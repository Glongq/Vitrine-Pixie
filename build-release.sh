#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 /path/to/Spotify-Vitrine-b16.ipa [new-output-directory]" >&2
    exit 2
fi
args=("$1")
if [ "$#" -gt 1 ]; then args+=(--output-dir "$2"); fi
exec python3 "$ROOT/NativeDownloads/tools/build.py" "${args[@]}"
