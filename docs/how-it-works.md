# How downloading and export work in Pixie 1.4

This guide examines the `eevee pixie fixed` project on the `port-98` branch, targeting Spotify 9.1.98 and EeveeSpotify 7.0.0. The port implementation was recorded in commit `443bfcd`. The explanation is based on the source code and build checks available on November 10, 2026.

## 1. What downloading and export do

| Operation | Result | Where the main work happens |
| --- | --- | --- |
| Downloading | The track is registered with Spotify's offline system and its data is stored inside the app | Pixie prepares the client and sends commands, while Spotify's native core handles the download |
| Export | A regular OGG or M4A audio file that can be saved or passed to the share sheet | Pixie locates cached data, extracts and validates the audio, and transcodes it when required |

The operations have different success conditions. For downloading, Pixie reads the state reported by Spotify's offline service. Export additionally requires accessible cache bytes, a correct association with the track, and a usable way to read the audio data.

The overall sequence is as follows.

```text
User action
    ↓
Prepare offline settings and the native manager
    ↓
Send a command to the Spotify core
    ↓
Spotify queue → retrieve data → write cache
    ↓
Confirm the download state
    ↓
When export is requested
    ↓
Locate cache → extract audio → validate the complete stream
    ↓
OGG or conversion to AAC/M4A
    ↓
Export library or share sheet
```

## 2. How Pixie connects to Spotify

Pixie is compiled into `SpotifyAudioProbe.dylib`. The builder adds this library to the IPA and adds a dependency to the Spotify executable. Once the library loads, its `SAPLoad` constructor installs settings handlers, captures the native manager, connects to the internal transport, and sets up key observations.

The library executes inside the Spotify process. It can therefore access player objects, internal app methods, and memory structures. Hooks intercept entry into the required functions. Where native ARM64 access is required, the builder inserts branches to small additional code fragments called trampolines. These call a Pixie handler, restore processor state, and continue Spotify execution.

Insertion points depend on the executable version. Checks cover the image UUID, original instructions, and available trampoline space. This explains the need for a separate port from 9.1.92 to 9.1.98 even when the Eevee version is identical.

Loading and handler installation are implemented in [PixieBootstrap.m](../NativeDownloads/src/Runtime/PixieBootstrap.m) and [patch_imports.py](../NativeDownloads/tools/patch_imports.py).

## 3. What Pixie prepares before downloading

### Client offline attributes

In `OfflineFlags.m`, Pixie intercepts reads of several `SPTCoreProductState` attributes.

| Attribute | Value supplied by Pixie |
| --- | --- |
| `offline` | `1` |
| `can-use-offline` | `1` |
| `max-offline-downloads-per-device` | `1,000,000` |
| `max-offline-tracks` | `1,000,000` |

The implementation handles several read paths, including string, object, boolean and integer values, as well as attribute dictionaries. This gives different parts of the client consistent offline capability values.

`OfflineConfig.m` rewrites the same targeted attributes in recognized bootstrap/customize Protobuf responses and the local customize cache. This covers the path where the core receives its settings through a configuration response. The cached-response handling also covers HTTP 304.

These changes supply client checks and offline settings with values that allow the app to reach native downloading. A locally read attribute describes the client's state. Actual delivery of data and keys is established through Spotify responses and events.

The implementation is in [OfflineFlags.m](../NativeDownloads/src/Spotify/OfflineFlags.m) and [OfflineConfig.m](../NativeDownloads/src/Spotify/OfflineConfig.m).

### Limits inside the native manager

The download core has its own fields for the track count limit and total music duration. Pixie captures `SPTOfflineManagerImplementation` when it is created, obtains its C++ manager, and runs preparation on Spotify's own queue.

Preparation checks the build, virtual method table, restriction setter instructions, and current values. When needed, it calls the native setter with raised limits. The music minimum is one million tracks and `2,147,483,647` seconds of total duration.

A trampoline is also installed on the setter. When Spotify later updates restrictions, the trampoline raises ordinary nonnegative music values to the configured minimum before continuing into the original setter. Special negative values take a separate branch. Episode fields are passed to the original handler.

This affects the queue's actual checks. The project code documents a case where the counter reached a small quota after a few tracks and new jobs received `TOO_MANY_TRACKS`. The native quota fields participate directly in that decision.

The relevant logic is in [NativeOfflineAdapter.m](../NativeDownloads/src/Spotify/NativeOfflineAdapter.m) and [patch_native_restrictions.py](../NativeDownloads/tools/patch_native_restrictions.py).

### Key request mode

The native key acquisition path has a mode argument. At the original call site it is `1`. The Pixie build sets it to `0`. The patch checks the call site, provider function entry, and the mode-mapping instructions inside the provider. The current production build uses fixed mode `0`.

This is a separate part of the mechanism. The client may accept a download command and then stop while obtaining a usable key. Queue readiness, command acknowledgement, and successful key acquisition are therefore tracked separately.

The code directly establishes the argument change from `1` to `0` and the use of the corresponding native provider branch. The precise server-side meaning of these internal enums and every reason for the branches' different behavior remain subjects for further investigation. The mode reported by the program should be read alongside observations of the actual download.

Argument modification is implemented in [patch_key_request_mode.py](../NativeDownloads/tools/patch_key_request_mode.py), with runtime verification in [NativeOfflineAdapter.m](../NativeDownloads/src/Spotify/NativeOfflineAdapter.m).

### Eevee's download handler

The builder also applies a narrow Eevee change that disables activation of a known reminder handler in the offline UI. This lets the action continue through Spotify's native offlining path. The edit checks the expected class name before applying.

This step is implemented in [patch_offline.py](https://github.com/Glongq/EeveeSpotifyReincarnated/blob/Master/NativeDownloads/tools/patch_offline.py).

## 4. What happens after pressing Download

### The current track

`SAPDownloadCurrentTrack` reads the current track's URI and title from the player. Pixie then prepares the manager, finds an available instance of Spotify's internal transport, and probes it with `GetItems`.

The internal service is named `spotify.offline_esperanto.proto.Offline`. A Protobuf message is passed through `callSingle:method:payload:onResponse:`. Registering a download uses `AddDownload` with the track URI.

That command reaches the app's offline core. Spotify then selects the appropriate audio file and handles network requests, keys, scheduling, cache writes, and its internal record of track availability. Pixie observes responses and job state.

When `GetItems` already reports a completed or active download, Pixie observes it. When a new registration is needed, it sends `AddDownload`. Each mutation is sent once. An ambiguous response leads to state reconciliation, avoiding duplicate registration caused by a single timeout.

The sequence is in [ManualTrackDownload.m](../NativeDownloads/src/Downloads/ManualTrackDownload.m), and supported explicit commands are defined in [SpotifyCommands.m](../NativeDownloads/src/Spotify/SpotifyCommands.m).

### Albums, selected releases, and playlists

For a group of releases, Pixie maintains an operation queue. Before submission it reads context state, checks whether an album belongs to the library, and adds it when necessary with a subsequent verification. Existing active downloads continue to be observed.

The current implementation prepares albums and singles with a window of up to four operations. A prepared release can immediately be registered in Spotify's queue. Pixie tracks at most 256 such operations. Spotify's scheduler determines actual network concurrency.

Album contexts are submitted through `Offline.AddDownload`. Playlists use `PlaylistService.SetOfflineState`. Playlist workflows also preserve order, ownership, and a narrower submission window. In certain paths, including preparing an album for export, the implementation calls the native `makeEntityAvailableOfflineWithURL:trackURLs:` method with the complete track list.

Pixie's queue coordinates user intent, preparation, cancellation, observation, and progress presentation. Spotify's native core owns network transfer scheduling.

These paths are implemented in [ArtistSessionScheduler.m](../NativeDownloads/src/Downloads/ArtistSessionScheduler.m), [ReleaseDownloadOperation.m](../NativeDownloads/src/Downloads/ReleaseDownloadOperation.m), [ArtistSessionPrivate.h](../NativeDownloads/src/Downloads/ArtistSessionPrivate.h), and [NativeAlbumCommand.m](../NativeDownloads/src/Spotify/NativeAlbumCommand.m).

## 5. How Pixie decides that downloading has finished

The program distinguishes several events.

1. The user requests a download.
2. The call enters the core.
3. The core acknowledges the command.
4. An active download state and progress appear.
5. Spotify reports a completed state.
6. For export, the complete audio stream is successfully read and validated.

A successful `AddDownload` response acknowledges the command. For the current track, Pixie then polls `GetItems` and completes its monitor after two consecutive observations of state `3`. Album operations track their context through `GetContexts` and subscriptions.

Track state and album state have different scopes. All individual tracks may already be cached while album context registration is still incomplete. The implementation therefore has separate context observation and bounded registration recovery procedures.

Checks and error messages are tied to a specific track or context. The downloader's global error stream provides additional diagnostic evidence. The code separately handles full storage, connection restrictions, expired licenses, key failures, quotas, and missing responses.

Completion handling is implemented in [ManualTrackDownload.m](../NativeDownloads/src/Downloads/ManualTrackDownload.m) and [ReleaseDownloadOperation.m](../NativeDownloads/src/Downloads/ReleaseDownloadOperation.m).

## 6. Why this combination enables downloading

The supported client already contains a complete offline download implementation. Pixie uses its interfaces and changes several conditions along the path into it.

- Prepared attributes allow the client's offline capability logic to proceed.
- Raised native manager values allow jobs to reserve slots despite a small initial music quota.
- The modified mode argument reaches the native key provider.
- Internal commands create actual jobs in Spotify's core.
- State observation lets the UI distinguish a confirmed result from waiting or failure.

Successful execution also requires a working Spotify session, available content, successful network operations, and usable key-mechanism responses. Those conditions are established through actual app responses. The project includes separate reads of license state, offline devices and quotas, as well as device management using Spotify's existing authentication.

The code identifies the client checks and calls that change. A complete account of server-side key issuance policy requires additional observations of the particular session and version.

## 7. How export finds the right bytes

A track has a Spotify URI. Its metadata also lists audio file identifiers. For export, Pixie obtains metadata through `ClassicMetadataService.GetEntity` and uses these file IDs to locate cached data.

A physical cache filename is associated with an internal cache descriptor and namespace. Pixie observes the native function that constructs this mapping and records the association between file ID, cache ID, descriptor kind, part index, and namespace. The cache ID is then used to construct the physical `.file` path.

The implementation searches two storage roots.

```text
Library/Application Support/PersistentCache/Storage
Library/Caches/VolatileCache
```

Observed mappings are available from memory and a local metadata index. Lookup also handles candidate variants and fragmented storage. The source file is opened with `O_RDONLY`, then checked for type, size, and stability during processing.

The 9.1.98 port exposed a change in an important cache object member. The namespace is now read at offset `0x2b8`, whereas 9.1.92 used `0x230`. That member participates in mappings and hashes. An incorrect offset can leave a track downloaded while export searches for a different cache name.

Mapping is implemented in [NativeCacheMap.m](../NativeDownloads/src/Export/NativeCacheMap.m), with lookup and reading in [TrackCacheExport.m](../NativeDownloads/src/Export/TrackCacheExport.m).

## 8. Where export keys come from

During downloading and playback, Spotify passes through functions that acquire, prepare, and apply key material. Pixie observes several of these boundaries. They include offline and streaming key callbacks, cache cipher setup, media-key record installation, and a point after native code has unsealed a protected key.

The observer receives a register snapshot. At the verified unsealing point, it copies 16 bytes from the native operation's result and associates them with a specific file ID. The association also requires matching instructions and the caller's return address. This reduces the risk of taking correctly sized data from a different call.

An already observed unsealed key takes precedence over a later callback that may carry a protected representation. That ordering rule preserves the useful unsealing result for the same file identifier.

Some observations remain in bounded process-memory tables. Verified unsealing results and storage keys can also be saved asynchronously in Keychain, scoped by installation, namespace, and file ID. The accessibility class is `AfterFirstUnlockThisDeviceOnly`. Raw-key output to diagnostic files is disabled in the normal build.

Functional observations needed by export continue when diagnostics are disabled. The Diagnostics switch controls additional event records.

This explains why an older downloaded track may require preparation again. Its bytes may already exist while Pixie has yet to observe a usable key, or its vault has no accessible key for that namespace.

Observation dispatch is in [ExportObservation.m](../NativeDownloads/src/Export/ExportObservation.m), key association and precedence in [ExportKeyStore.m](../NativeDownloads/src/Export/ExportKeyStore.m), and persistence in [ExportKeyVault.m](../NativeDownloads/src/Export/ExportKeyVault.m).

## 9. How cache data becomes an audio stream

Supported cache variants may require several processing layers.

### Storage envelope

A physical cache file contains service fields, block information, and a storage envelope. Pixie recognizes a header or footer, verifies checksums and sizes, checks block availability, and extracts the payload. Encrypted variants use an observed storage key.

### Media layer

The payload may contain another layer of audio encryption. Processing uses acquired media keys and records observed from the native mechanism. The code includes a bounded set of interpretations of key layout, IV, counter, and service prefix.

This selection concerns the format of already observed data. Some internal Spotify records have been studied as opaque values, so the implementation checks several ways to apply them. A quick preview of the stream beginning rejects unsuitable variants. Final acceptance depends on validating the complete audio container.

For certain fragmented variants, Pixie assembles multiple parts. It checks page sequence numbers, stream identity, and repeated prefixes. The assembled result then undergoes the same full validation.

These steps are implemented in [CacheEnvelope.c](../NativeDownloads/src/Export/CacheEnvelope.c), [MediaDecode.c](../NativeDownloads/src/Export/MediaDecode.c), and [TrackCacheExport.m](../NativeDownloads/src/Export/TrackCacheExport.m).

### Complete Ogg/Vorbis validation

Pixie checks Ogg page structure, CRC, page order, Vorbis headers, packet continuity, end of stream, and duration against track metadata. These checks reject incomplete cache parts, damaged data, and unsuitable decryption interpretations.

A recognizable beginning helps select a candidate. Complete validation determines whether the result can be saved as a finished track.

Validation is implemented in [OggExport.c](../NativeDownloads/src/Export/OggExport.c).

## 10. What selecting OGG or M4A does

### OGG

After successful validation, Pixie saves the extracted Ogg/Vorbis stream. Ordinary OGG export requires no additional audio encoding stage. Metadata and artwork may also be written.

### M4A

M4A conversion starts with the validated Vorbis stream. `stb_vorbis` decodes it into PCM, then Apple's system encoder produces AAC-LC in an M4A container. Metadata includes title, artist, album, year, track number, and JPEG artwork.

The implementation chooses settings supported by the specific AAC encoder and targets up to 320 kbit/s. The supported value depends on channel count and sample rate. M4A conversion transcodes between two compressed formats. Its bitrate describes the output AAC, while source quality is determined by the downloaded material.

The original quality is determined by the audio variant Spotify actually stored. Pixie includes a hint that opens the download quality settings.

Conversion is implemented in [M4AExport.m](../NativeDownloads/src/Export/M4AExport.m), with the quality hint in [NativeDownloadQuality.m](../NativeDownloads/src/Devices/NativeDownloadQuality.m).

## 11. Reuse, recovery, and saving results

Export can first reuse an existing file in `Documents/Pixie Exports` after validating it again. Cache processing creates temporary files for extraction, validation, and conversion. After success, the result is published in the export library or retained temporarily while it is passed through the share sheet.

Several paths handle missing usable data or keys. Depending on the operation, Pixie may prepare an ordinary Spotify download, offer an offline-copy refresh, or perform bounded recovery for a previously downloaded track. Automatic recovery has specific conditions, including a confirmed completed download, an eligible failure reason, and at most one attempt. Other refresh paths ask for user confirmation.

A refresh uses Spotify commands and verifies removal and subsequent downloading. Other owners, such as a downloaded playlist, may retain the track's offline copy, and the waiting logic accounts for that.

The overall sequence is coordinated by [TrackExport.m](../NativeDownloads/src/Export/TrackExport.m).

## 12. What enables export and what has been verified

Export becomes possible when the required conditions hold together.

- Metadata provides the correct file ID.
- Native cache observations identify the corresponding physical file or set of parts.
- The required storage and media keys are available, or the payload already contains readable audio.
- The extracted result passes complete validation.
- M4A export additionally requires a working system AAC encoder.

Each condition has a separate stage and failure reason. For example, `no_cache_file` concerns supported-file lookup, `storage_decode_failed` concerns the cache envelope, `no_media_key` concerns available key material, and `audio_validation_failed` concerns validation of the result. A Spotify downloaded state can therefore coexist with an export error.

For 9.1.98, completed checks cover compilation, expected instructions and patch regions, IPA component preservation, signatures, and source provenance. A separate test verifies the new namespace offset against an independent expected hash. The full host suite reported 63 passing tests and four failures. Two involve the known M4A scenarios, while the others concern system audio-component creation and nested sandbox initialization in the test environment.

A real-device check of these functions on an iPhone running 9.1.98 had yet to be independently confirmed when this guide was written. Internal structure names and the meaning of some opaque records were reconstructed by studying the binary. Those areas rely on exact build checks and result validation. Compatibility must be established again when porting to another Spotify version.

The analyzed source tree records the port and build outcome in `PORT-9.1.98.md` and `BUILD-9.1.98-RESULT.md`.
