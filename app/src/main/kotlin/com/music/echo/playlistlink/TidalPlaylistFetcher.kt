package echo.music.iad1tya.playlistlink

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.http.HttpStatusCode
import java.util.Locale
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Fetches Tidal playlists/albums/tracks from `api.tidal.com`'s public web-embed API, using the
 * same public embed token this codebase already relies on for Tidal canvas artwork lookups (see
 * `TidalCanvasProvider` in `:canvas`) — no user login required.
 */
internal object TidalPlaylistFetcher {
    private const val BASE = "https://api.tidal.com/v1"
    private const val TIDAL_TOKEN = "vNVdglQOjFJJGG2U"

    suspend fun fetch(link: PlaylistLink.Tidal): ExternalPlaylist {
        val client = PlaylistLinkHttpClient.client
        val countryCode = Locale.getDefault().country.takeIf { it.length == 2 } ?: "US"

        return when (link.kind) {
            LinkEntityKind.TRACK -> {
                val track = getJson(client, "$BASE/tracks/${link.id}", countryCode)
                ExternalPlaylist(
                    service = PlaylistService.TIDAL,
                    kind = LinkEntityKind.TRACK,
                    title = stringOf(track, "title").orEmpty(),
                    subtitle = artistName(track),
                    artworkUrl = coverUrl(track),
                    tracks = listOf(trackFromJson(track)),
                )
            }

            LinkEntityKind.PLAYLIST -> {
                val meta = getJson(client, "$BASE/playlists/${link.id}", countryCode)
                val tracks = collectItems(client, "$BASE/playlists/${link.id}/items", countryCode, unwrapItem = true)
                ExternalPlaylist(
                    service = PlaylistService.TIDAL,
                    kind = LinkEntityKind.PLAYLIST,
                    title = stringOf(meta, "title").orEmpty(),
                    subtitle = stringOf(meta["creator"]?.jsonObject, "name"),
                    artworkUrl = coverUrl(meta),
                    tracks = tracks,
                )
            }

            LinkEntityKind.ALBUM -> {
                val meta = getJson(client, "$BASE/albums/${link.id}", countryCode)
                val tracks = collectItems(client, "$BASE/albums/${link.id}/tracks", countryCode, unwrapItem = false)
                ExternalPlaylist(
                    service = PlaylistService.TIDAL,
                    kind = LinkEntityKind.ALBUM,
                    title = stringOf(meta, "title").orEmpty(),
                    subtitle = artistName(meta),
                    artworkUrl = coverUrl(meta),
                    tracks = tracks,
                )
            }
        }
    }

    private suspend fun getJson(client: HttpClient, url: String, countryCode: String): JsonObject {
        val response = client.get(url) {
            header("X-Tidal-Token", TIDAL_TOKEN)
            parameter("countryCode", countryCode)
        }
        if (response.status == HttpStatusCode.NotFound) {
            throw PlaylistLinkServiceException(PlaylistService.TIDAL, "That Tidal link couldn't be found")
        }
        if (response.status != HttpStatusCode.OK) {
            throw PlaylistLinkServiceException(
                PlaylistService.TIDAL,
                "Tidal returned an error (HTTP ${response.status.value})",
            )
        }
        return response.body<JsonObject>()
    }

    private suspend fun collectItems(
        client: HttpClient,
        url: String,
        countryCode: String,
        unwrapItem: Boolean,
    ): List<ExternalTrack> {
        val tracks = mutableListOf<ExternalTrack>()
        var offset = 0
        val limit = 100
        while (true) {
            val response = client.get(url) {
                header("X-Tidal-Token", TIDAL_TOKEN)
                parameter("countryCode", countryCode)
                parameter("limit", limit.toString())
                parameter("offset", offset.toString())
            }
            if (response.status != HttpStatusCode.OK) break
            val page = response.body<JsonObject>()
            val items = page["items"]?.jsonArray ?: break
            if (items.isEmpty()) break

            items.forEach { element ->
                val obj = element.jsonObject
                val trackObj = if (unwrapItem) obj["item"]?.jsonObject ?: obj else obj
                tracks += trackFromJson(trackObj)
            }

            val total = page["totalNumberOfItems"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: tracks.size
            offset += items.size
            if (offset >= total || items.size < limit) break
        }
        return tracks
    }

    private fun trackFromJson(obj: JsonObject): ExternalTrack {
        val artistNames = obj["artists"]?.jsonArray
            ?.mapNotNull { stringOf(it.jsonObject, "name") }
            ?.takeIf { it.isNotEmpty() }
            ?: listOfNotNull(artistName(obj))
        val durationSeconds = obj["duration"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
        return ExternalTrack(
            title = stringOf(obj, "title").orEmpty(),
            artists = artistNames,
            album = stringOf(obj["album"]?.jsonObject, "title"),
            durationMillis = durationSeconds?.times(1000),
            isrc = stringOf(obj, "isrc"),
            artworkUrl = coverUrl(obj),
        )
    }

    private fun artistName(obj: JsonObject): String? = stringOf(obj["artist"]?.jsonObject, "name")

    private fun coverUrl(obj: JsonObject): String? {
        val coverId = stringOf(obj["album"]?.jsonObject, "cover") ?: stringOf(obj, "cover") ?: return null
        val path = coverId.replace("-", "/")
        return "https://resources.tidal.com/images/$path/320x320.jpg"
    }

    private fun stringOf(obj: JsonObject?, key: String): String? = obj?.get(key)?.jsonPrimitive?.contentOrNull
}
