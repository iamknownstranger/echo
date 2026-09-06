package echo.music.iad1tya.playlistlink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaylistLinkParserTest {

    // ---- Spotify ----

    @Test
    fun `spotify playlist url`() {
        val link = PlaylistLinkParser.parse("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc123")
        assertEquals(PlaylistLink.Spotify("37i9dQZF1DXcBWIGoYBM5M", LinkEntityKind.PLAYLIST), link)
    }

    @Test
    fun `spotify album url with locale segment`() {
        val link = PlaylistLinkParser.parse("https://open.spotify.com/intl-de/album/4LH4d3cOWNNsVw41Gqt2kv")
        assertEquals(PlaylistLink.Spotify("4LH4d3cOWNNsVw41Gqt2kv", LinkEntityKind.ALBUM), link)
    }

    @Test
    fun `spotify track uri`() {
        val link = PlaylistLinkParser.parse("spotify:track:6rqhFgbbKwnb9MLmUQDhG6")
        assertEquals(PlaylistLink.Spotify("6rqhFgbbKwnb9MLmUQDhG6", LinkEntityKind.TRACK), link)
    }

    @Test
    fun `spotify uri is case insensitive`() {
        val link = PlaylistLinkParser.parse("SPOTIFY:PLAYLIST:37i9dQZF1DXcBWIGoYBM5M")
        assertEquals(PlaylistLink.Spotify("37i9dQZF1DXcBWIGoYBM5M", LinkEntityKind.PLAYLIST), link)
    }

    @Test
    fun `spotify link buried in share-sheet text`() {
        val link = PlaylistLinkParser.parse(
            "Check out this playlist!! https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=xyz you'll love it",
        )
        assertEquals(PlaylistLink.Spotify("37i9dQZF1DXcBWIGoYBM5M", LinkEntityKind.PLAYLIST), link)
    }

    @Test
    fun `spotify link with trailing punctuation`() {
        val link = PlaylistLinkParser.parse("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M.")
        assertEquals(PlaylistLink.Spotify("37i9dQZF1DXcBWIGoYBM5M", LinkEntityKind.PLAYLIST), link)
    }

    @Test
    fun `whitespace padded input is trimmed`() {
        val link = PlaylistLinkParser.parse("   https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M   ")
        assertEquals(PlaylistLink.Spotify("37i9dQZF1DXcBWIGoYBM5M", LinkEntityKind.PLAYLIST), link)
    }

    // ---- YouTube / YouTube Music ----

    @Test
    fun `youtube music playlist url`() {
        val link = PlaylistLinkParser.parse("https://music.youtube.com/playlist?list=PLtest123")
        assertEquals(PlaylistLink.YouTubeMusic("PLtest123", LinkEntityKind.PLAYLIST), link)
    }

    @Test
    fun `youtube watch url with list prefers playlist`() {
        val link = PlaylistLinkParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLxyz")
        assertEquals(PlaylistLink.YouTubeMusic("PLxyz", LinkEntityKind.PLAYLIST), link)
    }

    @Test
    fun `youtube watch url without list is a track`() {
        val link = PlaylistLinkParser.parse("https://youtube.com/watch?v=dQw4w9WgXcQ")
        assertEquals(PlaylistLink.YouTubeMusic("dQw4w9WgXcQ", LinkEntityKind.TRACK), link)
    }

    @Test
    fun `youtu-be short link is a track`() {
        val link = PlaylistLinkParser.parse("https://youtu.be/dQw4w9WgXcQ")
        assertEquals(PlaylistLink.YouTubeMusic("dQw4w9WgXcQ", LinkEntityKind.TRACK), link)
    }

    @Test
    fun `youtu-be short link with list prefers playlist`() {
        val link = PlaylistLinkParser.parse("https://youtu.be/dQw4w9WgXcQ?list=PLabc")
        assertEquals(PlaylistLink.YouTubeMusic("PLabc", LinkEntityKind.PLAYLIST), link)
    }

    // ---- Apple Music ----

    @Test
    fun `apple music playlist url`() {
        val link = PlaylistLinkParser.parse(
            "https://music.apple.com/us/playlist/todays-hits/pl.f4d106fed2bd41149aaacabb233eb5eb",
        )
        assertEquals(
            PlaylistLink.AppleMusic("pl.f4d106fed2bd41149aaacabb233eb5eb", LinkEntityKind.PLAYLIST, "us"),
            link,
        )
    }

    @Test
    fun `apple music album url`() {
        val link = PlaylistLinkParser.parse("https://music.apple.com/gb/album/discovery/1489294302")
        assertEquals(PlaylistLink.AppleMusic("1489294302", LinkEntityKind.ALBUM, "gb"), link)
    }

    @Test
    fun `apple music song url`() {
        val link = PlaylistLinkParser.parse("https://music.apple.com/us/song/stupid-song/1889992115")
        assertEquals(PlaylistLink.AppleMusic("1889992115", LinkEntityKind.TRACK, "us"), link)
    }

    @Test
    fun `apple music track deep-link inside album url`() {
        val link = PlaylistLinkParser.parse("https://music.apple.com/us/album/some-album/123456?i=987654")
        assertEquals(PlaylistLink.AppleMusic("987654", LinkEntityKind.TRACK, "us"), link)
    }

    // ---- Deezer ----

    @Test
    fun `deezer playlist url with language segment`() {
        val link = PlaylistLinkParser.parse("https://www.deezer.com/en/playlist/1996736122")
        assertEquals(PlaylistLink.Deezer("1996736122", LinkEntityKind.PLAYLIST), link)
    }

    @Test
    fun `deezer album url without language segment`() {
        val link = PlaylistLinkParser.parse("https://deezer.com/album/302127")
        assertEquals(PlaylistLink.Deezer("302127", LinkEntityKind.ALBUM), link)
    }

    @Test
    fun `deezer track url`() {
        val link = PlaylistLinkParser.parse("https://www.deezer.com/track/73707710")
        assertEquals(PlaylistLink.Deezer("73707710", LinkEntityKind.TRACK), link)
    }

    @Test
    fun `deezer short link is unresolved`() {
        val link = PlaylistLinkParser.parse("https://dzr.page.link/abcXYZ")
        assertEquals(PlaylistLink.ShortLink("https://dzr.page.link/abcXYZ", PlaylistService.DEEZER), link)
    }

    // ---- Amazon Music ----

    @Test
    fun `amazon music playlists url`() {
        val link = PlaylistLinkParser.parse("https://music.amazon.com/playlists/abc123XYZ")
        assertEquals(PlaylistLink.AmazonMusic("abc123XYZ", LinkEntityKind.PLAYLIST), link)
    }

    @Test
    fun `amazon music user-playlists url`() {
        val link = PlaylistLinkParser.parse(
            "https://music.amazon.co.uk/user-playlists/2270cba070934fef86f5473ea983f542gafn",
        )
        assertEquals(
            PlaylistLink.AmazonMusic("2270cba070934fef86f5473ea983f542gafn", LinkEntityKind.PLAYLIST),
            link,
        )
    }

    @Test
    fun `amazon music albums url`() {
        val link = PlaylistLinkParser.parse("https://music.amazon.de/albums/B00XYZ123")
        assertEquals(PlaylistLink.AmazonMusic("B00XYZ123", LinkEntityKind.ALBUM), link)
    }

    // ---- Tidal ----

    @Test
    fun `tidal browse playlist url`() {
        val link = PlaylistLinkParser.parse("https://tidal.com/browse/playlist/8829f196-4c58-411e-99d1-a89e3a40290b")
        assertEquals(PlaylistLink.Tidal("8829f196-4c58-411e-99d1-a89e3a40290b", LinkEntityKind.PLAYLIST), link)
    }

    @Test
    fun `tidal short-form album url`() {
        val link = PlaylistLinkParser.parse("https://tidal.com/album/96208425")
        assertEquals(PlaylistLink.Tidal("96208425", LinkEntityKind.ALBUM), link)
    }

    @Test
    fun `tidal track url`() {
        val link = PlaylistLinkParser.parse("https://tidal.com/track/14989955")
        assertEquals(PlaylistLink.Tidal("14989955", LinkEntityKind.TRACK), link)
    }

    // ---- SoundCloud ----

    @Test
    fun `soundcloud sets url`() {
        val link = PlaylistLinkParser.parse("https://soundcloud.com/caterkarlos/sets/sets")
        assertEquals(PlaylistLink.SoundCloud("caterkarlos", "sets"), link)
    }

    @Test
    fun `soundcloud non-sets url is unsupported`() {
        val link = PlaylistLinkParser.parse("https://soundcloud.com/someartist/some-track")
        assertNull(link)
    }

    // ---- Junk / unsupported input ----

    @Test
    fun `blank input returns null`() {
        assertNull(PlaylistLinkParser.parse(""))
        assertNull(PlaylistLinkParser.parse("   "))
    }

    @Test
    fun `plain text with no url returns null`() {
        assertNull(PlaylistLinkParser.parse("hello world, this is just a message"))
    }

    @Test
    fun `unrelated url returns null`() {
        assertNull(PlaylistLinkParser.parse("https://example.com/foo/bar"))
    }

    @Test
    fun `malformed url does not throw`() {
        assertNull(PlaylistLinkParser.parse("https://[not-a-valid-host"))
    }
}
