package echo.music.iad1tya.wear

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.ContentMetadata
import androidx.media3.exoplayer.offline.Download
import androidx.work.*
import com.google.android.gms.wearable.*
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import echo.music.iad1tya.playback.DownloadUtil
import echo.music.wear.sync.WatchTrack
import echo.music.wear.sync.WearProtocol as P
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext

@EntryPoint
@InstallIn(SingletonComponent::class)
interface WearDownloadEntryPoint {
  fun downloadUtil(): DownloadUtil
}

/** Only the GMS APK exposes this endpoint; the FOSS dependency graph stays unchanged. */
class PhoneWearListener : WearableListenerService() {
  override fun onMessageReceived(event: MessageEvent) {
    val id =
      when {
        event.path == P.REFRESH -> ""
        event.path.startsWith(P.REQUEST) ->
          event.path.removePrefix(P.REQUEST).takeIf(P::validId) ?: return
        else -> return
      }
    val work =
      OneTimeWorkRequestBuilder<PhoneWearWorker>()
        .setInputData(workDataOf("id" to id))
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
        .build()
    WorkManager.getInstance(this).enqueueUniqueWork("wear-send-$id", ExistingWorkPolicy.KEEP, work)
  }

  override fun onDataChanged(events: DataEventBuffer) {
    events.forEach { event ->
      val path = event.dataItem.uri.path.orEmpty()
      if (event.type == DataEvent.TYPE_CHANGED && path.startsWith(P.RECEIPT)) {
        val id = path.removePrefix(P.RECEIPT)
        if (P.validId(id)) {
          // A receipt means the watch committed a verified local copy. Removing the
          // transport item never removes the watch's library or the phone download.
          Wearable.getDataClient(this)
            .deleteDataItems(
              Uri.parse("wear://*${P.AUDIO}$id"),
              DataClient.FILTER_LITERAL,
            )
          Wearable.getDataClient(this).deleteDataItems(event.dataItem.uri)
        }
      }
    }
  }
}

@UnstableApi
class PhoneWearWorker(context: Context, parameters: WorkerParameters) :
  CoroutineWorker(context, parameters) {
  override suspend fun doWork(): Result =
    withContext(Dispatchers.IO) {
      val id = inputData.getString("id") ?: return@withContext Result.failure()
      if (id.isNotEmpty() && !P.validId(id)) return@withContext Result.failure()
      var staging: File? = null
      try {
        // DownloadManager must be constructed on a looper thread, even on cold start.
        val util =
          withContext(Dispatchers.Main) {
            EntryPointAccessors.fromApplication(
                applicationContext,
                WearDownloadEntryPoint::class.java,
              )
              .downloadUtil()
          }
        val client = Wearable.getDataClient(applicationContext)
        if (id.isEmpty()) {
          val tracks = mutableListOf<WatchTrack>()
          util.downloadManager.downloadIndex.getDownloads(Download.STATE_COMPLETED).use { cursor ->
            while (cursor.moveToNext() && tracks.size < P.MAX_TRACKS) {
              val songId = cursor.download.request.id
              if (!P.validId(songId)) continue
              val song = util.database.getSongByIdBlocking(songId) ?: continue
              if (song.song.isLocal || songId.endsWith("_canvas")) continue
              val track =
                WatchTrack(
                  songId,
                  song.title,
                  song.artists.joinToString { it.name },
                  song.song.duration,
                )
              // Stay below Data Layer's 100KB metadata limit even for multi-byte titles.
              if (runCatching { P.encode(tracks + track) }.isFailure) break
              tracks += track
            }
          }
          val request =
            PutDataMapRequest.create(P.CATALOG)
              .apply {
                dataMap.putByteArray("tracks", P.encode(tracks))
                dataMap.putLong("revision", System.currentTimeMillis())
              }
              .asPutDataRequest()
              .setUrgent()
          client.putDataItem(request).await()
        } else {
          val download =
            requireNotNull(util.downloadManager.downloadIndex.getDownload(id)) {
              "Download this track on the phone first"
            }
          require(download.state == Download.STATE_COMPLETED) {
            "Download this track on the phone first"
          }
          val key = download.request.customCacheKey ?: id
          val size =
            download.contentLength.takeIf { it > 0 }
              ?: ContentMetadata.getContentLength(util.downloadCache.getContentMetadata(key))
          require(size in 1..P.MAX_BYTES) { "Unsupported download size" }
          require(util.downloadCache.isCached(key, 0, size)) { "Phone download is incomplete" }
          val export = File.createTempFile("wear-export-", ".audio", applicationContext.cacheDir)
          staging = export
          val source =
            CacheDataSource.Factory()
              .setCache(util.downloadCache)
              .setUpstreamDataSourceFactory(null)
              .setCacheWriteDataSinkFactory(null)
              .createDataSource()
          try {
            source.open(
              DataSpec.Builder().setUri(download.request.uri).setKey(key).setLength(size).build()
            )
            export.outputStream().use { output ->
              val buffer = ByteArray(64 * 1024)
              var remaining = size
              while (remaining > 0) {
                val count = source.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                check(count > 0) { "Incomplete phone cache" }
                output.write(buffer, 0, count)
                remaining -= count
              }
            }
          } finally {
            source.close()
          }
          val song = util.database.getSongByIdBlocking(id) ?: error("Track removed")
          val track =
            WatchTrack(id, song.title, song.artists.joinToString { it.name }, song.song.duration)
          ParcelFileDescriptor.open(export, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            val request =
              PutDataMapRequest.create(P.AUDIO + id)
                .apply {
                  dataMap.putByteArray("track", P.encode(listOf(track)))
                  dataMap.putLong("size", size)
                  dataMap.putString("sha256", P.sha256(export))
                  dataMap.putAsset("audio", Asset.createFromFd(descriptor))
                  dataMap.putLong("revision", System.currentTimeMillis())
                }
                .asPutDataRequest()
                .setUrgent()
            // Asset is streamed from a file, never loaded as a whole ByteArray.
            client.putDataItem(request).await()
          }
        }
        Result.success()
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        if (runAttemptCount < 3 && e !is IllegalArgumentException) Result.retry()
        else {
          val message = e.message ?: "Watch sync failed"
          runCatching {
            Wearable.getDataClient(applicationContext)
              .putDataItem(
                PutDataMapRequest.create(P.ERROR + id)
                  .apply {
                    dataMap.putString("message", message)
                    dataMap.putLong("revision", System.currentTimeMillis())
                  }
                  .asPutDataRequest()
                  .setUrgent()
              )
              .await()
          }
          Result.failure(workDataOf("error" to message))
        }
      } finally {
        staging?.delete()
      }
    }
}
