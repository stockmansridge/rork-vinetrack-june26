package com.rork.vinetrack.ui.screens

import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CropFree
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.MarkerComposable
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.BlockEditorLayout
import com.rork.vinetrack.data.BlockRowLayout
import com.rork.vinetrack.data.BoundaryEdit
import com.rork.vinetrack.data.BoundaryEditor
import com.rork.vinetrack.data.BoundaryMidpoint
import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.RowInput
import com.rork.vinetrack.data.RowLimits
import com.rork.vinetrack.data.RowNumbering
import com.rork.vinetrack.data.blockRowLayout
import com.rork.vinetrack.data.calculateRowLines
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.normaliseRowDirection
import com.rork.vinetrack.data.stepRowDirection
import com.rork.vinetrack.ui.components.BlockBoundaryOverlay
import com.rork.vinetrack.ui.components.BlockGeometryColors
import com.rork.vinetrack.ui.components.BlockRowLabelsOverlay
import com.rork.vinetrack.ui.components.BlockRowLinesOverlay
import com.rork.vinetrack.ui.components.MapMyLocationButton
import com.rork.vinetrack.ui.components.OtherBlockOutlines
import com.rork.vinetrack.ui.components.OverZoomSatelliteLayer
import com.rork.vinetrack.ui.components.SATELLITE_IMAGERY_ATTRIBUTION
import com.rork.vinetrack.ui.components.SatelliteTileStatus
import com.rork.vinetrack.ui.components.estimatedCameraPosition
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.components.validMapPoints
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sqrt

private const val TAG = "BlockMapEditor"

/** How long the Google Map may take to report `onMapLoaded` before we offer a retry. */
private const val MAP_LOAD_TIMEOUT_MS = 12_000L

private val BoundaryBlue = BlockGeometryColors.Boundary
private val PanelSurface = Color(0xF21C1C1E)

/** Which half of the editor is active. Also picks the screen's entry mode. */
enum class BlockEditorMode { Boundary, Rows }

/**
 * The ONE place a block's boundary and row layout can be edited.
 *
 * The block form's map is a read-only preview; every mutation happens here, on
 * the shared draft state, so the two surfaces can never disagree about what the
 * block looks like.
 *
 * Layout:
 *  * top — close, a Boundary/Rows segmented control, and the two distinct map
 *    controls (centre on my location, fit geometry),
 *  * bottom — a compact bar anchored directly above the app navigation in
 *    Boundary mode, or a draggable, collapsible row sheet capped at half the
 *    usable map height in Rows mode.
 *
 * Rows are generated by the canonical [blockRowLayout] from the CURRENT draft
 * parameters, so every control updates the overlay in the same Compose frame.
 *
 * Map stack: a real Google base map with the over-zoom satellite layer on top,
 * so missing imagery can never leave the grower on a blank canvas.
 */
@Composable
fun BlockMapEditorScreen(
    boundary: SnapshotStateList<MarkerState>,
    otherBlocks: List<Paddock>,
    vineyardCenter: LatLng?,
    rowDirection: Double,
    onRowDirection: (Double) -> Unit,
    rowCount: Int,
    onRowCount: (Int) -> Unit,
    rowWidth: Double,
    onRowWidth: (Double) -> Unit,
    rowOffset: Double,
    onRowOffset: (Double) -> Unit,
    rowStartNumber: Int,
    onRowStartNumber: (Int) -> Unit,
    rowAscending: Boolean,
    onRowAscending: (Boolean) -> Unit,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
    /**
     * Identifies the vineyard + block being edited. Camera state is scoped to
     * it so reopening a DIFFERENT block never restores the previous block's
     * position.
     */
    cameraKey: String = "block",
    initialMode: BlockEditorMode = BlockEditorMode.Boundary,
) {
    var mode by remember(cameraKey) { mutableStateOf(initialMode) }
    var showTip by remember { mutableStateOf(true) }
    var showClearConfirm by remember { mutableStateOf(false) }
    var sheetExpanded by remember { mutableStateOf(initialMode == BlockEditorMode.Rows) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val density = LocalDensity.current

    var mapAttempt by remember { mutableStateOf(0) }
    var mapLoaded by remember { mutableStateOf(false) }
    var mapFailed by remember { mutableStateOf(false) }
    var framed by remember(cameraKey) { mutableStateOf(false) }
    var hasLocationPerm by remember { mutableStateOf(LocationTracker(context).hasPermission) }
    var locationMessage by remember { mutableStateOf<String?>(null) }

    /** Measured chrome, so "Fit" frames into the part of the map still visible. */
    var topChromePx by remember { mutableStateOf(0) }
    var bottomPanelPx by remember { mutableStateOf(0) }

    /** Reversible edits, newest last. Scoped to the block being edited. */
    val undoStack = remember(cameraKey) { mutableStateListOf<BoundaryEdit>() }

    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val fitPadding = remember(density) { with(density) { 48.dp.roundToPx() } }
    val anchorGap = BlockEditorLayout.BOTTOM_ANCHOR_GAP_DP.dp

    // Seed the camera synchronously so the map NEVER starts at the world
    // default (0,0) — that is what produced the "blank map" reports.
    val seedCamera = remember(cameraKey) {
        estimatedCameraPosition(
            boundary.map { it.position },
            singlePointZoom = BoundaryEditor.SINGLE_POINT_ZOOM,
        ) ?: vineyardCenter
            ?.takeIf { BoundaryEditor.isValidPoint(CoordinatePoint(it.latitude, it.longitude)) }
            ?.let { CameraPosition.fromLatLngZoom(it, BoundaryEditor.VINEYARD_CENTRE_ZOOM) }
    }
    val camera = rememberCameraPositionState(key = cameraKey) {
        seedCamera?.let { position = it }
    }

    val polyCoords by remember {
        derivedStateOf { boundary.map { CoordinatePoint(it.position.latitude, it.position.longitude) } }
    }

    // THE live row layout. Keyed on every draft parameter, so a slider drag, a
    // typed digit or a dragged boundary point all regenerate the overlay in the
    // same frame as the control that changed. (The previous implementation
    // memoised this with no keys and therefore drew the row set the editor
    // opened with, forever.)
    val layout: BlockRowLayout = remember(
        polyCoords, rowDirection, rowCount, rowWidth, rowOffset, rowStartNumber, rowAscending,
    ) {
        blockRowLayout(
            polygon = polyCoords,
            direction = rowDirection,
            count = rowCount,
            width = rowWidth,
            offset = rowOffset,
            numbering = RowNumbering(startNumber = rowStartNumber, ascending = rowAscending),
        )
    }

    val areaHa by remember { derivedStateOf { polygonAreaHectares(polyCoords) } }
    val midpoints by remember { derivedStateOf { BoundaryEditor.midpoints(polyCoords) } }

    /** Every coordinate the "Fit" control can frame in the current mode. */
    val fitTargets: List<LatLng> = remember(polyCoords, layout, mode) {
        val points = polyCoords.map { LatLng(it.latitude, it.longitude) }.toMutableList()
        if (mode == BlockEditorMode.Rows) {
            layout.framePoints.forEach { points += LatLng(it.latitude, it.longitude) }
        }
        points.validMapPoints()
    }
    val canFit = fitTargets.isNotEmpty()

    fun pushEdit(edit: BoundaryEdit) {
        undoStack.add(edit)
        if (undoStack.size > 100) undoStack.removeAt(0)
    }

    fun addPoint(position: LatLng) {
        boundary.add(MarkerState(position))
        pushEdit(BoundaryEdit.Added(boundary.lastIndex))
    }

    fun insertMidpoint(midpoint: BoundaryMidpoint) {
        val index = midpoint.insertIndex.coerceIn(0, boundary.size)
        boundary.add(index, MarkerState(LatLng(midpoint.point.latitude, midpoint.point.longitude)))
        pushEdit(BoundaryEdit.Inserted(index))
    }

    fun undoLast() {
        val edit = undoStack.removeLastOrNull() ?: return
        when (edit) {
            is BoundaryEdit.Added -> if (edit.index in boundary.indices) boundary.removeAt(edit.index)
            is BoundaryEdit.Inserted -> if (edit.index in boundary.indices) boundary.removeAt(edit.index)
            is BoundaryEdit.Moved -> boundary.getOrNull(edit.index)?.let {
                it.position = LatLng(edit.from.latitude, edit.from.longitude)
            }
            is BoundaryEdit.Cleared -> {
                boundary.clear()
                edit.points.forEach { boundary.add(MarkerState(LatLng(it.latitude, it.longitude))) }
            }
        }
    }

    fun clearBoundary() {
        if (boundary.isEmpty()) return
        pushEdit(BoundaryEdit.Cleared(polyCoords.toList()))
        boundary.clear()
    }

    suspend fun frameGeometry(animate: Boolean) {
        val points = fitTargets
        if (points.isEmpty()) return
        camera.fitToContent(
            points = points,
            paddingPx = fitPadding,
            singlePointZoom = BoundaryEditor.SINGLE_POINT_ZOOM,
            animate = animate,
            topInsetPx = topChromePx,
            bottomInsetPx = bottomPanelPx + with(density) { anchorGap.roundToPx() },
        )
        // Never leave the camera past the imagery's supported maximum.
        val zoom = camera.position.zoom
        val clamped = BoundaryEditor.clampZoom(zoom)
        if (abs(zoom - clamped) > 0.01f) {
            runCatching { camera.move(CameraUpdateFactory.zoomTo(clamped)) }
        }
    }

    // Report imagery problems distinctly from map-initialisation problems.
    var lastTileStatus by remember { mutableStateOf(SatelliteTileStatus.OK) }

    // Existing-boundary sanity check (decoding diagnostics, no coordinates logged).
    LaunchedEffect(cameraKey) {
        val invalid = polyCoords.count { !BoundaryEditor.isValidPoint(it) }
        if (invalid > 0) Log.w(TAG, "boundary has $invalid unusable coordinate(s) — excluded from framing")
    }

    // Frame only after the map reports it is ready — a bounds update on an
    // unmeasured map fails silently and leaves the camera at 0,0. Re-runs while
    // unframed so a boundary that loads after the map still gets framed.
    LaunchedEffect(mapLoaded, boundary.size, mapAttempt) {
        if (!mapLoaded || framed) return@LaunchedEffect
        when {
            fitTargets.isNotEmpty() -> {
                frameGeometry(animate = false)
                framed = true
            }
            vineyardCenter != null &&
                BoundaryEditor.isValidPoint(CoordinatePoint(vineyardCenter.latitude, vineyardCenter.longitude)) -> {
                camera.fitToContent(
                    points = listOf(vineyardCenter),
                    singlePointZoom = BoundaryEditor.VINEYARD_CENTRE_ZOOM,
                )
                framed = true
            }
            hasLocationPerm -> {
                val fix = LocationTracker(context).currentLocation()
                if (fix != null) {
                    camera.fitToContent(
                        points = listOf(LatLng(fix.latitude, fix.longitude)),
                        singlePointZoom = BoundaryEditor.VINEYARD_CENTRE_ZOOM,
                    )
                    framed = true
                } else {
                    Log.i(TAG, "no device fix for initial framing — keeping seeded camera")
                }
            }
            else -> Log.i(TAG, "no boundary, vineyard centre or location permission — keeping seeded camera")
        }
    }

    // Surface a recoverable state instead of an indefinitely blank map.
    LaunchedEffect(mapAttempt) {
        mapLoaded = false
        mapFailed = false
        delay(MAP_LOAD_TIMEOUT_MS)
        if (!mapLoaded) {
            mapFailed = true
            Log.w(TAG, "google map did not finish loading (attempt $mapAttempt)")
        }
    }

    // Edits live on the shared draft state, so leaving the editor — by the
    // Done button OR the system back gesture — always returns them to the form.
    BackHandler { onDone() }

    BoxWithConstraints(modifier = modifier.fillMaxSize().background(Color(0xFF1C1C1E))) {
        val usableHeightDp = maxHeight.value.toInt()
        val collapsedSheetDp = BlockEditorLayout.ROW_SHEET_COLLAPSED_HEIGHT_DP.dp
        val expandedSheetDp = BlockEditorLayout.expandedSheetHeightDp(usableHeightDp).dp

        key(mapAttempt) {
            GoogleMap(
                modifier = Modifier.fillMaxSize(),
                cameraPositionState = camera,
                // A REAL Google base map underneath the imagery: when a satellite
                // tile is missing the base map shows through instead of the empty
                // MapType.NONE canvas that used to read as a grey/cream screen.
                // Zoom is clamped to what the imagery source can actually serve.
                properties = MapProperties(
                    mapType = MapType.NORMAL,
                    isMyLocationEnabled = hasLocationPerm,
                    minZoomPreference = BoundaryEditor.MIN_ZOOM,
                    maxZoomPreference = BoundaryEditor.MAX_ZOOM,
                ),
                uiSettings = MapUiSettings(
                    zoomControlsEnabled = false,
                    mapToolbarEnabled = false,
                    compassEnabled = false,
                    myLocationButtonEnabled = false,
                    tiltGesturesEnabled = false,
                    rotationGesturesEnabled = false,
                ),
                onMapClick = { latLng ->
                    // Only the Boundary half of the editor treats a tap as an edit.
                    if (mode == BlockEditorMode.Boundary) addPoint(latLng)
                },
                onMapLoaded = {
                    mapLoaded = true
                    mapFailed = false
                },
            ) {
                OverZoomSatelliteLayer(
                    onStatus = { status ->
                        if (status != lastTileStatus) {
                            lastTileStatus = status
                            if (status != SatelliteTileStatus.OK) {
                                Log.w(TAG, "satellite imagery status: $status (base map still visible)")
                            }
                        }
                    },
                )

                // Context: other blocks already mapped in this vineyard.
                OtherBlockOutlines(
                    otherBlocks.mapNotNull { other ->
                        other.polygonPoints
                            ?.takeIf { it.size > 2 }
                            ?.map { LatLng(it.latitude, it.longitude) }
                    },
                )

                BlockBoundaryOverlay(points = boundary.map { it.position })

                // Live rows — always drawn, in BOTH modes, above the boundary fill.
                BlockRowLinesOverlay(layout)
                BlockRowLabelsOverlay(layout)

                if (mode == BlockEditorMode.Boundary) {
                    // Draggable numbered vertices — always above the midpoints.
                    boundary.forEachIndexed { index, ms ->
                        key(ms) {
                            LaunchedEffect(ms) {
                                var dragStart: LatLng? = null
                                snapshotFlow { ms.isDragging }.collect { dragging ->
                                    if (dragging) {
                                        dragStart = ms.position
                                    } else {
                                        val from = dragStart
                                        dragStart = null
                                        val at = boundary.indexOf(ms)
                                        if (from != null && at >= 0 && from != ms.position) {
                                            pushEdit(
                                                BoundaryEdit.Moved(
                                                    at,
                                                    CoordinatePoint(from.latitude, from.longitude),
                                                ),
                                            )
                                        }
                                    }
                                }
                            }
                            MarkerComposable(
                                index + 1,
                                state = ms,
                                draggable = true,
                                anchor = Offset(0.5f, 0.5f),
                                zIndex = 7f,
                                title = "Boundary point ${index + 1}",
                                onClick = { true },
                            ) {
                                PointHandle(index + 1)
                            }
                        }
                    }

                    // Functional midpoint insertion controls (small circular +).
                    midpoints.forEach { midpoint ->
                        key(midpoint.key) {
                            val position = LatLng(midpoint.point.latitude, midpoint.point.longitude)
                            val state = remember(midpoint.key) { MarkerState(position) }
                            state.position = position
                            MarkerComposable(
                                midpoint.key,
                                state = state,
                                anchor = Offset(0.5f, 0.5f),
                                zIndex = 6f,
                                title = midpoint.accessibilityLabel,
                                onClick = {
                                    insertMidpoint(midpoint)
                                    true
                                },
                            ) {
                                MidpointHandle()
                            }
                        }
                    }
                }
            }
        }

        // Top chrome: close + segmented control + the two DISTINCT map actions.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .onSizeChanged { topChromePx = it.height }
                .padding(top = statusTop + 8.dp, start = 12.dp, end = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                GlassCircleButton(Icons.Filled.Check, "Done", onClick = onDone)
                Spacer(Modifier.weight(1f))
                SegmentedToggle(mode = mode, onChange = { mode = it })
                Spacer(Modifier.weight(1f))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    // 1 — device location. Moves the camera only; never edits the polygon.
                    MapMyLocationButton(
                        camera = camera,
                        onMessage = { locationMessage = it },
                        contentDescription = "Centre on my location",
                        onPermissionGranted = { hasLocationPerm = true },
                    )
                    // 2 — frame the drawn geometry. Different icon, different job.
                    GlassCircleButton(
                        icon = Icons.Filled.CropFree,
                        contentDescription = if (mode == BlockEditorMode.Rows) {
                            "Fit boundary and rows"
                        } else {
                            "Fit vineyard boundary"
                        },
                        enabled = canFit,
                    ) {
                        scope.launch { frameGeometry(animate = true) }
                    }
                }
            }

            if (mapFailed) {
                MapFailureCard(
                    canCentreOnLocation = hasLocationPerm,
                    onRetry = {
                        framed = false
                        mapAttempt += 1
                    },
                    onCentreOnLocation = {
                        scope.launch {
                            val fix = LocationTracker(context).currentLocation()
                            if (fix == null) {
                                locationMessage = "Current location unavailable. Try again when GPS has a fix."
                                Log.w(TAG, "centre-on-location failed: no fix")
                            } else {
                                camera.fitToContent(
                                    points = listOf(LatLng(fix.latitude, fix.longitude)),
                                    singlePointZoom = BoundaryEditor.SINGLE_POINT_ZOOM,
                                    animate = true,
                                )
                            }
                        }
                    },
                )
            }

            locationMessage?.let { msg ->
                LaunchedEffect(msg) {
                    delay(3500)
                    locationMessage = null
                }
                Box(
                    modifier = Modifier
                        .padding(top = 10.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(Color(0xCC1C1C1E))
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                ) {
                    Text(msg, color = Color.White, fontSize = 12.sp)
                }
            }

            AnimatedVisibility(
                visible = showTip && mode == BlockEditorMode.Boundary,
                enter = fadeIn() + slideInVertically(),
                exit = fadeOut() + slideOutVertically(),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 10.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(Color(0xCC1C1C1E))
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Filled.Info, contentDescription = null, tint = BoundaryBlue, modifier = Modifier.size(18.dp))
                    Text(
                        "Tap the map to add a point, drag a numbered point to move it, or tap a ⊕ between two points to insert one.",
                        color = Color.White, fontSize = 12.sp, modifier = Modifier.weight(1f),
                    )
                    Icon(
                        Icons.Filled.Close, contentDescription = "Dismiss tip", tint = Color.White.copy(alpha = 0.6f),
                        modifier = Modifier.size(18.dp).clip(CircleShape).clickable { showTip = false },
                    )
                }
            }
        }

        // Bottom controls — anchored to the bottom of the usable map area, which
        // already sits directly above the VineTrack navigation bar (the host
        // Scaffold consumes both it and the system navigation inset).
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .onSizeChanged { bottomPanelPx = it.height }
                .padding(start = 10.dp, end = 10.dp, bottom = anchorGap),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                SATELLITE_IMAGERY_ATTRIBUTION,
                color = Color.White.copy(alpha = 0.55f),
                fontSize = 9.sp,
            )
            if (mode == BlockEditorMode.Boundary) {
                BoundaryControlBar(
                    pointCount = boundary.size,
                    areaHa = areaHa,
                    canUndo = undoStack.isNotEmpty(),
                    onAddCenter = { addPoint(camera.position.target) },
                    onUndo = { undoLast() },
                    onClear = { showClearConfirm = true },
                )
            } else {
                RowLayoutSheet(
                    layout = layout,
                    hasBoundary = boundary.size >= 3,
                    expanded = sheetExpanded,
                    onExpanded = { sheetExpanded = it },
                    collapsedHeight = collapsedSheetDp,
                    expandedHeight = expandedSheetDp,
                    onFitRows = { scope.launch { frameGeometry(animate = true) } },
                    rowDirection = rowDirection, onRowDirection = onRowDirection,
                    rowCount = rowCount, onRowCount = onRowCount,
                    rowWidth = rowWidth, onRowWidth = onRowWidth,
                    rowOffset = rowOffset, onRowOffset = onRowOffset,
                    rowStartNumber = rowStartNumber, onRowStartNumber = onRowStartNumber,
                    rowAscending = rowAscending, onRowAscending = onRowAscending,
                )
            }
        }
    }

    if (showClearConfirm) {
        AlertDialog(
            onDismissRequest = { showClearConfirm = false },
            title = { Text("Clear boundary?") },
            text = {
                Text(
                    "This removes all ${boundary.size} boundary points from the editor. " +
                        "The saved boundary only changes when you save the block, and Undo restores the points.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    clearBoundary()
                    showClearConfirm = false
                }) { Text("Clear", color = VineColors.Destructive) }
            },
            dismissButton = {
                TextButton(onClick = { showClearConfirm = false }) { Text("Cancel") }
            },
        )
    }

    LaunchedEffect(mode) {
        if (mode == BlockEditorMode.Rows) showTip = false
    }
}

/** Compact, recoverable state for a map that never finished loading. */
@Composable
private fun MapFailureCard(
    canCentreOnLocation: Boolean,
    onRetry: () -> Unit,
    onCentreOnLocation: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 10.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xE61C1C1E))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Map could not be loaded.", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "Your boundary points are safe — they are still in the editor.",
            color = Color.White.copy(alpha = 0.7f),
            fontSize = 11.sp,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            PillButton("Retry", Icons.Filled.Add, filled = true, onClick = onRetry)
            if (canCentreOnLocation) {
                PillButton("Centre on current location", Icons.Filled.CropFree, onClick = onCentreOnLocation)
            }
        }
    }
}

@Composable
private fun SegmentedToggle(mode: BlockEditorMode, onChange: (BlockEditorMode) -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0xCC1C1C1E))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        SegmentChip("Boundary", mode == BlockEditorMode.Boundary) { onChange(BlockEditorMode.Boundary) }
        SegmentChip("Rows", mode == BlockEditorMode.Rows) { onChange(BlockEditorMode.Rows) }
    }
}

@Composable
private fun SegmentChip(label: String, active: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(if (active) VineColors.LeafGreen else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            color = if (active) Color.White else Color.White.copy(alpha = 0.75f),
            fontSize = 13.sp,
            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
        )
    }
}

@Composable
private fun GlassCircleButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(Color(0xCC1C1C1E))
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = contentDescription,
            tint = if (enabled) Color.White else Color.White.copy(alpha = 0.35f),
            modifier = Modifier.size(20.dp),
        )
    }
}

/**
 * Boundary mode's bottom bar: one summary line, one action row, minimum
 * practical height — it hugs the bottom of the map instead of floating over
 * the boundary points.
 */
@Composable
private fun BoundaryControlBar(
    pointCount: Int,
    areaHa: Double,
    canUndo: Boolean,
    onAddCenter: () -> Unit,
    onUndo: () -> Unit,
    onClear: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(PanelSurface)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            buildString {
                append("$pointCount point").append(if (pointCount == 1) "" else "s")
                if (areaHa > 0) append("  ·  %.2f ha".format(areaHa))
            },
            color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PillButton("Add at Center", Icons.Filled.Add, filled = true, onClick = onAddCenter)
            PillButton("Undo", Icons.Filled.Undo, enabled = canUndo, onClick = onUndo)
            PillButton("Clear", Icons.Filled.Delete, destructive = true, enabled = pointCount > 0, onClick = onClear)
        }
    }
}

@Composable
private fun PillButton(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    filled: Boolean = false,
    destructive: Boolean = false,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val bg = when {
        filled -> BoundaryBlue
        else -> Color.White.copy(alpha = 0.12f)
    }
    val fg = when {
        !enabled -> Color.White.copy(alpha = 0.3f)
        destructive -> Color(0xFFFF6B6B)
        else -> Color.White
    }
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(bg)
            .let { if (enabled) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(icon, contentDescription = null, tint = fg, modifier = Modifier.size(16.dp))
        Text(label, color = fg, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

/**
 * Rows mode's control surface: a draggable bottom sheet.
 *
 * Collapsed it is a one-line summary plus two actions; expanded it is capped at
 * half the usable map height and scrolls internally, so the live row overlay is
 * always visible behind it while values change.
 */
@Composable
private fun RowLayoutSheet(
    layout: BlockRowLayout,
    hasBoundary: Boolean,
    expanded: Boolean,
    onExpanded: (Boolean) -> Unit,
    collapsedHeight: androidx.compose.ui.unit.Dp,
    expandedHeight: androidx.compose.ui.unit.Dp,
    onFitRows: () -> Unit,
    rowDirection: Double, onRowDirection: (Double) -> Unit,
    rowCount: Int, onRowCount: (Int) -> Unit,
    rowWidth: Double, onRowWidth: (Double) -> Unit,
    rowOffset: Double, onRowOffset: (Double) -> Unit,
    rowStartNumber: Int, onRowStartNumber: (Int) -> Unit,
    rowAscending: Boolean, onRowAscending: (Boolean) -> Unit,
) {
    val density = LocalDensity.current
    val collapsedPx = with(density) { collapsedHeight.toPx() }
    val expandedPx = with(density) { expandedHeight.toPx().coerceAtLeast(collapsedPx) }
    var dragPx by remember { mutableStateOf(0f) }
    val basePx = if (expanded) expandedPx else collapsedPx
    val heightPx = (basePx - dragPx).coerceIn(collapsedPx, expandedPx)
    val height = with(density) { heightPx.toDp() }

    val dragState = rememberDraggableState { delta -> dragPx += delta }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp, bottomStart = 20.dp, bottomEnd = 20.dp))
            .background(PanelSurface),
    ) {
        // Grab handle — drag to resize, tap to toggle.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .draggable(
                    state = dragState,
                    orientation = Orientation.Vertical,
                    onDragStopped = {
                        val travel = expandedPx - collapsedPx
                        val progress = if (travel > 0f) (heightPx - collapsedPx) / travel else 0f
                        onExpanded(progress >= BlockEditorLayout.ROW_SHEET_SNAP_FRACTION.toFloat())
                        dragPx = 0f
                    },
                )
                .clickable { onExpanded(!expanded) }
                .padding(vertical = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(width = 38.dp, height = 4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(Color.White.copy(alpha = 0.35f)),
            )
        }

        // Always-visible summary line.
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                "%s° · %d rows · %s m".format(
                    RowInput.formatDecimal(rowDirection),
                    rowCount,
                    RowInput.formatDecimal(rowWidth),
                ),
                color = Color.White,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            Icon(
                if (expanded) Icons.Filled.ExpandMore else Icons.Filled.ExpandLess,
                contentDescription = if (expanded) "Collapse row layout" else "Edit row layout",
                tint = Color.White.copy(alpha = 0.8f),
                modifier = Modifier
                    .size(26.dp)
                    .clip(CircleShape)
                    .clickable { onExpanded(!expanded) },
            )
        }

        if (!expanded) {
            Spacer(Modifier.height(8.dp))
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                PillButton("Edit row layout", Icons.Filled.Add, filled = true) { onExpanded(true) }
                PillButton("Fit rows", Icons.Filled.CropFree, onClick = onFitRows)
            }
        } else {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (!hasBoundary) {
                    Text(
                        "Draw a boundary with at least 3 points to preview rows.",
                        color = Color(0xFFFFD60A), fontSize = 12.sp,
                    )
                } else if (rowCount > 0 && layout.isEmpty) {
                    Text(
                        "These settings place no rows inside the boundary — check the shift and row width.",
                        color = Color(0xFFFFD60A), fontSize = 12.sp,
                    )
                }

                // Direction — 0–180 only: a row is an axis, not a heading.
                ControlRow(
                    label = "Direction",
                    field = {
                        NumericEntry(
                            canonical = RowInput.formatDecimal(rowDirection),
                            keyboardType = KeyboardType.Decimal,
                            suffix = "°",
                            onTyped = { text -> RowInput.direction(text)?.let(onRowDirection) },
                        )
                    },
                )
                SliderStrip(
                    value = rowDirection.toFloat(),
                    range = RowLimits.DIRECTION_MIN.toFloat()..RowLimits.DIRECTION_MAX.toFloat(),
                    onMinus = { onRowDirection(stepRowDirection(rowDirection, -0.5)) },
                    onPlus = { onRowDirection(stepRowDirection(rowDirection, 0.5)) },
                    onChange = { onRowDirection(normaliseRowDirection(RowInput.roundToDecimals(it.toDouble()))) },
                )

                DarkDivider()

                ControlRow(
                    label = "Rows",
                    field = {
                        NumericEntry(
                            canonical = rowCount.toString(),
                            keyboardType = KeyboardType.Number,
                            onTyped = { text -> RowInput.count(text)?.let(onRowCount) },
                        )
                    },
                    trailing = {
                        Stepper(
                            onMinus = { if (rowCount > RowLimits.COUNT_MIN) onRowCount(rowCount - 1) },
                            onPlus = { if (rowCount < RowLimits.COUNT_MAX) onRowCount(rowCount + 1) },
                        )
                    },
                )

                DarkDivider()

                ControlRow(
                    label = "Row width",
                    field = {
                        NumericEntry(
                            canonical = RowInput.formatDecimal(rowWidth),
                            keyboardType = KeyboardType.Decimal,
                            suffix = "m",
                            onTyped = { text -> RowInput.width(text)?.let(onRowWidth) },
                        )
                    },
                )
                SliderStrip(
                    value = rowWidth.toFloat(),
                    range = RowLimits.WIDTH_MIN.toFloat()..RowLimits.WIDTH_MAX.toFloat(),
                    onMinus = { onRowWidth((rowWidth - 0.1).coerceAtLeast(RowLimits.WIDTH_MIN)) },
                    onPlus = { onRowWidth((rowWidth + 0.1).coerceAtMost(RowLimits.WIDTH_MAX)) },
                    onChange = { onRowWidth(RowInput.roundToDecimals(it.toDouble())) },
                )

                DarkDivider()

                ControlRow(
                    label = "Shift rows",
                    field = {
                        NumericEntry(
                            canonical = RowInput.formatDecimal(rowOffset),
                            keyboardType = KeyboardType.Decimal,
                            suffix = "m",
                            onTyped = { text -> RowInput.shift(text)?.let(onRowOffset) },
                        )
                    },
                    trailing = {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "±",
                                color = BoundaryBlue,
                                fontSize = 16.sp,
                                fontWeight = FontWeight.Bold,
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .clickable { onRowOffset(-rowOffset) }
                                    .padding(horizontal = 8.dp, vertical = 2.dp),
                            )
                            Text(
                                "Reset",
                                color = if (rowOffset != 0.0) BoundaryBlue else Color.White.copy(alpha = 0.3f),
                                fontSize = 12.sp,
                                modifier = Modifier.clickable(enabled = rowOffset != 0.0) { onRowOffset(0.0) },
                            )
                        }
                    },
                )
                SliderStrip(
                    value = rowOffset.toFloat(),
                    range = -50f..50f,
                    onMinus = { onRowOffset((rowOffset - 0.5).coerceAtLeast(RowLimits.SHIFT_MIN)) },
                    onPlus = { onRowOffset((rowOffset + 0.5).coerceAtMost(RowLimits.SHIFT_MAX)) },
                    onChange = { onRowOffset(RowInput.roundToDecimals(it.toDouble())) },
                )

                if (rowCount > 0) {
                    DarkDivider()
                    ControlRow(
                        label = "Start number",
                        field = {
                            NumericEntry(
                                canonical = rowStartNumber.toString(),
                                keyboardType = KeyboardType.Number,
                                onTyped = { text -> RowInput.startNumber(text)?.let(onRowStartNumber) },
                            )
                        },
                        trailing = {
                            Stepper(
                                onMinus = { if (rowStartNumber > RowLimits.START_NUMBER_MIN) onRowStartNumber(rowStartNumber - 1) },
                                onPlus = { if (rowStartNumber < RowLimits.START_NUMBER_MAX) onRowStartNumber(rowStartNumber + 1) },
                            )
                        },
                    )
                    // Numbering side — reverses the LABELS only, never the geometry.
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.White.copy(alpha = 0.08f))
                            .clickable { onRowAscending(!rowAscending) }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        NumberEnd("First", layout.numbering.firstNumber(rowCount), Modifier.weight(1f))
                        Box(
                            modifier = Modifier.size(36.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                Icons.Filled.SwapHoriz,
                                contentDescription = "Swap row numbering side",
                                tint = BoundaryBlue,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                        NumberEnd("Last", layout.numbering.lastNumber(rowCount), Modifier.weight(1f))
                    }
                    PillButton("Fit rows", Icons.Filled.CropFree, onClick = onFitRows)
                }
            }
        }
    }
}

@Composable
private fun ControlRow(
    label: String,
    field: @Composable () -> Unit,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(label, color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
        field()
        trailing?.invoke()
    }
}

/**
 * Direct numeric entry for a row parameter.
 *
 * While the field has focus the grower's own text is preserved verbatim, so an
 * incomplete value like `24.` never clears the row overlay — [onTyped] simply
 * does not fire until the text parses, leaving the last valid value in place.
 * On blur the field snaps back to the canonical, clamped value.
 */
@Composable
private fun NumericEntry(
    canonical: String,
    keyboardType: KeyboardType,
    onTyped: (String) -> Unit,
    suffix: String? = null,
) {
    var field by remember { mutableStateOf(TextFieldValue(canonical)) }
    var focused by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current

    // Keep in step with slider / stepper changes, but never fight the keyboard.
    LaunchedEffect(canonical, focused) {
        if (!focused && field.text != canonical) field = TextFieldValue(canonical)
    }

    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(Color.White.copy(alpha = 0.12f))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        BasicTextField(
            value = field,
            onValueChange = { next ->
                field = next
                onTyped(next.text)
            },
            singleLine = true,
            textStyle = TextStyle(
                color = Color.White,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.End,
            ),
            cursorBrush = SolidColor(BoundaryBlue),
            keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
            modifier = Modifier
                .width(66.dp)
                .onFocusChanged { st ->
                    if (st.isFocused && !focused) {
                        // Select the current value so it can be typed straight over.
                        field = field.copy(selection = TextRange(0, field.text.length))
                    }
                    focused = st.isFocused
                },
        )
        if (suffix != null) {
            Text(suffix, color = Color.White.copy(alpha = 0.6f), fontSize = 13.sp)
        }
    }
}

@Composable
private fun SliderStrip(
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    onMinus: () -> Unit,
    onPlus: () -> Unit,
    onChange: (Float) -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        CircleIcon(Icons.AutoMirrored.Filled.ArrowBack, "Decrease", onMinus)
        Slider(
            value = value.coerceIn(range.start, range.endInclusive),
            onValueChange = onChange,
            valueRange = range,
            modifier = Modifier.weight(1f).heightIn(max = 28.dp),
            colors = SliderDefaults.colors(
                thumbColor = Color.White,
                activeTrackColor = BoundaryBlue,
                inactiveTrackColor = Color.White.copy(alpha = 0.2f),
            ),
        )
        CircleIcon(Icons.AutoMirrored.Filled.ArrowForward, "Increase", onPlus)
    }
}

@Composable
private fun Stepper(onMinus: () -> Unit, onPlus: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CircleIcon(Icons.Filled.Remove, "Decrease", onMinus)
        CircleIcon(Icons.Filled.Add, "Increase", onPlus)
    }
}

@Composable
private fun NumberEnd(label: String, number: Int, modifier: Modifier = Modifier) {
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, color = Color.White.copy(alpha = 0.6f), fontSize = 11.sp)
        Text("Row $number", color = BoundaryBlue, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun CircleIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, cd: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier.size(32.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f)).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = cd, tint = BoundaryBlue, modifier = Modifier.size(17.dp))
    }
}

@Composable
private fun DarkDivider() {
    Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(Color.White.copy(alpha = 0.12f)))
}

/** Numbered, draggable boundary vertex. Deliberately larger than a midpoint. */
@Composable
private fun PointHandle(number: Int) {
    Box(
        modifier = Modifier
            .size(28.dp)
            .clip(CircleShape)
            .background(Color.White)
            .padding(2.dp)
            .clip(CircleShape)
            .background(BoundaryBlue),
        contentAlignment = Alignment.Center,
    ) {
        Text("$number", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
    }
}

/**
 * Midpoint insertion control — a small circular ⊕, never a location pin, and
 * visibly smaller than a numbered vertex. The transparent ring around it keeps
 * the touch target comfortable.
 */
@Composable
private fun MidpointHandle() {
    Box(
        modifier = Modifier.size(30.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(16.dp)
                .clip(CircleShape)
                .background(Color(0xE60A84FF))
                .border(1.dp, Color.White, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.Add,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(11.dp),
            )
        }
    }
}

/** Equirectangular polygon area in hectares (matches Paddock.areaHectares). */
private fun polygonAreaHectares(points: List<CoordinatePoint>): Double {
    if (points.size < 3) return 0.0
    val centroidLat = points.sumOf { it.latitude } / points.size
    val mPerDegLat = 111_320.0
    val mPerDegLon = 111_320.0 * cos(centroidLat * Math.PI / 180.0)
    var area = 0.0
    val n = points.size
    for (i in 0 until n) {
        val j = (i + 1) % n
        val xi = points[i].longitude * mPerDegLon
        val yi = points[i].latitude * mPerDegLat
        val xj = points[j].longitude * mPerDegLon
        val yj = points[j].latitude * mPerDegLat
        area += xi * yj - xj * yi
    }
    return abs(area) / 2.0 / 10_000.0
}

/** Total laid-out row length in metres for the current preview (block summary). */
internal fun previewTotalRowLength(points: List<CoordinatePoint>, direction: Double, count: Int, width: Double, offset: Double): Double {
    val lines = calculateRowLines(points, direction, count, width, offset)
    if (lines.isEmpty()) return 0.0
    val centroidLat = if (points.isEmpty()) 0.0 else points.sumOf { it.latitude } / points.size
    val mPerDegLat = 111_320.0
    val mPerDegLon = 111_320.0 * cos(centroidLat * Math.PI / 180.0)
    return lines.sumOf { line ->
        val dLat = (line.end.latitude - line.start.latitude) * mPerDegLat
        val dLon = (line.end.longitude - line.start.longitude) * mPerDegLon
        sqrt(dLat * dLat + dLon * dLon)
    }
}

internal fun previewAreaHectares(points: List<CoordinatePoint>): Double = polygonAreaHectares(points)
