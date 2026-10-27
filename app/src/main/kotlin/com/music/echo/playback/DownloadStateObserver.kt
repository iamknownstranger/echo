package echo.music.iad1tya.playback

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import dagger.multibindings.Multibinds

/**
 * Optional flavor integrations observe changes without coupling the downloader to Play Services.
 */
interface DownloadStateObserver {
  fun onDownloadsChanged()
}

@Module
@InstallIn(SingletonComponent::class)
abstract class DownloadObserverModule {
  @Multibinds abstract fun observers(): Set<DownloadStateObserver>
}
