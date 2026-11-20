# Echo Music for Mac

A native Apple silicon client for Echo Music. Discover and search YouTube Music, play a collection, open a song shared from Echo on Android, or import audio from Finder. The player supports a queue, liked songs, local playlists, offline downloads, timed lyrics, and Listen Together rooms with Android.

## Build and open

Use an Apple silicon Mac running macOS 14 or later with a Swift 6 toolchain from Xcode or the Command Line Tools. Run these commands from the Echo Music repository root.

~~~sh
./macos/build.sh
open "macos/build/Echo Music.app"
~~~

The script builds a release executable for arm64, packages the Echo icon and license, verifies the ad-hoc signature, and writes both the app and a ZIP to macos/build. Drag the app into Applications to keep it. This is a local build. Public distribution with Developer ID signing and notarization requires Apple developer credentials.

## Using the player

- **Discover** shows collections and songs from the region’s public YouTube Music home feed. Open a collection to see its songs. Select a song to play it and queue the rows that follow.
- **Search** accepts song titles, artist names, Echo watch links, YouTube Music watch links, and youtu.be song links. Press Return to submit. Use the song menu to copy an Android-compatible Echo link.
- **Library** keeps likes, playlists, downloads, and imported file references on this Mac. Use the plus beside Playlists to create one, then use a song’s menu to add it. Download saves a playable audio file when the provider supplies a complete audio stream. Playback prefers the saved file.
- **On this Mac** imports audio supported by AVFoundation, including MP3, AAC, ALAC, WAV, AIFF, and FLAC. The original stays in place. Finder’s Open With action also starts playback.
- **Transport** provides previous, play/pause, next, seek, and volume. The queue button opens the track list. The lyrics button looks up the current recording on LRCLIB. Click a timed line to seek to it.
- **Keyboard** supports Command-F to search, Command-O to import, Command-P for play/pause, and Command-Left/Right for previous/next. Playback also registers with macOS Now Playing and media commands.

## Listen Together with Android

1. Open **Listen Together** in the Mac sidebar and **Together** on Android. Use the same room server on both devices. If you run your own Metroserver, enter its WebSocket URL on the Mac and select the same server in Android’s Listen Together settings.
2. On either device, enter a display name and create a room. Share the eight-character code with the other listener. On the Mac you can also paste an Android invite into the join field.
3. Join from the second device, then approve its request on the host. Choose a YouTube Music track on the host. Play, pause, seek and change songs from the host’s normal player controls.
4. Select **Leave room** to return to independent playback. After a brief connection loss the Mac tries to reattach while the app is running. If the relay has expired the room, create a new one or request to join again.

Each device plays its own copy of the recording. Echo shares the catalog ID, queue and timing over the room connection. Both listeners need access to that recording. An offline download associated with the same video ID works on the Mac. Finder imports are available for solo playback. Room codes are scoped to one server.

On some Metroserver versions, Android can briefly show guest playback controls after joining or reconnecting. With the Android change in this checkout, the first command the server declines switches the guest back to host-controlled playback and refreshes its position.

For planned provider imports, playback integrations and library tools, see the [provider and feature roadmap](ROADMAP.md).

## How the Mac client maps to Echo

The Android build uses Kotlin/JVM, Room, Compose, and Media3. Its catalog client is an Android Gradle library. The Mac target is a standalone Swift package using Apple frameworks, with no Android runtime, external media executable, or API key.

| Area | Android implementation examined | macOS implementation |
| --- | --- | --- |
| Catalog | innertube — YouTube.home, YouTube.search, SearchPage, InnerTube, YouTubeClient | Catalog calls the same public home, browse, song-search, and player interfaces. It maps shelf renderers to songs and collections, retains video IDs, and follows track-list continuation tokens. |
| Playback | MusicService, YTPlayerUtils, playback queues, Media3 session | Player resolves the stream when selected and hands AAC or HLS to AVPlayer. Queue position identifies an occurrence of a track, including repeats. AVFoundation drives time, end-of-item, and error events. MediaPlayer publishes Now Playing information. |
| Library and local audio | SongEntity, PlaylistEntity, LocalSongScanner, ExoDownloadService | Library atomically saves metadata in Application Support. It reads file tags with AVURLAsset and verifies the byte count and audio track before adding a download. |
| Lyrics | lrclib and the lyrics provider chain | The lyrics panel queries LRCLIB using title and artist, checks recording duration for synchronized lines, and supports plain text and instrumentals. |
| Sharing | MainActivity and SongMenu | The desktop search field reads Echo and YouTube song URLs. The song menu produces the same share.echomusic.fun/watch URL as Android. |
| Group listening | listentogether, its WebSocket protocol, room clock, and Media3 synchronization | RoomSession connects to the Android relay, and RoomPlayback maps room actions, readiness and server time to AVPlayer. |
| Other platform integrations | Cast, Echo Find, Android extensions, Google account sync, DSP and USB output | These integrations remain Android features. Playback on the Mac uses the selected system audio output. |

The services determine catalog availability, supported stream formats, and lyric coverage. The library lives at ~/Library/Application Support/Echo Music/library.json. Managed downloads live in the adjacent Downloads folder. Imported audio remains at its original path. Likes, playlists, and downloads persist between launches. The active queue lasts for the current session.

## Verification

Run from the macos directory with Swift 6 or later.

~~~sh
./test.sh
ECHO_LIVE_TESTS=1 ./test.sh
~~~

The offline tests exercise link validation, catalog parsing, LRC timing, library persistence, damaged library handling, and muted AVPlayer playback using generated audio. The opt-in network tests also open a live collection, search for a recording, fetch lyrics, stream and seek, and play a verified download from disk. They use temporary libraries and remove their test files.

To run the room integration test, start a private [Metroserver](https://github.com/MetrolistGroup/metroserver) and point the test at its WebSocket endpoint. The test creates a temporary room with two real AVPlayers. Generated audio makes it repeatable without a music-provider account.

~~~sh
ECHO_ROOM_TEST_URL=ws://127.0.0.1:8080/ws ./test.sh --filter roomPlaybackThroughMetroserver
~~~

The November 2026 interoperability check used Echo’s Universal GMS Android build on a Pixel emulator, the Mac room session and AVPlayer, and a private Metroserver at revision `1598616`. Both hosting directions admitted a listener and played a live catalog track. An Android host changed tracks and paused the Mac. A Mac host sought to 42.500 seconds and back to zero while paused, and Android reported both positions. Both clients reattached to the room after a relay restart. These checks measure player state. Physical speaker and Bluetooth output delay require hardware measurements.
