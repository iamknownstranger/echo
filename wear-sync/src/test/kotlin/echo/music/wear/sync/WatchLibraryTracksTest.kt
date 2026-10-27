package echo.music.wear.sync

import org.junit.Assert.*
import org.junit.Test

class WatchLibraryTracksTest {
  private val selected = WatchTrack("selected", "Selected song", "Artist", 180)
  private val saved = WatchTrack("saved", "Saved song", "Artist", 240)
  private val available = WatchTrack("available", "Phone song", "Artist", 200)

  @Test
  fun removedPhoneEntryRemainsReachableInBothViewsAfterRestart() {
    // Reproduce selection -> phone catalog removal -> process restart. The persisted
    // wanted metadata must still supply a row for the existing Retry/Cancel actions.
    val restoredWanted = WearProtocol.decode(WearProtocol.encode(listOf(selected)))
    for (watchOnly in listOf(true, false)) {
      val beforeRemoval = visibleWatchTracks(listOf(selected), emptyList(), restoredWanted, watchOnly)
      val afterRemoval = visibleWatchTracks(emptyList(), emptyList(), restoredWanted, watchOnly)
      assertEquals(listOf(selected), beforeRemoval)
      assertEquals(listOf(selected), afterRemoval)
    }
  }

  @Test
  fun pendingRowsKeepPrimaryOrderAndDoNotDuplicateCatalogOrSavedRows() {
    val updated = selected.copy(title = "Updated phone title")
    val wanted = listOf(saved, selected, available)
    assertEquals(
      listOf(saved, selected, available),
      visibleWatchTracks(listOf(updated, available), listOf(saved), wanted, true),
    )
    assertEquals(
      listOf(updated, available),
      visibleWatchTracks(listOf(updated, available), listOf(saved), wanted, false),
    )
  }

  @Test
  fun completionShowsOneSavedRowAndKeepsItOutOfAnAbsentPhoneCatalog() {
    val completed = selected.copy(title = "Verified local title")
    assertEquals(
      listOf(completed),
      visibleWatchTracks(emptyList(), listOf(completed), listOf(selected), true),
    )
    assertTrue(visibleWatchTracks(emptyList(), listOf(completed), listOf(selected), false).isEmpty())
  }

  @Test
  fun cancellationOfAnOrphanedSelectionFreesCapacityAfterPersistence() {
    val wanted = List(WearProtocol.MAX_TRACKS) { selected.copy(id = "pending_$it") }
    val visible = visibleWatchTracks(emptyList(), emptyList(), wanted, true)
    assertEquals(WearProtocol.MAX_TRACKS, visible.size)
    assertThrows(IllegalArgumentException::class.java) { WearProtocol.encode(wanted + available) }
    // Cancel uses the displayed ID to remove the same persistent wanted entry.
    val cancelledId = visible.first().id
    val remaining = WearProtocol.decode(WearProtocol.encode(wanted.filterNot { it.id == cancelledId }))
    for (watchOnly in listOf(true, false)) {
      assertFalse(
        visibleWatchTracks(emptyList(), emptyList(), remaining, watchOnly).any { it.id == cancelledId }
      )
    }
    assertEquals(
      WearProtocol.MAX_TRACKS,
      WearProtocol.decode(WearProtocol.encode(remaining + available)).size,
    )
  }

  @Test
  fun viewsStaySeparateWhenThereAreNoPendingSelections() {
    assertEquals(
      listOf(saved),
      visibleWatchTracks(listOf(available), listOf(saved), emptyList(), true),
    )
    assertEquals(
      listOf(available),
      visibleWatchTracks(listOf(available), listOf(saved), emptyList(), false),
    )
    assertTrue(visibleWatchTracks(emptyList(), emptyList(), emptyList(), true).isEmpty())
  }
}
