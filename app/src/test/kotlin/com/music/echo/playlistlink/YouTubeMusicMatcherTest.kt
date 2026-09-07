package echo.music.iad1tya.playlistlink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class YouTubeMusicMatcherTest {

    @Test
    fun `normalizeForMatch strips parenthesized remaster noise`() {
        assertEquals("song title", YouTubeMusicMatcher.normalizeForMatch("Song Title (Remastered 2011)"))
    }

    @Test
    fun `normalizeForMatch strips bracketed official video noise`() {
        assertEquals("song title", YouTubeMusicMatcher.normalizeForMatch("Song Title [Official Video]"))
    }

    @Test
    fun `normalizeForMatch strips bracketed feat noise`() {
        assertEquals("song title", YouTubeMusicMatcher.normalizeForMatch("Song Title (feat. Someone Else)"))
    }

    @Test
    fun `normalizeForMatch strips un-bracketed feat suffix`() {
        assertEquals("song title", YouTubeMusicMatcher.normalizeForMatch("Song Title feat. Someone Else"))
        assertEquals("song title", YouTubeMusicMatcher.normalizeForMatch("Song Title ft. Someone Else"))
    }

    @Test
    fun `normalizeForMatch strips trailing topic suffix`() {
        assertEquals("some artist", YouTubeMusicMatcher.normalizeForMatch("Some Artist - Topic"))
    }

    @Test
    fun `normalizeForMatch strips diacritics`() {
        assertEquals("cafe munchen", YouTubeMusicMatcher.normalizeForMatch("Café München"))
    }

    @Test
    fun `normalizeForMatch collapses punctuation and whitespace`() {
        assertEquals("song title", YouTubeMusicMatcher.normalizeForMatch("  Song,  Title!!  "))
    }

    @Test
    fun `normalizeForMatch on blank input returns empty string`() {
        assertEquals("", YouTubeMusicMatcher.normalizeForMatch(""))
        assertEquals("", YouTubeMusicMatcher.normalizeForMatch("   "))
    }

    @Test
    fun `bigrams of short strings are empty`() {
        assertTrue(YouTubeMusicMatcher.bigrams("").isEmpty())
        assertTrue(YouTubeMusicMatcher.bigrams("a").isEmpty())
    }

    @Test
    fun `bigrams of a normal string`() {
        assertEquals(setOf("ab", "bc"), YouTubeMusicMatcher.bigrams("abc"))
    }

    @Test
    fun `bigramSimilarity of identical strings is 1`() {
        val bigrams = YouTubeMusicMatcher.bigrams("hello world")
        assertEquals(1.0, YouTubeMusicMatcher.bigramSimilarity("hello world", bigrams, "hello world", bigrams), 0.0001)
    }

    @Test
    fun `bigramSimilarity of completely different strings is 0`() {
        val a = "hello"
        val b = "zzzzz"
        val score = YouTubeMusicMatcher.bigramSimilarity(a, YouTubeMusicMatcher.bigrams(a), b, YouTubeMusicMatcher.bigrams(b))
        assertEquals(0.0, score, 0.0001)
    }

    @Test
    fun `bigramSimilarity of near-identical strings is high but not 1`() {
        val a = "shape of you"
        val b = "shape of you "
        val score = YouTubeMusicMatcher.bigramSimilarity(a, YouTubeMusicMatcher.bigrams(a), b, YouTubeMusicMatcher.bigrams(b))
        assertTrue("expected high similarity but got $score", score > 0.9)
    }

    @Test
    fun `classify buckets scores into confidence levels`() {
        assertEquals(YouTubeMusicMatcher.Confidence.CONFIDENT, YouTubeMusicMatcher.classify(0.9))
        assertEquals(YouTubeMusicMatcher.Confidence.LOW_CONFIDENCE, YouTubeMusicMatcher.classify(0.5))
        assertEquals(YouTubeMusicMatcher.Confidence.NO_MATCH, YouTubeMusicMatcher.classify(0.1))
    }

    @Test
    fun `buildSearchQuery combines primary artist and title`() {
        val track = ExternalTrack(title = "Song", artists = listOf("Artist", "Other Artist"))
        assertEquals("Artist Song", YouTubeMusicMatcher.buildSearchQuery(track))
    }

    @Test
    fun `buildSearchQuery falls back to title only when no artist`() {
        val track = ExternalTrack(title = "Song", artists = emptyList())
        assertEquals("Song", YouTubeMusicMatcher.buildSearchQuery(track))
    }

    @Test
    fun `stripDiacritics handles a variety of accented characters`() {
        assertEquals("cafe", YouTubeMusicMatcher.stripDiacritics("café"))
        assertEquals("Beyonce", YouTubeMusicMatcher.stripDiacritics("Beyoncé"))
        assertEquals("MUNCHEN", YouTubeMusicMatcher.stripDiacritics("MÜNCHEN"))
    }
}
