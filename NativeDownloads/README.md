# Pixie Manager 1.3 — Vitrine / Spotify 9.1.90

The current companion is organized by responsibility. Its exact Spotify identity
and 51 production translation units are declared in
[targets/spotify-9.1.90.json](targets/spotify-9.1.90.json).

- [Build instructions](../BUILD.md)
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
capture is removed. Music remains in Spotify; ordinary audio-file export is not
a supported feature. The current target is the companion IPA; older jailbreak
releases are separate and were not rebuilt by this source update.
