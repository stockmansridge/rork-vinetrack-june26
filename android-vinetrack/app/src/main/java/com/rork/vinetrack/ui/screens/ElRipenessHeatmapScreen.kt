package com.rork.vinetrack.ui.screens

import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.NavigateBefore
import androidx.compose.material.icons.filled.NavigateNext
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.GroundOverlay
import com.google.maps.android.compose.GroundOverlayPosition
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.MarkerComposable
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.rememberCameraPositionState
import com.google.maps.android.compose.rememberMarkerState
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.ripeness.ElRipenessGeometry
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import com.rork.vinetrack.data.ripeness.ElRipenessObservationCache
import com.rork.vinetrack.data.ripeness.RipenessObservationRepository
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.delay

/** Playback cadence. Slow enough to read, fast enough to show a season. */
private const val PLAYBACK_TICK_MS = 320L

/** Converts a contract colour to a Compose colour. */
private fun ElRipenessHeatmap.Rgb.compose(): Color = Color(r, g, b)

/**
 * True when the device has animations turned off. Playback then advances
 * observation-to-observation instead of sweeping every day.
 */
@Composable
private fun rememberReduceMotion(): Boolean {
    val context = LocalContext.current
    return remember {
        try {
            Settings.Global.getFloat(
                context.contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f,
            ) == 0f
        } catch (_: Exception) {
            false
        }
    }
}

/**
 * The E-L Ripeness Heatmap surface.
 *
 * Embedded inside the Growth Stage Report behind the Summary / Ripeness Heatmap
 * selector, so it shares the report's vintage framing without disturbing the
 * Summary's own read path or its PDF export.
 *
 * Mirrors the Swift `ELRipenessHeatmapView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ElRipenessHeatmapContent(
    state: AppUiState,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val vineyardId = state.selectedVineyardId
    val reduceMotion = rememberReduceMotion()

    val owner = LocalViewModelStoreOwner.current
    val model: ElRipenessHeatmapViewModel = viewModel(
        key = "el-ripeness-heatmap",
        factory = remember {
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : androidx.lifecycle.ViewModel> create(modelClass: Class<T>): T =
                    ElRipenessHeatmapViewModel(
                        repository = RipenessObservationRepository(SessionStore(context)),
                        cache = ElRipenessObservationCache(context),
                    ) as T
            }
        },
    )
    val ui by model.ui.collectAsStateWithLifecycle()

    // The vineyard's own timezone keeps the field-capture day intact.
    val timeZone = remember(state.regionSettings) { TimeZone.getDefault() }

    LaunchedEffect(vineyardId, state.paddocks, state.isOnline) {
        if (vineyardId != null) {
            model.load(
                vineyardId = vineyardId,
                paddocks = state.paddocks,
                pendingRecords = state.growthRecords,
                seasonStartMonth = state.seasonStartMonth,
                seasonStartDay = state.seasonStartDay,
                timeZone = timeZone,
                isOnline = state.isOnline,
            )
        }
    }

    LaunchedEffect(state.growthRecords) {
        model.refreshPending(state.growthRecords, timeZone)
    }

    // Playback ticker.
    LaunchedEffect(ui.isPlaying, reduceMotion) {
        while (ui.isPlaying) {
            delay(if (reduceMotion) PLAYBACK_TICK_MS * 2 else PLAYBACK_TICK_MS)
            model.advancePlayback(reduceMotion)
        }
    }

    // Free rasters and stop rendering the moment the surface leaves the tree.
    DisposableEffect(Unit) {
        onDispose { model.teardown() }
    }

    var sheetObservation by remember { mutableStateOf<ElRipenessHeatmap.Observation?>(null) }

    Column(modifier = modifier.fillMaxSize()) {
        when (val load = ui.loadState) {
            is ElRipenessLoadState.Idle, is ElRipenessLoadState.Loading -> {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = VineColors.LeafGreen)
                }
            }

            is ElRipenessLoadState.UnavailableOffline -> {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    EmptyState(
                        icon = Icons.Filled.CloudOff,
                        title = "Not available offline",
                        message = "Connect once to download this vineyard's growth-stage " +
                            "observations. After that the heatmap works without a signal.",
                    )
                }
            }

            is ElRipenessLoadState.Failed -> {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    EmptyState(
                        icon = Icons.Filled.WarningAmber,
                        title = "Couldn't load observations",
                        message = load.message,
                    )
                }
            }

            is ElRipenessLoadState.EmptyVintage -> {
                VintageBar(ui, model, vine.textPrimary)
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    EmptyState(
                        icon = Icons.Filled.Spa,
                        title = "No observations this vintage",
                        message = "Record a growth-stage observation with a location to start " +
                            "building the ripeness surface.",
                    )
                }
            }

            is ElRipenessLoadState.Ready -> {
                VintageBar(ui, model, vine.textPrimary)
                BlockFilterBar(ui, model)
                HeatMap(
                    ui = ui,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    onObservationTap = { sheetObservation = it },
                )
                NoticeStrip(ui.notices)
                TimelineBar(ui, model)
                StatusRow(ui, vine.textSecondary)
                RipenessLegend()
            }
        }
    }

    sheetObservation?.let { observation ->
        ModalBottomSheet(
            onDismissRequest = { sheetObservation = null },
            sheetState = rememberModalBottomSheetState(),
        ) {
            ObservationSheetBody(observation, ui)
        }
    }
}

// ---- Vintage ----

@Composable
private fun VintageBar(
    ui: ElRipenessUiState,
    model: ElRipenessHeatmapViewModel,
    textColor: Color,
) {
    if (ui.availableVintages.isEmpty()) return
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(
            "Vintage",
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            color = textColor.copy(alpha = 0.7f),
        )
        Spacer(Modifier.height(6.dp))
        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            ui.availableVintages.forEach { vintage ->
                val selected = ui.selectedVintage == vintage
                FilterChip(
                    selected = selected,
                    onClick = { model.selectVintage(vintage) },
                    label = { Text(vintage.toString()) },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = VineColors.LeafGreen.copy(alpha = 0.22f),
                    ),
                    modifier = Modifier.semantics {
                        contentDescription = "Vintage $vintage${if (selected) ", selected" else ""}"
                    },
                )
            }
        }
    }
}

// ---- Block filter ----

@Composable
private fun BlockFilterBar(ui: ElRipenessUiState, model: ElRipenessHeatmapViewModel) {
    if (ui.blocks.size <= 1) return
    Row(
        Modifier
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        FilterChip(
            selected = ui.selectedBlockId == null,
            onClick = { model.selectBlock(null) },
            label = { Text("All blocks") },
        )
        ui.blocks.forEach { block ->
            FilterChip(
                selected = ui.selectedBlockId == block.id,
                onClick = { model.selectBlock(block.id) },
                label = { Text(block.name ?: "Block") },
            )
        }
    }
}

// ---- Map ----

@Composable
private fun HeatMap(
    ui: ElRipenessUiState,
    modifier: Modifier = Modifier,
    onObservationTap: (ElRipenessHeatmap.Observation) -> Unit,
) {
    val cameraPositionState = rememberCameraPositionState()
    val heat = ui.heatModel

    val allPoints = remember(ui.blocks, ui.selectedBlockId) {
        val wanted = ui.selectedBlockId?.let { id -> ui.blocks.filter { it.id == id } } ?: ui.blocks
        wanted.flatMap { block -> block.polygon.map { LatLng(it.lat, it.lng) } }
    }

    LaunchedEffect(allPoints) {
        if (allPoints.isNotEmpty()) {
            cameraPositionState.fitToContent(points = allPoints, paddingPx = 120)
        }
    }

    Box(modifier) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = cameraPositionState,
            properties = MapProperties(mapType = MapType.HYBRID),
            uiSettings = MapUiSettings(zoomControlsEnabled = false, mapToolbarEnabled = false),
        ) {
            // Heat surfaces, one ground overlay per block.
            ui.overlays.forEach { overlay ->
                val block = heat?.blocks?.firstOrNull { it.paddockId == overlay.paddockId }
                val bitmap = remember(overlay, block?.polygon) {
                    ElRipenessOverlayBitmap.build(
                        raster = overlay.raster,
                        bounds = overlay.bounds,
                        polygon = block?.polygon ?: emptyList(),
                    )
                }
                if (bitmap != null) {
                    GroundOverlay(
                        position = GroundOverlayPosition.create(
                            latLngBounds = LatLngBounds(
                                LatLng(overlay.bounds.south, overlay.bounds.west),
                                LatLng(overlay.bounds.north, overlay.bounds.east),
                            ),
                        ),
                        image = BitmapDescriptorFactory.fromBitmap(bitmap),
                        zIndex = 1f,
                    )
                }
            }

            // Block outlines.
            heat?.blocks?.forEach { block ->
                if (block.polygon.size >= 3) {
                    val selected = block.paddockId == ui.selectedBlockId
                    Polygon(
                        points = block.polygon.map { LatLng(it.lat, it.lng) },
                        fillColor = Color.Transparent,
                        strokeColor = Color.White.copy(alpha = if (selected) 0.95f else 0.55f),
                        strokeWidth = if (selected) 5f else 3f,
                        zIndex = 2f,
                    )
                }
            }

            // Observation pins, above the surface.
            heat?.blocks?.forEach { block ->
                block.influencing.forEach { ObservationPin(it, PinStyle.CURRENT, onObservationTap) }
                block.stale.forEach { ObservationPin(it, PinStyle.STALE, onObservationTap) }
            }
            heat?.unassigned?.forEach { ObservationPin(it, PinStyle.UNASSIGNED, onObservationTap) }

            // Block name plates carrying the influencing-only median.
            heat?.blocks?.forEach { block ->
                val centroid = ElRipenessGeometry.centroid(block.polygon)
                if (centroid != null && block.polygon.size >= 3) {
                    BlockLabel(block, centroid)
                }
            }
        }

        if (ui.isRendering) {
            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(12.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.Black.copy(alpha = 0.55f))
                    .padding(horizontal = 10.dp, vertical = 6.dp),
            ) {
                Text("Rendering…", color = Color.White, fontSize = 11.sp)
            }
        }
    }
}

private enum class PinStyle { CURRENT, STALE, UNASSIGNED }

@Composable
@com.google.maps.android.compose.GoogleMapComposable
private fun ObservationPin(
    observation: ElRipenessHeatmap.Observation,
    style: PinStyle,
    onTap: (ElRipenessHeatmap.Observation) -> Unit,
) {
    val fill = when (style) {
        PinStyle.CURRENT -> ElRipenessHeatmap.elColour(observation.el).compose()
        PinStyle.STALE -> Color(0xFF8E8E93)
        PinStyle.UNASSIGNED -> Color(0xFFFF9500)
    }
    val label = ElRipenessHeatmap.formatEl(observation.el)
    val styleWord = when (style) {
        PinStyle.CURRENT -> "current"
        PinStyle.STALE -> "stale"
        PinStyle.UNASSIGNED -> "unassigned location"
    }

    MarkerComposable(
        keys = arrayOf<Any>(observation.id, style.name, label),
        state = rememberMarkerState(position = LatLng(observation.lat, observation.lng)),
        title = "E-L $label",
        zIndex = 3f,
        onClick = {
            onTap(observation)
            true
        },
    ) {
        Box(
            Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(fill)
                .border(2.dp, Color.White, CircleShape)
                .semantics { contentDescription = "E-L $label, $styleWord" },
            contentAlignment = Alignment.Center,
        ) {
            Text(
                label,
                color = Color.White,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

@Composable
@com.google.maps.android.compose.GoogleMapComposable
private fun BlockLabel(
    block: ElRipenessHeatmap.BlockHeat,
    centroid: ElRipenessHeatmap.LatLng,
) {
    val median = block.medianEl
    val text = block.paddockName ?: "Block"
    val medianText = if (median != null) "E-L ${ElRipenessHeatmap.formatEl(median)}" else "No current data"

    MarkerComposable(
        keys = arrayOf<Any>(block.paddockId, medianText, text),
        state = rememberMarkerState(position = LatLng(centroid.lat, centroid.lng)),
        zIndex = 2.5f,
    ) {
        Column(
            Modifier
                .clip(RoundedCornerShape(6.dp))
                .background(Color.Black.copy(alpha = 0.62f))
                .padding(horizontal = 8.dp, vertical = 4.dp)
                .semantics { contentDescription = "$text, median $medianText" },
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(text, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
            Text(medianText, color = Color.White.copy(alpha = 0.85f), fontSize = 10.sp)
        }
    }
}

// ---- Notices ----

@Composable
private fun NoticeStrip(notices: List<ElRipenessNotice>) {
    if (notices.isEmpty()) return
    Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
        notices.forEach { notice ->
            val (icon, text) = when (notice) {
                is ElRipenessNotice.StaleOnly ->
                    Icons.Filled.Info to "Every observation in range is older than the recency " +
                        "window, so no surface is painted. Pins are shown greyed."

                is ElRipenessNotice.MissingPolygon ->
                    Icons.Filled.WarningAmber to
                        "No boundary mapped for ${notice.blockNames.joinToString(", ")} — " +
                        "observations still count, but no surface can be drawn."

                is ElRipenessNotice.OfflineCache -> {
                    val stamp = SimpleDateFormat("d MMM, HH:mm", Locale.getDefault())
                        .format(Date(notice.cachedAtEpochMs))
                    Icons.Filled.CloudOff to "Offline — showing data saved $stamp."
                }
            }
            Row(
                Modifier.fillMaxWidth().padding(vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(icon, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                Text(text, fontSize = 12.sp, color = LocalVineColors.current.textSecondary)
            }
        }
    }
}

// ---- Timeline ----

@Composable
private fun TimelineBar(ui: ElRipenessUiState, model: ElRipenessHeatmapViewModel) {
    val vine = LocalVineColors.current
    if (ui.timelineDays.isEmpty()) return
    val current = ui.currentDay

    Column(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(
                onClick = { model.stepToPreviousObservation() },
                enabled = ui.canStepBack,
            ) {
                Icon(
                    Icons.Filled.NavigateBefore,
                    contentDescription = "Previous observation",
                    tint = if (ui.canStepBack) vine.textPrimary else vine.textSecondary.copy(alpha = 0.4f),
                )
            }
            IconButton(onClick = { model.togglePlayback() }) {
                Icon(
                    if (ui.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (ui.isPlaying) "Pause playback" else "Play the season",
                    tint = VineColors.LeafGreen,
                )
            }
            IconButton(
                onClick = { model.stepToNextObservation() },
                enabled = ui.canStepForward,
            ) {
                Icon(
                    Icons.Filled.NavigateNext,
                    contentDescription = "Next observation",
                    tint = if (ui.canStepForward) vine.textPrimary else vine.textSecondary.copy(alpha = 0.4f),
                )
            }
            Spacer(Modifier.width(8.dp))
            Text(
                current?.iso ?: "",
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
            )
        }

        Slider(
            value = ui.timelineIndex.toFloat(),
            onValueChange = { model.setTimelineIndex(it.toInt()) },
            valueRange = 0f..(ui.timelineDays.size - 1).coerceAtLeast(1).toFloat(),
            modifier = Modifier
                .fillMaxWidth()
                .semantics {
                    contentDescription = "Season timeline, showing ${current?.iso ?: "no date"}"
                },
        )

        // Observation-day ticks so the operator can see where the data is.
        Row(Modifier.fillMaxWidth().height(6.dp)) {
            val total = ui.timelineDays.size.coerceAtLeast(1)
            val marks = ui.observationDayIndices.toSet()
            for (i in 0 until total) {
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxSize()
                        .background(
                            if (marks.contains(i)) VineColors.LeafGreen.copy(alpha = 0.85f)
                            else Color.Transparent
                        ),
                )
            }
        }
    }
}

// ---- Status + legend ----

@Composable
private fun StatusRow(ui: ElRipenessUiState, textColor: Color) {
    val counts = ui.statusCounts
    val median = ui.medianEl
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            "${counts.recorded} recorded · ${counts.influencing} influencing · " +
                "${counts.stale} stale · ${counts.unassigned} unassigned",
            fontSize = 11.sp,
            color = textColor,
        )
        if (median != null) {
            Text(
                "Median E-L ${ElRipenessHeatmap.formatEl(median)}",
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = textColor,
            )
        }
    }
}

@Composable
private fun RipenessLegend() {
    val stops = ElRipenessHeatmap.colourStops
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(10.dp)
                .clip(RoundedCornerShape(5.dp))
                .background(Brush.horizontalGradient(stops.map { it.rgb.compose() }))
                .semantics {
                    contentDescription = "Colour scale from E-L 1 dormant to E-L 43 harvest ripe"
                },
        )
        Spacer(Modifier.height(4.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("E-L 1", fontSize = 10.sp, color = LocalVineColors.current.textSecondary)
            Text("E-L 43", fontSize = 10.sp, color = LocalVineColors.current.textSecondary)
        }
        Spacer(Modifier.height(6.dp))
        Text(
            "E-L 47 (berries harvest-ripe) is recorded but never plotted — it sits outside " +
                "the 1–43 surface scale.",
            fontSize = 10.sp,
            color = LocalVineColors.current.textSecondary,
        )
    }
}

// ---- Detail sheet ----

@Composable
private fun ObservationSheetBody(
    observation: ElRipenessHeatmap.Observation,
    ui: ElRipenessUiState,
) {
    val vine = LocalVineColors.current
    val blockName = ui.blocks.firstOrNull { it.id == observation.paddockId }?.name
    Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
        Text(
            "E-L ${ElRipenessHeatmap.formatEl(observation.el)}",
            fontSize = 22.sp,
            fontWeight = FontWeight.Bold,
            color = vine.textPrimary,
        )
        Spacer(Modifier.height(10.dp))
        SheetRow("Recorded", ElRipenessHeatmap.dayKey(observation.dateIso))
        SheetRow("Block", if (observation.assigned) (blockName ?: "—") else "Unassigned location")
        SheetRow(
            "Coordinates",
            String.format(Locale.US, "%.5f, %.5f", observation.lat, observation.lng),
        )
        if (!observation.assigned) {
            Spacer(Modifier.height(10.dp))
            Text(
                "This observation has no block assignment, so it is counted but never " +
                    "contributes to a block's surface.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
        }
    }
}

@Composable
private fun SheetRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Text(label, fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.width(110.dp))
        Text(value, fontSize = 13.sp, color = vine.textPrimary, fontWeight = FontWeight.Medium)
    }
}
