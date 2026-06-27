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
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.calculateRowLines
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.Instant
import kotlin.math.roundToInt

private val EditAmber = Color(0xFFFF9500)

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
    var rowDirection by remember { mutableStateOf(existing?.rowDirection ?: 0.0) }
    var rowCount by remember { mutableStateOf(existing?.rowCount ?: 0) }
    var rowWidth by remember { mutableStateOf(existing?.rowWidth ?: 2.5) }
    var rowOffset by remember { mutableStateOf(existing?.rowOffset ?: 0.0) }
    var rowStartNumber by remember { mutableStateOf(1) }
    var rowAscending by remember { mutableStateOf(true) }
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
    val error = state.blockEditError

    val canSave by remember { derivedStateOf { name.isNotBlank() && !saving } }

    var showMapEditor by remember { mutableStateOf(false) }
    var showSoilEditor by remember { mutableStateOf(false) }
    val canEditSoil = state.currentRole in setOf("owner", "manager", "supervisor", "operator")

    if (showMapEditor) {
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
            onDone = { showMapEditor = false },
            modifier = modifier,
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

            // Immersive full-screen boundary + row editor (Apple-style)
            FullMapEditorButton(
                hasBoundary = boundary.size >= 3,
                onClick = { showMapEditor = true },
            )

            // Boundary editor
            BoundarySection(
                boundary = boundary,
                rowLines = remember {
                    derivedStateOf {
                        val poly = boundary.map { CoordinatePoint(it.position.latitude, it.position.longitude) }
                        calculateRowLines(poly, rowDirection, rowCount, rowWidth, rowOffset)
                    }
                }.value,
                vineyardCenter = state.selectedVineyard?.let { v ->
                    val lat = v.latitude; val lng = v.longitude
                    if (lat != null && lng != null) LatLng(lat, lng) else null
                },
            )

            // Row configuration
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Row Configuration", onLight = true)
                VineyardCard {
                    SliderRow("Direction", "${rowDirection.roundToInt()}°", rowDirection.toFloat(), 0f..360f) {
                        rowDirection = it.toDouble()
                    }
                    Spacer(Modifier.height(8.dp))
                    StepperRow("Row count", rowCount, 0, 500) { rowCount = it }
                    Spacer(Modifier.height(8.dp))
                    SliderRow("Row spacing", "%.1f m".format(rowWidth), rowWidth.toFloat(), 0.5f..6f) {
                        rowWidth = it.toDouble()
                    }
                    Spacer(Modifier.height(8.dp))
                    SliderRow("Shift rows", "%.0f m".format(rowOffset), rowOffset.toFloat(), -50f..50f) {
                        rowOffset = it.toDouble()
                    }
                }
            }

            if (rowCount > 0) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Row Numbering", onLight = true)
                    VineyardCard {
                        StepperRow("Start number", rowStartNumber, 1, 999) { rowStartNumber = it }
                        Spacer(Modifier.height(10.dp))
                        RowPositionPicker(rowStartNumber, rowCount, rowAscending) { rowAscending = it }
                    }
                }
            }

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
            onDismiss = { addingVariety = false },
            onAdd = { alloc -> allocations.add(alloc); addingVariety = false },
        )
    }

    if (saving) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = VineColors.LeafGreen)
        }
    }
}

@Composable
private fun BoundarySection(
    boundary: androidx.compose.runtime.snapshots.SnapshotStateList<MarkerState>,
    rowLines: List<com.rork.vinetrack.data.RowLine>,
    vineyardCenter: LatLng?,
) {
    val vine = LocalVineColors.current
    val camera = rememberCameraPositionState()
    var framed by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        if (framed) return@LaunchedEffect
        val pts = boundary.map { it.position }
        when {
            pts.size >= 2 -> {
                val b = LatLngBounds.builder().apply { pts.forEach { include(it) } }.build()
                runCatching { camera.move(CameraUpdateFactory.newLatLngBounds(b, 120)) }
            }
            pts.size == 1 -> camera.move(CameraUpdateFactory.newLatLngZoom(pts.first(), 17f))
            vineyardCenter != null -> camera.move(CameraUpdateFactory.newLatLngZoom(vineyardCenter, 16f))
        }
        framed = true
    }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionHeader("Boundary", onLight = true, modifier = Modifier.weight(1f))
            if (boundary.isNotEmpty()) {
                IconButton(onClick = { if (boundary.isNotEmpty()) boundary.removeAt(boundary.lastIndex) }) {
                    Icon(Icons.Filled.Undo, contentDescription = "Undo last point", tint = vine.textSecondary)
                }
                IconButton(onClick = { boundary.clear() }) {
                    Icon(Icons.Filled.Delete, contentDescription = "Clear boundary", tint = VineColors.Destructive)
                }
            }
        }
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
                properties = MapProperties(mapType = MapType.HYBRID),
                uiSettings = MapUiSettings(
                    zoomControlsEnabled = false,
                    mapToolbarEnabled = false,
                    rotationGesturesEnabled = false,
                    tiltGesturesEnabled = false,
                ),
                onMapClick = { boundary.add(MarkerState(it)) },
            ) {
                val poly by remember { derivedStateOf { boundary.map { it.position } } }
                if (poly.size >= 3) {
                    Polygon(
                        points = poly,
                        fillColor = EditAmber.copy(alpha = 0.12f),
                        strokeColor = EditAmber,
                        strokeWidth = 3f,
                    )
                }
                boundary.forEach { ms ->
                    Marker(
                        state = ms,
                        draggable = true,
                        onClick = { boundary.remove(ms); true },
                    )
                }
                rowLines.forEach { line ->
                    Polyline(
                        points = listOf(
                            LatLng(line.start.latitude, line.start.longitude),
                            LatLng(line.end.latitude, line.end.longitude),
                        ),
                        color = Color.White.copy(alpha = 0.7f),
                        width = 2f,
                    )
                }
            }
            if (boundary.isEmpty()) {
                Box(
                    Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.25f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(Icons.Filled.Map, contentDescription = null, tint = Color.White)
                        Spacer(Modifier.height(6.dp))
                        Text("Tap the map to add boundary points", color = Color.White, fontSize = 13.sp)
                    }
                }
            }
        }
        Text(
            if (boundary.isEmpty()) "Tap to add points · drag to move · tap a point to remove"
            else "${boundary.size} points · tap to add · drag to move · tap a point to remove",
            color = vine.textSecondary,
            fontSize = 12.sp,
        )
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
private fun StepperRow(label: String, value: Int, min: Int, max: Int, onChange: (Int) -> Unit) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = vine.textPrimary, modifier = Modifier.weight(1f), fontSize = 14.sp)
        IconButton(onClick = { if (value > min) onChange(value - 1) }) {
            Icon(Icons.Filled.Close, contentDescription = "Decrease", tint = vine.textSecondary, modifier = Modifier.size(16.dp))
        }
        Text("$value", color = vine.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
        IconButton(onClick = { if (value < max) onChange(value + 1) }) {
            Icon(Icons.Filled.Add, contentDescription = "Increase", tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = vine.textPrimary, modifier = Modifier.weight(1f), fontSize = 14.sp)
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = androidx.compose.material3.SwitchDefaults.colors(checkedTrackColor = VineColors.LeafGreen),
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
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Column(modifier = Modifier.weight(1f)) {
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
            if (meta.isNotEmpty()) Text(meta.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp)
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

@Composable
private fun AddVarietyDialog(
    state: AppUiState,
    onDismiss: () -> Unit,
    onAdd: (PaddockVarietyAllocation) -> Unit,
) {
    val vine = LocalVineColors.current
    var selectedKey by remember { mutableStateOf<String?>(null) }
    var percent by remember { mutableStateOf("") }
    var clone by remember { mutableStateOf("") }
    var rootstock by remember { mutableStateOf("") }
    val selectedRow = state.grapeVarieties.firstOrNull { it.varietyKey == selectedKey }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add variety") },
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
                                    .clickable { selectedKey = row.varietyKey }
                                    .padding(horizontal = 12.dp, vertical = 10.dp),
                            ) {
                                Text(row.displayName, color = vine.textPrimary, fontSize = 14.sp)
                            }
                        }
                    }
                    NumberField("Percentage (%)", percent, KeyboardType.Number) { percent = it }
                    OutlinedTextField(
                        value = clone,
                        onValueChange = { clone = it },
                        label = { Text("Clone (optional)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = rootstock,
                        onValueChange = { rootstock = it },
                        label = { Text("Rootstock (optional)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
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
                            varietyKey = row.varietyKey,
                            name = row.displayName,
                            percent = percent.toDoubleOrNull(),
                            clone = clone.trim().ifBlank { null },
                            rootstock = rootstock.trim().ifBlank { null },
                        ),
                    )
                },
            ) { Text("Add") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
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
private fun RowPositionPicker(startNumber: Int, rowCount: Int, ascending: Boolean, onChange: (Boolean) -> Unit) {
    val vine = LocalVineColors.current
    val firstNum = if (ascending) startNumber else startNumber + maxOf(rowCount - 1, 0)
    val lastNum = if (ascending) startNumber + maxOf(rowCount - 1, 0) else startNumber
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Row 1 position", color = vine.textSecondary, fontSize = 13.sp)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(vine.appBackground)
                .border(1.dp, vine.cardBorder, RoundedCornerShape(12.dp))
                .clickable { onChange(!ascending) }
                .padding(vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RowEnd("Left", firstNum, Modifier.weight(1f))
            Box(
                modifier = Modifier.size(34.dp).clip(RoundedCornerShape(17.dp)).background(VineColors.LeafGreen.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.SwapHoriz, contentDescription = "Swap row direction", tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
            }
            RowEnd("Right", lastNum, Modifier.weight(1f))
        }
    }
}

@Composable
private fun RowEnd(label: String, number: Int, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, color = vine.textSecondary, fontSize = 11.sp)
        Text("Row $number", color = VineColors.LeafGreen, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
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
