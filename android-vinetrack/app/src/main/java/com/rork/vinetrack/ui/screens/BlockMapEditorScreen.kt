package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerComposable
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.google.maps.android.compose.rememberMarkerState
import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.calculateRowLines
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.ui.components.MapMyLocationButton
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sqrt

private val BoundaryBlue = Color(0xFF0A84FF)
private val BoundaryAmber = Color(0xFFFF9500)

private enum class EditorMode { Boundary, Rows }

/**
 * Immersive, fullscreen boundary + row-layout editor — the Android parity for
 * the iOS `BoundaryMapEditor` + `RowConfigMapOverlay`. A segmented control
 * switches between drawing the block boundary (tap to add, drag numbered
 * handles to move, tap the dashed midpoints to insert) and configuring rows
 * (direction / count / spacing / shift / numbering) with a live row preview.
 *
 * Operates directly on the shared [boundary] handle list so edits persist back
 * into the parent [EditBlockScreen] form, and surfaces row config through value
 * + setter pairs.
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
) {
    var mode by remember { mutableStateOf(EditorMode.Boundary) }
    var showTip by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    val camera = rememberCameraPositionState()
    var mapLoaded by remember { mutableStateOf(false) }
    var framed by remember { mutableStateOf(false) }
    val context = LocalContext.current
    var hasLocationPerm by remember { mutableStateOf(LocationTracker(context).hasPermission) }
    var locationMessage by remember { mutableStateOf<String?>(null) }

    val statusTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val navBottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()

    // Frame only after the map has a measured size — a bounds update on an
    // unmeasured map fails silently and leaves the camera at 0,0.
    LaunchedEffect(mapLoaded) {
        if (!mapLoaded || framed) return@LaunchedEffect
        val pts = boundary.map { it.position }
        if (pts.isNotEmpty()) {
            camera.fitToContent(points = pts, paddingPx = 140, singlePointZoom = 18f)
        } else if (vineyardCenter != null) {
            camera.fitToContent(points = listOf(vineyardCenter), singlePointZoom = 16f)
        }
        framed = true
    }

    val polyCoords by remember {
        derivedStateOf { boundary.map { CoordinatePoint(it.position.latitude, it.position.longitude) } }
    }
    val rowLines by remember {
        derivedStateOf { calculateRowLines(polyCoords, rowDirection, rowCount, rowWidth, rowOffset) }
    }
    val areaHa by remember { derivedStateOf { polygonAreaHectares(polyCoords) } }

    Box(modifier = modifier.fillMaxSize().background(Color.Black)) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = camera,
            properties = MapProperties(mapType = MapType.HYBRID, isMyLocationEnabled = hasLocationPerm),
            uiSettings = MapUiSettings(
                zoomControlsEnabled = false,
                mapToolbarEnabled = false,
                compassEnabled = false,
                myLocationButtonEnabled = false,
                tiltGesturesEnabled = false,
                rotationGesturesEnabled = false,
            ),
            onMapClick = { latLng ->
                if (mode == EditorMode.Boundary) boundary.add(MarkerState(latLng))
            },
            onMapLoaded = { mapLoaded = true },
        ) {
            // Context: other blocks already mapped in this vineyard.
            otherBlocks.forEach { other ->
                val pts = other.polygonPoints
                if (pts != null && pts.size > 2) {
                    Polygon(
                        points = pts.map { LatLng(it.latitude, it.longitude) },
                        fillColor = BoundaryAmber.copy(alpha = 0.10f),
                        strokeColor = BoundaryAmber.copy(alpha = 0.7f),
                        strokeWidth = 2f,
                    )
                }
            }

            val poly = boundary.map { it.position }
            if (poly.size >= 3) {
                Polygon(
                    points = poly,
                    fillColor = BoundaryBlue.copy(alpha = 0.15f),
                    strokeColor = BoundaryBlue,
                    strokeWidth = 3f,
                )
            } else if (poly.size == 2) {
                Polyline(points = poly, color = BoundaryBlue, width = 3f)
            }

            // Row lines preview (first/last highlighted).
            rowLines.forEachIndexed { index, line ->
                val isEdge = index == 0 || index == rowLines.lastIndex
                Polyline(
                    points = listOf(
                        LatLng(line.start.latitude, line.start.longitude),
                        LatLng(line.end.latitude, line.end.longitude),
                    ),
                    color = if (isEdge) Color(0xFF34C759) else Color.White.copy(alpha = 0.75f),
                    width = if (isEdge) 4f else 2f,
                )
            }

            if (mode == EditorMode.Boundary) {
                // Draggable numbered point handles.
                boundary.forEachIndexed { index, ms ->
                    key(index, ms) {
                        MarkerComposable(
                            state = ms,
                            draggable = true,
                            anchor = androidx.compose.ui.geometry.Offset(0.5f, 0.5f),
                        ) {
                            PointHandle(index + 1)
                        }
                    }
                }
                // Dashed midpoint insert handles.
                midpoints(poly).forEach { mp ->
                    key("mid-${mp.insertIndex}-${mp.point.latitude}-${mp.point.longitude}") {
                        val mState = rememberMarkerState(position = mp.point)
                        Marker(
                            state = mState,
                            alpha = 0.9f,
                            onClick = {
                                boundary.add(mp.insertIndex, MarkerState(mp.point))
                                true
                            },
                            icon = com.google.android.gms.maps.model.BitmapDescriptorFactory
                                .defaultMarker(com.google.android.gms.maps.model.BitmapDescriptorFactory.HUE_AZURE),
                        )
                    }
                }
            }
        }

        // Top chrome: close + segmented control.
        Column(
            modifier = Modifier.fillMaxWidth().padding(top = statusTop + 8.dp, start = 12.dp, end = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                GlassCircleButton(Icons.Filled.Close, "Done", onClick = onDone)
                Spacer(Modifier.weight(1f))
                SegmentedToggle(mode = mode, onChange = { mode = it })
                Spacer(Modifier.weight(1f))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    MapMyLocationButton(
                        camera = camera,
                        onMessage = { locationMessage = it },
                        onPermissionGranted = { hasLocationPerm = true },
                    )
                    GlassCircleButton(Icons.Filled.GpsFixed, "Recenter") {
                        scope.launch {
                            val pts = boundary.map { it.position }
                            if (pts.isNotEmpty()) {
                                camera.fitToContent(points = pts, paddingPx = 140, singlePointZoom = 18f, animate = true)
                            } else if (vineyardCenter != null) {
                                camera.fitToContent(points = listOf(vineyardCenter), singlePointZoom = 16f, animate = true)
                            }
                        }
                    }
                }
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
                visible = showTip && mode == EditorMode.Boundary,
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
                        "Place boundary points between the rows, not on top of vines, for the most accurate row and area calculations.",
                        color = Color.White, fontSize = 12.sp, modifier = Modifier.weight(1f),
                    )
                    Icon(
                        Icons.Filled.Close, contentDescription = "Dismiss tip", tint = Color.White.copy(alpha = 0.6f),
                        modifier = Modifier.size(18.dp).clip(CircleShape).clickable { showTip = false },
                    )
                }
            }
        }

        // Bottom controls.
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(start = 12.dp, end = 12.dp, bottom = navBottom + 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (mode == EditorMode.Boundary) {
                BoundaryControls(
                    pointCount = boundary.size,
                    areaHa = areaHa,
                    onAddCenter = { boundary.add(MarkerState(camera.position.target)) },
                    onUndo = { if (boundary.isNotEmpty()) boundary.removeAt(boundary.lastIndex) },
                    onClear = { boundary.clear() },
                )
            } else {
                RowControlPanel(
                    hasBoundary = boundary.size >= 3,
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

    LaunchedEffect(mode) {
        if (mode == EditorMode.Rows) showTip = false
    }
}

@Composable
private fun SegmentedToggle(mode: EditorMode, onChange: (EditorMode) -> Unit) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0xCC1C1C1E))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        SegmentChip("Boundary", mode == EditorMode.Boundary) { onChange(EditorMode.Boundary) }
        SegmentChip("Rows", mode == EditorMode.Rows) { onChange(EditorMode.Rows) }
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
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(Color(0xCC1C1C1E))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = Color.White, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun BoundaryControls(
    pointCount: Int,
    areaHa: Double,
    onAddCenter: () -> Unit,
    onUndo: () -> Unit,
    onClear: () -> Unit,
) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0xE61C1C1E))
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                buildString {
                    append("$pointCount point").append(if (pointCount == 1) "" else "s")
                    if (areaHa > 0) append("  ·  %.2f ha".format(areaHa))
                },
                color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PillButton("Add at Center", Icons.Filled.Add, filled = true, onClick = onAddCenter)
                PillButton("Undo", Icons.Filled.Undo, enabled = pointCount > 0, onClick = onUndo)
                PillButton("Clear", Icons.Filled.Delete, destructive = true, enabled = pointCount > 0, onClick = onClear)
            }
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
        filled -> Color.White
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

@Composable
private fun RowControlPanel(
    hasBoundary: Boolean,
    rowDirection: Double, onRowDirection: (Double) -> Unit,
    rowCount: Int, onRowCount: (Int) -> Unit,
    rowWidth: Double, onRowWidth: (Double) -> Unit,
    rowOffset: Double, onRowOffset: (Double) -> Unit,
    rowStartNumber: Int, onRowStartNumber: (Int) -> Unit,
    rowAscending: Boolean, onRowAscending: (Boolean) -> Unit,
) {
    val firstNum = if (rowAscending) rowStartNumber else rowStartNumber + maxOf(rowCount - 1, 0)
    val lastNum = if (rowAscending) rowStartNumber + maxOf(rowCount - 1, 0) else rowStartNumber
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(Color(0xF21C1C1E))
            .padding(16.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (!hasBoundary) {
                Text(
                    "Draw a boundary with at least 3 points to preview rows.",
                    color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp,
                )
            }
            // Direction
            DarkSliderRow(
                label = "Direction",
                value = "${"%.1f".format(rowDirection)}°",
                sliderValue = rowDirection.toFloat(),
                range = 0f..360f,
                onMinus = { onRowDirection(maxOf(0.0, rowDirection - 0.5)) },
                onPlus = { onRowDirection(minOf(360.0, rowDirection + 0.5)) },
                onChange = { onRowDirection(it.toDouble()) },
            )
            DarkDivider()
            // Row count stepper
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Rows", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                StepperControl(
                    value = rowCount,
                    onMinus = { if (rowCount > 0) onRowCount(rowCount - 1) },
                    onPlus = { if (rowCount < 500) onRowCount(rowCount + 1) },
                )
            }
            DarkDivider()
            DarkSliderRow(
                label = "Row Width",
                value = "%.1f m".format(rowWidth),
                sliderValue = rowWidth.toFloat(),
                range = 0f..4f,
                onMinus = { onRowWidth(maxOf(0.0, rowWidth - 0.1)) },
                onPlus = { onRowWidth(minOf(4.0, rowWidth + 0.1)) },
                onChange = { onRowWidth(it.toDouble()) },
            )
            DarkDivider()
            DarkSliderRow(
                label = "Shift Rows",
                value = "%.1f m".format(rowOffset),
                sliderValue = rowOffset.toFloat(),
                range = -50f..50f,
                onMinus = { onRowOffset(rowOffset - 0.5) },
                onPlus = { onRowOffset(rowOffset + 0.5) },
                onChange = { onRowOffset(it.toDouble()) },
                trailing = {
                    Text(
                        "Reset",
                        color = if (rowOffset != 0.0) BoundaryBlue else Color.White.copy(alpha = 0.3f),
                        fontSize = 12.sp,
                        modifier = Modifier.clickable(enabled = rowOffset != 0.0) { onRowOffset(0.0) },
                    )
                },
            )
            if (rowCount > 0) {
                DarkDivider()
                // Row numbering
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Start number", color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
                    StepperControl(
                        value = rowStartNumber,
                        onMinus = { if (rowStartNumber > 1) onRowStartNumber(rowStartNumber - 1) },
                        onPlus = { if (rowStartNumber < 9999) onRowStartNumber(rowStartNumber + 1) },
                    )
                }
                // Row 1 position picker (left/right)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.White.copy(alpha = 0.08f))
                        .clickable { onRowAscending(!rowAscending) }
                        .padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    NumberEnd("Left", firstNum, Modifier.weight(1f))
                    Box(
                        modifier = Modifier.size(36.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Filled.SwapHoriz, contentDescription = "Swap row direction", tint = BoundaryBlue, modifier = Modifier.size(20.dp))
                    }
                    NumberEnd("Right", lastNum, Modifier.weight(1f))
                }
            }
        }
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
private fun StepperControl(value: Int, onMinus: () -> Unit, onPlus: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        CircleIcon(Icons.Filled.Remove, "Decrease", onMinus)
        Text("$value", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(44.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        CircleIcon(Icons.Filled.Add, "Increase", onPlus)
    }
}

@Composable
private fun CircleIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, cd: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier.size(34.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f)).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = cd, tint = BoundaryBlue, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun DarkSliderRow(
    label: String,
    value: String,
    sliderValue: Float,
    range: ClosedFloatingPointRange<Float>,
    onMinus: () -> Unit,
    onPlus: () -> Unit,
    onChange: (Float) -> Unit,
    trailing: (@Composable () -> Unit)? = null,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
            Text(value, color = BoundaryBlue, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            if (trailing != null) {
                Spacer(Modifier.width(12.dp))
                trailing()
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CircleIcon(Icons.AutoMirrored.Filled.ArrowBack, "Decrease", onMinus)
            Slider(
                value = sliderValue.coerceIn(range.start, range.endInclusive),
                onValueChange = onChange,
                valueRange = range,
                modifier = Modifier.weight(1f),
                colors = SliderDefaults.colors(
                    thumbColor = Color.White,
                    activeTrackColor = BoundaryBlue,
                    inactiveTrackColor = Color.White.copy(alpha = 0.2f),
                ),
            )
            CircleIcon(Icons.AutoMirrored.Filled.ArrowForward, "Increase", onPlus)
        }
    }
}

@Composable
private fun DarkDivider() {
    Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(Color.White.copy(alpha = 0.12f)))
}

@Composable
private fun PointHandle(number: Int) {
    Box(
        modifier = Modifier.size(26.dp).clip(CircleShape).background(BoundaryBlue),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier.size(22.dp).clip(CircleShape).background(BoundaryBlue),
            contentAlignment = Alignment.Center,
        ) {
            Text("$number", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
    }
}

private data class Midpoint(val point: LatLng, val insertIndex: Int)

/** Edge midpoints for insert handles (includes the closing edge when >= 3 points). */
private fun midpoints(points: List<LatLng>): List<Midpoint> {
    if (points.size < 2) return emptyList()
    val out = mutableListOf<Midpoint>()
    val n = points.size
    for (i in 0 until n) {
        val j = (i + 1) % n
        if (j == 0 && n < 3) continue
        val a = points[i]
        val b = points[j]
        out.add(
            Midpoint(
                LatLng((a.latitude + b.latitude) / 2.0, (a.longitude + b.longitude) / 2.0),
                i + 1,
            ),
        )
    }
    return out
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
