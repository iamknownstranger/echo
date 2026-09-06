package echo.music.iad1tya.playlistlink

import com.music.innertube.models.SongItem

/**
 * A music service the "universal playlist link" feature knows how to parse and (where possible)
 * resolve without asking the user to log in.
 */
enum class PlaylistService {
    SPOTIFY,
    YOUTUBE_MUSIC,
    APPLE_MUSIC,
    DEEZER,
    AMAZON_MUSIC,
    TIDAL,
    SOUNDCLOUD,
}

/** What kind of catalog entity a parsed link points at. */
enum class LinkEntityKind {
    PLAYLIST,
    ALBUM,
    TRACK,
}

/**
 * A pasted link, classified by service and entity kind. Produced by [PlaylistLinkParser], which
 * is pure and side-effect free — no network access happens until [PlaylistLinkRepository]
 * resolves one of these into an [ExternalPlaylist].
 */
sealed interface PlaylistLink {
    val service: PlaylistService
    val kind: LinkEntityKind

    data class Spotify(val id: String, override val kind: LinkEntityKind) : PlaylistLink {
        override val service get() = PlaylistService.SPOTIFY
    }

    data class YouTubeMusic(val id: String, override val kind: LinkEntityKind) : PlaylistLink {
        override val service get() = PlaylistService.YOUTUBE_MUSIC
    }

    data class AppleMusic(
        val id: String,
        override val kind: LinkEntityKind,
        val storefront: String,
    ) : PlaylistLink {
        override val service get() = PlaylistService.APPLE_MUSIC
    }

    data class Deezer(val id: String, override val kind: LinkEntityKind) : PlaylistLink {
        override val service get() = PlaylistService.DEEZER
    }

    data class AmazonMusic(val id: String, override val kind: LinkEntityKind) : PlaylistLink {
        override val service get() = PlaylistService.AMAZON_MUSIC
    }

    data class Tidal(val id: String, override val kind: LinkEntityKind) : PlaylistLink {
        override val service get() = PlaylistService.TIDAL
    }

    /** `soundcloud.com/<user>/sets/<slug>` — SoundCloud playlists only. */
    data class SoundCloud(val user: String, val slug: String) : PlaylistLink {
        override val kind get() = LinkEntityKind.PLAYLIST
        override val service get() = PlaylistService.SOUNDCLOUD
    }

    /**
     * A link recognized as belonging to [likelyService] but whose real target is hidden behind a
     * redirect (e.g. a `dzr.page.link` short link). [PlaylistLinkRepository] follows the redirect
     * and re-parses the resolved URL before this can be resolved into tracks.
     */
    data class ShortLink(val rawUrl: String, val likelyService: PlaylistService) : PlaylistLink {
        override val kind get() = LinkEntityKind.PLAYLIST
        override val service get() = likelyService
    }
}

/** A track as reported by a foreign music service, not yet matched to YouTube Music. */
data class ExternalTrack(
    val title: String,
    val artists: List<String> = emptyList(),
    val album: String? = null,
    val durationMillis: Long? = null,
    val isrc: String? = null,
    val artworkUrl: String? = null,
) {
    val artistDisplay: String get() = artists.joinToString(", ")
}

/**
 * The result of resolving a [PlaylistLink] into its track list.
 *
 * [nativeMatches] is populated only when [service] is [PlaylistService.YOUTUBE_MUSIC]: those
 * tracks are already YouTube Music entities and need no fuzzy matching, so it is index-aligned
 * with [tracks] (which mirrors the same songs purely for display).
 */
data class ExternalPlaylist(
    val service: PlaylistService,
    val kind: LinkEntityKind,
    val title: String,
    val subtitle: String? = null,
    val artworkUrl: String? = null,
    val tracks: List<ExternalTrack>,
    val nativeMatches: List<SongItem>? = null,
)

/** The pasted text could not be recognized as a link from any supported service. */
class PlaylistLinkUnsupportedException(message: String) : Exception(message)

/** The link was recognized, but [service] could not be resolved (missing login, dead API, etc). */
class PlaylistLinkServiceException(val service: PlaylistService, message: String) : Exception(message)
