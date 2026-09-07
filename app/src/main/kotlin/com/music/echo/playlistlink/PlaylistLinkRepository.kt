package echo.music.iad1tya.playlistlink

import android.content.Context
import com.music.innertube.YouTube
import com.music.innertube.models.SongItem
import dagger.hilt.android.qualifiers.ApplicationContext
import echo.music.iad1tya.R
import echo.music.iad1tya.spotifyimport.SpotifyImportRepository
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.http.HttpHeaders
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException

/**
 * Resolves a pasted link from any supported music service into an [ExternalPlaylist] of tracks
 * ready for [YouTubeMusicMatcher]. This is step 2 of the "universal playlist link" pipeline —
 * step 1 ([PlaylistLinkParser]) classifies the link, this fetches its track list, and the caller
 * (see the `PlaylistLinkViewModel`) runs matching, then plays/saves/downloads the result.
 */
@Singleton
class PlaylistLinkRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val spotifyImportRepository: SpotifyImportRepository,
) {

    /** @throws PlaylistLinkUnsupportedException when [rawInput] isn't a recognizable link. */
    suspend fun resolve(rawInput: String): ExternalPlaylist {
        val link = PlaylistLinkParser.parse(rawInput)
            ?: throw PlaylistLinkUnsupportedException(context.getString(R.string.playlist_link_unrecognized))
        return resolveLink(link)
    }

    private suspend fun resolveLink(link: PlaylistLink): ExternalPlaylist = when (link) {
        is PlaylistLink.ShortLink -> resolveShortLink(link)
        is PlaylistLink.YouTubeMusic -> resolveYouTube(link)
        is PlaylistLink.Spotify -> resolveSpotify(link)
        is PlaylistLink.AppleMusic -> wrapServiceErrors(PlaylistService.APPLE_MUSIC) { AppleMusicPlaylistFetcher.fetch(link) }
        is PlaylistLink.Deezer -> wrapServiceErrors(PlaylistService.DEEZER) { DeezerPlaylistFetcher.fetch(link) }
        is PlaylistLink.Tidal -> wrapServiceErrors(PlaylistService.TIDAL) { TidalPlaylistFetcher.fetch(link) }
        is PlaylistLink.SoundCloud -> wrapServiceErrors(PlaylistService.SOUNDCLOUD) { SoundCloudPlaylistFetcher.fetch(link) }
        is PlaylistLink.AmazonMusic -> throw PlaylistLinkServiceException(
            PlaylistService.AMAZON_MUSIC,
            context.getString(R.string.playlist_link_amazon_unsupported),
        )
    }

    private suspend fun resolveShortLink(link: PlaylistLink.ShortLink): ExternalPlaylist {
        val resolvedUrl = followRedirect(link.rawUrl)
        val resolved = resolvedUrl?.let(PlaylistLinkParser::parse)
            ?: throw PlaylistLinkServiceException(
                link.likelyService,
                context.getString(R.string.playlist_link_short_link_failed),
            )
        return resolveLink(resolved)
    }

    private suspend fun resolveYouTube(link: PlaylistLink.YouTubeMusic): ExternalPlaylist =
        if (link.kind == LinkEntityKind.TRACK) {
            val song = YouTube.queue(videoIds = listOf(link.id)).getOrElse { error ->
                if (error is CancellationException) throw error
                throw PlaylistLinkServiceException(
                    PlaylistService.YOUTUBE_MUSIC,
                    context.getString(R.string.playlist_link_youtube_failed),
                )
            }.firstOrNull() ?: throw PlaylistLinkServiceException(
                PlaylistService.YOUTUBE_MUSIC,
                context.getString(R.string.playlist_link_youtube_failed),
            )
            ExternalPlaylist(
                service = PlaylistService.YOUTUBE_MUSIC,
                kind = LinkEntityKind.TRACK,
                title = song.title,
                subtitle = song.artists.joinToString(", ") { it.name },
                artworkUrl = song.thumbnail,
                tracks = listOf(song.toExternalTrack()),
                nativeMatches = listOf(song),
            )
        } else {
            val page = YouTube.playlist(link.id).getOrElse { error ->
                if (error is CancellationException) throw error
                throw PlaylistLinkServiceException(
                    PlaylistService.YOUTUBE_MUSIC,
                    context.getString(R.string.playlist_link_youtube_failed),
                )
            }
            ExternalPlaylist(
                service = PlaylistService.YOUTUBE_MUSIC,
                kind = LinkEntityKind.PLAYLIST,
                title = page.playlist.title,
                subtitle = page.playlist.author?.name,
                artworkUrl = page.playlist.thumbnail,
                tracks = page.songs.map { it.toExternalTrack() },
                nativeMatches = page.songs,
            )
        }

    private suspend fun resolveSpotify(link: PlaylistLink.Spotify): ExternalPlaylist {
        if (link.kind == LinkEntityKind.TRACK) {
            throw PlaylistLinkServiceException(
                PlaylistService.SPOTIFY,
                context.getString(R.string.playlist_link_spotify_track_unsupported),
            )
        }
        val bundle = try {
            when (link.kind) {
                LinkEntityKind.PLAYLIST -> spotifyImportRepository.fetchPlaylistTracksForLink(link.id)
                LinkEntityKind.ALBUM -> spotifyImportRepository.fetchAlbumTracksForLink(link.id)
                LinkEntityKind.TRACK -> error("unreachable")
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw PlaylistLinkServiceException(
                PlaylistService.SPOTIFY,
                e.message ?: context.getString(R.string.spotify_not_connected),
            )
        }
        return ExternalPlaylist(
            service = PlaylistService.SPOTIFY,
            kind = link.kind,
            title = bundle.title,
            subtitle = bundle.subtitle,
            artworkUrl = bundle.artworkUrl,
            tracks = bundle.tracks,
        )
    }

    /** Follows an HTTP redirect chain (e.g. `dzr.page.link`) and returns the final landed URL. */
    private suspend fun followRedirect(rawUrl: String): String? = try {
        val response = PlaylistLinkHttpClient.client.get(rawUrl) {
            header(HttpHeaders.UserAgent, "Mozilla/5.0")
        }
        response.call.request.url.toString().takeIf { it.isNotBlank() && it != rawUrl }
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private suspend fun <T> wrapServiceErrors(service: PlaylistService, block: suspend () -> T): T = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: PlaylistLinkServiceException) {
        throw e
    } catch (e: Exception) {
        throw PlaylistLinkServiceException(
            service,
            e.message ?: context.getString(R.string.playlist_link_generic_failure),
        )
    }
}

private fun SongItem.toExternalTrack(): ExternalTrack = ExternalTrack(
    title = title,
    artists = artists.map { it.name },
    album = album?.name,
    durationMillis = duration?.toLong()?.times(1000),
    artworkUrl = thumbnail,
)
