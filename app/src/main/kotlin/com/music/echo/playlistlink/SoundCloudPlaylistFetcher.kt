package echo.music.iad1tya.playlistlink

import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Fetches SoundCloud "sets" (playlists) by parsing the `window.__sc_hydration` JSON blob that
 * SoundCloud's own server-rendered playlist page embeds — SoundCloud has no public playlist API
 * usable without a registered `client_id`, so this is the public-webpage-JSON tier described for
 * services without an open API.
 */
internal object SoundCloudPlaylistFetcher {
    private const val DESKTOP_USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

    suspend fun fetch(link: PlaylistLink.SoundCloud): ExternalPlaylist {
        val client = PlaylistLinkHttpClient.client
        val url = "https://soundcloud.com/${link.user}/sets/${link.slug}"
        val response = client.get(url) {
            header(HttpHeaders.UserAgent, DESKTOP_USER_AGENT)
        }
        if (response.status != HttpStatusCode.OK) {
            throw PlaylistLinkServiceException(
                PlaylistService.SOUNDCLOUD,
                "SoundCloud returned an error (HTTP ${response.status.value})",
            )
        }

        val html = response.bodyAsText()
        val hydrationJson = extractHydrationJson(html)
            ?: throw PlaylistLinkServiceException(PlaylistService.SOUNDCLOUD, "Couldn't read that SoundCloud playlist")
        val hydration = PlaylistLinkHttpClient.json.parseToJsonElement(hydrationJson).jsonArray
        val data = hydration
            .map { it.jsonObject }
            .firstOrNull { it["hydratable"]?.jsonPrimitive?.contentOrNull == "playlist" }
            ?.get("data")
            ?.jsonObject
            ?: throw PlaylistLinkServiceException(PlaylistService.SOUNDCLOUD, "That SoundCloud playlist couldn't be found")

        val tracks = data["tracks"]?.jsonArray?.map { trackFromJson(it.jsonObject) }.orEmpty()
        return ExternalPlaylist(
            service = PlaylistService.SOUNDCLOUD,
            kind = LinkEntityKind.PLAYLIST,
            title = stringOf(data, "title").orEmpty(),
            subtitle = stringOf(data["user"]?.jsonObject, "username"),
            artworkUrl = stringOf(data, "artwork_url"),
            tracks = tracks,
        )
    }

    private fun trackFromJson(obj: JsonObject): ExternalTrack {
        val durationMillis = obj["full_duration"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
            ?: obj["duration"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
        return ExternalTrack(
            title = stringOf(obj, "title").orEmpty(),
            artists = listOfNotNull(stringOf(obj["user"]?.jsonObject, "username")),
            album = null,
            durationMillis = durationMillis,
            isrc = null,
            artworkUrl = stringOf(obj, "artwork_url"),
        )
    }

    private fun stringOf(obj: JsonObject?, key: String): String? = obj?.get(key)?.jsonPrimitive?.contentOrNull

    /**
     * Finds `window.__sc_hydration = [ ... ]` in [html] and returns the bracket-balanced JSON
     * array text, tracking string literals so a `]`/`[` inside a quoted value never miscounts.
     * A plain shortest-match regex would truncate on the first `];` it happens to see, which is
     * far too common inside the payload itself.
     */
    private fun extractHydrationJson(html: String): String? {
        val markerIndex = html.indexOf("window.__sc_hydration")
        if (markerIndex < 0) return null
        val arrayStart = html.indexOf('[', markerIndex)
        if (arrayStart < 0) return null

        var depth = 0
        var inString = false
        var escapeNext = false
        for (i in arrayStart until html.length) {
            val c = html[i]
            if (inString) {
                when {
                    escapeNext -> escapeNext = false
                    c == '\\' -> escapeNext = true
                    c == '"' -> inString = false
                }
                continue
            }
            when (c) {
                '"' -> inString = true
                '[' -> depth++
                ']' -> {
                    depth--
                    if (depth == 0) return html.substring(arrayStart, i + 1)
                }
            }
        }
        return null
    }
}
