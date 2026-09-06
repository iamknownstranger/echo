package echo.music.iad1tya.playlistlink

import java.net.URI
import java.net.URLDecoder

/**
 * Classifies a raw pasted string (a bare URL, a `spotify:` URI, or free-form share-sheet text
 * with a link buried inside it) into a [PlaylistLink].
 *
 * Pure and side-effect free by design — no network calls happen here, which is what makes this
 * unit-testable. Following a redirect for a [PlaylistLink.ShortLink] is [PlaylistLinkRepository]'s
 * job, not this parser's.
 */
object PlaylistLinkParser {

    private val URL_IN_TEXT_REGEX = Regex("""(?i)https?://\S+""")
    private val TRAILING_PUNCTUATION_REGEX = Regex("""[)\]}>.,;!?'"]+$""")

    private val SPOTIFY_URI_REGEX =
        Regex("""(?i)^spotify:(playlist|album|track):([A-Za-z0-9]+)$""")
    private val SPOTIFY_PATH_REGEX =
        Regex("""(?i)^/(?:intl-[a-z]{2}/)?(playlist|album|track)/([A-Za-z0-9]+)""")
    private val APPLE_MUSIC_PATH_REGEX =
        Regex("""(?i)^/([a-z]{2})/(playlist|album|song)/[^/]+/([A-Za-z0-9_.\-]+)""")
    private val DEEZER_PATH_REGEX =
        Regex("""(?i)^/(?:[a-z]{2}/)?(playlist|album|track)/(\d+)""")
    private val AMAZON_PATH_REGEX =
        Regex("""(?i)^/(playlists|albums|user-playlists)/([A-Za-z0-9]+)""")
    private val TIDAL_PATH_REGEX =
        Regex("""(?i)^/(?:browse/)?(playlist|album|track)/([A-Za-z0-9-]+)""")
    private val SOUNDCLOUD_SETS_REGEX =
        Regex("""(?i)^/([^/]+)/sets/([^/?]+)""")

    /** Returns `null` when [rawInput] contains nothing recognizable as a supported playlist link. */
    fun parse(rawInput: String): PlaylistLink? {
        val trimmed = rawInput.trim()
        if (trimmed.isEmpty()) return null

        spotifyUri(trimmed)?.let { return it }

        val urlText = extractUrl(trimmed) ?: return null
        val uri = safeParseUri(urlText) ?: return null
        val host = uri.host?.lowercase()?.removePrefix("www.") ?: return null
        val path = uri.rawPath.orEmpty()
        val query = parseQuery(uri.rawQuery)

        return when {
            host == "open.spotify.com" -> parseSpotifyPath(path)
            host == "music.youtube.com" || host == "youtube.com" || host == "m.youtube.com" ->
                parseYouTubePath(path, query)
            host == "youtu.be" -> parseYoutuBe(path, query)
            host == "music.apple.com" -> parseAppleMusicPath(path, query)
            host == "dzr.page.link" -> PlaylistLink.ShortLink(urlText, PlaylistService.DEEZER)
            host == "deezer.com" -> parseDeezerPath(path)
            host.startsWith("music.amazon.") -> parseAmazonPath(path)
            host == "tidal.com" || host == "listen.tidal.com" -> parseTidalPath(path)
            host == "soundcloud.com" -> parseSoundCloudPath(path)
            else -> null
        }
    }

    private fun spotifyUri(text: String): PlaylistLink.Spotify? {
        val match = SPOTIFY_URI_REGEX.find(text) ?: return null
        val kind = entityKind(match.groupValues[1]) ?: return null
        return PlaylistLink.Spotify(id = match.groupValues[2], kind = kind)
    }

    private fun parseSpotifyPath(path: String): PlaylistLink.Spotify? {
        val match = SPOTIFY_PATH_REGEX.find(path) ?: return null
        val kind = entityKind(match.groupValues[1]) ?: return null
        return PlaylistLink.Spotify(id = match.groupValues[2], kind = kind)
    }

    private fun parseYouTubePath(path: String, query: Map<String, String>): PlaylistLink.YouTubeMusic? {
        query["list"]?.takeIf { it.isNotBlank() }?.let {
            return PlaylistLink.YouTubeMusic(id = it, kind = LinkEntityKind.PLAYLIST)
        }
        query["v"]?.takeIf { it.isNotBlank() }?.let {
            return PlaylistLink.YouTubeMusic(id = it, kind = LinkEntityKind.TRACK)
        }
        return null
    }

    private fun parseYoutuBe(path: String, query: Map<String, String>): PlaylistLink.YouTubeMusic? {
        query["list"]?.takeIf { it.isNotBlank() }?.let {
            return PlaylistLink.YouTubeMusic(id = it, kind = LinkEntityKind.PLAYLIST)
        }
        val videoId = path.trim('/').takeIf { it.isNotEmpty() } ?: return null
        return PlaylistLink.YouTubeMusic(id = videoId, kind = LinkEntityKind.TRACK)
    }

    private fun parseAppleMusicPath(path: String, query: Map<String, String>): PlaylistLink.AppleMusic? {
        val match = APPLE_MUSIC_PATH_REGEX.find(path) ?: return null
        val storefront = match.groupValues[1].lowercase()
        val type = match.groupValues[2].lowercase()
        val id = match.groupValues[3]

        // A track deep-link inside an album URL, e.g. .../album/name/12345?i=67890
        query["i"]?.takeIf { it.isNotBlank() }?.let {
            return PlaylistLink.AppleMusic(id = it, kind = LinkEntityKind.TRACK, storefront = storefront)
        }

        val kind = when (type) {
            "playlist" -> LinkEntityKind.PLAYLIST
            "album" -> LinkEntityKind.ALBUM
            "song" -> LinkEntityKind.TRACK
            else -> return null
        }
        return PlaylistLink.AppleMusic(id = id, kind = kind, storefront = storefront)
    }

    private fun parseDeezerPath(path: String): PlaylistLink.Deezer? {
        val match = DEEZER_PATH_REGEX.find(path) ?: return null
        val kind = entityKind(match.groupValues[1]) ?: return null
        return PlaylistLink.Deezer(id = match.groupValues[2], kind = kind)
    }

    private fun parseAmazonPath(path: String): PlaylistLink.AmazonMusic? {
        val match = AMAZON_PATH_REGEX.find(path) ?: return null
        val kind = when (match.groupValues[1].lowercase()) {
            "playlists", "user-playlists" -> LinkEntityKind.PLAYLIST
            "albums" -> LinkEntityKind.ALBUM
            else -> return null
        }
        return PlaylistLink.AmazonMusic(id = match.groupValues[2], kind = kind)
    }

    private fun parseTidalPath(path: String): PlaylistLink.Tidal? {
        val match = TIDAL_PATH_REGEX.find(path) ?: return null
        val kind = entityKind(match.groupValues[1]) ?: return null
        return PlaylistLink.Tidal(id = match.groupValues[2], kind = kind)
    }

    private fun parseSoundCloudPath(path: String): PlaylistLink.SoundCloud? {
        val match = SOUNDCLOUD_SETS_REGEX.find(path) ?: return null
        return PlaylistLink.SoundCloud(user = match.groupValues[1], slug = match.groupValues[2])
    }

    private fun entityKind(pathSegment: String): LinkEntityKind? = when (pathSegment.lowercase()) {
        "playlist" -> LinkEntityKind.PLAYLIST
        "album" -> LinkEntityKind.ALBUM
        "track" -> LinkEntityKind.TRACK
        else -> null
    }

    /**
     * Finds the URL to classify inside [text]: an explicit `http(s)://` link if present (even
     * buried in share-sheet text with surrounding words), otherwise the whole trimmed input if it
     * already looks like a bare domain (missing only the scheme).
     */
    private fun extractUrl(text: String): String? {
        URL_IN_TEXT_REGEX.find(text)?.let { return it.value.trimEnd().let(::stripTrailingPunctuation) }
        val bareCandidate = stripTrailingPunctuation(text)
        return if (LOOKS_LIKE_BARE_DOMAIN.containsMatchIn(bareCandidate)) "https://$bareCandidate" else null
    }

    private fun stripTrailingPunctuation(text: String): String =
        text.replace(TRAILING_PUNCTUATION_REGEX, "")

    private val LOOKS_LIKE_BARE_DOMAIN = Regex(
        """(?i)^(open\.spotify\.com|music\.youtube\.com|youtube\.com|youtu\.be|music\.apple\.com|deezer\.com|dzr\.page\.link|music\.amazon\.\w+|tidal\.com|listen\.tidal\.com|soundcloud\.com)/"""
    )

    private fun safeParseUri(url: String): URI? = try {
        URI(url)
    } catch (_: Exception) {
        null
    }

    private fun parseQuery(rawQuery: String?): Map<String, String> {
        if (rawQuery.isNullOrEmpty()) return emptyMap()
        return rawQuery.split('&').mapNotNull { pair ->
            if (pair.isEmpty()) return@mapNotNull null
            val separatorIndex = pair.indexOf('=')
            val key: String
            val value: String
            if (separatorIndex < 0) {
                key = decodeComponent(pair)
                value = ""
            } else {
                key = decodeComponent(pair.substring(0, separatorIndex))
                value = decodeComponent(pair.substring(separatorIndex + 1))
            }
            key to value
        }.toMap()
    }

    private fun decodeComponent(value: String): String = try {
        URLDecoder.decode(value, "UTF-8")
    } catch (_: Exception) {
        value
    }
}
