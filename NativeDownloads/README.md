# Pixie Manager 1.4 — Vitrine / Spotify 9.1.90

The current companion is organized by responsibility. Its exact Spotify identity
and 88 production translation units are declared in
[targets/spotify-9.1.90.json](targets/spotify-9.1.90.json).

- [Build instructions](../BUILD-pixie-v1.3.md)
- [Integration and file map](docs/INTEGRATION-MAP.md)
- [Data and lifetime contracts](docs/CONTRACTS.md)
- [Host fixture runner](tests/README.md)

`src/Spotify` owns native adapters and transport; `Downloads` owns manual jobs
and artist sessions; `Playlists` owns ordered playlist work; `UI` and `Artwork`
own presentation; `Diagnostics` owns optional logs and export; `Devices` owns
offline-device checks; `Runtime` owns startup. Public compatibility APIs remain
in `Public`. Native byte guards and generated identity remain in `Generated`.

```sh
python3 NativeDownloads/tools/validate_vitrine_9190.py
python3 NativeDownloads/tools/test.py
```

Settings/artist fixtures compile without launching by default. Vitrine keeps its
own authentication provider, SGSpclientHeaders. Diagnostics are optional and WAV
capture is removed. Native downloads remain inside Spotify. The Export module additionally turns downloaded tracks into ordinary audio files
(M4A by default, Ogg optional): it reads Spotify's offline cache, validates the
audio and adds cover art and tags. Use the Downloaded tracks manager or the
native share menu to save files outside the app.
Key state is process-only; a usable key and complete cache must be available. The current target is the companion IPA; older jailbreak
releases are separate and were not rebuilt by this source update.
