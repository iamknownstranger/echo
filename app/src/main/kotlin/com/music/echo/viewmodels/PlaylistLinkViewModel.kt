package echo.music.iad1tya.viewmodels

import android.content.Context
import androidx.core.net.toUri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.exoplayer.offline.DownloadRequest
import androidx.media3.exoplayer.offline.DownloadService
import com.music.innertube.models.SongItem
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import echo.music.iad1tya.R
import echo.music.iad1tya.db.MusicDatabase
import echo.music.iad1tya.db.entities.PlaylistEntity
import echo.music.iad1tya.models.MediaMetadata
import echo.music.iad1tya.models.toMediaMetadata
import echo.music.iad1tya.playback.ExoDownloadService
import echo.music.iad1tya.playlistlink.ExternalTrack
import echo.music.iad1tya.playlistlink.LinkEntityKind
import echo.music.iad1tya.playlistlink.PlaylistLinkParser
import echo.music.iad1tya.playlistlink.PlaylistLinkRepository
import echo.music.iad1tya.playlistlink.PlaylistLinkServiceException
import echo.music.iad1tya.playlistlink.PlaylistLinkUnsupportedException
import echo.music.iad1tya.playlistlink.PlaylistService
import echo.music.iad1tya.playlistlink.YouTubeMusicMatcher
import echo.music.iad1tya.utils.reportException
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One reviewable row: a source track and whatever YouTube Music match was found for it. */
data class PlaylistLinkReviewRow(
    val index: Int,
    val source: ExternalTrack,
    val candidate: SongItem?,
    val confidence: YouTubeMusicMatcher.Confidence,
    val included: Boolean,
)

data class PlaylistLinkUiState(
    val inputText: String = "",
    val detectedService: PlaylistService? = null,
    val detectedKind: LinkEntityKind? = null,
    val isResolving: Boolean = false,
    val resolveError: String? = null,
    val resolvedTitle: String? = null,
    val resolvedSubtitle: String? = null,
    val resolvedArtworkUrl: String? = null,
    val isMatching: Boolean = false,
    val matchProgress: Int = 0,
    val matchTotal: Int = 0,
    val results: List<PlaylistLinkReviewRow> = emptyList(),
    val actionMessage: String? = null,
) {
    val hasResults: Boolean get() = results.isNotEmpty()
    val includedCount: Int get() = results.count { it.included && it.candidate != null }
    val isBusy: Boolean get() = isResolving || isMatching
}

@HiltViewModel
class PlaylistLinkViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val repository: PlaylistLinkRepository,
    private val database: MusicDatabase,
) : ViewModel() {

    private val _uiState = MutableStateFlow(PlaylistLinkUiState())
    val uiState: StateFlow<PlaylistLinkUiState> = _uiState.asStateFlow()

    private var resolveJob: Job? = null

    fun onInputTextChange(text: String) {
        val parsed = PlaylistLinkParser.parse(text)
        _uiState.update {
            it.copy(
                inputText = text,
                detectedService = parsed?.service,
                detectedKind = parsed?.kind,
                resolveError = null,
            )
        }
    }

    fun resolveAndMatch() {
        val input = uiState.value.inputText.trim()
        if (input.isBlank() || uiState.value.isBusy) return

        resolveJob?.cancel()
        resolveJob = viewModelScope.launch(Dispatchers.IO) {
            _uiState.update {
                it.copy(
                    isResolving = true,
                    resolveError = null,
                    results = emptyList(),
                    actionMessage = null,
                    resolvedTitle = null,
                    resolvedSubtitle = null,
                    resolvedArtworkUrl = null,
                )
            }

            val playlist = try {
                repository.resolve(input)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: PlaylistLinkServiceException) {
                _uiState.update { it.copy(isResolving = false, resolveError = error.message) }
                return@launch
            } catch (error: PlaylistLinkUnsupportedException) {
                _uiState.update { it.copy(isResolving = false, resolveError = error.message) }
                return@launch
            } catch (error: Throwable) {
                reportException(error)
                _uiState.update {
                    it.copy(
                        isResolving = false,
                        resolveError = error.message ?: context.getString(R.string.playlist_link_generic_failure),
                    )
                }
                return@launch
            }

            _uiState.update {
                it.copy(
                    isResolving = false,
                    resolvedTitle = playlist.title,
                    resolvedSubtitle = playlist.subtitle,
                    resolvedArtworkUrl = playlist.artworkUrl,
                )
            }

            if (playlist.tracks.isEmpty()) {
                _uiState.update { it.copy(resolveError = context.getString(R.string.playlist_link_empty)) }
                return@launch
            }

            val nativeMatches = playlist.nativeMatches
            if (nativeMatches != null) {
                val rows = playlist.tracks.mapIndexed { index, track ->
                    PlaylistLinkReviewRow(
                        index = index,
                        source = track,
                        candidate = nativeMatches.getOrNull(index),
                        confidence = YouTubeMusicMatcher.Confidence.CONFIDENT,
                        included = true,
                    )
                }
                _uiState.update { it.copy(results = rows) }
                return@launch
            }

            _uiState.update {
                it.copy(
                    isMatching = true,
                    matchProgress = 0,
                    matchTotal = playlist.tracks.size,
                    results = playlist.tracks.mapIndexed { index, track ->
                        PlaylistLinkReviewRow(index, track, null, YouTubeMusicMatcher.Confidence.NO_MATCH, false)
                    },
                )
            }

            YouTubeMusicMatcher.matchAll(playlist.tracks).collect { event ->
                when (event) {
                    is YouTubeMusicMatcher.MatchEvent.Progress ->
                        _uiState.update { it.copy(matchProgress = event.resolved, matchTotal = event.total) }

                    is YouTubeMusicMatcher.MatchEvent.Resolved ->
                        _uiState.update { state ->
                            val updated = state.results.toMutableList()
                            val row = updated.getOrNull(event.index) ?: return@update state
                            updated[event.index] = row.copy(
                                candidate = event.result.candidate,
                                confidence = event.result.confidence,
                                included = event.result.confidence != YouTubeMusicMatcher.Confidence.NO_MATCH,
                            )
                            state.copy(results = updated)
                        }

                    is YouTubeMusicMatcher.MatchEvent.Completed ->
                        _uiState.update { it.copy(isMatching = false) }
                }
            }
        }
    }

    fun cancelResolve() {
        resolveJob?.cancel()
        resolveJob = null
        _uiState.update { it.copy(isResolving = false, isMatching = false) }
    }

    fun toggleRowIncluded(index: Int) {
        _uiState.update { state ->
            val updated = state.results.toMutableList()
            val row = updated.getOrNull(index) ?: return@update state
            if (row.candidate == null) return@update state
            updated[index] = row.copy(included = !row.included)
            state.copy(results = updated)
        }
    }

    fun dismissError() {
        _uiState.update { it.copy(resolveError = null) }
    }

    fun dismissActionMessage() {
        _uiState.update { it.copy(actionMessage = null) }
    }

    fun reset() {
        resolveJob?.cancel()
        resolveJob = null
        _uiState.value = PlaylistLinkUiState()
    }

    /** Every included, successfully-matched row, ready to queue/save/download. */
    fun includedMediaMetadata(): List<MediaMetadata> =
        uiState.value.results
            .filter { it.included && it.candidate != null }
            .mapNotNull { it.candidate?.toMediaMetadata() }

    fun saveAsPlaylist(name: String) {
        val tracks = includedMediaMetadata()
        val playlistName = name.ifBlank { uiState.value.resolvedTitle.orEmpty() }
        if (tracks.isEmpty() || playlistName.isBlank()) return

        viewModelScope.launch(Dispatchers.IO) {
            val newPlaylist = PlaylistEntity(name = playlistName, thumbnailUrl = uiState.value.resolvedArtworkUrl)
            database.withTransaction {
                insert(newPlaylist)
                tracks.forEach { insert(it) }
            }
            val playlist = database.playlist(newPlaylist.id).firstOrNull()
            if (playlist != null) {
                database.addSongToPlaylist(playlist, tracks.map { it.id })
            }
            _uiState.update {
                it.copy(
                    actionMessage = context.getString(R.string.playlist_link_saved, tracks.size, playlistName),
                )
            }
        }
    }

    fun downloadIncluded() {
        val tracks = includedMediaMetadata()
        if (tracks.isEmpty()) return

        viewModelScope.launch(Dispatchers.IO) {
            database.withTransaction { tracks.forEach { insert(it) } }
            withContext(Dispatchers.Main) {
                tracks.forEach(::enqueueDownload)
            }
            _uiState.update {
                it.copy(actionMessage = context.getString(R.string.playlist_link_downloading, tracks.size))
            }
        }
    }

    private fun enqueueDownload(metadata: MediaMetadata) {
        val downloadRequest = DownloadRequest.Builder(metadata.id, metadata.id.toUri())
            .setCustomCacheKey(metadata.id)
            .setData(metadata.title.toByteArray())
            .build()
        DownloadService.sendAddDownload(context, ExoDownloadService::class.java, downloadRequest, false)
    }
}
