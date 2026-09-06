@file:OptIn(ExperimentalMaterial3Api::class)

package echo.music.iad1tya.ui.screens

import android.content.Context
import android.content.ClipboardManager
import android.widget.Toast
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavController
import coil3.compose.AsyncImage
import echo.music.iad1tya.LocalPlayerAwareWindowInsets
import echo.music.iad1tya.LocalPlayerConnection
import echo.music.iad1tya.R
import echo.music.iad1tya.extensions.toMediaItem
import echo.music.iad1tya.playback.queues.ListQueue
import echo.music.iad1tya.playlistlink.PlaylistService
import echo.music.iad1tya.playlistlink.YouTubeMusicMatcher
import echo.music.iad1tya.ui.component.DefaultDialog
import echo.music.iad1tya.ui.component.IconButton
import echo.music.iad1tya.ui.component.TextFieldDialog
import echo.music.iad1tya.ui.utils.backToMain
import echo.music.iad1tya.viewmodels.PlaylistLinkReviewRow
import echo.music.iad1tya.viewmodels.PlaylistLinkUiState
import echo.music.iad1tya.viewmodels.PlaylistLinkViewModel

/**
 * "Universal playlist link" — paste any Spotify / Apple Music / Deezer / Tidal / Amazon Music /
 * SoundCloud / YouTube Music playlist, album, or track link and find its songs on YouTube Music,
 * then play, save, or download them. Reached from Library's Import menu, or an incoming share.
 */
@Composable
fun PlaylistLinkScreen(
    navController: NavController,
    initialLink: String? = null,
    viewModel: PlaylistLinkViewModel = hiltViewModel(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val playerConnection = LocalPlayerConnection.current
    val context = LocalContext.current

    var showSaveDialog by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(initialLink) {
        if (!initialLink.isNullOrBlank()) {
            viewModel.onInputTextChange(initialLink)
            viewModel.resolveAndMatch()
        }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize().nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.playlist_link_title)) },
                navigationIcon = {
                    IconButton(
                        onClick = navController::navigateUp,
                        onLongClick = navController::backToMain,
                    ) {
                        Icon(painterResource(R.drawable.arrow_back), null)
                    }
                },
                scrollBehavior = scrollBehavior,
            )
        },
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(
                    LocalPlayerAwareWindowInsets.current.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom),
                ),
            contentPadding = PaddingValues(
                top = innerPadding.calculateTopPadding() + 16.dp,
                bottom = innerPadding.calculateBottomPadding() + 32.dp,
                start = 16.dp,
                end = 16.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                PlaylistLinkInputCard(
                    state = state,
                    onInputChange = viewModel::onInputTextChange,
                    onResolve = viewModel::resolveAndMatch,
                )
            }

            if (state.isBusy) {
                item { PlaylistLinkProgressCard(state = state, onCancel = viewModel::cancelResolve) }
            }

            if (state.resolvedTitle != null && !state.isResolving) {
                item {
                    PlaylistLinkResultHeader(
                        state = state,
                        onReset = viewModel::reset,
                    )
                }
            }

            if (state.hasResults) {
                items(state.results, key = { it.index }) { row ->
                    PlaylistLinkRowCard(row = row, onToggle = { viewModel.toggleRowIncluded(row.index) })
                }
            }

            if (state.hasResults && !state.isMatching) {
                item {
                    PlaylistLinkActionBar(
                        includedCount = state.includedCount,
                        onPlayNow = {
                            val items = viewModel.includedMediaMetadata().map { it.toMediaItem() }
                            if (items.isNotEmpty()) {
                                playerConnection?.playQueue(ListQueue(title = state.resolvedTitle, items = items))
                            }
                        },
                        onSave = { showSaveDialog = true },
                        onDownload = viewModel::downloadIncluded,
                    )
                }
            }
        }
    }

    state.resolveError?.let { error ->
        DefaultDialog(
            onDismiss = viewModel::dismissError,
            title = { Text(stringResource(R.string.playlist_link_error_title)) },
            buttons = {
                TextButton(onClick = viewModel::dismissError) {
                    Text(stringResource(android.R.string.ok))
                }
            },
        ) {
            Text(error, style = MaterialTheme.typography.bodyMedium)
        }
    }

    state.actionMessage?.let { message ->
        LaunchedEffect(message) {
            Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
            viewModel.dismissActionMessage()
        }
    }

    if (showSaveDialog) {
        TextFieldDialog(
            icon = { Icon(painterResource(R.drawable.playlist_add), contentDescription = null) },
            title = { Text(stringResource(R.string.playlist_link_save_playlist_title)) },
            initialTextFieldValue = TextFieldValue(state.resolvedTitle.orEmpty()),
            autoFocus = true,
            onDismiss = { showSaveDialog = false },
            onDone = { name ->
                showSaveDialog = false
                viewModel.saveAsPlaylist(name)
            },
        )
    }
}

@Composable
private fun PlaylistLinkInputCard(
    state: PlaylistLinkUiState,
    onInputChange: (String) -> Unit,
    onResolve: () -> Unit,
) {
    val context = LocalContext.current

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = stringResource(R.string.playlist_link_desc),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            OutlinedTextField(
                value = state.inputText,
                onValueChange = onInputChange,
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                shape = CircleShape,
                placeholder = { Text(stringResource(R.string.playlist_link_hint)) },
                trailingIcon = {
                    androidx.compose.material3.IconButton(
                        onClick = {
                            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                            val pasted = clipboard?.primaryClip
                                ?.takeIf { it.itemCount > 0 }
                                ?.getItemAt(0)
                                ?.coerceToText(context)
                                ?.toString()
                            if (!pasted.isNullOrBlank()) onInputChange(pasted)
                        },
                    ) {
                        Icon(
                            imageVector = Icons.Filled.ContentPaste,
                            contentDescription = stringResource(R.string.playlist_link_paste),
                        )
                    }
                },
            )

            AnimatedVisibility(visible = state.detectedService != null) {
                state.detectedService?.let { service ->
                    Text(
                        text = stringResource(R.string.playlist_link_detected, serviceDisplayName(service)),
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }

            Button(
                onClick = onResolve,
                modifier = Modifier.fillMaxWidth(),
                enabled = state.inputText.isNotBlank() && !state.isBusy,
                shape = CircleShape,
            ) {
                Text(stringResource(R.string.playlist_link_resolve))
            }
        }
    }
}

@Composable
private fun PlaylistLinkProgressCard(state: PlaylistLinkUiState, onCancel: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.3f)),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            val label = if (state.isMatching) {
                stringResource(R.string.playlist_link_matching_progress, state.matchProgress, state.matchTotal)
            } else {
                state.detectedService?.let { stringResource(R.string.playlist_link_resolving, serviceDisplayName(it)) }
                    ?: stringResource(R.string.playlist_link_resolving, "")
            }
            Text(label, style = MaterialTheme.typography.bodyMedium)

            if (state.isMatching && state.matchTotal > 0) {
                LinearProgressIndicator(
                    progress = { state.matchProgress.toFloat() / state.matchTotal.toFloat() },
                    modifier = Modifier.fillMaxWidth().clip(CircleShape),
                )
            } else {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth().clip(CircleShape))
            }

            TextButton(onClick = onCancel, modifier = Modifier.align(Alignment.End)) {
                Text(stringResource(android.R.string.cancel))
            }
        }
    }
}

@Composable
private fun PlaylistLinkResultHeader(state: PlaylistLinkUiState, onReset: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        state.resolvedArtworkUrl?.let { url ->
            AsyncImage(
                model = url,
                contentDescription = null,
                modifier = Modifier.size(56.dp).clip(RoundedCornerShape(12.dp)),
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = state.resolvedTitle.orEmpty(),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = state.resolvedSubtitle ?: stringResource(R.string.playlist_link_included_count, state.includedCount, state.results.size),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        TextButton(onClick = onReset) {
            Text(stringResource(R.string.playlist_link_new_search))
        }
    }
}

@Composable
private fun PlaylistLinkRowCard(row: PlaylistLinkReviewRow, onToggle: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        elevation = CardDefaults.cardElevation(defaultElevation = 0.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Checkbox(
                checked = row.included,
                onCheckedChange = { onToggle() },
                enabled = row.candidate != null,
            )

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = row.source.title,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = row.source.artistDisplay,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val candidate = row.candidate
                if (candidate != null) {
                    Text(
                        text = "→ ${candidate.title} · ${candidate.artists.joinToString(", ") { it.name }}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            ConfidenceBadge(confidence = row.confidence, hasCandidate = row.candidate != null)
        }
    }
}

@Composable
private fun ConfidenceBadge(confidence: YouTubeMusicMatcher.Confidence, hasCandidate: Boolean) {
    val (label, color) = when {
        !hasCandidate || confidence == YouTubeMusicMatcher.Confidence.NO_MATCH ->
            stringResource(R.string.playlist_link_no_match) to MaterialTheme.colorScheme.error
        confidence == YouTubeMusicMatcher.Confidence.LOW_CONFIDENCE ->
            stringResource(R.string.playlist_link_low_confidence) to MaterialTheme.colorScheme.tertiary
        else ->
            stringResource(R.string.playlist_link_confident_match) to MaterialTheme.colorScheme.primary
    }
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(color.copy(alpha = 0.15f))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Text(text = label, style = MaterialTheme.typography.labelSmall, color = color)
    }
}

@Composable
private fun PlaylistLinkActionBar(
    includedCount: Int,
    onPlayNow: () -> Unit,
    onSave: () -> Unit,
    onDownload: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(
            onClick = onPlayNow,
            modifier = Modifier.fillMaxWidth(),
            enabled = includedCount > 0,
            shape = CircleShape,
        ) {
            Icon(painterResource(R.drawable.play), contentDescription = null, modifier = Modifier.size(20.dp))
            Text(
                modifier = Modifier.padding(start = 8.dp),
                text = stringResource(R.string.playlist_link_play_now),
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            OutlinedButton(
                onClick = onSave,
                modifier = Modifier.weight(1f),
                enabled = includedCount > 0,
                shape = CircleShape,
            ) {
                Text(stringResource(R.string.playlist_link_save_playlist))
            }
            OutlinedButton(
                onClick = onDownload,
                modifier = Modifier.weight(1f),
                enabled = includedCount > 0,
                shape = CircleShape,
            ) {
                Text(stringResource(R.string.playlist_link_download))
            }
        }
    }
}

@Composable
private fun serviceDisplayName(service: PlaylistService): String = when (service) {
    PlaylistService.SPOTIFY -> stringResource(R.string.playlist_link_service_spotify)
    PlaylistService.YOUTUBE_MUSIC -> stringResource(R.string.playlist_link_service_youtube_music)
    PlaylistService.APPLE_MUSIC -> stringResource(R.string.playlist_link_service_apple_music)
    PlaylistService.DEEZER -> stringResource(R.string.playlist_link_service_deezer)
    PlaylistService.AMAZON_MUSIC -> stringResource(R.string.playlist_link_service_amazon_music)
    PlaylistService.TIDAL -> stringResource(R.string.playlist_link_service_tidal)
    PlaylistService.SOUNDCLOUD -> stringResource(R.string.playlist_link_service_soundcloud)
}
