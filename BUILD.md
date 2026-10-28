# Build Vitrine beta 16 / Spotify 9.1.90 / Pixie 1.3

Requires macOS, full Xcode, Python 3 and Theos for rebuilding Vitrine. Follow
Vitrine's own dependency instructions. This repository is a source overlay;
Spotify binaries and complete upstream checkouts are not included.

## Prepare the pinned Vitrine source

```sh
git clone https://github.com/My-Name-Is-Jeff/vitrine.git vitrine-upstream
git -C vitrine-upstream checkout 36d3b38ec39c0b8b696f1d2db026ca9e9939bf14
git -C vitrine-upstream apply --check ../patches/vitrine-pixie.patch
git -C vitrine-upstream apply ../patches/vitrine-pixie.patch
```

The existing patch preserves the native and redesigned controls and the Pixie
integration. Native addresses and source ownership are declared in
`NativeDownloads/targets/spotify-9.1.90.json`.

## Validate and build

```sh
python3 NativeDownloads/tools/validate_vitrine_9190.py
python3 NativeDownloads/tools/test.py
python3 NativeDownloads/tools/test_settings_ui.py --compile-only
python3 NativeDownloads/tools/build.py /path/to/stock-Vitrine-b16-with-plugins.ipa --theos /path/to/theos
```

The input is a compatible Vitrine beta 16 / Spotify 9.1.90 IPA before Pixie was
applied. The full driver generates the Spotify flag table, rebuilds Vitrine and
Pixie and verifies the packaged IPA. Paths containing spaces are handled through
a temporary Theos alias. Outputs go into a fresh root `outputs` directory.

A reviewed rebuilt library may be supplied with `--vitrine-dylib` to skip Vitrine
compilation. The lower-level `build_vitrine_9190.py` accepts the same library and
an explicit new `--output` IPA path. Installation requires normal resigning.
No build command installs or launches on a phone.

The public API, file map and ownership contracts are documented under
`NativeDownloads/docs`. After reviewing source changes, regenerate provenance
with `python3 NativeDownloads/tools/source_provenance.py`. The published snapshot
covers committed overlay sources; the complete upstream source remains pinned
by the checkout revision and integration patch above.

Regular IPA version: tested through LiveContainer and SideStore.
Jailbreak version: NOT TESTED on a jailbroken device. The current branch supports
the companion IPA only. Older DEBs remain at tag `pixie-9.1.90-jailbreak-1` and
have not been rebuilt from this source update. Historical tooling is not included.
