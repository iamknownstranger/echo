package echo.music.iad1tya.playlistlink

import echo.music.iad1tya.utils.AppleMusicTokenProvider
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Fetches Apple Music playlists/albums/tracks from the real Apple Music Catalog API
 * (`amp-api.music.apple.com`), authenticated with the anonymous web-player JWT this app already
 * extracts for Apple Music album descriptions (see [AppleMusicTokenProvider]) — no Apple ID
 * required, since it's the same token `music.apple.com` hands to any anonymous visitor.
 */
internal object AppleMusicPlaylistFetcher {
    private const val BASE = "https://amp-api.music.apple.com/v1"
    private const val HOST = "https://amp-api.music.apple.com"

    suspend fun fetch(link: PlaylistLink.AppleMusic): ExternalPlaylist {
        val client = PlaylistLinkHttpClient.client
        val token = AppleMusicTokenProvider.getToken()
        val storefront = link.storefront.ifBlank { "us" }

        return when (link.kind) {
            LinkEntityKind.TRACK -> {
                val resource = fetchResource(client, token, "$BASE/catalog/$storefront/songs/${link.id}")
                val attrs = resourceAttributes(resource)
                ExternalPlaylist(
                    service = PlaylistService.APPLE_MUSIC,
                    kind = LinkEntityKind.TRACK,
                    title = attr(attrs, "name").orEmpty(),
                    subtitle = attr(attrs, "artistName"),
                    artworkUrl = artworkUrl(attrs),
                    tracks = listOf(trackFromAttributes(attrs)),
                )
            }

            LinkEntityKind.ALBUM -> {
                val resource = fetchResource(client, token, "$BASE/catalog/$storefront/albums/${link.id}")
                val attrs = resourceAttributes(resource)
                ExternalPlaylist(
                    service = PlaylistService.APPLE_MUSIC,
                    kind = LinkEntityKind.ALBUM,
                    title = attr(attrs, "name").orEmpty(),
                    subtitle = attr(attrs, "artistName"),
                    artworkUrl = artworkUrl(attrs),
                    tracks = paginateTracks(client, token, "$BASE/catalog/$storefront/albums/${link.id}/tracks"),
                )
            }

            LinkEntityKind.PLAYLIST -> {
                val resource = fetchResource(client, token, "$BASE/catalog/$storefront/playlists/${link.id}")
                val attrs = resourceAttributes(resource)
                ExternalPlaylist(
                    service = PlaylistService.APPLE_MUSIC,
                    kind = LinkEntityKind.PLAYLIST,
                    title = attr(attrs, "name").orEmpty(),
                    subtitle = attr(attrs, "curatorName"),
                    artworkUrl = artworkUrl(attrs),
                    tracks = paginateTracks(client, token, "$BASE/catalog/$storefront/playlists/${link.id}/tracks"),
                )
            }
        }
    }

    private suspend fun fetchResource(client: HttpClient, token: String, url: String): JsonObject {
        val response = client.get(url) {
            header("Authorization", "Bearer $token")
            header("Origin", "https://music.apple.com")
        }
        if (response.status == HttpStatusCode.NotFound) {
            throw PlaylistLinkServiceException(PlaylistService.APPLE_MUSIC, "That Apple Music link couldn't be found")
        }
        if (response.status != HttpStatusCode.OK) {
            throw PlaylistLinkServiceException(
                PlaylistService.APPLE_MUSIC,
                "Apple Music returned an error (HTTP ${response.status.value})",
            )
        }
        val root = response.body<JsonObject>()
        return root["data"]?.jsonArray?.firstOrNull()?.jsonObject
            ?: throw PlaylistLinkServiceException(PlaylistService.APPLE_MUSIC, "Apple Music returned no data for that link")
    }

    private suspend fun paginateTracks(client: HttpClient, token: String, firstUrl: String): List<ExternalTrack> {
        val tracks = mutableListOf<ExternalTrack>()
        var url: String? = firstUrl
        while (url != null) {
            val response = client.get(url) {
                header("Authorization", "Bearer $token")
                header("Origin", "https://music.apple.com")
            }
            if (response.status != HttpStatusCode.OK) break
            val root = response.body<JsonObject>()
            root["data"]?.jsonArray?.forEach { element ->
                tracks += trackFromAttributes(resourceAttributes(element.jsonObject))
            }
            val next = root["next"]?.jsonPrimitive?.contentOrNull
            url = next?.let { HOST + it }
        }
        return tracks
    }

    private fun resourceAttributes(resource: JsonObject): JsonObject? = resource["attributes"]?.jsonObject

    private fun trackFromAttributes(attrs: JsonObject?): ExternalTrack {
        val durationMillis = attrs?.get("durationInMillis")?.jsonPrimitive?.contentOrNull?.toLongOrNull()
        return ExternalTrack(
            title = attr(attrs, "name").orEmpty(),
            artists = listOfNotNull(attr(attrs, "artistName")),
            album = attr(attrs, "albumName"),
            durationMillis = durationMillis,
            isrc = attr(attrs, "isrc"),
            artworkUrl = artworkUrl(attrs),
        )
    }

    private fun artworkUrl(attrs: JsonObject?): String? {
        val template = attr(attrs?.get("artwork")?.jsonObject, "url") ?: return null
        return template.replace("{w}", "300").replace("{h}", "300")
    }

    private fun attr(obj: JsonObject?, key: String): String? = obj?.get(key)?.jsonPrimitive?.contentOrNull
}
