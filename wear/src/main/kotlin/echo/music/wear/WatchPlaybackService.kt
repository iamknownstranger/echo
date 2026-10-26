package echo.music.wear

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/** This player has local file URIs only; phone playback is never taken over. */
class WatchPlaybackService : MediaSessionService() {
  private var session: MediaSession? = null

  override fun onCreate() {
    super.onCreate()
    val player =
      ExoPlayer.Builder(this).build().apply {
        setAudioAttributes(
          AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build(),
          true,
        )
        setHandleAudioBecomingNoisy(true)
        setWakeMode(C.WAKE_MODE_LOCAL)
        repeatMode = Player.REPEAT_MODE_OFF
      }
    val activity =
      PendingIntent.getActivity(
        this,
        0,
        Intent(this, WatchActivity::class.java),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
      )
    session =
      MediaSession.Builder(this, player)
        .setSessionActivity(activity)
        .setCallback(
          object : MediaSession.Callback {
            override fun onAddMediaItems(
              session: MediaSession,
              controller: MediaSession.ControllerInfo,
              mediaItems: MutableList<MediaItem>,
            ): ListenableFuture<MutableList<MediaItem>> {
              val library = WatchLibrary.get(this@WatchPlaybackService)
              val offline = library.state.value.offline.associateBy { it.id }
              val items =
                mediaItems
                  .mapNotNull { requested ->
                    val track = offline[requested.mediaId] ?: return@mapNotNull null
                    MediaItem.Builder()
                      .setMediaId(track.id)
                      .setUri(android.net.Uri.fromFile(library.audio(track.id)))
                      .setMediaMetadata(
                        MediaMetadata.Builder()
                          .setTitle(track.title)
                          .setArtist(track.artist)
                          .build()
                      )
                      .build()
                  }
                  .toMutableList()
              return Futures.immediateFuture(items)
            }
          }
        )
        .build()
  }

  override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

  override fun onDestroy() {
    session?.run {
      player.release()
      release()
    }
    session = null
    super.onDestroy()
  }
}
