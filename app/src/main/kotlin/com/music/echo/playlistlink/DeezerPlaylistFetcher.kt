package echo.music.iad1tya.playlistlink

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Fetches Deezer playlists/albums/tracks from Deezer's own public JSON API
 * (`api.deezer.com`) — no authentication required.
 */
internal object DeezerPlaylistFetcher {
    private const val BASE = "https://api.deezer.com"

    suspend fun fetch(link: PlaylistLink.Deezer): ExternalPlaylist {
        val client = PlaylistLinkHttpClient.client
        val resourcePath = when (link.kind) {
            LinkEntityKind.PLAYLIST -> "playlist/${link.id}"
            LinkEntityKind.ALBUM -> "album/${link.id}"
            LinkEntityKind.TRACK -> "track/${link.id}"
        }

        val response = client.get("$BASE/$resourcePath")
        if (response.status != HttpStatusCode.OK) {
            throw PlaylistLinkServiceException(
                PlaylistService.DEEZER,
                "Deezer returned an error (HTTP ${response.status.value})",
            )
        }
        val root = response.body<JsonObject>()
        if (root.containsKey("error")) {
            throw PlaylistLinkServiceException(PlaylistService.DEEZER, "Deezer couldn't find that link")
        }

        if (link.kind == LinkEntityKind.TRACK) {
            return ExternalPlaylist(
                service = PlaylistService.DEEZER,
                kind = LinkEntityKind.TRACK,
                title = stringOf(root, "title").orEmpty(),
                subtitle = stringOf(root["artist"]?.jsonObject, "name"),
                artworkUrl = albumArtwork(root),
                tracks = listOf(trackFromJson(root)),
            )
        }

        val subtitle = when (link.kind) {
            LinkEntityKind.ALBUM -> stringOf(root["artist"]?.jsonObject, "name")
            else -> stringOf(root["creator"]?.jsonObject, "name")
        }
        val artworkUrl = stringOf(root, "cover_medium") ?: stringOf(root, "picture_medium")

        return ExternalPlaylist(
            service = PlaylistService.DEEZER,
            kind = link.kind,
            title = stringOf(root, "title").orEmpty(),
            subtitle = subtitle,
            artworkUrl = artworkUrl,
            tracks = collectTracks(client, root),
        )
    }

    private suspend fun collectTracks(client: HttpClient, root: JsonObject): List<ExternalTrack> {
        val tracks = mutableListOf<ExternalTrack>()
        val tracksObj = root["tracks"]?.jsonObject
        tracksObj?.get("data")?.jsonArray?.forEach { tracks += trackFromJson(it.jsonObject) }

        var nextUrl = stringOf(tracksObj, "next")
        while (!nextUrl.isNullOrBlank()) {
            val page = client.get(nextUrl).body<JsonObject>()
            page["data"]?.jsonArray?.forEach { tracks += trackFromJson(it.jsonObject) }
            nextUrl = stringOf(page, "next")
        }
        return tracks
    }

    private fun trackFromJson(obj: JsonObject): ExternalTrack {
        val title = stringOf(obj, "title") ?: stringOf(obj, "title_short").orEmpty()
        val artistName = stringOf(obj["artist"]?.jsonObject, "name")
        val albumTitle = stringOf(obj["album"]?.jsonObject, "title")
        val durationSeconds = obj["duration"]?.jsonPrimitive?.contentOrNull?.toLongOrNull()
        return ExternalTrack(
            title = title,
            artists = listOfNotNull(artistName),
            album = albumTitle,
            durationMillis = durationSeconds?.times(1000),
            isrc = stringOf(obj, "isrc"),
            artworkUrl = albumArtwork(obj),
        )
    }

    private fun albumArtwork(obj: JsonObject): String? =
        stringOf(obj["album"]?.jsonObject, "cover_medium") ?: stringOf(obj, "cover_medium")

    private fun stringOf(obj: JsonObject?, key: String): String? =
        obj?.get(key)?.jsonPrimitive?.contentOrNull
}
