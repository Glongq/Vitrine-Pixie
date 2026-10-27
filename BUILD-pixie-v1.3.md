# Build Vitrine beta 16 / Spotify 9.1.90 / Pixie 1.3

The supported path is the companion IPA. Addresses and source ownership live in
`NativeDownloads/targets/spotify-9.1.90.json`. Historical build commands, unused queues and unported jailbreak tools are not
included in this publication. See BUILD.md to prepare the pinned upstream source.

```sh
python3 NativeDownloads/tools/validate_vitrine_9190.py
python3 NativeDownloads/tools/test.py
python3 NativeDownloads/tools/test_settings_ui.py --compile-only
python3 NativeDownloads/tools/build.py /path/to/stock-Vitrine-b16-with-plugins.ipa --theos /path/to/theos
```

A reviewed current Vitrine library can be supplied with `--vitrine-dylib` to
rebuild only Pixie. `--output-dir` must name a fresh directory. Input IPA files,
certificates and outputs are not source dependencies and must not be committed.
Builds sign locally with ad-hoc signatures; installation requires the user's
normal signing method. Nothing installs or launches on a device.

The native/redesigned Vitrine UI and SGSpclientHeaders adapter are preserved.
Edit the target profile, then run `generate_target.py` when target identity
changes. `source_provenance.py` records a source snapshot after review.

The root legacy Makefile built Eevee, not Vitrine. The current root Makefile is
only a thin wrapper for validate/test/build; Vitrine's own Theos Makefile stays
in vitrine-upstream/tweak. No current DEB target is claimed by this refactor.
