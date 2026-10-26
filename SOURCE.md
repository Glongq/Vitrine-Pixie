# Source provenance

Current source snapshot: **Pixie Manager v1.3**. The existing jailbreak release/tag retains its earlier source snapshot and DEB files.

- Base: [Vitrine 1.0.0-beta.16](https://github.com/My-Name-Is-Jeff/vitrine), pinned to commit `36d3b38ec39c0b8b696f1d2db026ca9e9939bf14`.
- `patches/vitrine-pixie.patch`: the local changes against that exact revision. Vitrine's existing code remains under its original GPL-3.0 licence and authorship.
- `NativeDownloads/`: Pixie companion implementation, build patchers, jailbreak runtime/bootstrap and development fixtures, evolved from Glongq's EeveeSpotifyReincarnated extension and ported to Spotify 9.1.90 / Vitrine.
- Integration, development and builds: OpenAI Codex under Glongq's direction. Device testing: Glongq.
- `source-manifest.json`: SHA-256 hashes of all published files, including source code, patches and documentation, except the manifest itself.

This snapshot excludes generated binaries, IPAs, personal/device logs, private signing files, dependency installations and the complete upstream Git checkout.
