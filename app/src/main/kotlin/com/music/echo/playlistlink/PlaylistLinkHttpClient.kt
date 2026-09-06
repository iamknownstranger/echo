package echo.music.iad1tya.playlistlink

import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json

/**
 * Shared Ktor client for the credential-free playlist-link fetchers (Deezer, Tidal, SoundCloud,
 * Apple Music web scraping). Mirrors the lazy-singleton-client convention already used throughout
 * the app (see [echo.music.iad1tya.spotify.Spotify] and the Tidal canvas provider) rather than
 * wiring a new Hilt-provided client.
 */
internal object PlaylistLinkHttpClient {
    val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        explicitNulls = false
        coerceInputValues = true
    }

    val client by lazy {
        HttpClient(OkHttp) {
            expectSuccess = false
            install(ContentNegotiation) { json(json) }
            install(HttpTimeout) {
                connectTimeoutMillis = 15_000
                requestTimeoutMillis = 25_000
                socketTimeoutMillis = 25_000
            }
        }
    }
}
