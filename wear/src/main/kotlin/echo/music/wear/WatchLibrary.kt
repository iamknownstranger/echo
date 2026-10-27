package echo.music.wear

import android.content.Context
import android.util.AtomicFile
import echo.music.wear.sync.WatchTrack
import echo.music.wear.sync.WearProtocol as P
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class LibraryState(
  val catalog: List<WatchTrack> = emptyList(),
  val offline: List<WatchTrack> = emptyList(),
  val wanted: List<WatchTrack> = emptyList(),
  val message: String? = null,
)

/** One process-wide owner; AtomicFile protects metadata across process death. */
class WatchLibrary private constructor(context: Context) {
  private val dir = File(context.filesDir, "music").apply { mkdirs() }

  private fun read(name: String): List<WatchTrack> = runCatching {
    P.decode(AtomicFile(File(dir, name)).readFully())
  }
    .getOrDefault(emptyList())

  private fun initialState(): LibraryState {
    val wanted = read("wanted")
    // A process may die between verified rename and manifest publication. Only
    // commit() creates .audio files, so recover those from durable selection metadata.
    val offline = (read("offline") + wanted).distinctBy { it.id }.filter { audio(it.id).exists() }
    return LibraryState(read("catalog"), offline, wanted)
  }

  private val mutable = MutableStateFlow(initialState())
  val state = mutable.asStateFlow()

  fun audio(id: String): File {
    require(P.validId(id))
    return File(dir, "$id.audio")
  }

  fun staging(id: String): File {
    require(P.validId(id))
    return File(dir, "$id.part")
  }

  fun freeBytes() = dir.usableSpace

  private fun save(name: String, tracks: List<WatchTrack>) {
    val file = AtomicFile(File(dir, name))
    val output = file.startWrite()
    try {
      output.write(P.encode(tracks))
      file.finishWrite(output)
    } catch (e: Exception) {
      file.failWrite(output)
      throw e
    }
  }

  @Synchronized
  fun catalog(tracks: List<WatchTrack>) {
    save("catalog", tracks)
    mutable.value = mutable.value.copy(catalog = tracks)
  }

  @Synchronized
  fun message(value: String?) {
    mutable.value = mutable.value.copy(message = value)
  }

  @Synchronized
  fun want(track: WatchTrack) {
    val tracks = mutable.value.wanted.filterNot { it.id == track.id } + track
    save("wanted", tracks)
    mutable.value = mutable.value.copy(wanted = tracks)
  }

  @Synchronized fun wants(id: String) = mutable.value.wanted.any { it.id == id }

  @Synchronized
  fun commit(track: WatchTrack, staging: File): Boolean {
    if (!wants(track.id)) {
      staging.delete()
      return false
    }
    check(staging.renameTo(audio(track.id))) { "Could not commit audio" }
    val tracks = mutable.value.offline.filterNot { it.id == track.id } + track
    save("offline", tracks)
    mutable.value = mutable.value.copy(offline = tracks, message = null)
    return true
  }

  @Synchronized
  fun remove(id: String) {
    val wanted = mutable.value.wanted.filterNot { it.id == id }
    val offline = mutable.value.offline.filterNot { it.id == id }
    mutable.value = mutable.value.copy(wanted = wanted, offline = offline)
    // Free audio space before writing manifests, so removal still works when full.
    audio(id).delete()
    // An active writer may finish its unlinked descriptor, but wants() prevents publication.
    staging(id).delete()
    save("wanted", wanted)
    save("offline", offline)
  }

  companion object {
    @Volatile private var instance: WatchLibrary? = null

    fun get(context: Context): WatchLibrary =
      instance
        ?: synchronized(this) {
          instance ?: WatchLibrary(context.applicationContext).also { instance = it }
        }
  }
}
