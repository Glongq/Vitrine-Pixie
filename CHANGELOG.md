# Changelog

## 2026-10-27 — Pixie Manager v1.3

- Refactored Pixie Manager code

Source update only. No IPA or DEB is uploaded with this update.

## 2026-10-26 — Vitrine beta 16 + Pixie Manager v1.3

- Updated Vitrine to beta 16
- Download releases directly from artist profiles, download separately or into a new or existing playlist

Source update only. No IPA or DEB is uploaded with this update.

## 2026-10-23 — Pixie Manager v1.2.1 sources

- Updated Vitrine from beta 13 to beta 14
- Slightly improved Pixie Manager interface
- Improved offline device management
- Improved download stability and audio hooks

**Regular IPA version: tested through LiveContainer and SideStore.**

**Jailbreak version: NOT TESTED on a jailbroken device.**

This publication updates source code and patches. No IPA is uploaded here, and the previous jailbreak release and DEBs have not been rebuilt.

## 2026-10-21 — Pixie Manager v1.2 sources

- Added optional detailed diagnostic tracing and a single JSON export.
- Added offline-device management to inspect devices and remove selected devices, freeing download slots.
- Added trace, compatibility, device-management and support-log fixtures, with native observation patch guards.
- Consolidated diagnostic export in Pixie settings.
- Local tests and simulator checks passed during development; latest diagnostic changes are not yet verified on an iPhone.
- Previous jailbreak DEBs and their release remain unchanged. This is a source update, not a rebuilt DEB release.

## 2026-10-20 — Local files fix and jailbreak packages

- Fixed a crash while resolving cover artwork for local tracks when Spotify receives malformed or unrelated metadata URLs. Valid local paths, file URLs and local-image URIs remain supported.
- Added rootless and rootful jailbreak packages, runtime patch guards, initialization and package build sources.
- Pixie currently uses an English interface.
- Regular IPA: tested through LiveContainer and SideStore. Jailbreak DEBs: local package, signature and patch-engine checks passed; execution on a jailbroken device is **not tested**.
- The local-cover resolver fixture covers malformed URLs, valid artwork paths, fallback metadata and edited artwork precedence.
- The jailbreak DEB does not include the IPA-only Live Activity / App Intents extension.

## 2026-10-20 — Playlist and mix controls fix

- Fixed the common redesigned playlist header, including mixes and header variants: when Spotify supplies both Add and Download, both now appear as separate glass buttons on the left, with Play on the right.
- Kept the independent action row stable across transient header model updates.
- Download uses Spotify’s existing action. No download button is fabricated when Spotify does not supply one.
- Preserved the existing row for own playlists and Liked Songs when the independent action pair is absent.
- Added playlist simulator fixture checks for narrow layouts and native action forwarding.

Local fixture results: mix, late-save and no-download variants passed. These are component checks; this source publication does not introduce a new IPA release.
