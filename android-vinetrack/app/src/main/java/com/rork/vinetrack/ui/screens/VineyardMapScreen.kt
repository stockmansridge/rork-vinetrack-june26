package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Label
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.rork.vinetrack.data.MapDefaults
import com.rork.vinetrack.data.MapStyle
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.components.isValidMapCoordinate
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.MapsComposeExperimentalApi
import com.google.maps.android.compose.MarkerComposable
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import kotlinx.coroutines.launch

/** Customer-facing map display modes for the overview map. */
private enum class MapMode { TopDown, Overview }

/** 3D Overview camera tilt in degrees (top-down uses 0). */
private const val OVERVIEW_TILT = 50f

/**
 * Below this zoom level block-name chips are hidden to keep the map readable
 * and avoid rendering many label composables when zoomed out across a region.
 */
private const val LABEL_MIN_ZOOM = 13.5f

/** iOS-style amber used for block boundaries and name chips over satellite imagery. */
private val BlockAmber = Color(0xFFFF9500)

private fun MapStyle.toMapType(): MapType = when (this) {
    MapStyle.Hybrid -> MapType.HYBRID
    MapStyle.Satellite -> MapType.SATELLITE
    MapStyle.Normal -> MapType.NORMAL
    MapStyle.Terrain -> MapType.TERRAIN
}

private fun CoordinatePoint.toLatLng(): LatLng = LatLng(latitude, longitude)

/** Centroid of a block polygon, used to anchor its name label. */
private fun Paddock.centroid(): LatLng? {
    val pts = polygonPoints ?: return null
    if (pts.isEmpty()) return null
    val lat = pts.sumOf { it.latitude } / pts.size
    val lng = pts.sumOf { it.longitude } / pts.size
    return LatLng(lat, lng)
}

private fun Pin.latLng(): LatLng? {
    val lat = latitude ?: return null
    val lng = longitude ?: return null
    if (!isValidMapCoordinate(lat, lng)) return null
    return LatLng(lat, lng)
}

/**
 * Full-screen vineyard overview map mirroring the iOS dashboard map: hybrid
 * (satellite) imagery, block boundary polygons with name labels, row lines and
 * pins. Includes a customer-facing Top-down / 3D Overview display control.
 * Read-only — switching modes performs no database writes.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VineyardMapScreen(
    state: AppUiState,
    modifier: Modifier = Modifier,
    defaults: MapDefaults = MapDefaults.factory,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Vineyard Map") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        VineyardMapContent(
            state = state,
            pins = state.pins,
            defaults = defaults,
            modifier = Modifier.fillMaxSize().padding(padding),
        )
    }
}

/**
 * Reusable vineyard map surface (no scaffold/top bar) so it can be embedded both
 * as the standalone Vineyard Map and as the Pins tab's Map view mode. Renders the
 * given [pins] over satellite imagery with block boundaries, row lines and labels.
 * Read-only — switching display modes performs no database writes. When
 * [onPinClick] is supplied, tapping a pin marker centres it in the upper half of
 * the map (so a bottom detail sheet never hides it) and invokes the callback;
 * otherwise the marker shows its default info-window callout.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VineyardMapContent(
    state: AppUiState,
    pins: List<Pin>,
    modifier: Modifier = Modifier,
    defaults: MapDefaults = MapDefaults.factory,
    onPinClick: ((Pin) -> Unit)? = null,
) {
    val scope = rememberCoroutineScope()

    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }
    val locatedPins = remember(pins) { pins.filter { it.latLng() != null } }
    // Resolve each pin's configured colour (iOS nameColorMap parity).
    val colorMap = remember(state.repairButtons, state.growthButtons) { pinColorMap(state) }

    // Points that frame the mapped content: pins first, then block geometry,
    // then the vineyard's saved location as a last resort (iOS parity).
    val framePoints = remember(blocks, locatedPins, state.selectedVineyard) {
        val pinPoints = locatedPins.mapNotNull { it.latLng() }
        if (pinPoints.isNotEmpty()) return@remember pinPoints
        val geometry = blocks.flatMap { block ->
            (block.polygonPoints ?: emptyList())
                .filter { isValidMapCoordinate(it.latitude, it.longitude) }
                .map { it.toLatLng() }
        }
        if (geometry.isNotEmpty()) return@remember geometry
        val v = state.selectedVineyard
        if (isValidMapCoordinate(v?.latitude, v?.longitude)) {
            listOf(LatLng(v?.latitude ?: 0.0, v?.longitude ?: 0.0))
        } else {
            emptyList()
        }
    }

    val cameraPositionState = rememberCameraPositionState()
    var mode by remember { mutableStateOf(if (defaults.overview3D) MapMode.Overview else MapMode.TopDown) }
    var mapLoaded by remember { mutableStateOf(false) }
    var hasFramed by remember { mutableStateOf(false) }
    // Measured map size, used to keep a tapped pin visible above the detail sheet.
    var mapSizePx by remember { mutableStateOf(IntSize.Zero) }

    // Session-only overlay visibility, seeded from persisted Settings defaults.
    // Toggling here affects only the current map session (no writes to MapPrefsStore).
    var showPins by remember(defaults.showPins) { mutableStateOf(defaults.showPins) }
    var showRowLines by remember(defaults.showRowLines) { mutableStateOf(defaults.showRowLines) }
    var showBlockLabels by remember(defaults.showBlockLabels) { mutableStateOf(defaults.showBlockLabels) }

    // Frame the content once the map is laid out, and re-frame when the
    // mapped content changes (vineyard switch, pin filters, data arriving
    // after the map loaded). User pans never trigger this — it is keyed only
    // on the content, not the camera.
    LaunchedEffect(mapLoaded, framePoints) {
        if (!mapLoaded || framePoints.isEmpty()) return@LaunchedEffect
        cameraPositionState.fitToContent(
            points = framePoints,
            paddingPx = 120,
            singlePointZoom = 17f,
            animate = hasFramed,
        )
        hasFramed = true
    }

    // Re-apply tilt whenever the mode changes, preserving centre and zoom.
    LaunchedEffect(mode, hasFramed) {
        if (!hasFramed) return@LaunchedEffect
        val current = cameraPositionState.position
        val target = CameraPosition.Builder()
            .target(current.target)
            .zoom(current.zoom)
            .bearing(current.bearing)
            .tilt(if (mode == MapMode.Overview) OVERVIEW_TILT else 0f)
            .build()
        scope.launch {
            runCatching {
                cameraPositionState.animate(CameraUpdateFactory.newCameraPosition(target), 600)
            }
        }
    }

    if (framePoints.isEmpty()) {
        Box(modifier.padding(16.dp), contentAlignment = Alignment.Center) {
            EmptyState(
                icon = Icons.Filled.Map,
                title = "Nothing to map yet",
                message = "Map blocks and drop pins on the web portal or iOS app and they'll appear here over satellite imagery.",
            )
        }
        return
    }

    Box(modifier) {
        GoogleMap(
                modifier = Modifier.fillMaxSize().onSizeChanged { mapSizePx = it },
                cameraPositionState = cameraPositionState,
                properties = MapProperties(mapType = defaults.style.toMapType()),
                uiSettings = MapUiSettings(
                    zoomControlsEnabled = false,
                    mapToolbarEnabled = false,
                    tiltGesturesEnabled = true,
                    rotationGesturesEnabled = true,
                ),
                onMapLoaded = { mapLoaded = true },
            ) {
                // Hide labels when zoomed out to keep the map readable and cheap.
                // derivedStateOf only flips the markers when crossing the threshold.
                val labelsVisible by remember {
                    derivedStateOf {
                        cameraPositionState.position.zoom >= LABEL_MIN_ZOOM
                    }
                }

                // Block boundaries
                blocks.forEach { block ->
                    val poly = block.polygonPoints?.map { it.toLatLng() } ?: emptyList()
                    if (poly.size >= 3) {
                        Polygon(
                            points = poly,
                            fillColor = BlockAmber.copy(alpha = 0.08f),
                            strokeColor = BlockAmber,
                            strokeWidth = 3f,
                            // Vineyard layout sits at the very back; labels (1f)
                            // and pins (2f) always read in front.
                            zIndex = 0f,
                        )
                    }
                    // Row lines
                    if (showRowLines) block.rows?.forEach { row ->
                        val s = row.startPoint
                        val e = row.endPoint
                        if (s != null && e != null) {
                            Polyline(
                                points = listOf(s.toLatLng(), e.toLatLng()),
                                color = Color.White.copy(alpha = 0.55f),
                                width = 2f,
                                zIndex = 0f,
                            )
                        }
                    }
                    // Always-visible block-name chip (iOS parity). Tapping still
                    // surfaces the name + area/rows callout via title/snippet.
                    if (showBlockLabels && labelsVisible) block.centroid()?.let { center ->
                        BlockLabelMarker(block = block, position = center)
                    }
                }

                // Pins — rendered in their actual configured colour (iOS parity)
                // and stacked above block labels/boundaries via zIndex so they
                // always read in the foreground.
                if (showPins) locatedPins.forEach { pin ->
                    pin.latLng()?.let { position ->
                        val sync = state.pinSyncState(pin.id)
                        // Echo the attached row/path/side on its own line (the
                        // list/detail already show this), then notes + sync state.
                        val statusLine = listOfNotNull(
                            pin.notes?.takeIf { it.isNotBlank() },
                            sync.primaryLabel,
                        ).joinToString(" · ").takeIf { it.isNotBlank() }
                        val snippet = listOfNotNull(
                            pin.rowAttachmentLabel,
                            statusLine,
                        ).joinToString("\n").takeIf { it.isNotBlank() }
                        PinMapMarker(
                            pin = pin,
                            position = position,
                            color = pinColor(pin, colorMap),
                            snippet = snippet,
                            faded = sync.hasAny,
                            onPinClick = onPinClick?.let { cb ->
                                { tapped: Pin ->
                                    // Keep the tapped pin visible above the bottom
                                    // detail sheet: centre it at the current zoom,
                                    // then nudge the camera down-screen so the pin
                                    // sits in the upper half of the map. No zoom
                                    // change, no jump.
                                    scope.launch {
                                        runCatching {
                                            cameraPositionState.animate(
                                                CameraUpdateFactory.newLatLng(position),
                                                300,
                                            )
                                            if (mapSizePx.height > 0) {
                                                cameraPositionState.animate(
                                                    CameraUpdateFactory.scrollBy(0f, mapSizePx.height * 0.18f),
                                                    200,
                                                )
                                            }
                                        }
                                    }
                                    cb(tapped)
                                }
                            },
                        )
                    }
                }
            }

            ModeControl(
                mode = mode,
                onChange = { mode = it },
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 12.dp),
            )

            OverlayControls(
                showPins = showPins,
                showRowLines = showRowLines,
                showBlockLabels = showBlockLabels,
                onTogglePins = { showPins = !showPins },
                onToggleRowLines = { showRowLines = !showRowLines },
                onToggleBlockLabels = { showBlockLabels = !showBlockLabels },
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(start = 12.dp, bottom = 16.dp),
            )

            // Re-centre on the mapped content after a manual pan/zoom.
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 12.dp, bottom = 16.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.55f))
                    .clickable {
                        scope.launch {
                            cameraPositionState.fitToContent(
                                points = framePoints,
                                paddingPx = 120,
                                singlePointZoom = 17f,
                                animate = true,
                            )
                        }
                    }
                    .padding(11.dp),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.GpsFixed,
                    contentDescription = "Re-centre map",
                    tint = Color.White,
                    modifier = Modifier.size(20.dp),
                )
            }

            // Helpful note if no Maps key is configured for this build.
            AnimatedVisibility(
                visible = com.rork.vinetrack.BuildConfig.MAPS_API_KEY.isBlank(),
                enter = fadeIn(),
                exit = fadeOut(),
                modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp),
            ) {
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.Black.copy(alpha = 0.7f))
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                ) {
                    Text(
                        "Map imagery needs a Google Maps key for this build.",
                        color = Color.White,
                        fontSize = 12.sp,
                    )
                }
            }
        }
}

private fun blockSubtitle(block: Paddock): String? {
    val parts = mutableListOf<String>()
    if (block.areaHectares > 0) parts.add("${"%.2f".format(block.areaHectares)} ha")
    if (block.rowCount > 0) parts.add("${block.rowCount} rows")
    return parts.joinToString(" · ").takeIf { it.isNotBlank() }
}

/**
 * Compact always-visible block-name chip rendered as a map marker (iOS parity).
 * Tapping still shows the standard name + area/rows callout via title/snippet.
 */
@OptIn(MapsComposeExperimentalApi::class)
@Composable
private fun BlockLabelMarker(block: Paddock, position: LatLng) {
    val markerState = remember(position) { MarkerState(position = position) }
    MarkerComposable(
        keys = arrayOf(block.id, block.name, block.rowCount.toString()),
        state = markerState,
        title = block.name,
        snippet = blockSubtitle(block),
        anchor = Offset(0.5f, 0.5f),
        zIndex = 1f,
    ) {
        // Two-line chip (name over "N rows"), matching the iOS map annotation.
        Column(
            modifier = Modifier
                .clip(RoundedCornerShape(6.dp))
                .background(BlockAmber.copy(alpha = 0.85f))
                .padding(horizontal = 8.dp, vertical = 3.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                block.name,
                color = Color.White,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
            if (block.rowCount > 0) {
                Text(
                    "${block.rowCount} rows",
                    color = Color.White,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                )
            }
        }
    }
}

/**
 * A vineyard pin rendered in its actual configured colour as a circular marker
 * (iOS `PinsMapView` parity): a coloured disc with a white ring, a tick when the
 * pin is completed, otherwise a small inner dot. Stacked above block labels and
 * boundaries via zIndex so pins always read in the foreground.
 */
@OptIn(MapsComposeExperimentalApi::class)
@Composable
private fun PinMapMarker(
    pin: Pin,
    position: LatLng,
    color: Color,
    snippet: String?,
    faded: Boolean,
    onPinClick: ((Pin) -> Unit)?,
) {
    val markerState = remember(position) { MarkerState(position = position) }
    MarkerComposable(
        keys = arrayOf(pin.id, pin.isCompleted.toString(), color.value.toString(), faded.toString()),
        state = markerState,
        title = pin.displayTitle,
        snippet = snippet,
        anchor = Offset(0.5f, 0.5f),
        alpha = if (faded) 0.8f else 1f,
        zIndex = 2f,
        onClick = {
            val cb = onPinClick
            if (cb != null) {
                cb(pin)
                true
            } else {
                false
            }
        },
    ) {
        // Solid colour disc with a subtle vertical gradient, matching the iOS
        // `Circle().fill(color.gradient)` pin marker (no heavy outer ring).
        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(
                    Brush.verticalGradient(
                        listOf(color, color.copy(alpha = 0.82f)),
                    ),
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (pin.isCompleted) {
                Icon(Icons.Filled.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(15.dp))
            } else {
                Box(Modifier.size(10.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.4f)))
            }
        }
    }
}

@Composable
private fun OverlayControls(
    showPins: Boolean,
    showRowLines: Boolean,
    showBlockLabels: Boolean,
    onTogglePins: () -> Unit,
    onToggleRowLines: () -> Unit,
    onToggleBlockLabels: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(22.dp))
            .background(Color.Black.copy(alpha = 0.55f))
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        OverlayChip(Icons.Filled.PushPin, "Pins", showPins, onTogglePins)
        OverlayChip(Icons.Filled.Timeline, "Rows", showRowLines, onToggleRowLines)
        OverlayChip(Icons.AutoMirrored.Filled.Label, "Labels", showBlockLabels, onToggleBlockLabels)
    }
}

@Composable
private fun OverlayChip(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(18.dp))
            .background(if (selected) VineColors.LeafGreen else Color.Transparent)
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = if (selected) Color.White else Color.White.copy(alpha = 0.8f),
            modifier = Modifier.size(16.dp),
        )
        Text(
            label,
            color = if (selected) Color.White else Color.White.copy(alpha = 0.8f),
            fontSize = 13.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
        )
    }
}

@Composable
private fun ModeControl(mode: MapMode, onChange: (MapMode) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(22.dp))
            .background(Color.Black.copy(alpha = 0.55f))
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        ModeChip("Top-down", mode == MapMode.TopDown) { onChange(MapMode.TopDown) }
        ModeChip("3D Overview", mode == MapMode.Overview) { onChange(MapMode.Overview) }
    }
}

@Composable
private fun ModeChip(label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(18.dp))
            .background(if (selected) VineColors.LeafGreen else Color.Transparent)
            .clickable { onClick() }
            .padding(horizontal = 16.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            color = if (selected) Color.White else Color.White.copy(alpha = 0.8f),
            fontSize = 13.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
        )
    }
}
