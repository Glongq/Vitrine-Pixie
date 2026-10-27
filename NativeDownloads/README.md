# Experimental Native Downloads — UI release v7

This directory contains the native-download extension used in `spotify-ui-v7`.
It is an independently built companion library for EeveeSpotifyReincarnated.
The download runtime is unchanged from v4. The settings UI removes the manual
mute action. `provenance.json` preserves the v4 hashes; `provenance-ui-v7.json`
records the current UI sources and the unchanged download backend.
The packaging and test scripts have been adapted for this repository.

Implementation, integration, documentation and local builds: **OpenAI Codex**,
under **Glongq**'s direction. Device testing and feedback: Glongq.
Upstream EeveeSpotify contributors retain credit for the base project.

## Tested configuration

- EeveeSpotify base: 7.0.0.
- Spotify: **9.1.88**, ARM64 Mach-O UUID `f51dbd933b8f3a12943196c606e3afc2`.
- Device verification: iPhone 15 Pro Max, iOS 27.0.1, inside LiveContainer.
- Languages: English and Russian, following the app language.

Other Spotify binaries, signing methods, jailbreak packages, iPads, long-term
licence renewal, and cellular-only downloads have not been independently
validated for this extension. An identical version label alone does not establish
compatibility: the native patchers verify the Mach-O UUID and instruction bytes.

## Build the checked overlay

Requires macOS, Python 3, full Xcode, and the iPhoneOS SDK. Select Xcode with
`xcode-select` if your active developer directory points to Command Line Tools.
Supply your own **unmodified EeveeSpotify 7.0.0 / Spotify 9.1.88 IPA**. A vanilla
Spotify IPA, or an already modified v1–v4 IPA, is not the input for this command.

```sh
python3 NativeDownloads/tools/test_patchers.py
THEOS_PACKAGE_SCHEME=rootless make -j2 all FINALPACKAGE=1
python3 NativeDownloads/tools/build.py /absolute/path/to/EeveeSpotify-7.0.0-9.1.88.ipa --eevee-dylib .theos/obj/EeveeSpotify.dylib
```

Outputs are in `NativeDownloads/outputs/`:

- `spotify-ui-v7.ipa`: import and sign through LiveContainer in the normal way.
- `SpotifyAudioProbe.dylib`: the companion library.
- `build-manifest.json`: input/output hashes, source hashes and patch details.

Use `--output-dir /absolute/path/to/output` to choose another output directory.
The input file is never overwritten. No Spotify binary or IPA is included in Git.
The builder rejects unrecognised or already patched native binaries. It verifies
archive integrity, native instruction guards, generated quota constants, dyld
imports, and source hashes. The output is ad-hoc signed for packaging; installation
still requires the receiving installation tool's normal signing process.
The v7 glass controls require a rebuilt Eevee library. The builder rejects an old
library without the new action-row markers. When the supplied IPA already contains
the newly compiled Eevee UI, `--eevee-dylib` can be omitted.

## GitHub Actions

Use **Native Downloads — Validate / Build IPA**. Validation runs on pushes and
pull requests without an IPA. To build, select **Run workflow** and supply an HTTPS
direct-download URL for your own compatible EeveeSpotify base IPA. The output is
an Actions artifact; this workflow does not create a public release. Leave the URL
empty to run validation only. With an original 7.0.0 base, also supply the URL of
an Eevee library compiled from the current sources. The workflow does not compile
the Theos project itself.

The older upstream IPA workflows produce upstream builds. They do not implicitly
include this overlay. For a local full upstream rebuild followed by the overlay:

```sh
NATIVE_DOWNLOADS=1 ./build-ipa-local.sh /absolute/path/to/decrypted-Spotify.ipa
```

This second route needs the upstream Theos/cyan/ipapatch dependencies. It compiles
the upstream Eevee tweak before adding the overlay. Its input Spotify binary must
still match the guarded UUID. A newly compiled upstream base is not claimed to be
byte-identical to the Eevee 7.0.0 base used in the original device verification.

## Use

- Use Spotify's regular album or playlist Download button for native bulk downloads.
- Open **EeveeSpotify → Track downloads** for the single-track action and status.
- Enable diagnostics there when collecting a report. Diagnostics are off by default.
- Downloads remain in Spotify's own offline storage. This release does not export
  MP3/WAV files and does not need to play every track before downloading it.
- A successful `AddDownload` reply means accepted, not completed. The single-track
  action confirms completion through two consecutive native downloaded states.

## Tests

The portable checks require Python only:

```sh
python3 NativeDownloads/tools/test_patchers.py
```

The full host tests require Apple Silicon macOS and full Xcode. Set the optional
IPA path to include the real-binary checks; without it those checks explicitly skip.

```sh
SPOTIFY_TEST_IPA=/absolute/path/to/EeveeSpotify-7.0.0-9.1.88.ipa python3 NativeDownloads/tools/test.py
```

The UIKit fixture requires a booted ARM64 iPhone simulator with iOS 27 or later:

```sh
python3 NativeDownloads/tools/test_settings_ui.py
```

The fixture checks settings layout, RU/EN, page protocols and mini-player clearance.
It does not simulate Spotify downloading or prove device playback.

The glass action-row fixture compiles the actual production row and the shared
native tap helper. It checks widths 320–768 pt, horizontal scrolling, Play staying
at the right edge, native download state changes and one action per control. It
also reproduces the artist header’s initially hidden 8 pt preview and its delayed
appearance without a second controller layout:

```sh
python3 Tests/PlaylistActionRow/test.py
```

## UI v7

Spotify's original download control receives Eevee's shared `GlassKit.pane`
background. Its native foreground, outline, animations, accessibility, icon subtree
and handlers are preserved. No replacement download button, icon snapshot,
forwarded download tap or download-model hook is used.

The native header lookup handles `DownloadButton.Granular.*` states verified in
the running iPhone, as well as `Components.UI.DownloadIcon` and the older
`Components.UI.DownloadButton`. Binding is cached per header, including missing
results. A new lookup is allowed when a native control is replaced; a header
without a control gets one retry when it enters a window. There is no periodic
search or timer.

The native download control is mounted once into the horizontal action area.
On playlist/album pages the native preview is mounted after its initial hidden
state completes. Play stays separately at the right. No download control is
fabricated on pages where Spotify has none.

Artist previews stay entirely in Spotify's native Element/OverflowStack layout:
no reparenting, frame changes, new glass background or replacement tap handler.
The custom action strip starts after the preview's current native drawing/hit
area, including content extending beyond its layout shell. Scoped native
hidden/bounds/center notifications coalesce geometry updates onto one main-queue
turn. No timer, display-link, full-screen scan or repeated reparenting is used.

The original v4–v6 provenance files and local archives are preserved.

## Device-slot management (Spotify 9.1.90)

Public packages use `Spotify-<Spotify version>-Vitrine-Pixie-v<release>.ipa`
and the matching `.zip` name. The current release is `v1.2`, also shown in the
menu and the exported log's `pixie_build` field.

The `device-slots 2` build retains the verified direct mode-0 instruction. It
adds **Manage offline device slots** and **Enable offline listening on this
copy** under **Download compatibility**. It does not fabricate a free-license
count, change device identifiers, or automatically remove registrations.
Selecting mode 1 is disabled in the UI and backend. Returning to mode 0 is
offered only for a verified runtime selector actually observed returning 1.
A saved preference alone is insufficient. Fixed mode-1 executables need a
mode-0 build, since no executable instruction is changed at runtime.
Five licenses mean up to five devices storing offline music. Slot release is
for troubleshooting download problems, with a warning before confirmation.

Opening the device list performs reads only. The authenticated HTTPS license
and device responses must agree with Spotify's in-process state before a
selection can be reviewed. Disabling a registration requires a second explicit
confirmation; the reviewed list is checked again before sending a command.
Commands are sequential and are never automatically replayed. Each disabled
registration must be observed inactive and the free-slot count must increase
before the UI reports success. Releasing an old registration can make its
cached tracks unavailable offline. Enabling the current copy consumes an
available slot and is a separate action, also verified through fresh reads.

Route fragments and the POST method were verified in the supplied executable.
The direct HTTPS integration is not yet verified against a real account; an
unsupported route, rejected authentication, mismatched state, or missing reply
is reported as an error, never a successful repair. Host tests use an isolated
`NSURLProtocol` registry and fake credentials; they do not contact Spotify.

All action results and readbacks are included in the existing single-file
**Send log** export. Authenticated request headers are not logged or exported.


## Detailed diagnostics (Spotify 9.1.90)

The **Diagnostics** switch controls the detailed trace. If it was enabled before
launch, detailed trace collection starts when the Pixie library initializes. Enabling it later
starts a new segment; earlier calls cannot be reconstructed. Disabling it closes
the trace, cancels its RPC deadlines and network monitor, clears native callback
and metadata associations, and stops the passive player/error observers.
The troubleshooting/action audit is also gated by Diagnostics. While it is off,
Pixie does not collect or append new action records.

With Diagnostics off from launch the detailed trace creates no writer queue,
files, RPC wrappers, deadlines, network monitor or metadata map. Fixed native
observation trampolines still forward through their inactive check, and installed
Objective-C hooks continue forwarding originals. This is not a claim of zero CPU
overhead.

### Evidence captured

- Each event has a run ID, segment, event ID, operation/parent ID, UTC capture
  time and monotonic time since trace initialization. Writer/enqueue timestamps
  and queue delay are separate. A journal decode timestamp is explicitly not
  relabeled as the original response time.
- Startup/export manifests contain loaded module paths and UUIDs, bounded
  load-command hashes, exact critical loaded-code samples for the supported
  9.1.90 UUID, and hook signature/installation/current-IMP/first-call checks.
  Hash scopes are labeled; these are not full-file hashes or certificate proofs.
- Pixie settings actions, current-track/album operations, compatibility reads,
  native queue samples and observed icon/row states form a chronology. Icon and
  core-state comparisons use the same URI with independently timestamped
  observations. A green icon never proves that an audio file was tested.
- Calls crossing the verified Esperanto bridge/Cosmos hooks include method,
  service, transport, parent operation, invocation/return, callback, timeout,
  exception, stream close and observed lifetime acquire/cancel. Known Offline
  protobufs include items, contexts, progress, licenses, playback status and
  preflight fields. Unknown payloads retain only bounded field shapes/lengths.
  A deadline means no reply was observed by that time, not a proven rejection.
  Late and duplicate callbacks remain visible and still reach native code.
- Selected product flags and bootstrap/customize attributes are recorded before
  and after Pixie's transform, including cache origin, local write readback,
  HTTP status and URL changes. Delegate input may already have passed another
  mod's hook; it is never described as an untouched server value.
- Three guarded native boundaries observe the actual argument immediately
  before the existing key-provider call and entry into its original success or
  failure callback. Static mode 0, callback ownership and original results are
  preserved. No returned key, token, license blob or audio is read. Success means
  the native success callback ran, not that key origin or validity was tested.
  Callback correlation requires exact functor identity or a unique captured
  wrapper/owner/file ID; missing and ambiguous links are explicit. Independently
  observed metadata may link a file ID to a track URI within the current segment.
  No extra metadata/key/network request is sent to establish that link.
- Parsed native download errors, player requests/state, foreground/background,
  protected-data changes, local audio route, low-power and OS network-path
  observations are included. A network path is not proof of endpoint reachability;
  a local route is not proof of the Spotify Connect destination.

For example, an album operation can be followed to AddDownload's acknowledgement,
then to its context/item states and native key callbacks. If the command was
acknowledged but the key failure callback ran, those are separate observed facts;
a server denial is not asserted without its response. If core state and the UI
icon disagree, the report includes both times. If no native request crossed an
instrumented boundary, the log says it was not observed, not why it never happened.

### Export, retention and limits

**Send log** exports one JSON file (`Pixie support log 3`) with the detailed trace,
hook coverage, diagnostics, journal, summary and legacy text sections. The trace
is read through its serial writer; the other sections retain their own capture
times and are not an atomic snapshot of Spotify's process or server.

Detailed records are flushed immediately. Three JSONL files retain at most
8 MiB each; pending events are bounded at 512, RPC observations at 256 and
individual serialized records at 128 KiB. Known collections and field/string
lengths are also bounded. Queue drops, truncation, oversize omissions, rotations,
evicted bytes, malformed records, export read errors, write errors/errno, native
mapping evictions and hook-capacity gaps are reported. A rotated or interrupted
log may lack earlier operations even if a later callback refers to them.
`fflush` is not `fsync`; sudden termination or power loss can omit the last events.

Coverage is limited to Pixie and the explicitly instrumented Spotify boundaries.
It does not cover every Spotify function, every native key-provider call site,
all internal file operations or calls preceding library initialization. Unknown
failure causes remain unknown; an iOS `.ips` report is still needed for a crash.
Authorization headers, access/refresh tokens, cookies, key bytes and unknown
binary payload contents are excluded. Trace IDs and binary fingerprints are
identifiers, not credentials.

### Verification

`tools/test.py` includes ASan/UBSan fixtures for frozen boundary snapshots,
disabled initialization, RPC late/cancel/timeout behavior, lifetime inheritance,
callback identity/copy/ambiguity, metadata links, rapid diagnostic toggles,
secret exclusion, rotation, overflow and write failures. The ARM64 production
trampoline fixture checks register/vector/condition/FP state, hidden result
pointers, original callback execution, fixed mode 0, the inactive path and a
missing helper. Exact supplied-binary checks reject changed instructions,
occupied caves and repeated patches and compare every byte outside the allowed
observation boundaries. These are local fixtures, not a claim of successful
album downloading or certificate trust on an iPhone.


## Contact links

The final **Me** section in **Pixie Download Manager** uses the same native
inset-grouped rows as the other settings. **GitHub** opens
https://github.com/Glongq/Vitrine-Pixie and **Telegram channel** opens
https://t.me/glongqforks through iOS URL handling. This release is labeled v1.2
in the menu, diagnostic build field and package name; the earlier v1.2 and
v1.3 archives are retained in their original output folders.


## Pixie 1.2 menu and log-reset update

Reusable settings cells restore interaction and selection before being configured.
The verified mode-0 row alone is read only; its disabled state cannot leak into
download, quota, device-management, diagnostics or link rows after a reload.

**Diagnostics > Reset log** removes Pixie's journal/action files, rotated detailed
trace files, previous exported reports and retained journal/player history. The
switch stays in the user's chosen state, including changes made during reset.
If enabled, a new segment starts with a reset marker and fresh diagnostic reads;
if disabled, reset does not enable recording or create a trace writer from cold.
The native downloader and stored music are not reset. Runtime counters that are
explicitly labeled as process totals retain that scope. Other mods' exported
diagnostic snapshots remain independent of Pixie's event history.

Callbacks left in Spotify-owned subscriptions after disabling diagnostics take
the inactive path before decoding their payload. Pixie action-audit records are
also skipped before copying, serializing or enqueuing them.
