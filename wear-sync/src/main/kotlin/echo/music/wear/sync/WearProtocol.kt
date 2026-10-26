package echo.music.wear.sync

import java.io.*
import java.security.MessageDigest

data class WatchTrack(val id: String, val title: String, val artist: String, val duration: Int)

/** Versioned, bounded wire format. No URLs, account cookies, or phone cache paths cross devices. */
object WearProtocol {
  const val ROOT = "/echo/v1"
  const val CATALOG = "$ROOT/catalog"
  const val REFRESH = "$ROOT/refresh"
  const val REQUEST = "$ROOT/request/"
  const val AUDIO = "$ROOT/audio/"
  const val ERROR = "$ROOT/error/"
  const val RECEIPT = "$ROOT/receipt/"
  const val MAX_BYTES = 100L * 1024 * 1024
  const val MAX_TRACKS = 200
  const val MAX_CATALOG_BYTES = 80 * 1024

  fun validId(id: String) = id.matches(Regex("[A-Za-z0-9_-]{1,128}"))

  fun encode(tracks: List<WatchTrack>): ByteArray {
    require(tracks.size <= MAX_TRACKS)
    val bytes = ByteArrayOutputStream()
    DataOutputStream(bytes).use { out ->
      out.writeInt(1)
      out.writeInt(tracks.size)
      tracks.forEach {
        require(validId(it.id))
        out.writeUTF(it.id)
        out.writeUTF(it.title.take(160))
        out.writeUTF(it.artist.take(160))
        out.writeInt(it.duration)
      }
    }
    return bytes.toByteArray().also { require(it.size <= MAX_CATALOG_BYTES) }
  }

  fun decode(bytes: ByteArray): List<WatchTrack> {
    require(bytes.size <= MAX_CATALOG_BYTES)
    return DataInputStream(ByteArrayInputStream(bytes)).use { input ->
      require(input.readInt() == 1) { "Unsupported sync version" }
      val count = input.readInt()
      require(count in 0..MAX_TRACKS)
      val tracks =
        List(count) {
          val id = input.readUTF()
          require(validId(id))
          WatchTrack(id, input.readUTF(), input.readUTF(), input.readInt())
        }
      require(tracks.map { it.id }.distinct().size == count)
      require(input.available() == 0)
      tracks
    }
  }

  fun sha256(file: File): String =
    file.inputStream().use { input ->
      val digest = MessageDigest.getInstance("SHA-256")
      val buffer = ByteArray(64 * 1024)
      while (true) {
        val n = input.read(buffer)
        if (n < 0) break
        digest.update(buffer, 0, n)
      }
      digest.digest().joinToString("") { "%02x".format(it) }
    }

  /** Caller publishes staging via atomic rename only after this succeeds. */
  fun receive(input: InputStream, staging: File, size: Long, sha: String) {
    require(size in 1..MAX_BYTES)
    require(sha.matches(Regex("[a-f0-9]{64}")))
    try {
      staging.outputStream().use { out ->
        val buffer = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
          val n = input.read(buffer)
          if (n < 0) break
          total += n
          require(total <= size) { "Transfer exceeds declared size" }
          out.write(buffer, 0, n)
        }
        require(total == size) { "Incomplete transfer" }
        out.fd.sync()
      }
      require(sha256(staging) == sha) { "Checksum mismatch" }
    } catch (e: Exception) {
      staging.delete()
      throw e
    }
  }
}
