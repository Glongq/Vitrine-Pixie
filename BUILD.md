# Build Spotify 9.1.90 + Pixie v1.3

Requires macOS, full Xcode with an iOS 26+ SDK, Python 3, Theos, GNU make, ldid and dpkg. Follow Vitrine's own setup instructions for its build dependencies.

## 1. Prepare Vitrine sources

From this repository root:

```sh
git clone https://github.com/My-Name-Is-Jeff/vitrine.git vitrine
git -C vitrine checkout 36d3b38ec39c0b8b696f1d2db026ca9e9939bf14
git -C vitrine apply --check ../patches/vitrine-pixie.patch
git -C vitrine apply ../patches/vitrine-pixie.patch
```

This pins Vitrine **1.0.0-beta.16**. The patch includes album and playlist controls, artist-profile download controls for both native and redesigned layouts, development fixtures and local build fixes. Original project files and notices remain upstream.

## 2. Build the updated glass controls

Supply your own compatible decrypted Spotify IPA for Vitrine's flag generation, following its README. Set `THEOS` to your Theos installation. Once the upstream flag-generation step has been completed:

```sh
cd vitrine
env -u MAKELEVEL gmake -C tweak package SG_DRIVER=0 -j4
cd ..
cp vitrine/tweak/.theos/obj/spotifyglass.dylib /tmp/pixie-spotifyglass.dylib
codesign --force --sign - --timestamp=none /tmp/pixie-spotifyglass.dylib
```

## 3. Build Pixie into the base IPA

Use your own **Vitrine 1.0.0-beta.16 / Spotify 9.1.90 IPA**, before Pixie has been applied. A plain Spotify IPA is not the input to this overlay builder.

```sh
python3 NativeDownloads/tools/build_vitrine_9190.py /path/to/Vitrine-b16-9.1.90.ipa \
  --vitrine-dylib /tmp/pixie-spotifyglass.dylib \
  --output NativeDownloads/outputs/pixie-9.1.90/Spotify-9.1.90-Vitrine-b16-Pixie-v1.3.ipa
```

Output: `NativeDownloads/outputs/pixie-9.1.90/Spotify-9.1.90-Vitrine-b16-Pixie-v1.3.ipa`.

The builder compiles the companion library, validates guarded native patches, redirects the selected audio imports, normalizes the bundled Substrate dependency, signs the changed binaries ad hoc and checks archive integrity. The input IPA is not overwritten. Import/sign the output with your installation tool; packaging signatures are not a personal installation certificate.

## Tests and scope

`NativeDownloads/tests/` contains the component fixtures used during development. The redesigned album and playlist fixtures are included in the upstream patch (`harness/album/` and `harness/playlist/`, with `verify-actions` mode). Fixtures alone do not prove device downloading or offline playback.

WAV capture and its implementation have been removed. Encoded audio cache/export code remains a disabled research prototype; it is not a supported export feature. No account credentials, device logs, signing material or Spotify executable are included.

**Regular IPA version: tested through LiveContainer and SideStore.**

**Jailbreak version: NOT TESTED on a jailbroken device.**

## Jailbreak packages (rootless / rootful)

**The published DEBs remain the previous release.** This v1.3 source update does not rebuild or revalidate jailbreak execution. To reproduce the existing DEBs, use tag `pixie-9.1.90-jailbreak-1` rather than current `main`.

These packages are for an original Spotify 9.1.90 installation on a jailbroken device. Install **one** package matching the jailbreak layout, then restart Spotify. Do not install on top of an IPA with Vitrine/Pixie already injected.

After building the patched Vitrine library above, from this repository root:

```sh
ln -s vitrine vitrine-upstream
python3 NativeDownloads/tools/build_debs.py /path/to/Vitrine-9.1.90.ipa \
  --vitrine-dylib /tmp/pixie-spotifyglass.dylib \
  --theos /path/to/theos
```

The source symlink supplies the expected Vitrine source path; Theos must include its Substrate development framework. The builder uses the supplied decrypted IPA only for executable validation and local patch-engine tests. It does not package Spotify itself, account data or the input IPA.

Outputs: `NativeDownloads/outputs/pixie-9.1.90-deb/`, with rootless (`iphoneos-arm64`, `/var/jb`) and rootful (`iphoneos-arm`) DEBs. Both require a compatible Substrate hook provider. The package contains Vitrine and Pixie together; do not install a second Vitrine tweak alongside it.

Local package checks and the 12-case patch-engine fixture are not a substitute for a jailbroken-device test. The IPA-only Live Activity / App Intents extension is not included in the DEB.
