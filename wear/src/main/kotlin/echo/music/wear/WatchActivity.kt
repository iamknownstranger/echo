package echo.music.wear

import android.Manifest
import android.content.ComponentName
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.*
import androidx.work.WorkInfo
import androidx.work.WorkManager
import echo.music.wear.sync.WatchTrack
import java.util.concurrent.CancellationException
import kotlinx.coroutines.guava.await

class WatchActivity : ComponentActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    if (Build.VERSION.SDK_INT >= 33)
      requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
    setContent { WatchApp() }
  }

  @Composable
  private fun WatchApp() {
    val library = remember { WatchLibrary.get(this) }
    val state by library.state.collectAsState()
    var controller by remember { mutableStateOf<MediaController?>(null) }
    var playing by remember { mutableStateOf(false) }
    var nowPlaying by remember { mutableStateOf("") }
    var playerError by remember { mutableStateOf<String?>(null) }
    var downloadsOnly by remember { mutableStateOf(true) }
    var work by remember { mutableStateOf<List<WorkInfo>>(emptyList()) }
    val manager = remember { WorkManager.getInstance(this) }
    DisposableEffect(manager) {
      val live = manager.getWorkInfosByTagLiveData("watch-sync")
      val observer = androidx.lifecycle.Observer<List<WorkInfo>> { work = it.orEmpty() }
      live.observe(this@WatchActivity, observer)
      onDispose { live.removeObserver(observer) }
    }
    LaunchedEffect(Unit) {
      val future =
        MediaController.Builder(
            this@WatchActivity,
            SessionToken(
              this@WatchActivity,
              ComponentName(this@WatchActivity, WatchPlaybackService::class.java),
            ),
          )
          .buildAsync()
      try {
        controller = future.await()
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        playerError = "Player unavailable: ${e.message}"
      }
      WatchSync.refresh(this@WatchActivity)
    }
    DisposableEffect(controller) {
      val player = controller
      fun update() {
        playing = player?.isPlaying == true
        nowPlaying = player?.mediaMetadata?.title?.toString().orEmpty()
      }
      val listener =
        object : Player.Listener {
          override fun onEvents(player: Player, events: Player.Events) {
            update()
          }

          override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
            playerError = "Playback failed. Try downloading this track again."
          }
        }
      player?.addListener(listener)
      update()
      onDispose {
        player?.removeListener(listener)
        player?.release()
      }
    }
    MaterialTheme(
      colors =
        Colors(
          primary = Color.White,
          onPrimary = Color.Black,
          background = Color.Black,
          onBackground = Color.White,
        )
    ) {
      val listState = rememberScalingLazyListState()
      Scaffold(timeText = { TimeText() }, positionIndicator = { PositionIndicator(listState) }) {
        ScalingLazyColumn(
          state = listState,
          modifier = Modifier.fillMaxSize().background(Color.Black),
          contentPadding = PaddingValues(horizontal = 22.dp, vertical = 34.dp),
          verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
          item { Text("ECHO", style = MaterialTheme.typography.title2) }
          item {
            Text(
              "${state.offline.size} saved • ${library.freeBytes() / (1024 * 1024)} MB free",
              style = MaterialTheme.typography.caption2,
              textAlign = TextAlign.Center,
            )
          }
          if (nowPlaying.isNotEmpty()) {
            item { Text(nowPlaying, modifier = Modifier.basicMarquee(), maxLines = 1) }
            item {
              Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                  modifier = Modifier.size(40.dp),
                  onClick = { controller?.seekToPreviousMediaItem() },
                  enabled = controller?.hasPreviousMediaItem() == true,
                ) {
                  Text("Prev")
                }
                Button(
                  modifier = Modifier.size(40.dp),
                  onClick = { controller?.let { if (it.isPlaying) it.pause() else it.play() } },
                ) {
                  Text(if (playing) "Pause" else "Play")
                }
                Button(
                  modifier = Modifier.size(40.dp),
                  onClick = { controller?.seekToNextMediaItem() },
                  enabled = controller?.hasNextMediaItem() == true,
                ) {
                  Text("Next")
                }
              }
            }
          }
          item {
            Action(if (downloadsOnly) "Browse phone downloads" else "Show saved on watch") {
              downloadsOnly = !downloadsOnly
            }
          }
          item { Action("Sync with phone") { WatchSync.refresh(this@WatchActivity) } }
          if (state.message != null) item { Text(state.message!!, textAlign = TextAlign.Center) }
          if (playerError != null) item { Text(playerError!!, textAlign = TextAlign.Center) }
          val active = work.count { !it.state.isFinished }
          if (active > 0)
            item {
              Text(
                "Sync queued / transferring ($active). Keep phone connected.",
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.caption2,
              )
            }
          val tracks = if (downloadsOnly) state.offline else state.catalog
          if (tracks.isEmpty())
            item {
              Text(
                if (downloadsOnly) "No music saved yet. Browse phone downloads to choose tracks."
                else
                  "Download music in Echo on your phone, then tap Sync with phone. Shows up to 200 tracks.",
                textAlign = TextAlign.Center,
              )
            }
          items(tracks, key = { it.id }) { track ->
            val saved = state.offline.any { it.id == track.id }
            val wanted = state.wanted.any { it.id == track.id }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
              Text(track.title, modifier = Modifier.basicMarquee(), maxLines = 1)
              Text(track.artist, style = MaterialTheme.typography.caption2, maxLines = 1)
              if (saved) {
                Action("Play on watch", enabled = controller != null) {
                  playerError = null
                  val queue = state.offline
                  controller?.run {
                    setMediaItems(
                      queue.map { mediaItem(it, library) },
                      queue.indexOfFirst { it.id == track.id },
                      0L,
                    )
                    prepare()
                    play()
                  }
                }
              } else {
                Action(if (wanted) "Retry download" else "Download to watch") {
                  WatchSync.download(this@WatchActivity, track)
                }
              }
              if (wanted || saved) {
                Action(if (saved) "Remove from watch" else "Cancel download") {
                  // Avoid deleting a file currently held by ExoPlayer.
                  controller?.run {
                    if ((0 until mediaItemCount).any { getMediaItemAt(it).mediaId == track.id })
                      clearMediaItems()
                  }
                  runCatching { library.remove(track.id) }
                    .onFailure { library.message("Could not update watch library: ${it.message}") }
                  manager.cancelUniqueWork("watch-request-${track.id}")
                }
              }
              Spacer(Modifier.height(8.dp))
            }
          }
        }
      }
    }
  }

  @Composable
  private fun Action(label: String, enabled: Boolean = true, onClick: () -> Unit) {
    Chip(
      onClick = onClick,
      enabled = enabled,
      label = { Text(label, maxLines = 2) },
      modifier = Modifier.fillMaxWidth(),
      colors =
        ChipDefaults.primaryChipColors(
          backgroundColor = Color(0xFF202020),
          contentColor = Color.White,
        ),
    )
  }

  private fun mediaItem(track: WatchTrack, library: WatchLibrary): MediaItem =
    MediaItem.Builder()
      .setMediaId(track.id)
      .setUri(android.net.Uri.fromFile(library.audio(track.id)))
      .setMediaMetadata(
        MediaMetadata.Builder().setTitle(track.title).setArtist(track.artist).build()
      )
      .build()
}
