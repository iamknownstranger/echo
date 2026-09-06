package echo.music.iad1tya.playlistlink

import com.music.innertube.YouTube
import com.music.innertube.models.SongItem
import java.text.Normalizer
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/**
 * Matches [ExternalTrack]s (from a foreign music service) to their best YouTube Music
 * equivalent by searching `:innertube` and scoring candidates on normalized title similarity,
 * artist overlap, and duration proximity — with a small bonus for official song results over
 * user-uploaded videos.
 */
object YouTubeMusicMatcher {

    enum class Confidence { CONFIDENT, LOW_CONFIDENCE, NO_MATCH }

    data class MatchResult(
        val track: ExternalTrack,
        val candidate: SongItem?,
        val score: Double,
        val confidence: Confidence,
    )

    /** Progress/result events emitted while [matchAll] works through a track list. */
    sealed interface MatchEvent {
        data class Progress(val resolved: Int, val total: Int) : MatchEvent
        data class Resolved(val index: Int, val result: MatchResult) : MatchEvent
        data class Completed(val results: List<MatchResult>) : MatchEvent
    }

    const val DEFAULT_MAX_CONCURRENCY = 5

    private const val CONFIDENT_THRESHOLD = 0.72
    private const val LOW_CONFIDENCE_THRESHOLD = 0.45
    private const val OFFICIAL_SONG_BONUS = 0.05

    private val TOPIC_SUFFIX_PATTERN = Regex("""(?i)\s*-\s*topic$""")
    private val BRACKETED_NOISE_PATTERN = Regex("""\([^)]*\)|\[[^\]]*]""")
    private val FEAT_SUFFIX_PATTERN = Regex("""(?i)\b(feat|ft)\.?\s+.*$""")
    private val NON_ALNUM_PATTERN = Regex("[^a-z0-9\\s]")
    private val MULTI_SPACE_PATTERN = Regex("\\s+")
    private val COMBINING_MARKS_PATTERN = Regex("\\p{Mn}+")

    /**
     * Matches every entry in [tracks] against YouTube Music search, running at most
     * [maxConcurrency] searches at once so a large playlist doesn't hammer InnerTube. Emits a
     * [MatchEvent.Resolved] + [MatchEvent.Progress] pair as each track finishes (completion
     * order, not input order) and a final [MatchEvent.Completed] with results restored to input
     * order. Cancelling the collecting coroutine cancels all in-flight searches. A single failed
     * search is recorded as [Confidence.NO_MATCH] rather than aborting the rest.
     */
    fun matchAll(
        tracks: List<ExternalTrack>,
        maxConcurrency: Int = DEFAULT_MAX_CONCURRENCY,
    ): Flow<MatchEvent> = channelFlow {
        if (tracks.isEmpty()) {
            send(MatchEvent.Completed(emptyList()))
            return@channelFlow
        }

        val semaphore = Semaphore(maxConcurrency)
        val resolvedCount = AtomicInteger(0)
        val results = arrayOfNulls<MatchResult>(tracks.size)

        coroutineScope {
            tracks.forEachIndexed { index, track ->
                launch {
                    semaphore.withPermit {
                        val result = try {
                            matchOne(track)
                        } catch (cancellation: CancellationException) {
                            throw cancellation
                        } catch (_: Throwable) {
                            MatchResult(track, null, 0.0, Confidence.NO_MATCH)
                        }
                        results[index] = result
                        send(MatchEvent.Resolved(index, result))
                        send(MatchEvent.Progress(resolvedCount.incrementAndGet(), tracks.size))
                    }
                }
            }
        }

        send(
            MatchEvent.Completed(
                results.mapIndexed { index, result ->
                    result ?: MatchResult(tracks[index], null, 0.0, Confidence.NO_MATCH)
                },
            ),
        )
    }

    private suspend fun matchOne(track: ExternalTrack): MatchResult {
        val searchResult = YouTube.search(buildSearchQuery(track), YouTube.SearchFilter.FILTER_SONG)
            .getOrElse { error ->
                if (error is CancellationException) throw error
                return MatchResult(track, null, 0.0, Confidence.NO_MATCH)
            }

        val candidates = searchResult.items.filterIsInstance<SongItem>().distinctBy { it.id }
        if (candidates.isEmpty()) return MatchResult(track, null, 0.0, Confidence.NO_MATCH)

        val normalizedTitle = normalizeForMatch(track.title)
        val titleBigrams = bigrams(normalizedTitle)
        val normalizedArtist = normalizeForMatch(track.artistDisplay)
        val artistBigrams = bigrams(normalizedArtist)

        var best: SongItem? = null
        var bestScore = -1.0
        for (candidate in candidates) {
            val score = scoreCandidate(
                normalizedTitle = normalizedTitle,
                titleBigrams = titleBigrams,
                normalizedArtist = normalizedArtist,
                artistBigrams = artistBigrams,
                sourceDurationMillis = track.durationMillis,
                candidate = candidate,
            )
            if (score > bestScore) {
                bestScore = score
                best = candidate
            }
        }

        val finalScore = bestScore.coerceIn(0.0, 1.0)
        return MatchResult(track, best, finalScore, classify(finalScore))
    }

    private fun scoreCandidate(
        normalizedTitle: String,
        titleBigrams: Set<String>,
        normalizedArtist: String,
        artistBigrams: Set<String>,
        sourceDurationMillis: Long?,
        candidate: SongItem,
    ): Double {
        val candidateTitle = normalizeForMatch(candidate.title)
        val candidateArtist = normalizeForMatch(candidate.artists.joinToString(" ") { it.name })

        val titleScore = bigramSimilarity(normalizedTitle, titleBigrams, candidateTitle, bigrams(candidateTitle))
        val artistScore = if (normalizedArtist.isBlank()) {
            0.5
        } else {
            bigramSimilarity(normalizedArtist, artistBigrams, candidateArtist, bigrams(candidateArtist))
        }
        val durationScore = durationScore(sourceDurationMillis, candidate.duration)

        var score = titleScore * 0.5 + artistScore * 0.3 + durationScore * 0.2
        if (!candidate.isVideoSong) score += OFFICIAL_SONG_BONUS
        return score
    }

    private fun durationScore(sourceMillis: Long?, candidateSeconds: Int?): Double {
        if (sourceMillis == null || sourceMillis <= 0 || candidateSeconds == null) return 0.5
        val diffSeconds = abs(sourceMillis / 1000 - candidateSeconds)
        return when {
            diffSeconds <= 2 -> 1.0
            diffSeconds <= 5 -> 0.85
            diffSeconds <= 10 -> 0.6
            diffSeconds <= 20 -> 0.3
            else -> 0.0
        }
    }

    internal fun classify(score: Double): Confidence = when {
        score >= CONFIDENT_THRESHOLD -> Confidence.CONFIDENT
        score >= LOW_CONFIDENCE_THRESHOLD -> Confidence.LOW_CONFIDENCE
        else -> Confidence.NO_MATCH
    }

    internal fun buildSearchQuery(track: ExternalTrack): String {
        val artist = track.artists.firstOrNull().orEmpty()
        return if (artist.isBlank()) track.title else "$artist ${track.title}"
    }

    /**
     * Aggressively normalizes a title/artist for comparison: lowercase, strip diacritics, strip
     * bracketed/parenthesized noise (`(Remastered 2011)`, `[Official Video]`), strip an
     * un-bracketed `feat./ft.` suffix, strip a trailing `- Topic` (YouTube's auto-generated
     * artist channel suffix), then collapse punctuation and whitespace.
     */
    internal fun normalizeForMatch(input: String): String {
        if (input.isBlank()) return ""
        var normalized = input.lowercase()
        normalized = stripDiacritics(normalized)
        normalized = TOPIC_SUFFIX_PATTERN.replace(normalized, "")
        normalized = BRACKETED_NOISE_PATTERN.replace(normalized, " ")
        normalized = FEAT_SUFFIX_PATTERN.replace(normalized, "")
        normalized = NON_ALNUM_PATTERN.replace(normalized, " ")
        normalized = MULTI_SPACE_PATTERN.replace(normalized, " ").trim()
        return normalized
    }

    internal fun stripDiacritics(input: String): String {
        val decomposed = Normalizer.normalize(input, Normalizer.Form.NFD)
        return COMBINING_MARKS_PATTERN.replace(decomposed, "")
    }

    internal fun bigrams(normalized: String): Set<String> =
        if (normalized.length < 2) emptySet() else normalized.windowed(2).toSet()

    /** Dice coefficient over bigram sets. */
    internal fun bigramSimilarity(a: String, bigramsA: Set<String>, b: String, bigramsB: Set<String>): Double {
        if (a == b) return 1.0
        if (bigramsA.isEmpty() || bigramsB.isEmpty()) return 0.0
        val intersection = bigramsA.count { it in bigramsB }
        return (2.0 * intersection) / (bigramsA.size + bigramsB.size)
    }
}
