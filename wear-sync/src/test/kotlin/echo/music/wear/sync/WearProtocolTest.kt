package echo.music.wear.sync

import java.io.ByteArrayInputStream
import java.io.File
import org.junit.Assert.*
import org.junit.Test

class WearProtocolTest {
  @Test
  fun catalogRoundTripsUnicodeAndEmptyLibrary() {
    val tracks = listOf(WatchTrack("abc-123_", "音楽 🎵", "Björk", 234))
    assertEquals(tracks, WearProtocol.decode(WearProtocol.encode(tracks)))
    assertEquals(emptyList<WatchTrack>(), WearProtocol.decode(WearProtocol.encode(emptyList())))
  }

  @Test
  fun rejectsTraversalIdsDuplicateIdsAndOversizedCatalogs() {
    assertFalse(WearProtocol.validId("../song"))
    assertFalse(WearProtocol.validId("song/audio"))
    val track = WatchTrack("id", "Song", "Artist", 100)
    assertThrows(IllegalArgumentException::class.java) {
      WearProtocol.decode(WearProtocol.encode(listOf(track, track)))
    }
    assertThrows(IllegalArgumentException::class.java) {
      WearProtocol.encode(List(201) { track })
    }
    assertThrows(IllegalArgumentException::class.java) { WearProtocol.decode(ByteArray(90_000)) }
  }

  @Test
  fun rejectsUnknownVersionAndTrailingBytes() {
    assertThrows(IllegalArgumentException::class.java) {
      WearProtocol.decode(byteArrayOf(0, 0, 0, 2, 0, 0, 0, 0))
    }
    assertThrows(IllegalArgumentException::class.java) {
      WearProtocol.decode(WearProtocol.encode(emptyList()) + byteArrayOf(1))
    }
  }

  @Test
  fun commitsExactBytesAndRejectsTruncationCorruptionAndOverflow() {
    val source = File.createTempFile("echo-source", ".audio")
    val staging = File.createTempFile("echo-receive", ".part")
    try {
      val bytes = ByteArray(180_000) { (it % 251).toByte() }
      source.writeBytes(bytes)
      val sha = WearProtocol.sha256(source)
      WearProtocol.receive(ByteArrayInputStream(bytes), staging, bytes.size.toLong(), sha)
      assertArrayEquals(bytes, staging.readBytes())
      for (bad in
        listOf(
          bytes.copyOf(bytes.size - 1),
          bytes + byteArrayOf(0),
          bytes.copyOf().apply { this[99] = 0 },
        )) {
        assertThrows(IllegalArgumentException::class.java) {
          WearProtocol.receive(ByteArrayInputStream(bad), staging, bytes.size.toLong(), sha)
        }
        assertFalse(staging.exists())
      }
    } finally {
      source.delete()
      staging.delete()
    }
  }

  @Test
  fun refusesUnboundedTransfer() {
    val file = File.createTempFile("echo-size", ".part")
    try {
      assertThrows(IllegalArgumentException::class.java) {
        WearProtocol.receive(
          ByteArrayInputStream(byteArrayOf()),
          file,
          WearProtocol.MAX_BYTES + 1,
          "0".repeat(64),
        )
      }
    } finally {
      file.delete()
    }
  }
}
