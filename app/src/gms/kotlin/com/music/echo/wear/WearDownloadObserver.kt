package echo.music.iad1tya.wear

import android.content.Context
import androidx.work.*
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.IntoSet
import echo.music.iad1tya.playback.DownloadStateObserver

@Module
@InstallIn(SingletonComponent::class)
object WearDownloadObserverModule {
  @Provides
  @IntoSet
  fun observer(@ApplicationContext context: Context): DownloadStateObserver =
    object : DownloadStateObserver {
      override fun onDownloadsChanged() {
        val work =
          OneTimeWorkRequestBuilder<PhoneWearWorker>().setInputData(workDataOf("id" to "")).build()
        WorkManager.getInstance(context)
          .enqueueUniqueWork("wear-catalog", ExistingWorkPolicy.APPEND_OR_REPLACE, work)
      }
    }
}
