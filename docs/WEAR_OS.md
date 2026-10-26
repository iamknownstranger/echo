# Echo Music architecture and Pixel Watch 2 companion

## Repository examined

Upstream analysis revision: `b3bab0f0fcb0a7a57dffee3333d15eb53b13fdbf`.
Fork integration base: `iamknownstranger/echo` at `0b329d66`.
The companion is ported onto the fork without importing later upstream changes;
the fork's playlist-link import feature and existing dependency versions remain.
The upstream revision analyzed below has both `foss` and `gms` flavors and SDK 37.
The fork integration retains its SDK 36, NDK 27.0.12077973 and version 1.2.5.
Later upstream DSP/domain/USB modules described in the analysis are not imported
into this older fork; the companion uses only download interfaces already present.

## Objective and existing functionality

Echo Music is a native Android music client centered on YouTube Music catalog
access through InnerTube, rather than a hosted music backend. Its product combines
catalog browsing/search, playlists and library management, streaming and offline
playback. It adds synchronized lyrics, local audio, podcast-oriented content,
recognition, artwork/video canvases, recommendation generation, Spotify imports,
Last.fm taste signals, group listening, Cast, automotive browsing, and widgets.
These are separate integrations around one phone playback owner.

The important distinction for a watch is between an account/library record, a
completed offline download, and a transient playback cache entry. A Room song row
or `isDownloaded` flag alone is insufficient proof that the complete audio exists.
Neither YouTube URLs nor phone file paths are portable to another device.

## Structure and responsibilities

| Area | Implementation and responsibility |
|---|---|
| `:app` | Application startup, Hilt graph, Compose navigation/screens, ViewModels, phone playback and feature orchestration |
| `:core` | Room schema/DAOs/entities, preferences, shared models and utilities; exposes `MusicDatabase` over `InternalDatabase` |
| `:domain` | Kotlin/JVM domain contracts and use cases; does not own Android playback |
| `:playback` | Media3 support: queue implementations, chunked data sources, sleep timer, audio routing, analysis and playback helpers |
| `:innertube` | YouTube/YouTube Music requests, response models, parsing and catalog operations |
| `:lyrics` and provider modules | Lyrics orchestration and independent lyrics sources (`lrclib`, `kugou`, `betterlyrics`, `paxsenixlyrics`, `simpmusic`, `youlyplus`) |
| Canvas modules, `:artistvideo` | Optional visual media providers and artwork integrations |
| `:shazamkit` | Recognition integration |
| `:metadata`, `:unison` | Shared metadata and supporting utilities |
| `:dsp-core`, `:audio-dsp`, `:usbaudio` | DSP and specialized output support; unnecessary in the watch APK |

Source folders in `:app` still use `com/music/echo/`, while most Kotlin package
names and the app ID use `echo.music.iad1tya`. Namespace must be read from the
actual file; directory names are not a reliable package identifier.

The phone uses MVVM with repositories/helpers and Hilt singleton services, rather
than a fully isolated clean-architecture stack. `MainActivity` supplies the Compose
UI, `PlayerConnection` connects screens to the player, and `MusicService` is the
large application-level playback coordinator. `MusicService` extends Media3
`MediaLibraryService`; its `MediaLibrarySessionCallback` supplies external browsing
and controller integration. Queue ownership and playback state stay centralized.

Room stores song identity, artists, album relationships, formats, playlists,
lyrics, history and recommendation signals. Preferences are in DataStore. The
DAO and `MusicDatabase` facade are in `:core`; changing persisted entities would
require a migration. This companion does not alter the phone database schema.

### Phone streaming path

1. A screen/ViewModel resolves catalog or library items and constructs a queue.
2. `PlayerConnection` commands the phone's existing `MusicService`.
3. The service builds Media3 items and resolves playable streams through
   `YTPlayerUtils` and the InnerTube-related resolution helpers.
4. Its data-source chain checks the persistent download cache and playback cache
   before falling back to upstream audio. URL resolution includes expiration and
   provider-specific handling, so copying a URL is unsuitable for offline sync.
5. The service owns audio focus, session state, queue progression, statistics and
   integrations. Feature UIs such as Music Flow command this same service.

### Phone download path

`DownloadUtil` owns a Media3 `DownloadManager`, using a `ResolvingDataSource` and
`ChunkingDataSourceFactory`. The upstream can reuse already-streamed phone bytes.
`ExoDownloadService` handles the Android download service/notification lifecycle.
Download requests use track IDs as custom cache keys. `AppModule` supplies separate
`SimpleCache` instances: an evictable player cache and a non-evicting download cache
under the phone's private files directory. The download index and cache metadata
are distinct from Room's song metadata.

Completion updates download state and asynchronously updates Room. Cache files
are segmented implementation artifacts: blindly transferring those files would
also require reproducing their cache index. The companion instead reconstructs
one continuous media file by reading a completed request through a **read-only,
cache-only `CacheDataSource`**, checking content length and full cache coverage.
There is no new network audio request or transcoding in this path.

## Architectural assessment

The existing separation of cache ownership, download indexing and metadata makes
cache-only export possible without changing provider resolution or Room schemas.
Media3 sessions also provide a suitable independently running watch player. The
small domain layer and focused provider modules are useful boundaries; importing
all of `:core` into Wear would nevertheless pull in far more dependencies than
this companion needs.

The main maintenance risk is application-level coupling: `MusicService` spans
thousands of lines and coordinates playback, resolution, statistics and multiple
optional features. Watch code therefore uses a small download observer and an
entry point to the existing singleton rather than adding another concern to that
service. The app's source-folder/package mismatch and stale flavor/SDK notes also
make assumptions based on naming unsafe.

Offline truth is distributed across the Media3 index, byte cache, and asynchronously
updated Room fields. Export validates the first two at the time of reading and
uses Room for descriptive metadata only. A phone deletion racing an export can
still fail that transfer, but cannot turn a partial watch file into a saved song.

Catalog streaming depends on unofficial/provider-specific response parsing and
expiring stream resolution; those concerns remain on the phone. The watch's
saved-file path avoids carrying that dependency into disconnected playback.
Native/DSP and third-party dependencies complicate building the entire phone
application, so standalone watch build success must be distinguished from phone
integration success. The existing GPL license applies to this repository's
companion implementation as well.

## Companion implementation

| New area | Purpose |
|---|---|
| `:wear` | Separate Wear OS APK, round-screen Compose UI, private offline library, WorkManager syncing, and watch-local Media3 service |
| `:wear-sync` | Small shared library with track DTO, bounded versioned wire codec, ID validation and verified streaming file receiver |
| `app/src/gms/.../wear` | Phone listener, cache export/catalog worker and download-state observer |
| `DownloadStateObserver` | Flavor-independent optional Hilt multibinding, keeping Play Services out of the phone's FOSS graph |

The watch does not depend on the phone app module, InnerTube, Room, Hilt, native
DSP libraries, recognition, lyrics providers, or video canvases. This reduces
package size and watch background work. The watch needs the paired phone for
initial library discovery and transfers; after saving a track it needs neither
the phone nor Internet access to play it.

```mermaid
sequenceDiagram
    participant UI as Watch UI
    participant W as Watch WorkManager
    participant DL as Wear Data Layer
    participant P as Phone worker
    participant C as Phone download cache
    participant F as Watch private files
    UI->>W: Sync catalog / select Download
    W->>DL: Refresh or track request message
    DL->>P: Listener queues persistent work
    P->>C: Read complete cached bytes only
    P->>DL: Track metadata + file-backed audio Asset
    DL->>W: Durable DataItem change
    W->>F: Stream to .part; verify size + SHA-256
    W->>F: Atomic rename + persist offline metadata
    W->>DL: Receipt after successful commit
    DL->>P: Remove acknowledged transport Asset
    UI->>F: Play local file through watch MediaSessionService
```

### Sync semantics

- `/echo/v1/catalog`: a bounded snapshot of completed phone downloads. Refresh is
  available on the watch, runs on watch app launch, and is published when phone
  downloads complete or begin removal.
- `/echo/v1/request/<id>`: watch asks for a completed phone track. Messages wake
  work; audio never travels in a message payload.
- `/echo/v1/audio/<id>`: metadata, declared byte count, SHA-256 and a file-backed
  Data Layer Asset. Asset transport avoids loading an entire song into memory.
- `/echo/v1/error/<id>`: actionable phone-side transfer failure text.
- `/echo/v1/receipt/<id>`: acknowledgement after a verified local commit. Phone
  removes the transport item; it retains its original download.
- Selected downloads are stored as a persistent wanted list. WorkManager retries
  phone disconnection and delayed asset arrival, with bounded exponential backoff.
  DataItems are reconciled when requesting sync, covering callbacks missed while
  the process was stopped. Retry restarts the application-level transfer; byte
  range resumption is delegated to the Data Layer and is not implemented here.
- Removing/cancelling a watch selection removes the wanted entry. The receiver
  checks it again before publishing a file, so a late transfer cannot restore a
  cancelled download. Unwanted incoming transport items are deleted so cancelled
  assets do not occupy Data Layer storage indefinitely. The protocol is designed
  for one paired watch; coordinating several watches is not implemented. Removing an item queued in the current player clears that
  queue before deleting its file.
- Pending selections are appended to both views even when removed from the phone
  catalog, preserving Retry/Cancel controls after refresh or restart. Rows are
  deduplicated by ID, with the primary view metadata taking precedence.
- Catalog removals do **not** delete saved watch audio. A disconnected phone never
  implies that an offline watch track should be removed.
- This is catalog/audio replication plus transfer receipts. It does not replicate
  playlists, likes, history, play position or the phone's current playback queue,
  and it does not control phone playback.

### Storage and playback guarantees

Audio lives in `files/music/<validated-id>.audio` on the **watch**, not its cache
directory or a phone URI. Catalog, wanted and offline manifests use `AtomicFile`.
Only verified files are listed as playable. Incomplete transfers remain `.part`
files and are overwritten on retry. Receiver limits are 100 MiB per song, a 20 MiB
free-space reserve, and 200 entries per manifest; catalog metadata is capped at
80 KiB, below the Data Layer's 100 KiB item limit. The catalog intentionally
exposes at most 200 completed phone downloads. Large-library pagination is a
future extension, not silent unlimited-library support.

The phone determines size from the completed download index or cache content
metadata. A download with unknown size or missing cache spans is rejected rather
than transferred as if complete. Only ordinary valid-ID completed downloads are
advertised; phone-local files and canvas assets are excluded.

The watch player is an independent Media3 `ExoPlayer` in `MediaSessionService`,
with audio focus, becoming-noisy handling, playback notification and a local wake
lock during playback. Session media-item requests are mapped back to committed
watch-library IDs, preventing arbitrary incoming URIs from replacing local media.
The app provides play/pause, previous/next and a local queue. Use Wear OS's system
Bluetooth controls to connect headphones. Queue state itself is not persisted
across process death; the saved library is.

No account cookie, signed streaming URL, or phone-private path is sent to the
watch. Wear Data Layer requires matching application IDs and signing certificates.
Release and debug pairs are intentionally separate (`echo.music.iad1tya` and
`echo.music.iad1tya.debug`). App-private audio is not exported through a provider.
Google Play Services and a paired Wear OS device are required for sync.

## Build and install

Use JDK 21. The new watch modules compile against stable SDK 36; the existing
fork phone module also uses SDK 36 and retains NDK 27.0.12077973. Configure
`local.properties` with the Android SDK location. Firebase configuration is
optional. Build the GMS phone variant and watch APK:

```sh
./gradlew --configure-on-demand :wear-sync:testDebugUnitTest :wear:assembleDebug :wear:lintDebug
./gradlew :app:assembleUniversalGmsDebug
adb -s PHONE_SERIAL install -r app/build/outputs/apk/universalGms/debug/app-universal-gms-debug.apk
adb -s WATCH_SERIAL install -r wear/build/outputs/apk/debug/wear-debug.apk
```

Check actual phone APK output naming under `app/build/outputs/apk` if Gradle
changes the variant directory layout. Both debug APKs explicitly use `~/.android/debug.keystore`; CI creates that
shared key before Gradle runs and verifies equal certificate hashes before
uploading the APKs. A watch debug APK cannot sync with a public
release phone APK. For distribution, sign both release APKs with the same
certificate; the watch module reads the same `keystore.jks` or
`app/keystore/release.keystore` and signing environment variables as the phone. No release key is bundled here.

1. Pair Pixel Watch 2 with the Android phone using the Pixel Watch app.
2. Install both matching APKs, open Echo on the phone, and finish a song download.
3. Open Echo on the watch, grant notification permission, and tap **Sync with phone**.
4. Choose **Browse phone downloads**, then **Download to watch** for selected songs.
5. Wait until tracks appear under **saved on watch**; connect headphones to the watch.
6. Disconnect the phone and disable watch Wi-Fi/mobile data. Play from the saved
   library to confirm the audio is genuinely on-watch.

## Validation and remaining device checks

`WearProtocolTest` exercises Unicode metadata, empty catalogs, invalid/path-traversal
IDs, duplicate IDs, bounds, version mismatches, trailing bytes, valid transfers,
truncation, overflow and checksum corruption. These checks target data-loss and
file-publication behavior, not just codec implementation details.

Hardware validation still needs a paired phone and Pixel Watch 2: complete the
install/offline procedure above; interrupt Bluetooth halfway through a transfer;
restart both processes; retry; cancel an in-flight transfer; remove a phone copy
and confirm the watch copy remains; fill watch storage near the reserve; test
headphone disconnect, audio focus, background playback and reboot. Confirm Data
Layer wake-up and asset delivery on the actual Wear OS/Play Services versions.
A successful host test is not evidence these device scenarios passed.

### CI validation and release artifacts

The Android CI workflow runs `:wear-sync:testDebugUnitTest` and the fork's
`:app:testUniversalGmsDebugUnitTest`, including its existing playlist parser and
matcher tests, before assembling the GMS phone and watch APKs. XML/HTML test
reports are uploaded even if a test fails. APK uploads occur only after successful
tests and builds. Release assets must come from the successful run for the tagged
commit, rather than the earlier upstream-based local builds.

Use the two APKs from the same run: both must have the same signing certificate
and application ID. Without repository signing secrets, CI produces debug APKs
(`echo.music.iad1tya.debug`) that install separately from the public release.
Download tracks inside that modified debug phone app before syncing.

A prerelease indicates that physical phone/watch pairing, Bluetooth audio,
interrupted transfers and disconnected playback remain device acceptance tests.
Host and CI tests do not establish end-to-end transport or hardware behavior.
