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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MenuAnchorType
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
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
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
import com.rork.vinetrack.data.GddCalculationMode
import com.rork.vinetrack.data.GddResetMode
import com.rork.vinetrack.data.GddSettingsStore
import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.PaddockReferenceCounts
import com.rork.vinetrack.data.RowInput
import com.rork.vinetrack.data.RowNumbering
import com.rork.vinetrack.data.SoilProfileRepository
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.blockRowLayout
import com.rork.vinetrack.data.model.BackendSoilProfile
import com.rork.vinetrack.data.model.BuiltInGrapeVarietyGDD
import com.rork.vinetrack.data.model.CloneRootstockOptions
import com.rork.vinetrack.data.model.CloneRootstockSentinels
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.GrapeVarietyRow
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRowRegeneration
import com.rork.vinetrack.data.model.PaddockRowVineCount
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.data.model.VineyardCloneRow
import com.rork.vinetrack.data.model.VineyardRootstockRow
import com.rork.vinetrack.data.model.canonicalVarietyName
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
    /** iOS `accessControl.canDeleteOperationalRecords` — gates the Danger Zone. */
    canDelete: Boolean = false,
    onDone: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current

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
    // MANUAL per-row vine counts (sql/188), keyed by ROW NUMBER — the one
    // identifier that stays stable while the editor regenerates geometry.
    val rowVineCountOverrides = remember(existing?.id) {
        mutableStateMapOf<Int, Int>().apply {
            putAll(PaddockRowRegeneration.overrides(existing?.rows.orEmpty()))
        }
    }
    // The row currently open in the per-row vine-count editor.
    var rowVineCountTarget by remember { mutableStateOf<RowVineCountTarget?>(null) }
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

    // Soil profile summary (iOS `soilSection`): read through the same repository
    // the soil editor uses; the editor remains the only write path.
    val soilRepo = remember { SoilProfileRepository(SessionStore(context)) }
    var soilProfile by remember(existing?.id) { mutableStateOf<BackendSoilProfile?>(null) }
    var soilLoading by remember(existing?.id) { mutableStateOf(existing != null) }
    var soilReloadTick by remember { mutableStateOf(0) }
    LaunchedEffect(existing?.id, soilReloadTick) {
        val pid = existing?.id ?: return@LaunchedEffect
        soilLoading = true
        soilProfile = runCatching { soilRepo.fetchPaddockSoilProfile(pid) }.getOrNull()
        soilLoading = false
    }

    // Danger Zone (iOS `dangerZoneSection`): linked-record check gates permanent delete.
    val showDangerZone = existing != null && canDelete
    var refCounts by remember(existing?.id) { mutableStateOf<PaddockReferenceCounts?>(null) }
    var refCountsLoading by remember(existing?.id) { mutableStateOf(false) }
    var refCountsFailed by remember(existing?.id) { mutableStateOf(false) }
    var showArchiveConfirm by remember { mutableStateOf(false) }
    var showPermanentDeleteConfirm by remember { mutableStateOf(false) }
    var performingDestructive by remember { mutableStateOf(false) }
    LaunchedEffect(existing?.id, showDangerZone) {
        val pid = existing?.id ?: return@LaunchedEffect
        if (!showDangerZone) return@LaunchedEffect
        refCountsLoading = true
        vm.loadPaddockReferenceCounts(pid) { counts ->
            refCounts = counts
            refCountsFailed = counts == null
            refCountsLoading = false
        }
    }

    // Clone / rootstock pickers opened from an allocation row (iOS
    // `clonePickerTarget` / `rootstockPickerTarget`). Selections are applied
    // with copy() so the allocation id and every other field are preserved.
    var clonePickerIndex by remember { mutableStateOf<Int?>(null) }
    var rootstockPickerIndex by remember { mutableStateOf<Int?>(null) }

    val gddDefaults = remember { GddSettingsStore(context).load() }

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
                                rowVineCountOverrides = rowVineCountOverrides.toMap(),
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

            // Section order mirrors iOS `EditPaddockSheet.body`:
            // Name → Boundary → Row Configuration (+ Numbering) → Vine & Trellis
            // Spacing → Phenology → Degree Days Override → Grape Varieties →
            // Irrigation → Soil → [Block Summary, Vines Per Row] → [Danger Zone].

            // 1. Block Name
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

            // 2. Boundary — the full-screen editor is the ONE place the boundary
            // and rows can be changed; the preview below is read-only.
            FullMapEditorButton(
                hasBoundary = boundary.size >= 3,
                onClick = { editorMode = BlockEditorMode.Boundary },
            )
            BlockPreviewSection(
                boundary = boundary,
                layout = previewLayout,
                vineyardCenter = state.selectedVineyard?.let { v ->
                    val lat = v.latitude; val lng = v.longitude
                    if (lat != null && lng != null) LatLng(lat, lng) else null
                },
                onEdit = { editorMode = BlockEditorMode.Boundary },
            )

            // 3. Row Configuration + Row Numbering — summary only (unchanged);
            // editing happens on the full-screen map's Rows tab.
            RowLayoutSummary(
                layout = previewLayout,
                rowCount = rowCount,
                boundaryPoints = boundary.size,
                onEdit = { editorMode = BlockEditorMode.Rows },
            )

            // 4. Vine & Trellis Spacing
            VineTrellisSpacingSection(
                vineSpacing = vineSpacing,
                onVineSpacing = { vineSpacing = it },
                postSpacing = postSpacing,
                onPostSpacing = { postSpacing = it },
                rowCount = rowCount,
                // iOS uses the SAVED block's effective total row length here.
                savedEffectiveRowLength = existing?.effectiveTotalRowLength ?: 0.0,
            )

            // 5. Phenology (dates + Planting Year)
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
                    Spacer(Modifier.height(6.dp))
                    TrailingNumberRow(
                        label = "Planting Year",
                        value = plantingYear,
                        placeholder = "e.g. 2018",
                        unit = null,
                        keyboard = KeyboardType.Number,
                        fieldWidth = 96.dp,
                        onChange = { plantingYear = it },
                    )
                }
                Text(
                    "Set key phenology dates each season. Degree-day accumulation starts from the Reset Point selected below (budburst is typical for ripeness tracking).",
                    color = vine.textSecondary,
                    fontSize = 12.sp,
                )
            }

            // 6. Degree Days Override — two labelled dropdowns; null = inherit.
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Degree Days Override", onLight = true)
                VineyardCard {
                    OverrideDropdown(
                        label = "Calculation",
                        options = listOf<Pair<String?, String>>(
                            null to "Vineyard Default (${gddDefaults.calculationMode.shortName})",
                        ) + GddCalculationMode.entries.map { it.storageKey to it.displayName },
                        selected = calcMode,
                        onSelect = { calcMode = it },
                    )
                    Spacer(Modifier.height(10.dp))
                    OverrideDropdown(
                        label = "Reset Point",
                        options = listOf<Pair<String?, String>>(
                            null to "Vineyard Default (${gddDefaults.resetMode.displayName})",
                        ) + GddResetMode.entries.map { it.storageKey to it.displayName },
                        selected = resetMode,
                        onSelect = { resetMode = it },
                    )
                }
                Text(
                    "Leave on “Vineyard Default” to inherit from Vineyard Setup. Override per block if, for example, you want to track ripening from flowering on this block only.",
                    color = vine.textSecondary,
                    fontSize = 12.sp,
                )
            }

            // 7. Grape Varieties
            run {
                val totalPercent = allocations.sumOf { it.percent ?: 0.0 }
                val totalOk = kotlin.math.abs(totalPercent - 100.0) < 0.5
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        SectionHeader("Grape Varieties", onLight = true, fillWidth = false, modifier = Modifier.weight(1f))
                        if (allocations.isNotEmpty()) {
                            Text(
                                "Total: ${totalPercent.toInt()}%",
                                color = if (totalOk) VineColors.LeafGreen else VineColors.Warning,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                            )
                        }
                    }
                    VineyardCard {
                        allocations.forEachIndexed { index, alloc ->
                            AllocationRow(
                                alloc = alloc,
                                variety = resolveAllocationVariety(alloc, state.grapeVarieties),
                                onPercent = { p -> allocations[index] = alloc.copy(percent = p) },
                                onEdit = { editingAllocationIndex = index },
                                onRemove = { allocations.removeAt(index) },
                                onPickClone = { clonePickerIndex = index },
                                onPickRootstock = { rootstockPickerIndex = index },
                            )
                            HorizontalDivider(Modifier.padding(vertical = 10.dp), color = vine.cardBorder)
                        }
                        TextButton(onClick = { addingVariety = true }) {
                            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.size(6.dp))
                            Text("Add Variety")
                        }
                    }
                    Text(
                        when {
                            allocations.isEmpty() ->
                                "Add varieties planted in this block. Manage the master list in Settings → Vineyard Setup → Grape Varieties."
                            !totalOk -> "Percentages should total 100%. Currently: ${totalPercent.toInt()}%."
                            else -> "Percentages total 100%."
                        },
                        color = if (allocations.isNotEmpty() && !totalOk) VineColors.Warning else vine.textSecondary,
                        fontSize = 12.sp,
                    )
                }
            }

            // 8. Irrigation
            IrrigationSection(
                flowPerEmitter = flowPerEmitter,
                onFlowPerEmitter = { flowPerEmitter = it },
                emitterSpacing = emitterSpacing,
                onEmitterSpacing = { emitterSpacing = it },
                rowWidth = rowWidth,
            )

            // 9. Soil
            SoilSection(
                isNewBlock = existing == null,
                loading = soilLoading,
                profile = soilProfile,
                isAustralianVineyard = isAustralianCountry(state.selectedVineyard?.country),
                canEdit = canEditSoil,
                onEdit = { showSoilEditor = true },
            )

            // 10. Block Summary + Vines Per Row (iOS: boundary AND rows required)
            run {
                val polyCoords = boundary.map { CoordinatePoint(it.position.latitude, it.position.longitude) }
                if (polyCoords.size > 2 && rowCount > 0) {
                    val calculatedLength = previewTotalRowLength(polyCoords, rowDirection, rowCount, rowWidth, rowOffset)
                    BlockSummaryCard(
                        calculatedRowLengthM = calculatedLength,
                        vineSpacing = vineSpacing,
                        rowLengthOverride = rowLengthOverride,
                        onRowLengthOverride = { rowLengthOverride = it },
                        vineCountOverride = vineCountOverride,
                        onVineCountOverride = { vineCountOverride = it },
                    )
                    RowVineCountsCard(
                        entries = rowVineCountEntries(
                            layout = previewLayout,
                            vineSpacing = vineSpacing,
                            overrides = rowVineCountOverrides,
                        ),
                        onEditRow = { rowVineCountTarget = it },
                        onClearAll = { rowVineCountOverrides.clear() },
                    )
                }
            }

            // 11. Danger Zone — existing blocks, authorised roles only.
            if (showDangerZone) {
                DangerZoneSection(
                    loading = refCountsLoading,
                    counts = refCounts,
                    checkFailed = refCountsFailed,
                    busy = performingDestructive,
                    onArchive = { showArchiveConfirm = true },
                    onDeletePermanently = { showPermanentDeleteConfirm = true },
                )
            }

            Spacer(Modifier.height(12.dp))
        }
    }

    rowVineCountTarget?.let { target ->
        RowVineCountDialog(
            target = target,
            currentOverride = rowVineCountOverrides[target.number],
            onDismiss = { rowVineCountTarget = null },
            onSave = { value ->
                if (value != null) {
                    rowVineCountOverrides[target.number] = value
                } else {
                    rowVineCountOverrides.remove(target.number)
                }
            },
        )
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
                onSaved = { saved ->
                    if (saved != null) soilProfile = saved
                    soilReloadTick++
                    showSoilEditor = false
                },
                onDismiss = { showSoilEditor = false },
            )
        }
    }

    // Clone / rootstock pickers from an allocation row — same dialogs as the
    // add/edit flow; the result is applied with copy() onto the SAME allocation.
    clonePickerIndex?.let { idx ->
        val alloc = allocations.getOrNull(idx)
        val variety = alloc?.let { resolveAllocationVariety(it, state.grapeVarieties) }
        if (alloc == null) {
            clonePickerIndex = null
        } else {
            val key = variety?.varietyKey ?: alloc.varietyKey
            if (key == null) {
                clonePickerIndex = null
            } else {
                ClonePickerDialog(
                    state = state,
                    varietyKey = key,
                    varietyName = variety?.displayName ?: alloc.displayName ?: "Variety",
                    currentKey = alloc.cloneKey,
                    currentText = alloc.clone,
                    onCreateCustomClone = vm::addCustomClone,
                    onSelect = { k, text ->
                        allocations[idx] = alloc.copy(cloneKey = k, clone = text?.trim()?.ifBlank { null })
                        clonePickerIndex = null
                    },
                    onDismiss = { clonePickerIndex = null },
                )
            }
        }
    }
    rootstockPickerIndex?.let { idx ->
        val alloc = allocations.getOrNull(idx)
        if (alloc == null) {
            rootstockPickerIndex = null
        } else {
            RootstockPickerDialog(
                state = state,
                currentKey = alloc.rootstockKey,
                currentText = alloc.rootstock,
                onCreateCustomRootstock = vm::addCustomRootstock,
                onSelect = { k, text ->
                    allocations[idx] = alloc.copy(rootstockKey = k, rootstock = text?.trim()?.ifBlank { null })
                    rootstockPickerIndex = null
                },
                onDismiss = { rootstockPickerIndex = null },
            )
        }
    }

    // Danger Zone confirmations (iOS: archive confirmation dialog; permanent
    // delete requires typing the block name). Existing VM operations only.
    if (showArchiveConfirm && existing != null) {
        val preview = refCounts?.takeIf { !it.isEmpty }?.summaryLines?.take(4)?.joinToString(", ")
        AlertDialog(
            onDismissRequest = { showArchiveConfirm = false },
            title = { Text("Archive ${existing.name}?") },
            text = {
                Text(
                    if (preview != null) {
                        "This block has linked records ($preview). Archiving keeps it available for historical reports but hides it from active selectors."
                    } else {
                        "Archiving keeps this block available for historical reports but hides it from active selectors."
                    },
                    color = vine.textSecondary,
                    fontSize = 14.sp,
                )
            },
            confirmButton = {
                TextButton(
                    enabled = !performingDestructive,
                    onClick = {
                        showArchiveConfirm = false
                        performingDestructive = true
                        vm.archivePaddock(existing.id) { ok ->
                            performingDestructive = false
                            if (ok) onDone()
                        }
                    },
                ) { Text("Archive block", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { showArchiveConfirm = false }) { Text("Cancel") } },
        )
    }
    if (showPermanentDeleteConfirm && existing != null) {
        var typedName by remember { mutableStateOf("") }
        val matches = typedName.trim().equals(existing.name, ignoreCase = true)
        AlertDialog(
            onDismissRequest = { showPermanentDeleteConfirm = false },
            title = { Text("Delete ${existing.name} permanently?") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        "This cannot be undone. Type “${existing.name}” to confirm.",
                        color = vine.textSecondary,
                        fontSize = 14.sp,
                    )
                    OutlinedTextField(
                        value = typedName,
                        onValueChange = { typedName = it },
                        placeholder = { Text("Type block name") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = matches && !performingDestructive && refCounts?.isEmpty == true,
                    onClick = {
                        showPermanentDeleteConfirm = false
                        performingDestructive = true
                        vm.hardDeletePaddock(existing.id) { ok ->
                            performingDestructive = false
                            if (ok) onDone()
                        }
                    },
                ) { Text("Delete permanently", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { showPermanentDeleteConfirm = false }) { Text("Cancel") } },
        )
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

/**
 * Labelled single-choice dropdown (iOS `Picker` row parity). A `null` key is
 * the inherited "Vineyard Default" option; any other key is an explicit
 * block override. The selected title is a single unwrapped line.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OverrideDropdown(
    label: String,
    options: List<Pair<String?, String>>,
    selected: String?,
    onSelect: (String?) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val selectedTitle = options.firstOrNull { it.first == selected }?.second
        ?: options.firstOrNull { it.first == null }?.second
        ?: ""
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
        OutlinedTextField(
            value = selectedTitle,
            onValueChange = {},
            readOnly = true,
            singleLine = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (key, title) ->
                val isSelected = key == selected
                val check: (@Composable () -> Unit)? =
                    if (isSelected) ({ Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.LeafGreen) }) else null
                DropdownMenuItem(
                    text = {
                        Text(title, fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal)
                    },
                    trailingIcon = check,
                    onClick = {
                        onSelect(key)
                        open = false
                    },
                )
            }
        }
    }
}

/** `Label ........ [value] unit` row with a compact trailing text field (iOS HStack form row). */
@Composable
private fun TrailingNumberRow(
    label: String,
    value: String,
    placeholder: String,
    unit: String?,
    keyboard: KeyboardType,
    onChange: (String) -> Unit,
    fieldWidth: Dp = 88.dp,
) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, color = vine.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        OutlinedTextField(
            value = value,
            onValueChange = onChange,
            placeholder = { Text(placeholder, fontSize = 14.sp) },
            singleLine = true,
            textStyle = LocalTextStyle.current.copy(
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
                textAlign = TextAlign.End,
            ),
            keyboardOptions = KeyboardOptions(keyboardType = keyboard),
            modifier = Modifier.width(fieldWidth),
        )
        if (unit != null) Text(unit, color = vine.textSecondary, fontSize = 12.sp)
    }
}

/** Read-only `Label ........ value` row; [emphasis] tints the value. */
@Composable
private fun ValueRow(label: String, value: String, emphasis: Color? = null, italic: Boolean = false) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = emphasis ?: vine.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Text(
            value,
            color = emphasis ?: vine.textPrimary,
            fontSize = 14.sp,
            fontWeight = if (italic) FontWeight.Normal else FontWeight.SemiBold,
            fontStyle = if (italic) FontStyle.Italic else FontStyle.Normal,
            fontFamily = if (italic) null else FontFamily.Monospace,
        )
    }
}

/** iOS `vineSpacingSection`: slider, post spacing, derived intermediate posts. */
@Composable
private fun VineTrellisSpacingSection(
    vineSpacing: Double,
    onVineSpacing: (Double) -> Unit,
    postSpacing: String,
    onPostSpacing: (String) -> Unit,
    rowCount: Int,
    savedEffectiveRowLength: Double,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Vine & Trellis Spacing", onLight = true)
        VineyardCard {
            SliderRow("Vine Spacing", "%.2f m".format(vineSpacing), vineSpacing.toFloat(), 0.5f..3f) {
                onVineSpacing(it.toDouble())
            }
            Spacer(Modifier.height(8.dp))
            TrailingNumberRow(
                label = "Intermediate Post Spacing",
                value = postSpacing,
                placeholder = "0.00",
                unit = "m",
                keyboard = KeyboardType.Decimal,
                onChange = onPostSpacing,
            )
            val spacing = postSpacing.toDoubleOrNull()?.takeIf { it > 0 }
            if (spacing != null && savedEffectiveRowLength > 0) {
                // iOS: posts = floor(total / spacing) - 2 end posts per row, never negative.
                val posts = maxOf(0, (savedEffectiveRowLength / spacing).toInt() - 2 * maxOf(rowCount, 0))
                Spacer(Modifier.height(10.dp))
                ValueRow("Intermediate Posts", posts.toString(), emphasis = VineColors.EarthBrown)
            }
        }
        Text(
            "Vine Spacing is used to estimate vine count. Intermediate Post Spacing is the distance (m) between trellis posts inside a row, excluding the two end posts per row.",
            color = vine.textSecondary,
            fontSize = 12.sp,
        )
    }
}

/**
 * iOS `irrigationSection`: Flow per Emitter (L/hr), Emitter Spacing (m), Row
 * Spacing (read-only, bound to the block's row width), then the derived
 * Application Rate in mm/hr and the ML/ha/hr figure it is derived from.
 */
@Composable
private fun IrrigationSection(
    flowPerEmitter: String,
    onFlowPerEmitter: (String) -> Unit,
    emitterSpacing: String,
    onEmitterSpacing: (String) -> Unit,
    rowWidth: Double,
) {
    val vine = LocalVineColors.current
    val flow = flowPerEmitter.toDoubleOrNull()?.takeIf { it > 0 }
    val spacing = emitterSpacing.toDoubleOrNull()?.takeIf { it > 0 }
    val rate = irrigationApplicationRate(flow, spacing, rowWidth)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Irrigation", onLight = true)
        VineyardCard {
            TrailingNumberRow(
                label = "Flow per Emitter",
                value = flowPerEmitter,
                placeholder = "0.0",
                unit = "L/hr",
                keyboard = KeyboardType.Decimal,
                onChange = onFlowPerEmitter,
            )
            Spacer(Modifier.height(8.dp))
            TrailingNumberRow(
                label = "Emitter Spacing",
                value = emitterSpacing,
                placeholder = "0.00",
                unit = "m",
                keyboard = KeyboardType.Decimal,
                onChange = onEmitterSpacing,
            )
            Spacer(Modifier.height(10.dp))
            if (rowWidth > 0) {
                ValueRow("Row Spacing", "%.2f m".format(rowWidth))
            } else {
                ValueRow("Row Spacing", "Not set", emphasis = vine.textSecondary, italic = true)
            }
            HorizontalDivider(Modifier.padding(vertical = 10.dp), color = vine.cardBorder)
            if (rate != null) {
                ValueRow("Application Rate", "%.2f mm/hr".format(rate.mmPerHour), emphasis = IrrigationTeal)
                Spacer(Modifier.height(6.dp))
                ValueRow("ML/ha/hr", "%.4f".format(rate.megalitresPerHaPerHour), emphasis = VineColors.Info)
            } else {
                ValueRow("Application Rate", "Not calculable", emphasis = vine.textSecondary, italic = true)
            }
        }
        Text(
            "ML/ha/hr = (emitters per ha × flow) ÷ 1,000,000. mm/hr = ML/ha/hr × 100. " +
                "Row spacing (%.1f m) is used for the calculation.".format(rowWidth),
            color = vine.textSecondary,
            fontSize = 12.sp,
        )
    }
}

/** iOS `soilSection`: summary of the saved profile (read-only) + edit affordance. */
@Composable
private fun SoilSection(
    isNewBlock: Boolean,
    loading: Boolean,
    profile: BackendSoilProfile?,
    isAustralianVineyard: Boolean,
    canEdit: Boolean,
    onEdit: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Soil", onLight = true)
        VineyardCard {
            when {
                isNewBlock -> Text(
                    "Save this block first to set up its soil profile.",
                    color = vine.textSecondary, fontSize = 13.sp,
                )
                loading && profile == null -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = VineColors.Primary)
                    Text("Loading soil profile…", color = vine.textSecondary, fontSize = 13.sp)
                }
                profile != null -> SoilProfileSummary(profile)
                else -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("No soil profile set", color = vine.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                    Text(
                        if (isAustralianVineyard) {
                            "Tip: Use “Fetch from NSW SEED” in the editor to estimate the soil profile from your block centroid, or set it manually."
                        } else {
                            "Add a soil class, available water capacity and root depth so the Irrigation Advisor can produce soil-aware recommendations."
                        },
                        color = vine.textSecondary, fontSize = 12.sp,
                    )
                }
            }
            if (!isNewBlock) {
                Spacer(Modifier.height(6.dp))
                TextButton(onClick = onEdit, enabled = canEdit) {
                    Icon(
                        if (profile == null) Icons.Filled.Add else Icons.Filled.Edit,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.size(6.dp))
                    Text(if (profile == null) "Add soil profile" else "Edit soil profile")
                }
            }
        }
        Text(
            "Soil information feeds the Irrigation Advisor. Manual edits set a manual override so NSW SEED won't silently overwrite your values.",
            color = vine.textSecondary,
            fontSize = 12.sp,
        )
    }
}

/** Field-for-field port of iOS `soilProfileSummary`. */
@Composable
private fun SoilProfileSummary(soil: BackendSoilProfile) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SummaryLine("Soil class", soilClassDisplay(soil))
        soil.soilLandscape?.takeIf { it.isNotEmpty() }?.let { SummaryLine("Soil landscape", it) }
        soil.soilLandscapeCode?.takeIf { it.isNotEmpty() }?.let { SummaryLine("SALIS code", it) }
        soil.australianSoilClassification?.takeIf { it.isNotEmpty() }?.let { SummaryLine("Australian Soil Classification", it) }
        soil.landSoilCapability?.takeIf { it.isNotEmpty() }?.let { lsc ->
            SummaryLine("Land and Soil Capability", soil.landSoilCapabilityClass?.let { "$lsc (class $it)" } ?: lsc)
        }
        soil.availableWaterCapacityMmPerM?.takeIf { it > 0 }?.let { SummaryLine("AWC", "%.0f mm/m".format(it)) }
        soil.effectiveRootDepthM?.takeIf { it > 0 }?.let { SummaryLine("Effective root depth", "%.2f m".format(it)) }
        soil.managementAllowedDepletionPercent?.takeIf { it > 0 }?.let { SummaryLine("Allowed depletion", "%.0f%%".format(it)) }
        soil.rootZoneCapacityMm?.let { SummaryLine("Root-zone capacity", "%.0f mm".format(it)) }
        soil.readilyAvailableWaterMm?.let { SummaryLine("Readily available water", "%.0f mm".format(it)) }
        Row(verticalAlignment = Alignment.CenterVertically) {
            soil.confidence?.takeIf { it.isNotEmpty() }?.let {
                Text(
                    "Confidence: ${it.replaceFirstChar { c -> c.uppercase() }}",
                    color = vine.textSecondary, fontSize = 11.sp,
                )
            }
            Spacer(Modifier.weight(1f))
            when {
                soil.isManualOverride -> Text("Manual override", color = VineColors.Info, fontSize = 11.sp)
                soil.source == "nsw_seed" -> Text("NSW SEED", color = vine.textSecondary, fontSize = 11.sp)
            }
        }
        soil.manualNotes?.takeIf { it.isNotEmpty() }?.let {
            Text(it, color = vine.textSecondary, fontSize = 12.sp)
        }
    }
}

private fun soilClassDisplay(soil: BackendSoilProfile): String {
    soil.typedSoilClass?.let { return it.fallbackLabel }
    soil.irrigationSoilClass?.takeIf { it.isNotEmpty() }?.let { return it }
    return "Unknown"
}

private fun isAustralianCountry(country: String?): Boolean {
    val c = country?.trim()?.lowercase() ?: return false
    return c == "au" || c == "aus" || c == "australia"
}

/**
 * iOS `dangerZoneSection`: linked-record status, Archive, and Delete
 * permanently (only once the reference check confirms zero linked records).
 * Confirmation dialogs live in the parent; this only surfaces the actions.
 */
@Composable
private fun DangerZoneSection(
    loading: Boolean,
    counts: PaddockReferenceCounts?,
    checkFailed: Boolean,
    busy: Boolean,
    onArchive: () -> Unit,
    onDeletePermanently: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(14.dp))
            SectionHeader("Danger Zone", onLight = true, fillWidth = false)
        }
        VineyardCard {
            when {
                loading && counts == null -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = VineColors.Primary)
                    Text("Checking linked records…", color = vine.textSecondary, fontSize = 12.sp)
                }
                counts != null && counts.isEmpty -> Text(
                    "No linked records — safe to delete permanently.",
                    color = vine.textSecondary, fontSize = 12.sp,
                )
                counts != null -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Linked records found", color = vine.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    Text(counts.summaryLines.joinToString(", "), color = vine.textSecondary, fontSize = 11.sp)
                    Text(
                        "This block has linked records, so it cannot be permanently deleted. Archiving will remove it from active lists while keeping historical records intact.",
                        color = vine.textSecondary, fontSize = 11.sp,
                    )
                }
                checkFailed -> Text(
                    "Couldn’t check linked records.",
                    color = VineColors.Warning, fontSize = 12.sp,
                )
            }
            Spacer(Modifier.height(6.dp))
            TextButton(onClick = onArchive, enabled = !busy) {
                Icon(Icons.Filled.Archive, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(6.dp))
                Text("Archive block", color = VineColors.Destructive)
            }
            if (counts != null && counts.isEmpty) {
                TextButton(onClick = onDeletePermanently, enabled = !busy) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Delete permanently", color = VineColors.Destructive)
                }
            }
        }
        Text(
            "Archive removes the block from active selectors but keeps its history. Permanent delete is only offered when no linked records remain.",
            color = vine.textSecondary,
            fontSize = 12.sp,
        )
    }
}

/**
 * Resolves an allocation to the vineyard's master variety row (iOS
 * `PaddockVarietyResolver` light): by id, then key, then canonical name.
 */
private fun resolveAllocationVariety(
    alloc: PaddockVarietyAllocation,
    varieties: List<GrapeVarietyRow>,
): GrapeVarietyRow? {
    alloc.varietyId?.let { id -> varieties.firstOrNull { it.id.equals(id, ignoreCase = true) } }?.let { return it }
    alloc.varietyKey?.let { key -> varieties.firstOrNull { it.varietyKey == key } }?.let { return it }
    val canon = alloc.displayName?.let { canonicalVarietyName(it) } ?: return null
    return varieties.firstOrNull { it.canonicalName == canon }
}

/**
 * iOS variety allocation row: name + Optimal GDD (or a not-in-master warning),
 * trailing percent field and remove control, then Clone / Rootstock selector
 * rows with the shared-catalogue note. Tapping the name opens the full editor.
 */
@Composable
private fun AllocationRow(
    alloc: PaddockVarietyAllocation,
    variety: GrapeVarietyRow?,
    onPercent: (Double?) -> Unit,
    onEdit: () -> Unit,
    onRemove: () -> Unit,
    onPickClone: () -> Unit,
    onPickRootstock: () -> Unit,
) {
    val vine = LocalVineColors.current
    val displayName = variety?.displayName ?: alloc.displayName ?: alloc.varietyKey ?: "Unknown"
    val optimalGdd = variety?.let { it.optimalGddOverride ?: BuiltInGrapeVarietyGDD.gddForKey(it.varietyKey) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .clickable(onClick = onEdit)
                    .padding(vertical = 2.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(displayName, color = vine.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                when {
                    variety != null && optimalGdd != null ->
                        Text("Optimal: ${optimalGdd.toInt()} GDD", color = vine.textSecondary, fontSize = 11.sp)
                    variety == null && displayName != "Unknown" ->
                        Text("Not in master list — add in Settings → Grape Varieties", color = VineColors.Warning, fontSize = 11.sp)
                }
            }
            OutlinedTextField(
                value = alloc.percent?.let { formatNum(it) } ?: "",
                onValueChange = { onPercent(it.toDoubleOrNull()) },
                placeholder = { Text("0", fontSize = 14.sp) },
                singleLine = true,
                textStyle = LocalTextStyle.current.copy(
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                    textAlign = TextAlign.End,
                ),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.width(72.dp),
            )
            Text("%", color = vine.textSecondary, fontSize = 12.sp)
            IconButton(onClick = onRemove, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Filled.RemoveCircle, contentDescription = "Remove $displayName", tint = VineColors.Destructive)
            }
        }
        CatalogSelectorField(
            label = "Clone",
            value = alloc.clone?.takeIf { it.isNotBlank() } ?: "Not specified",
            hint = null,
            enabled = true,
            onClick = onPickClone,
        )
        CatalogSelectorField(
            label = "Rootstock",
            value = alloc.rootstock?.takeIf { it.isNotBlank() } ?: "Not recorded",
            hint = null,
            enabled = true,
            onClick = onPickRootstock,
        )
        Text(
            "Optional — from the shared catalogue, synced across devices",
            color = vine.textSecondary.copy(alpha = 0.8f),
            fontSize = 11.sp,
        )
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

// ---------------------------------------------------------------------------
// Vines per row (sql/188) — the Android twin of the iOS "Vines Per Row"
// section and RowVineCountEditorSheet.
// ---------------------------------------------------------------------------

/** Identifies the row currently open in the per-row vine-count editor. */
data class RowVineCountTarget(
    val number: Int,
    /**
     * The AUTOMATIC calculation for this row, carrying its reason when the
     * block can't produce a number yet.
     */
    val calculation: PaddockRowVineCount.Calculation,
) {
    val calculated: Int? get() = calculation.value
}

/**
 * One row of the compact vine-count list: its number, the automatically
 * calculated estimate, and the manual count when one is set.
 */
data class RowVineCountEntry(
    val number: Int,
    val calculation: PaddockRowVineCount.Calculation,
    val override: Int?,
) {
    val calculated: Int? get() = calculation.value

    /** The count actually in use — manual wins, else calculated. */
    val effective: Int? get() = override ?: calculation.value
    val isManual: Boolean get() = override != null
}

/**
 * Builds the live per-row list from the CURRENT draft geometry, so the numbers
 * update as the layout is edited — no save and no database round trip.
 * Matches the iOS `rowVineCountEntries`.
 */
private fun rowVineCountEntries(
    layout: BlockRowLayout,
    vineSpacing: Double,
    overrides: Map<Int, Int>,
): List<RowVineCountEntry> {
    val rows = layout.rows
    if (rows.isEmpty()) return emptyList()
    val centroidLat = rows.sumOf { (it.line.start.latitude + it.line.end.latitude) / 2.0 } / rows.size
    val mPerDegLat = 111_320.0
    val mPerDegLon = 111_320.0 * kotlin.math.cos(centroidLat * Math.PI / 180.0)
    return rows.map { row ->
        val dLat = (row.line.end.latitude - row.line.start.latitude) * mPerDegLat
        val dLon = (row.line.end.longitude - row.line.start.longitude) * mPerDegLon
        val length = kotlin.math.sqrt(dLat * dLat + dLon * dLon)
        RowVineCountEntry(
            number = row.number,
            calculation = PaddockRowVineCount.calculation(length, vineSpacing),
            override = overrides[row.number],
        )
    }.sortedBy { it.number }
}

@Composable
private fun RowVineCountsCard(
    entries: List<RowVineCountEntry>,
    onEditRow: (RowVineCountTarget) -> Unit,
    onClearAll: () -> Unit,
) {
    val vine = LocalVineColors.current
    val manualCount = entries.count { it.isManual }
    val total = entries.sumOf { it.effective ?: 0 }
    // Only ONE hint is worth showing, and it is the same for every row: the
    // block-level thing that has to be fixed first.
    val blockHint = entries.firstNotNullOfOrNull { entry ->
        entry.calculation.unavailable
            ?.takeIf { it == PaddockRowVineCount.Unavailable.MISSING_VINE_SPACING }
            ?.message
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Vines Per Row", onLight = true)
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                entries.forEach { entry ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .clickable {
                                onEditRow(RowVineCountTarget(entry.number, entry.calculation))
                            }
                            .padding(vertical = 10.dp, horizontal = 4.dp),
                    ) {
                        Text(
                            "Row ${entry.number}",
                            color = vine.textPrimary,
                            fontSize = 14.sp,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            entry.effective?.let { "%,d vines".format(it) } ?: "—",
                            color = if (entry.isManual) VineColors.LeafGreen else vine.textSecondary,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 14.sp,
                        )
                        if (entry.isManual) {
                            Text(
                                "Manual",
                                color = VineColors.LeafGreen,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 11.sp,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(VineColors.LeafGreen.copy(alpha = 0.14f))
                                    .padding(horizontal = 6.dp, vertical = 2.dp),
                            )
                        }
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            contentDescription = null,
                            tint = vine.textSecondary,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
                Spacer(Modifier.height(6.dp))
                if (blockHint != null) {
                    Text(blockHint, color = VineColors.Info, fontSize = 12.sp)
                } else {
                    Text(
                        "Total from rows: %,d vines".format(total) +
                            if (manualCount > 0) " \u00b7 $manualCount manual" else "",
                        color = vine.textSecondary,
                        fontSize = 12.sp,
                    )
                }
                Text(
                    "Every row's vines are calculated automatically from its own length " +
                        "and the block's vine spacing. Tap a row only to record a different " +
                        "real count. Manual counts are used by piece-rate pruning costing; " +
                        "the Block Summary vine count above is unchanged and still drives " +
                        "water, spray and yield estimates.",
                    color = vine.textSecondary,
                    fontSize = 12.sp,
                )
                if (manualCount > 0) {
                    TextButton(onClick = onClearAll) { Text("Clear all manual counts") }
                }
            }
        }
    }
}

/**
 * The single-row vine-count editor (sql/188).
 *
 * Deliberately minimal — this is not a row-management workflow. It shows the
 * three numbers a grower needs and nothing else: the calculated estimate, the
 * optional manual override, and the count actually being used.
 *
 * The calculated value is ALWAYS derived automatically from this row's own
 * length and the block's vine spacing — the grower never has to type anything
 * to get a vine count. Clearing the field immediately returns to it.
 */
@Composable
private fun RowVineCountDialog(
    target: RowVineCountTarget,
    currentOverride: Int?,
    onDismiss: () -> Unit,
    onSave: (Int?) -> Unit,
) {
    val vine = LocalVineColors.current
    var text by remember(target.number) { mutableStateOf(currentOverride?.toString() ?: "") }
    val parsed = PaddockRowVineCount.parseOverride(text)
    val effective = parsed.value ?: target.calculated
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Row ${target.number}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Calculated vines", color = vine.textSecondary, fontSize = 14.sp)
                    Text(
                        target.calculated?.let { "%,d".format(it) } ?: "—",
                        color = vine.textSecondary,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                    )
                }
                target.calculation.message?.let {
                    Text(it, color = VineColors.Info, fontSize = 12.sp)
                }
                NumberField("Manual override", text, KeyboardType.Number) { text = it }
                parsed.message?.let {
                    Text(it, color = VineColors.Destructive, fontSize = 12.sp)
                }
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Using", color = vine.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                    Text(
                        effective?.let { "%,d vines".format(it) } ?: "—",
                        color = VineColors.LeafGreen,
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp,
                    )
                }
                Text(
                    "Leave blank to use the calculated estimate from this row's length " +
                        "and the block's vine spacing. Whole vines only.",
                    color = vine.textSecondary,
                    fontSize = 12.sp,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = !parsed.isInvalid,
                onClick = {
                    onSave(parsed.value)
                    onDismiss()
                },
            ) { Text("Done", fontWeight = FontWeight.SemiBold) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/**
 * iOS `blockSummarySection`: Calculated Row Length, Estimated Vines, then the
 * Calculation Overrides (Row Length, Vine Count) with a reset when active. The
 * override fields are the SAME state the save path already writes.
 */
@Composable
private fun BlockSummaryCard(
    calculatedRowLengthM: Double,
    vineSpacing: Double,
    rowLengthOverride: String,
    onRowLengthOverride: (String) -> Unit,
    vineCountOverride: String,
    onVineCountOverride: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    // iOS: estimated vines use the override row length when one is typed.
    val effectiveRowLength = rowLengthOverride.toDoubleOrNull() ?: calculatedRowLengthM
    val estimatedVines = if (vineSpacing > 0) (effectiveRowLength / vineSpacing).toInt() else 0
    val overrideActive = rowLengthOverride.isNotEmpty() || vineCountOverride.isNotEmpty()
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Block Summary", onLight = true)
        VineyardCard {
            ValueRow("Calculated Row Length", "%.0f m".format(calculatedRowLengthM), emphasis = vine.textSecondary)
            Spacer(Modifier.height(6.dp))
            ValueRow("Estimated Vines", estimatedVines.toString(), emphasis = VineColors.Info)
            HorizontalDivider(Modifier.padding(vertical = 10.dp), color = vine.cardBorder)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Calculation Overrides", color = vine.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Text(
                    "Used for water usage & yield estimates only — does not affect trip path tracking.",
                    color = vine.textSecondary, fontSize = 12.sp,
                )
                TrailingNumberRow(
                    label = "Row Length",
                    value = rowLengthOverride,
                    placeholder = "%.0f".format(calculatedRowLengthM),
                    unit = "m",
                    keyboard = KeyboardType.Decimal,
                    onChange = onRowLengthOverride,
                    fieldWidth = 104.dp,
                )
                TrailingNumberRow(
                    label = "Vine Count",
                    value = vineCountOverride,
                    placeholder = estimatedVines.toString(),
                    unit = null,
                    keyboard = KeyboardType.Number,
                    onChange = onVineCountOverride,
                    fieldWidth = 104.dp,
                )
                if (overrideActive) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.Edit, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.size(6.dp))
                        Text("Manual override active", color = VineColors.Warning, fontSize = 12.sp, modifier = Modifier.weight(1f))
                        TextButton(onClick = { onRowLengthOverride(""); onVineCountOverride("") }) { Text("Reset All", fontSize = 12.sp) }
                    }
                }
            }
        }
        Text(
            "Row length and vine count are auto-calculated from boundary geometry. Override values here for more accurate water usage and yield calculations — trip path tracking always uses the mapped row geometry.",
            color = vine.textSecondary,
            fontSize = 12.sp,
        )
    }
}

/** iOS `.teal` used for the Application Rate row. */
private val IrrigationTeal = Color(0xFF30B0C7)

/** Derived irrigation figures, in the two units iOS displays. */
private data class IrrigationRate(val megalitresPerHaPerHour: Double, val mmPerHour: Double)

/**
 * iOS `irrigationSection` maths: emitters/ha = 10,000 ÷ (row width × emitter
 * spacing); L/ha/hr = emitters/ha × flow; ML/ha/hr = L/ha/hr ÷ 1,000,000;
 * mm/hr = ML/ha/hr × 100. Same formula as before, now exposing both units.
 */
private fun irrigationApplicationRate(flow: Double?, emitterSpacing: Double?, rowWidth: Double?): IrrigationRate? {
    if (flow == null || emitterSpacing == null || rowWidth == null) return null
    if (flow <= 0 || emitterSpacing <= 0 || rowWidth <= 0) return null
    val emittersPerHa = 10_000.0 / (rowWidth * emitterSpacing)
    val litresPerHaPerHour = emittersPerHa * flow
    val ml = litresPerHaPerHour / 1_000_000.0
    return IrrigationRate(megalitresPerHaPerHour = ml, mmPerHour = ml * 100.0)
}

private fun formatNum(v: Double): String =
    if (v % 1.0 == 0.0) v.toLong().toString() else "%.2f".format(v).trimEnd('0').trimEnd('.')

private val editDateFormatter = java.time.format.DateTimeFormatter.ofPattern("d MMM yyyy", java.util.Locale.getDefault())

private fun formatBlockDate(iso: String?): String? {
    val ms = com.rork.vinetrack.data.model.parseIsoToEpochMs(iso) ?: return null
    return Instant.ofEpochMilli(ms).atZone(java.time.ZoneId.systemDefault()).format(editDateFormatter)
}
