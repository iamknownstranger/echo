package echo.music.wear

import android.content.Context
import android.net.Uri
import androidx.work.*
import com.google.android.gms.wearable.*
import echo.music.wear.sync.WatchTrack
import echo.music.wear.sync.WearProtocol as P
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext

object WatchSync {
  fun refresh(context: Context) = request(context, "")

  fun download(context: Context, track: WatchTrack) {
    val library = WatchLibrary.get(context)
    try {
      library.want(track)
      library.message(null)
      request(context, track.id)
    } catch (e: Exception) {
      library.message("Unable to queue download: ${e.message}")
    }
  }

  private fun request(context: Context, id: String) {
    val request =
      OneTimeWorkRequestBuilder<WatchRequestWorker>()
        .setInputData(workDataOf("id" to id))
        .addTag("watch-sync")
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
        .build()
    WorkManager.getInstance(context)
      .enqueueUniqueWork("watch-request-$id", ExistingWorkPolicy.REPLACE, request)
  }

  fun receive(context: Context, uri: Uri) {
    val path = uri.path.orEmpty()
    if (path != P.CATALOG && !path.startsWith(P.AUDIO) && !path.startsWith(P.ERROR)) return
    if (path.startsWith(P.AUDIO) && !P.validId(path.removePrefix(P.AUDIO))) return
    val request =
      OneTimeWorkRequestBuilder<WatchReceiveWorker>()
        .setInputData(workDataOf("uri" to uri.toString()))
        .addTag("watch-sync")
        .build()
    WorkManager.getInstance(context)
      .enqueueUniqueWork("watch-receive-$path", ExistingWorkPolicy.APPEND_OR_REPLACE, request)
  }
}

class WatchDataListener : WearableListenerService() {
  override fun onDataChanged(events: DataEventBuffer) {
    // Event buffers cannot escape the callback. Workers re-read the durable DataItem.
    events.forEach {
      if (it.type == DataEvent.TYPE_CHANGED) WatchSync.receive(this, it.dataItem.uri)
    }
  }
}

class WatchRequestWorker(context: Context, params: WorkerParameters) :
  CoroutineWorker(context, params) {
  override suspend fun doWork(): Result =
    withContext(Dispatchers.IO) {
      val id = inputData.getString("id") ?: return@withContext Result.failure()
      val library = WatchLibrary.get(applicationContext)
      if (id.isNotEmpty() && (!P.validId(id) || !library.wants(id)))
        return@withContext Result.failure()
      if (id.isNotEmpty() && library.state.value.offline.any { it.id == id })
        return@withContext Result.success()
      try {
        val nodes = Wearable.getNodeClient(applicationContext).connectedNodes.await()
        if (nodes.isEmpty()) error("Connect your phone to sync")
        for (node in nodes) {
          Wearable.getMessageClient(applicationContext)
            .sendMessage(
              node.id,
              if (id.isEmpty()) P.REFRESH else P.REQUEST + id,
              byteArrayOf(),
            )
            .await()
        }
        // Reconcile items persisted while this process was stopped, including an
        // asset whose original callback arrived before the user chose Download.
        Wearable.getDataClient(applicationContext).dataItems.await().use { items ->
          items.forEach { WatchSync.receive(applicationContext, it.uri) }
        }
        if (id.isEmpty()) Result.success()
        else retryOrFail("Transfer pending; keep phone connected")
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        retryOrFail(e.message ?: "Sync unavailable")
      }
    }

  private fun retryOrFail(message: String): Result =
    if (runAttemptCount < 8) Result.retry()
    else {
      WatchLibrary.get(applicationContext).message(message)
      Result.failure(workDataOf("error" to message))
    }
}

class WatchReceiveWorker(context: Context, params: WorkerParameters) :
  CoroutineWorker(context, params) {
  override suspend fun doWork(): Result =
    withContext(Dispatchers.IO) {
      val uri = inputData.getString("uri")?.let(Uri::parse) ?: return@withContext Result.failure()
      val library = WatchLibrary.get(applicationContext)
      val client = Wearable.getDataClient(applicationContext)
      try {
        val item = client.getDataItem(uri).await() ?: return@withContext Result.success()
        val map = DataMapItem.fromDataItem(item).dataMap
        if (uri.path.orEmpty().startsWith(P.ERROR)) {
          val id = uri.path.orEmpty().removePrefix(P.ERROR)
          if (
            id.isEmpty() || (library.wants(id) && library.state.value.offline.none { it.id == id })
          ) {
            library.message(map.getString("message") ?: "Phone transfer failed")
          }
        } else if (uri.path == P.CATALOG) {
          library.catalog(P.decode(map.getByteArray("tracks") ?: error("Missing catalog")))
        } else {
          val id = uri.path.orEmpty().removePrefix(P.AUDIO)
          require(P.validId(id))
          if (!library.wants(id)) {
            client.deleteDataItems(uri).await()
            return@withContext Result.success()
          }
          val track = P.decode(map.getByteArray("track") ?: error("Missing metadata")).single()
          require(track.id == id)
          val size = map.getLong("size")
          require(size in 1..P.MAX_BYTES)
          if (library.state.value.offline.none { it.id == id }) {
            check(library.freeBytes() > size + 20 * 1024 * 1024) {
              "Not enough watch storage; remove a download"
            }
            val asset = map.getAsset("audio") ?: error("Missing audio")
            val response = client.getFdForAsset(asset).await()
            try {
              val input = response.inputStream
              input.use { P.receive(it, library.staging(id), size, map.getString("sha256") ?: "") }
            } finally {
              response.release()
            }
            if (!library.commit(track, library.staging(id))) {
              client.deleteDataItems(uri).await()
              return@withContext Result.success()
            }
          }
          WorkManager.getInstance(applicationContext).cancelUniqueWork("watch-request-$id")
          client
            .putDataItem(
              PutDataMapRequest.create(P.RECEIPT + id)
                .apply {
                  dataMap.putLong("received", System.currentTimeMillis())
                }
                .asPutDataRequest()
                .setUrgent()
            )
            .await()
        }
        Result.success()
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        if (runAttemptCount < 3 && e !is IllegalArgumentException) Result.retry()
        else {
          library.message(e.message ?: "Transfer failed")
          Result.failure(workDataOf("error" to (e.message ?: "Transfer failed")))
        }
      }
    }
}
