package echo.music.wear.sync

/** Keep selected downloads reachable even when the phone no longer advertises them. */
fun visibleWatchTracks(
  catalog: List<WatchTrack>,
  offline: List<WatchTrack>,
  wanted: List<WatchTrack>,
  watchDownloadsOnly: Boolean,
): List<WatchTrack> {
  val savedIds = offline.mapTo(hashSetOf()) { it.id }
  val pending = wanted.filterNot { it.id in savedIds }
  val primary = if (watchDownloadsOnly) offline else catalog
  // Primary metadata/order wins, and Compose receives one row per stable track ID.
  return (primary + pending).distinctBy { it.id }
}
