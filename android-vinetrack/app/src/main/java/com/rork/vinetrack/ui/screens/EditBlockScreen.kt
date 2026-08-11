package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.BlockRowLayout
import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.RowInput
import com.rork.vinetrack.data.RowNumbering
import com.rork.vinetrack.data.blockRowLayout
import com.rork.vinetrack.data.model.CloneRootstockOptions
import com.rork.vinetrack.data.model.CloneRootstockSentinels
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.data.model.VineyardCloneRow
import com.rork.vinetrack.data.model.VineyardRootstockRow
import com.rork.vinetrack.data.normaliseRowDirection
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BlockBoundaryOverlay
import com.rork.vinetrack.ui.components.BlockRowLabelsOverlay
import com.rork.vinetrack.ui.components.BlockRowLinesOverlay
import com.rork.vinetrack.ui.components.MapMyLocationButton
import com.rork.vinetrack.ui.components.OverZoomSatelliteLayer
import com.rork.vinetrack.ui.components.SATELLITE_IMAGERY_ATTRIBUTION
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.Instant
import kotlinx.coroutines.delay


/**
 * Create / edit a block (paddock), mirroring the iOS `EditPaddockSheet`: name,
 * a map-based boundary editor (tap to add, drag to move, tap a point to remove),
 * row configuration that regenerates row lines via [calculateRowLines], vine &
 * irrigation setup, variety allocations, phenology dates, GDD overrides, and
 * override fields. Saving upserts the full row through the same `paddocks`
 * contract iOS uses.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditBlockScreen(
    vm: AppViewModel,
    state: AppUiState,
    existing: Paddock?,
    modifier: Modifier = Modifier,
    onDone: () -> Unit,
) {
    val vine = LocalVineColors.current

    var name by remember { mutableStateOf(existing?.name ?: "") }
    val boundary = remember {
        mutableStateListOf<MarkerState>().apply {
            existing?.polygonPoints?.forEach { add(MarkerState(LatLng(it.latitude, it.longitude))) }
        }
    }
    // A saved direction of e.g. 204.8° describes the same parallel lines as
    // 24.8°, so it is normalised on load — the layout is unchanged on screen and
    // the canonical value is what gets written on the next save.
    var rowDirection by remember { mutableStateOf(normaliseRowDirection(existing?.rowDirection ?: 0.0)) }
    var rowCount by remember { mutableStateOf(existing?.rowCount ?: 0) }
    var rowWidth by remember { mutableStateOf(existing?.rowWidth ?: 2.5) }
    var rowOffset by remember { mutableStateOf(existing?.rowOffset ?: 0.0) }
    // Recover the numbering the block was saved with so reopening it reproduces
    // the same first/last labels instead of silently resetting to 1.
    val savedNumbering = remember(existing?.id) {
        RowNumbering.fromSavedRows(existing?.rows?.map { it.number } ?: emptyList())
    }
    var rowStartNumber by remember { mutableStateOf(savedNumbering.startNumber) }
    var rowAscending by remember { mutableStateOf(savedNumbering.ascending) }
    var vineSpacing by remember { mutableStateOf(existing?.vineSpacing ?: 1.0) }
    var postSpacing by remember { mutableStateOf(existing?.intermediatePostSpacing?.let { formatNum(it) } ?: "") }
    var flowPerEmitter by remember { mutableStateOf(existing?.flowPerEmitter?.let { formatNum(it) } ?: "") }
    var emitterSpacing by remember { mutableStateOf(existing?.emitterSpacing?.let { formatNum(it) } ?: "") }
    var vineCountOverride by remember { mutableStateOf(existing?.vineCountOverride?.toString() ?: "") }
    var rowLengthOverride by remember { mutableStateOf(existing?.rowLengthOverride?.let { formatNum(it) } ?: "") }
    var plantingYear by remember { mutableStateOf(existing?.plantingYear?.toString() ?: "") }
    var calcMode by remember { mutableStateOf(existing?.calculationModeOverride) }
    var resetMode by remember { mutableStateOf(existing?.resetModeOverride) }
    val allocations = remember {
        mutableStateListOf<PaddockVarietyAllocation>().apply { existing?.varietyAllocations?.let { addAll(it) } }
    }
    var budburst by remember { mutableStateOf(existing?.budburstDate) }
    var flowering by remember { mutableStateOf(existing?.floweringDate) }
    var veraison by remember { mutableStateOf(existing?.veraisonDate) }
    var harvest by remember { mutableStateOf(existing?.harvestDate) }

    var saving by remember { mutableStateOf(false) }
    var addingVariety by remember { mutableStateOf(false) }
    // Index of the allocation being edited (clone/rootstock/percent) — the
    // same dialog as "Add variety", prefilled. null = no edit in progress.
    var editingAllocationIndex by remember { mutableStateOf<Int?>(null) }
    val error = state.blockEditError

    val canSave by remember { derivedStateOf { name.isNotBlank() && !saving } }

    var editorMode by remember { mutableStateOf<BlockEditorMode?>(null) }
    var showSoilEditor by remember { mutableStateOf(false) }
    val canEditSoil = state.currentRole in setOf("owner", "manager", "supervisor", "operator")

    /** The one canonical layout — the preview and the editor share it exactly. */
    val previewLayout: BlockRowLayout = run {
        val poly by remember {
            derivedStateOf { boundary.map { CoordinatePoint(it.position.latitude, it.position.longitude) } }
        }
        remember(poly, rowDirection, rowCount, rowWidth, rowOffset, rowStartNumber, rowAscending) {
            blockRowLayout(
                polygon = poly,
                direction = rowDirection,
                count = rowCount,
                width = rowWidth,
                offset = rowOffset,
                numbering = RowNumbering(startNumber = rowStartNumber, ascending = rowAscending),
            )
        }
    }

    val openEditorMode = editorMode
    if (openEditorMode != null) {
        BlockMapEditorScreen(
            boundary = boundary,
            otherBlocks = state.paddocks.filter { it.id != existing?.id },
            vineyardCenter = state.selectedVineyard?.let { v ->
                val lat = v.latitude; val lng = v.longitude
                if (lat != null && lng != null) LatLng(lat, lng) else null
            },
            rowDirection = rowDirection, onRowDirection = { rowDirection = it },
            rowCount = rowCount, onRowCount = { rowCount = it },
            rowWidth = rowWidth, onRowWidth = { rowWidth = it },
            rowOffset = rowOffset, onRowOffset = { rowOffset = it },
            rowStartNumber = rowStartNumber, onRowStartNumber = { rowStartNumber = it },
            rowAscending = rowAscending, onRowAscending = { rowAscending = it },
            onDone = { editorMode = null },
            modifier = modifier,
            // Camera state is scoped to this vineyard + block, so reopening a
            // different block never restores the previous block's position.
            cameraKey = "${state.selectedVineyardId ?: "-"}:${existing?.id ?: "new-block"}",
            initialMode = openEditorMode,
        )
        return
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(if (existing == null) "New Block" else "Edit Block", maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = { vm.clearBlockEditError(); onDone() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Cancel")
                    }
                },
                actions = {
                    TextButton(
                        enabled = canSave,
                        onClick = {
                            saving = true
                            val poly = boundary.map { CoordinatePoint(it.position.latitude, it.position.longitude) }
                            vm.savePaddock(
                                existing = existing,
                                name = name.trim(),
                                polygonPoints = poly,
                                rowDirection = rowDirection,
                                rowCount = rowCount,
                                rowWidth = rowWidth,
                                rowOffset = rowOffset,
                                rowStartNumber = rowStartNumber,
                                rowNumberAscending = rowAscending,
                                vineSpacing = vineSpacing,
                                intermediatePostSpacing = postSpacing.toDoubleOrNull(),
                                flowPerEmitter = flowPerEmitter.toDoubleOrNull(),
                                emitterSpacing = emitterSpacing.toDoubleOrNull(),
                                vineCountOverride = vineCountOverride.toIntOrNull(),
                                rowLengthOverride = rowLengthOverride.toDoubleOrNull(),
                                plantingYear = plantingYear.filter { it.isDigit() }.toIntOrNull(),
                                calculationModeOverride = calcMode,
                                resetModeOverride = resetMode,
                                varietyAllocations = allocations.toList(),
                                budburstDate = budburst,
                                floweringDate = flowering,
                                veraisonDate = veraison,
                                harvestDate = harvest,
                            ) { ok ->
                                saving = false
                                if (ok) onDone()
                            }
                        },
                    ) { Text("Save", fontWeight = FontWeight.SemiBold) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            if (error != null) {
                VineyardCard {
                    Text(error, color = VineColors.Destructive, fontSize = 14.sp)
                }
            }

            // Name
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Block Name", onLight = true)
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    placeholder = { Text("e.g. Block A") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            // Immersive full-screen boundary + row editor — the ONE place the
            // boundary and rows can be changed.
            FullMapEditorButton(
                hasBoundary = boundary.size >= 3,
                onClick = { editorMode = BlockEditorMode.Boundary },
            )

            // Read-only preview of the current draft geometry.
            BlockPreviewSection(
                boundary = boundary,
                layout = previewLayout,
                vineyardCenter = state.selectedVineyard?.let { v ->
                    val lat = v.latitude; val lng = v.longitude
                    if (lat != null && lng != null) LatLng(lat, lng) else null
                },
                onEdit = { editorMode = BlockEditorMode.Boundary },
            )

            // Row layout — summary only; editing happens on the full-screen map.
            RowLayoutSummary(
                layout = previewLayout,
                rowCount = rowCount,
                boundaryPoints = boundary.size,
                onEdit = { editorMode = BlockEditorMode.Rows },
            )

            // Live block summary (area, rows, total length, vines)
            run {
                val polyCoords = boundary.map { CoordinatePoint(it.position.latitude, it.position.longitude) }
                val summaryArea = previewAreaHectares(polyCoords)
                val summaryLen = previewTotalRowLength(polyCoords, rowDirection, rowCount, rowWidth, rowOffset)
                val overrideVines = vineCountOverride.toIntOrNull()
                val summaryVines = overrideVines ?: if (vineSpacing > 0) (summaryLen / vineSpacing).toInt() else 0
                if (polyCoords.size >= 3 || rowCount > 0) {
                    BlockSummaryCard(
                        areaHa = summaryArea,
                        rowCount = rowCount,
                        totalRowLengthM = rowLengthOverride.toDoubleOrNull() ?: summaryLen,
                        vineCount = summaryVines,
                    )
                }
            }

            // Vine & spacing
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Vine & Trellis Spacing", onLight = true)
                VineyardCard {
                    SliderRow("Vine spacing", "%.2f m".format(vineSpacing), vineSpacing.toFloat(), 0.5f..3f) {
                        vineSpacing = it.toDouble()
                    }
                    Spacer(Modifier.height(8.dp))
                    NumberField("Intermediate post spacing (m)", postSpacing) { postSpacing = it }
                }
            }

            // Irrigation
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Irrigation", onLight = true)
                VineyardCard {
                    NumberField("Flow per emitter (L/h)", flowPerEmitter) { flowPerEmitter = it }
                    Spacer(Modifier.height(8.dp))
                    NumberField("Emitter spacing (m)", emitterSpacing) { emitterSpacing = it }
                    val rate = applicationRate(flowPerEmitter.toDoubleOrNull(), emitterSpacing.toDoubleOrNull(), rowWidth)
                    if (rate != null) {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            "Application rate ≈ %.2f mm/h".format(rate),
                            color = vine.textSecondary,
                            fontSize = 13.sp,
                        )
                    }
                }
            }

            // Varieties
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Grape Varieties", onLight = true)
                VineyardCard {
                    if (allocations.isEmpty()) {
                        Text("No varieties added yet.", color = vine.textSecondary, fontSize = 14.sp)
                    } else {
                        allocations.forEachIndexed { index, alloc ->
                            AllocationRow(
                                alloc = alloc,
                                onPercent = { p -> allocations[index] = alloc.copy(percent = p) },
                                onEdit = { editingAllocationIndex = index },
                                onRemove = { allocations.removeAt(index) },
                            )
                            if (index < allocations.lastIndex) Spacer(Modifier.height(10.dp))
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                    TextButton(onClick = { addingVariety = true }) {
                        Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(6.dp))
                        Text("Add variety")
                    }
                }
            }

            // Soil profile (existing blocks only — needs a server id)
            if (existing != null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Soil", onLight = true)
                    VineyardCard {
                        Text(
                            "Soil class, available water capacity and root depth feed the Irrigation Advisor.",
                            color = vine.textSecondary, fontSize = 13.sp,
                        )
                        Spacer(Modifier.height(10.dp))
                        TextButton(onClick = { showSoilEditor = true }, enabled = canEditSoil) {
                            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.size(6.dp))
                            Text("Edit soil profile")
                        }
                    }
                }
            }

            // Phenology
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Phenology", onLight = true)
                VineyardCard {
                    DateFieldRow("Budburst", budburst) { budburst = it }
                    Spacer(Modifier.height(6.dp))
                    DateFieldRow("Flowering", flowering) { flowering = it }
                    Spacer(Modifier.height(6.dp))
                    DateFieldRow("Veraison", veraison) { veraison = it }
                    Spacer(Modifier.height(6.dp))
                    DateFieldRow("Harvest", harvest) { harvest = it }
                }
            }

            // GDD overrides
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Degree Days Override", onLight = true)
                VineyardCard {
                    OptionRow(
                        label = "Calculation mode",
                        options = listOf(null to "Use default", "gdd" to "Standard GDD", "bedd" to "BEDD"),
                        selected = calcMode,
                    ) { calcMode = it }
                    Spacer(Modifier.height(8.dp))
                    OptionRow(
                        label = "Reset point",
                        options = listOf(
                            null to "Use default",
                            "seasonStart" to "Season Start",
                            "budburst" to "Budburst",
                            "flowering" to "Flowering",
                            "veraison" to "Veraison",
                        ),
                        selected = resetMode,
                    ) { resetMode = it }
                }
            }

            // Overrides
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Overrides & Planting", onLight = true)
                VineyardCard {
                    NumberField("Vine count override", vineCountOverride, KeyboardType.Number) { vineCountOverride = it }
                    Spacer(Modifier.height(8.dp))
                    NumberField("Total row length override (m)", rowLengthOverride) { rowLengthOverride = it }
                    Spacer(Modifier.height(8.dp))
                    NumberField("Planting year", plantingYear, KeyboardType.Number) { plantingYear = it }
                }
            }

            Spacer(Modifier.height(12.dp))
        }
    }

    if (showSoilEditor && existing != null) {
        val vid = state.selectedVineyardId
        if (vid != null) {
            SoilProfileEditorSheet(
                vineyardId = vid,
                paddockId = existing.id,
                paddockName = name.ifBlank { existing.name },
                vineyardCountry = state.selectedVineyard?.country,
                canEdit = canEditSoil,
                onSaved = { showSoilEditor = false },
                onDismiss = { showSoilEditor = false },
            )
        }
    }

    if (addingVariety) {
        AddVarietyDialog(
            state = state,
            onCreateCustomClone = vm::addCustomClone,
            onCreateCustomRootstock = vm::addCustomRootstock,
            onDismiss = { addingVariety = false },
            onAdd = { alloc -> allocations.add(alloc); addingVariety = false },
        )
    }

    val editIdx = editingAllocationIndex
    if (editIdx != null && editIdx < allocations.size) {
        AddVarietyDialog(
            state = state,
            initial = allocations[editIdx],
            onCreateCustomClone = vm::addCustomClone,
            onCreateCustomRootstock = vm::addCustomRootstock,
            onDismiss = { editingAllocationIndex = null },
            onAdd = { alloc ->
                allocations[editIdx] = alloc
                editingAllocationIndex = null
            },
        )
    }

    if (saving) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = VineColors.Primary)
        }
    }
}

/**
 * READ-ONLY preview of the block's saved/draft geometry.
 *
 * It renders exactly what the full-screen editor renders — the same
 * [blockRowLayout] output through the same overlays — but has no editing
 * affordances at all: no draggable markers, no pins, no midpoint controls. A
 * map tap opens the full-screen editor rather than dropping a boundary point,
 * so the boundary can only ever be changed in one place.
 */
@Composable
private fun BlockPreviewSection(
    boundary: androidx.compose.runtime.snapshots.SnapshotStateList<MarkerState>,
    layout: BlockRowLayout,
    vineyardCenter: LatLng?,
    onEdit: () -> Unit,
) {
    val vine = LocalVineColors.current
    val camera = rememberCameraPositionState()
    var mapLoaded by remember { mutableStateOf(false) }
    val context = LocalContext.current
    var hasLocationPerm by remember { mutableStateOf(LocationTracker(context).hasPermission) }
    var locationMessage by remember { mutableStateOf<String?>(null) }

    val boundaryPoints by remember { derivedStateOf { boundary.map { it.position } } }
    val framePoints = remember(boundaryPoints, layout) {
        boundaryPoints + layout.framePoints.map { LatLng(it.latitude, it.longitude) }
    }

    // Re-frames whenever the geometry itself changes — so returning from the
    // editor immediately shows the new boundary and rows at a sensible zoom
    // instead of whatever the editor was left at. Panning/zooming by hand does
    // not change the geometry, so it is never fought by this effect.
    LaunchedEffect(mapLoaded, framePoints) {
        if (!mapLoaded) return@LaunchedEffect
        when {
            framePoints.isNotEmpty() ->
                camera.fitToContent(points = framePoints, paddingPx = 96, singlePointZoom = 17f, animate = true)
            vineyardCenter != null ->
                camera.fitToContent(points = listOf(vineyardCenter), singlePointZoom = 16f)
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Boundary & Rows", onLight = true)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(300.dp)
                .clip(RoundedCornerShape(16.dp))
                .border(1.dp, vine.cardBorder, RoundedCornerShape(16.dp)),
        ) {
            GoogleMap(
                modifier = Modifier.fillMaxSize(),
                cameraPositionState = camera,
                // Real base map + over-zoom imagery, matching the editor, so the
                // preview can never render as a blank canvas.
                properties = MapProperties(mapType = MapType.NORMAL, isMyLocationEnabled = hasLocationPerm),
                uiSettings = MapUiSettings(
                    zoomControlsEnabled = false,
                    mapToolbarEnabled = false,
                    myLocationButtonEnabled = false,
                    rotationGesturesEnabled = false,
                    tiltGesturesEnabled = false,
                ),
                // A tap is navigation, never an edit.
                onMapClick = { onEdit() },
                onMapLoaded = { mapLoaded = true },
            ) {
                OverZoomSatelliteLayer()
                BlockBoundaryOverlay(points = boundaryPoints)
                BlockRowLinesOverlay(layout)
                BlockRowLabelsOverlay(layout)
            }
            if (boundaryPoints.isEmpty()) {
                Box(
                    Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)).clickable { onEdit() },
                    contentAlignment = Alignment.Center,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(Icons.Filled.Map, contentDescription = null, tint = Color.White)
                        Spacer(Modifier.height(6.dp))
                        Text("No boundary yet", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                        Text(
                            "Tap to draw it on the full-screen map",
                            color = Color.White.copy(alpha = 0.8f),
                            fontSize = 12.sp,
                        )
                    }
                }
            }
            MapMyLocationButton(
                camera = camera,
                onMessage = { locationMessage = it },
                onPermissionGranted = { hasLocationPerm = true },
                modifier = Modifier.align(Alignment.TopEnd).padding(10.dp),
            )
            Text(
                SATELLITE_IMAGERY_ATTRIBUTION,
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 8.sp,
                modifier = Modifier.align(Alignment.BottomStart).padding(start = 8.dp, bottom = 4.dp),
            )
            locationMessage?.let { msg ->
                LaunchedEffect(msg) {
                    delay(3500)
                    locationMessage = null
                }
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(10.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color(0xCC1C1C1E))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                ) {
                    Text(msg, color = Color.White, fontSize = 12.sp)
                }
            }
        }
        Text(
            buildString {
                append(if (boundaryPoints.isEmpty()) "Preview only" else "${boundaryPoints.size} points")
                if (layout.rows.isNotEmpty()) append(" · ${layout.rows.size} rows")
                append(" · Tap Edit boundary & rows on map to make changes")
            },
            color = vine.textSecondary,
            fontSize = 12.sp,
        )
    }
}

/**
 * Read-only row-layout summary. Row values are edited on the full-screen map
 * so the numbers here can never disagree with the geometry drawn above them.
 */
@Composable
private fun RowLayoutSummary(
    layout: BlockRowLayout,
    rowCount: Int,
    boundaryPoints: Int,
    onEdit: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Row Layout", onLight = true)
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SummaryLine("Direction", "${RowInput.formatDecimal(layout.direction)}°")
                SummaryLine("Rows", if (rowCount > 0) "$rowCount" else "—")
                SummaryLine("Row width", "${RowInput.formatDecimal(layout.width)} m")
                SummaryLine("Shift", "${RowInput.formatDecimal(layout.offset)} m")
                if (rowCount > 0) {
                    SummaryLine(
                        "Numbering",
                        "Row ${layout.numbering.firstNumber(rowCount)} → Row ${layout.numbering.lastNumber(rowCount)}",
                    )
                }
                if (rowCount > 0 && boundaryPoints < 3) {
                    Text(
                        "Row settings are saved but this block has no boundary yet, so no rows can be drawn. " +
                            "Nothing has been changed — open the map editor to draw the boundary.",
                        color = VineColors.Destructive, fontSize = 12.sp,
                    )
                } else if (rowCount > 0 && layout.isEmpty) {
                    Text(
                        "These saved row settings place no rows inside the boundary. " +
                            "Nothing has been changed — open the map editor to review the direction, width and shift.",
                        color = VineColors.Destructive, fontSize = 12.sp,
                    )
                }
                Spacer(Modifier.height(2.dp))
                TextButton(onClick = onEdit) {
                    Icon(Icons.Filled.Map, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Edit row layout")
                }
            }
        }
        Text(
            "Row direction, count, width, shift and numbering are set on the full-screen map.",
            color = vine.textSecondary,
            fontSize = 12.sp,
        )
    }
}

@Composable
private fun SummaryLine(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = vine.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Text(value, color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun SliderRow(
    label: String,
    value: String,
    sliderValue: Float,
    range: ClosedFloatingPointRange<Float>,
    onChange: (Float) -> Unit,
) {
    val vine = LocalVineColors.current
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = vine.textPrimary, modifier = Modifier.weight(1f), fontSize = 14.sp)
            Text(value, color = vine.textSecondary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
        Slider(
            value = sliderValue.coerceIn(range.start, range.endInclusive),
            onValueChange = onChange,
            valueRange = range,
            colors = androidx.compose.material3.SliderDefaults.colors(
                thumbColor = VineColors.LeafGreen,
                activeTrackColor = VineColors.LeafGreen,
            ),
        )
    }
}

@Composable
private fun NumberField(
    label: String,
    value: String,
    keyboard: KeyboardType = KeyboardType.Decimal,
    onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboard),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun OptionRow(
    label: String,
    options: List<Pair<String?, String>>,
    selected: String?,
    onSelect: (String?) -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, color = vine.textSecondary, fontSize = 13.sp)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            options.forEach { (key, title) ->
                val active = key == selected
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (active) VineColors.LeafGreen else vine.appBackground)
                        .border(1.dp, if (active) VineColors.LeafGreen else vine.cardBorder, RoundedCornerShape(10.dp))
                        .clickable { onSelect(key) }
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                ) {
                    Text(
                        title,
                        color = if (active) Color.White else vine.textPrimary,
                        fontSize = 12.sp,
                        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                    )
                }
            }
        }
    }
}

@Composable
private fun AllocationRow(
    alloc: PaddockVarietyAllocation,
    onPercent: (Double?) -> Unit,
    onEdit: () -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Column(
            modifier = Modifier
                .weight(1f)
                .clip(RoundedCornerShape(8.dp))
                .clickable(onClick = onEdit)
                .padding(vertical = 2.dp),
        ) {
            Text(
                alloc.displayName ?: alloc.varietyKey ?: "Variety",
                color = vine.textPrimary,
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
            )
            val meta = buildList {
                alloc.clone?.takeIf { it.isNotBlank() }?.let { add("Clone $it") }
                alloc.rootstock?.takeIf { it.isNotBlank() }?.let { add("Rootstock $it") }
            }
            if (meta.isNotEmpty()) {
                Text(meta.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp)
            } else {
                Text("Tap to set clone & rootstock", color = vine.textSecondary, fontSize = 12.sp)
            }
        }
        OutlinedTextField(
            value = alloc.percent?.let { formatNum(it) } ?: "",
            onValueChange = { onPercent(it.toDoubleOrNull()) },
            label = { Text("%") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.size(width = 86.dp, height = 60.dp),
        )
        IconButton(onClick = onRemove) {
            Icon(Icons.Filled.Delete, contentDescription = "Remove", tint = VineColors.Destructive)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DateFieldRow(label: String, iso: String?, onChange: (String?) -> Unit) {
    val vine = LocalVineColors.current
    var showPicker by remember { mutableStateOf(false) }
    val display = formatBlockDate(iso) ?: "Not set"
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = vine.textPrimary, modifier = Modifier.weight(1f), fontSize = 14.sp)
        TextButton(onClick = { showPicker = true }) { Text(display) }
        if (iso != null) {
            IconButton(onClick = { onChange(null) }) {
                Icon(Icons.Filled.Close, contentDescription = "Clear $label", tint = vine.textSecondary, modifier = Modifier.size(16.dp))
            }
        }
    }
    if (showPicker) {
        val initial = com.rork.vinetrack.data.model.parseIsoToEpochMs(iso) ?: System.currentTimeMillis()
        val dpState = androidx.compose.material3.rememberDatePickerState(initialSelectedDateMillis = initial)
        androidx.compose.material3.DatePickerDialog(
            onDismissRequest = { showPicker = false },
            confirmButton = {
                TextButton(onClick = {
                    dpState.selectedDateMillis?.let { onChange(Instant.ofEpochMilli(it).toString()) }
                    showPicker = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { showPicker = false }) { Text("Cancel") } },
        ) { androidx.compose.material3.DatePicker(state = dpState) }
    }
}

/**
 * Add or edit ONE variety allocation. Clone and rootstock come from the
 * shared catalogues (sql/182) via searchable pickers — the same contract as
 * the iOS `ClonePickerSheet`/`RootstockPickerSheet`. Pass [initial] to edit
 * an existing allocation (prefilled; confirm replaces it).
 */
@Composable
private fun AddVarietyDialog(
    state: AppUiState,
    onCreateCustomClone: (String, String, (VineyardCloneRow?) -> Unit) -> Unit,
    onCreateCustomRootstock: (String, (VineyardRootstockRow?) -> Unit) -> Unit,
    onDismiss: () -> Unit,
    onAdd: (PaddockVarietyAllocation) -> Unit,
    initial: PaddockVarietyAllocation? = null,
) {
    val vine = LocalVineColors.current
    var selectedKey by remember { mutableStateOf(initial?.varietyKey) }
    var percent by remember { mutableStateOf(initial?.percent?.let { formatNum(it) } ?: "") }
    var cloneKey by remember { mutableStateOf(initial?.cloneKey) }
    var cloneText by remember { mutableStateOf(initial?.clone) }
    var rootstockKey by remember { mutableStateOf(initial?.rootstockKey) }
    var rootstockText by remember { mutableStateOf(initial?.rootstock) }
    var showClonePicker by remember { mutableStateOf(false) }
    var showRootstockPicker by remember { mutableStateOf(false) }
    val selectedRow = state.grapeVarieties.firstOrNull { it.varietyKey == selectedKey }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (initial == null) "Add variety" else "Edit variety") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (state.grapeVarieties.isEmpty()) {
                    Text(
                        "No varieties in this vineyard's catalog yet. Add varieties from the Growth & Varieties screen first.",
                        color = vine.textSecondary,
                        fontSize = 13.sp,
                    )
                } else {
                    Text("Variety", color = vine.textSecondary, fontSize = 13.sp)
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        state.grapeVarieties.forEach { row ->
                            val active = row.varietyKey == selectedKey
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(if (active) VineColors.LeafGreen.copy(alpha = 0.15f) else vine.appBackground)
                                    .border(1.dp, if (active) VineColors.LeafGreen else vine.cardBorder, RoundedCornerShape(10.dp))
                                    .clickable {
                                        if (selectedKey != row.varietyKey) {
                                            // A clone belongs to its variety — changing
                                            // the variety clears the clone. Rootstock is
                                            // variety-independent and deliberately kept.
                                            cloneKey = null
                                            cloneText = null
                                        }
                                        selectedKey = row.varietyKey
                                    }
                                    .padding(horizontal = 12.dp, vertical = 10.dp),
                            ) {
                                Text(row.displayName, color = vine.textPrimary, fontSize = 14.sp)
                            }
                        }
                    }
                    NumberField("Percentage (%)", percent, KeyboardType.Number) { percent = it }
                    CatalogSelectorField(
                        label = "Clone",
                        value = cloneText ?: "Not specified",
                        hint = if (selectedRow == null) "Select a variety first" else null,
                        enabled = selectedRow != null,
                    ) { showClonePicker = true }
                    CatalogSelectorField(
                        label = "Rootstock",
                        value = rootstockText ?: "Not recorded",
                        hint = null,
                        enabled = true,
                    ) { showRootstockPicker = true }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = selectedRow != null,
                onClick = {
                    val row = selectedRow ?: return@TextButton
                    onAdd(
                        PaddockVarietyAllocation(
                            // Stable planting identity (sql/184): keep the id when
                            // editing, mint one for a new allocation. Never
                            // regenerate — picking records link to it.
                            id = initial?.id ?: java.util.UUID.randomUUID().toString(),
                            varietyKey = row.varietyKey,
                            name = row.displayName,
                            percent = percent.toDoubleOrNull(),
                            clone = cloneText?.trim()?.ifBlank { null },
                            rootstock = rootstockText?.trim()?.ifBlank { null },
                            cloneKey = cloneKey,
                            rootstockKey = rootstockKey,
                        ),
                    )
                },
            ) { Text(if (initial == null) "Add" else "Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )

    val cloneVariety = selectedRow
    if (showClonePicker && cloneVariety != null) {
        ClonePickerDialog(
            state = state,
            varietyKey = cloneVariety.varietyKey,
            varietyName = cloneVariety.displayName,
            currentKey = cloneKey,
            currentText = cloneText,
            onCreateCustomClone = onCreateCustomClone,
            onSelect = { key, text ->
                cloneKey = key
                cloneText = text
                showClonePicker = false
            },
            onDismiss = { showClonePicker = false },
        )
    }
    if (showRootstockPicker) {
        RootstockPickerDialog(
            state = state,
            currentKey = rootstockKey,
            currentText = rootstockText,
            onCreateCustomRootstock = onCreateCustomRootstock,
            onSelect = { key, text ->
                rootstockKey = key
                rootstockText = text
                showRootstockPicker = false
            },
            onDismiss = { showRootstockPicker = false },
        )
    }
}

/** Tappable read-only field showing the current catalogue selection. */
@Composable
private fun CatalogSelectorField(
    label: String,
    value: String,
    hint: String?,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .border(1.dp, vine.cardBorder, RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(label, color = vine.textSecondary, fontSize = 12.sp)
        Text(
            if (!enabled && hint != null) hint else value,
            color = if (enabled) vine.textPrimary else vine.textSecondary,
            fontSize = 14.sp,
        )
    }
}

/**
 * Searchable clone selector for ONE variety: shared catalogue entries
 * (scoped to [varietyKey]), the vineyard's custom clones for that variety,
 * the mass-selection sentinel, "Not specified", a preserved legacy free-text
 * row, and a custom-add action (degrades to free text offline).
 */
@Composable
private fun ClonePickerDialog(
    state: AppUiState,
    varietyKey: String,
    varietyName: String,
    currentKey: String?,
    currentText: String?,
    onCreateCustomClone: (String, String, (VineyardCloneRow?) -> Unit) -> Unit,
    onSelect: (String?, String?) -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    var query by remember { mutableStateOf("") }
    var adding by remember { mutableStateOf(false) }
    var addError by remember { mutableStateOf<String?>(null) }
    val system = CloneRootstockOptions.systemClonesForVariety(state.cloneCatalog, varietyKey, query)
    val custom = CloneRootstockOptions.customClonesForVariety(state.vineyardClones, varietyKey, query)
    val canAdd = CloneRootstockOptions.canOfferCustomClone(state.cloneCatalog, state.vineyardClones, varietyKey, query)
    val legacy = currentText?.trim()?.takeIf { currentKey == null && it.isNotEmpty() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Clone — $varietyName") },
        text = {
            Column(
                modifier = Modifier
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    label = { Text("Search clones") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                PickerOptionRow(
                    title = "Not specified",
                    subtitle = "Clone unknown / not recorded",
                    selected = currentKey == null && legacy == null,
                ) { onSelect(null, null) }
                PickerOptionRow(
                    title = CloneRootstockSentinels.MASS_SELECTION_DISPLAY,
                    subtitle = "No certified clone — mass-selected material",
                    selected = currentKey == CloneRootstockSentinels.MASS_SELECTION,
                ) {
                    onSelect(CloneRootstockSentinels.MASS_SELECTION, CloneRootstockSentinels.MASS_SELECTION_DISPLAY)
                }
                if (legacy != null) {
                    PickerOptionRow(
                        title = "Keep “$legacy”",
                        subtitle = "Existing entry, kept as typed",
                        selected = true,
                    ) { onSelect(null, legacy) }
                }
                if (system.isNotEmpty()) {
                    PickerSectionLabel("Catalogue — $varietyName")
                    system.forEach { entry ->
                        PickerOptionRow(
                            title = entry.displayName,
                            subtitle = entry.subtitle,
                            selected = currentKey == entry.key,
                        ) { onSelect(entry.key, entry.displayName) }
                    }
                }
                if (custom.isNotEmpty()) {
                    PickerSectionLabel("My clones")
                    custom.forEach { row ->
                        PickerOptionRow(
                            title = row.displayName,
                            subtitle = "Custom · this vineyard",
                            selected = currentKey == row.cloneKey,
                        ) { onSelect(row.cloneKey, row.displayName) }
                    }
                }
                if (canAdd) {
                    TextButton(
                        enabled = !adding,
                        onClick = {
                            adding = true
                            addError = null
                            onCreateCustomClone(varietyKey, query.trim()) { row ->
                                adding = false
                                if (row != null) {
                                    onSelect(row.cloneKey, row.displayName)
                                } else {
                                    // Degrade gracefully: keep the value as text.
                                    addError = "Couldn't reach the catalogue — saved as text."
                                    onSelect(null, query.trim())
                                }
                            }
                        },
                    ) { Text("Add “${query.trim()}” as custom clone") }
                    addError?.let { Text(it, color = VineColors.Destructive, fontSize = 12.sp) }
                }
                if (system.isEmpty() && custom.isEmpty() && query.isBlank()) {
                    Text(
                        "No catalogue clones for $varietyName yet. Search to add one as a custom clone.",
                        color = vine.textSecondary,
                        fontSize = 12.sp,
                    )
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/**
 * Searchable rootstock selector — the catalogue is independent of variety.
 * Includes the own-roots sentinel, "Not recorded", custom rootstocks, a
 * preserved legacy free-text row and a custom-add action.
 */
@Composable
private fun RootstockPickerDialog(
    state: AppUiState,
    currentKey: String?,
    currentText: String?,
    onCreateCustomRootstock: (String, (VineyardRootstockRow?) -> Unit) -> Unit,
    onSelect: (String?, String?) -> Unit,
    onDismiss: () -> Unit,
) {
    var query by remember { mutableStateOf("") }
    var adding by remember { mutableStateOf(false) }
    var addError by remember { mutableStateOf<String?>(null) }
    val system = CloneRootstockOptions.systemRootstocks(state.rootstockCatalog, query)
    val custom = CloneRootstockOptions.customRootstocks(state.vineyardRootstocks, query)
    val canAdd = CloneRootstockOptions.canOfferCustomRootstock(state.rootstockCatalog, state.vineyardRootstocks, query)
    val legacy = currentText?.trim()?.takeIf { currentKey == null && it.isNotEmpty() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rootstock") },
        text = {
            Column(
                modifier = Modifier
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    label = { Text("Search rootstocks") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                PickerOptionRow(
                    title = "Not recorded",
                    subtitle = "Rootstock unknown / not recorded",
                    selected = currentKey == null && legacy == null,
                ) { onSelect(null, null) }
                PickerOptionRow(
                    title = "Own roots / ungrafted",
                    subtitle = "Vines growing on their own roots",
                    selected = currentKey == CloneRootstockSentinels.OWN_ROOTS,
                ) {
                    onSelect(CloneRootstockSentinels.OWN_ROOTS, CloneRootstockSentinels.OWN_ROOTS_DISPLAY)
                }
                if (legacy != null) {
                    PickerOptionRow(
                        title = "Keep “$legacy”",
                        subtitle = "Existing entry, kept as typed",
                        selected = true,
                    ) { onSelect(null, legacy) }
                }
                if (system.isNotEmpty()) {
                    PickerSectionLabel("Rootstock catalogue")
                    system.forEach { entry ->
                        PickerOptionRow(
                            title = entry.displayName,
                            subtitle = entry.parentage ?: "",
                            selected = currentKey == entry.key,
                        ) { onSelect(entry.key, entry.displayName) }
                    }
                }
                if (custom.isNotEmpty()) {
                    PickerSectionLabel("My rootstocks")
                    custom.forEach { row ->
                        PickerOptionRow(
                            title = row.displayName,
                            subtitle = "Custom · this vineyard",
                            selected = currentKey == row.rootstockKey,
                        ) { onSelect(row.rootstockKey, row.displayName) }
                    }
                }
                if (canAdd) {
                    TextButton(
                        enabled = !adding,
                        onClick = {
                            adding = true
                            addError = null
                            onCreateCustomRootstock(query.trim()) { row ->
                                adding = false
                                if (row != null) {
                                    onSelect(row.rootstockKey, row.displayName)
                                } else {
                                    addError = "Couldn't reach the catalogue — saved as text."
                                    onSelect(null, query.trim())
                                }
                            }
                        },
                    ) { Text("Add “${query.trim()}” as custom rootstock") }
                    addError?.let { Text(it, color = VineColors.Destructive, fontSize = 12.sp) }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun PickerSectionLabel(text: String) {
    val vine = LocalVineColors.current
    Text(text, color = vine.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
}

@Composable
private fun PickerOptionRow(
    title: String,
    subtitle: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(if (selected) VineColors.LeafGreen.copy(alpha = 0.12f) else vine.appBackground)
            .border(1.dp, if (selected) VineColors.LeafGreen else vine.cardBorder, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, color = vine.textPrimary, fontSize = 14.sp)
            if (subtitle.isNotEmpty()) Text(subtitle, color = vine.textSecondary, fontSize = 12.sp)
        }
        if (selected) {
            Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun FullMapEditorButton(hasBoundary: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(VineColors.LeafGreen)
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.2f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Map, contentDescription = null, tint = Color.White)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Edit boundary & rows on map", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
            Text(
                if (hasBoundary) "Tap to refine the boundary and rows full-screen"
                else "Draw your block boundary on the full-screen map",
                color = Color.White.copy(alpha = 0.85f), fontSize = 12.sp,
            )
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Color.White)
    }
}

@Composable
private fun BlockSummaryCard(areaHa: Double, rowCount: Int, totalRowLengthM: Double, vineCount: Int) {
    val vine = LocalVineColors.current
    val cells = listOf(
        "Area" to (if (areaHa > 0) "%.2f ha".format(areaHa) else "—"),
        "Rows" to (if (rowCount > 0) rowCount.toString() else "—"),
        "Row length" to (if (totalRowLengthM > 0) "%,.0f m".format(totalRowLengthM) else "—"),
        "Vines" to (if (vineCount > 0) "%,d".format(vineCount) else "—"),
    )
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Block Summary", onLight = true)
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                cells.chunked(2).forEach { pair ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        pair.forEach { (label, value) ->
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(value, color = vine.textPrimary, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                                Text(label, color = vine.textSecondary, fontSize = 12.sp)
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Litres-per-emitter + spacing + row width → mm/hour application rate. */
private fun applicationRate(flow: Double?, emitterSpacing: Double?, rowWidth: Double?): Double? {
    if (flow == null || emitterSpacing == null || rowWidth == null) return null
    if (emitterSpacing <= 0 || rowWidth <= 0) return null
    val emittersPerHa = 10_000.0 / (rowWidth * emitterSpacing)
    val litresPerHaPerHour = emittersPerHa * flow
    return litresPerHaPerHour / 1_000_000.0 * 100.0
}

private fun formatNum(v: Double): String =
    if (v % 1.0 == 0.0) v.toLong().toString() else "%.2f".format(v).trimEnd('0').trimEnd('.')

private val editDateFormatter = java.time.format.DateTimeFormatter.ofPattern("d MMM yyyy", java.util.Locale.getDefault())

private fun formatBlockDate(iso: String?): String? {
    val ms = com.rork.vinetrack.data.model.parseIsoToEpochMs(iso) ?: return null
    return Instant.ofEpochMilli(ms).atZone(java.time.ZoneId.systemDefault()).format(editDateFormatter)
}
