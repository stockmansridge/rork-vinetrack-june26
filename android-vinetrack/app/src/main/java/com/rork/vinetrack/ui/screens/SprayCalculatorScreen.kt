package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Calculate
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Science
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImagePainter
import coil3.compose.SubcomposeAsyncImage
import coil3.compose.SubcomposeAsyncImageContent
import com.rork.vinetrack.data.CanopyWaterRates
import com.rork.vinetrack.data.CanopyWaterRatesStore
import com.rork.vinetrack.data.SprayCalculator
import com.rork.vinetrack.data.SprayRecordRepository
import com.rork.vinetrack.data.TrackingPattern
import com.rork.vinetrack.data.TripRowSequencePlanner
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.sprayOperationTypes
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.SprayJobRowPlan
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.Instant
import java.util.Locale
import java.util.UUID
import kotlin.math.abs

/** Mutable editor state for one chemical line in the calculator. */
private class CalcChemLine(
    savedChemicalId: String,
    name: String,
    unit: String,
    basis: SprayCalculator.RateBasis,
    rate: String,
    costPerUnit: Double?,
) {
    var savedChemicalId by mutableStateOf(savedChemicalId)
    var name by mutableStateOf(name)
    var unit by mutableStateOf(unit)
    var basis by mutableStateOf(basis)
    var rate by mutableStateOf(rate)
    var costPerUnit by mutableStateOf(costPerUnit)
}

/**
 * Android Spray Calculator — a focused port of the iOS `SprayCalculatorView`.
 *
 * Flow: pick blocks → pick equipment (tank) → choose canopy size/density (with
 * row spacing) to derive the recommended water rate (L/ha) from the on-device
 * [CanopyWaterRates] → optionally override the spray rate (with a live
 * concentration factor) → add chemical lines from the saved-chemical library →
 * calculate the tank mix → save it as a new spray record.
 *
 * It reuses the existing create path (`createSprayRecord`) so the manual "Log a
 * spray" flow is untouched. Costing is gated to owner/manager, matching the rest
 * of the spray module.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayCalculatorScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onSaved: () -> Unit = {},
    onJobStarted: ((String) -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val canopyRates = remember { CanopyWaterRatesStore(context).load() }
    val canEditCost = state.currentRole == "owner" || state.currentRole == "manager"

    var sprayName by remember { mutableStateOf("") }
    var operationType by remember { mutableStateOf(sprayOperationTypes.first()) }
    val selectedPaddockIds = remember { mutableStateListOf<String>() }
    var sprayEquipmentId by remember { mutableStateOf<String?>(null) }
    var canopySize by remember { mutableStateOf(SprayCalculator.CanopySize.MEDIUM) }
    var canopyDensity by remember { mutableStateOf(SprayCalculator.CanopyDensity.LOW) }
    var rowSpacingText by remember { mutableStateOf("") }
    var hasEditedRowSpacing by remember { mutableStateOf(false) }
    var sprayRateText by remember { mutableStateOf("") }
    var hasEditedSprayRate by remember { mutableStateOf(false) }
    val chemLines = remember { mutableStateListOf<CalcChemLine>() }

    // Row plan (Stage 3B) — only used when saving a job for later.
    var trackingPattern by remember { mutableStateOf(TrackingPattern.SEQUENTIAL) }
    var startPath by remember { mutableStateOf(0.5) }
    var directionHigherFirst by remember { mutableStateOf(true) }

    var result by remember { mutableStateOf<SprayCalculator.Result?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    var showTemplateDialog by remember { mutableStateOf(false) }
    var templateNameText by remember { mutableStateOf("") }

    val selectedPaddocks = remember(selectedPaddockIds.toList(), state.paddocks) {
        state.paddocks.filter { selectedPaddockIds.contains(it.id) }
    }
    val totalArea = selectedPaddocks.sumOf { it.areaHectares }

    // Average row spacing across selected blocks (default 2.5m, matching iOS).
    val averageRowSpacing = remember(selectedPaddocks) {
        val widths = selectedPaddocks.mapNotNull { it.rowWidth?.takeIf { w -> w > 0 } }
        if (widths.isEmpty()) 2.5 else widths.sum() / widths.size
    }
    val rowSpacing = if (hasEditedRowSpacing) (rowSpacingText.toDoubleOrNull() ?: averageRowSpacing) else averageRowSpacing

    val per100m = SprayCalculator.litresPer100m(canopyRates, canopySize, canopyDensity)
    val recommendedRate = CanopyWaterRates.litresPerHa(per100m, rowSpacing)
    val chosenRate = if (hasEditedSprayRate) (sprayRateText.toDoubleOrNull() ?: recommendedRate) else recommendedRate
    val concentrationFactor = if (chosenRate > 0) recommendedRate / chosenRate else 1.0
    val usesCF = SprayCalculator.usesConcentrationFactor(operationType)

    val selectedEquipment = state.sprayEquipment.firstOrNull { it.id == sprayEquipmentId }
    val tankCapacity = selectedEquipment?.tankCapacityLitres?.takeIf { it > 0 } ?: 0.0

    // Row-plan derived values. Blocks are ordered by lowest row number first so
    // the path math matches iOS for multi-block selections.
    val orderedSelectedPaddocks = remember(selectedPaddocks) {
        selectedPaddocks.sortedWith(TripRowSequencePlanner.rowOrderComparator)
    }
    val hasRowGeometry = remember(orderedSelectedPaddocks) {
        TripRowSequencePlanner.hasAnyRowGeometry(orderedSelectedPaddocks)
    }
    val availablePaths = remember(orderedSelectedPaddocks) {
        TripRowSequencePlanner.availablePaths(orderedSelectedPaddocks)
    }
    // Re-snap the start path into the valid range whenever the selection changes.
    LaunchedEffect(availablePaths) {
        startPath = if (availablePaths.none { abs(it - startPath) < 0.01 }) {
            availablePaths.firstOrNull() ?: 0.5
        } else {
            TripRowSequencePlanner.clampedStartPath(startPath, orderedSelectedPaddocks)
        }
    }
    val pathSequence = remember(orderedSelectedPaddocks, trackingPattern, startPath, directionHigherFirst) {
        if (!hasRowGeometry || trackingPattern == TrackingPattern.FREE_DRIVE) emptyList()
        else TripRowSequencePlanner.generateSequence(orderedSelectedPaddocks, trackingPattern, startPath, directionHigherFirst)
    }
    val rowGuidanceHelperText = remember(orderedSelectedPaddocks) {
        val n = TripRowSequencePlanner.combinedTotalRows(orderedSelectedPaddocks)
        if (n <= 0) {
            "Row guidance unavailable for the selected blocks"
        } else {
            val range = TripRowSequencePlanner.combinedRangeLabel(orderedSelectedPaddocks)
            val paths = TripRowSequencePlanner.combinedPathsLabel(orderedSelectedPaddocks)
            if (orderedSelectedPaddocks.size > 1) "Row guidance follows all selected blocks ($range \u00b7 $paths)"
            else "Row guidance follows selected block ($range \u00b7 $paths)"
        }
    }

    fun runCalculation() {
        errorMessage = null
        if (selectedPaddockIds.isEmpty()) {
            errorMessage = "Select at least one block."
            return
        }
        if (totalArea <= 0) {
            errorMessage = "Selected blocks have no mapped area to calculate against."
            return
        }
        if (rowSpacing <= 0) {
            errorMessage = "Row spacing must be greater than zero."
            return
        }
        if (tankCapacity <= 0) {
            errorMessage = "Select spray equipment with a tank capacity."
            return
        }
        if (chosenRate <= 0) {
            errorMessage = "Water rate must be greater than zero."
            return
        }
        val lines = chemLines
            .filter { it.name.isNotBlank() }
            .map {
                SprayCalculator.Line(
                    savedChemicalId = it.savedChemicalId,
                    name = it.name.trim(),
                    unit = it.unit,
                    basis = it.basis,
                    rate = it.rate.toDoubleOrNull() ?: 0.0,
                    costPerUnit = if (canEditCost) it.costPerUnit else null,
                )
            }
        if (lines.isEmpty()) {
            errorMessage = "Add at least one chemical to calculate the mix."
            return
        }
        result = SprayCalculator.calculate(
            selectedPaddocks = selectedPaddocks,
            waterRateLitresPerHectare = chosenRate,
            tankCapacity = tankCapacity,
            lines = lines,
            concentrationFactor = if (usesCF) concentrationFactor else 1.0,
            operationType = operationType,
        )
    }

    fun buildInput(asTemplate: Boolean, templateName: String?): SprayRecordRepository.SprayInput {
        val r = result!!
        val iso = Instant.now().toString()
        val tanks = SprayCalculator.buildTanks(r, chosenRate)
        val reference = if (asTemplate) templateName?.trim()?.ifBlank { null } else sprayName.trim().ifBlank { null }
        return SprayRecordRepository.SprayInput(
            date = iso,
            startTime = iso,
            temperature = null,
            windSpeed = null,
            windDirection = null,
            humidity = null,
            sprayReference = reference,
            notes = null,
            numberOfFansJets = null,
            averageSpeed = null,
            equipmentType = selectedEquipment?.displayName,
            tractor = null,
            tractorGear = null,
            machineId = null,
            sprayEquipmentId = sprayEquipmentId,
            operationType = operationType,
            tripId = null,
            isTemplate = asTemplate,
            tanks = tanks,
        )
    }

    fun saveRecord(asTemplate: Boolean, templateName: String? = null) {
        result ?: return
        if (saving) return
        saving = true
        vm.createSprayRecord(buildInput(asTemplate, templateName)) { ok ->
            saving = false
            if (ok) onSaved()
        }
    }

    /**
     * Save the calculated mix as a "Not Started" spray job: an inactive spray
     * trip plus a linked spray record (mirrors iOS `saveForLater`). The first
     * selected block links the trip; the comma-joined block names are the
     * trip's display name.
     */
    /** Build the shared row plan for the current calculator selection. */
    fun buildRowPlan(totalTanks: Int): SprayJobRowPlan {
        // Free Drive when the user chose it or when no block has row geometry.
        val effectivePattern = if (hasRowGeometry) trackingPattern else TrackingPattern.FREE_DRIVE
        return SprayJobRowPlan(
            trackingPattern = effectivePattern.rawValue,
            rowSequence = pathSequence,
            totalTanks = totalTanks,
        )
    }

    fun saveJobForLater() {
        val r = result ?: return
        if (saving) return
        saving = true
        val firstPaddock = selectedPaddocks.firstOrNull()
        val paddockNames = selectedPaddocks.joinToString(", ") { it.name }
        vm.createSprayJobForLater(
            input = buildInput(asTemplate = false, templateName = null),
            paddockId = firstPaddock?.id,
            paddockName = paddockNames,
            rowPlan = buildRowPlan(r.totalTanks),
        ) { ok ->
            saving = false
            if (ok) onSaved()
        }
    }

    /**
     * Start the calculated job immediately as an active trip and jump to the
     * live Trips detail, mirroring "Start job now" from the spray detail.
     */
    fun startJobNow() {
        val r = result ?: return
        if (saving) return
        if (state.activeTrip != null) {
            errorMessage = "Finish the active trip before starting another spray job."
            return
        }
        saving = true
        val firstPaddock = selectedPaddocks.firstOrNull()
        val paddockNames = selectedPaddocks.joinToString(", ") { it.name }
        vm.startSprayJobNow(
            input = buildInput(asTemplate = false, templateName = null),
            paddockId = firstPaddock?.id,
            paddockName = paddockNames,
            rowPlan = buildRowPlan(r.totalTanks),
        ) { ok ->
            saving = false
            if (ok) {
                val startedId = vm.activeTripIdOrNull()
                onSaved()
                if (startedId != null) onJobStarted?.invoke(startedId)
            } else {
                errorMessage = state.sprayError ?: "Couldn't start the spray job."
            }
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Spray Calculator") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                OutlinedTextField(
                    value = sprayName,
                    onValueChange = { sprayName = it },
                    label = { Text("Spray name (optional)") },
                    placeholder = { Text("e.g. Downy Mildew Spray #3") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            // Operation type
            item {
                var menu by remember { mutableStateOf(false) }
                ExposedDropdownMenuBox(expanded = menu, onExpandedChange = { menu = it }) {
                    OutlinedTextField(
                        value = operationType,
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Operation type") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = menu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        sprayOperationTypes.forEach { op ->
                            DropdownMenuItem(text = { Text(op) }, onClick = { operationType = op; menu = false })
                        }
                    }
                }
            }

            // Blocks
            item { SectionHeader("Blocks", onLight = true) }
            item {
                VineyardCard {
                    if (state.paddocks.isEmpty()) {
                        Text("No blocks configured", fontSize = 13.sp, color = vine.textSecondary)
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            state.paddocks.forEach { p ->
                                val selected = selectedPaddockIds.contains(p.id)
                                BlockSelectRow(
                                    paddock = p,
                                    selected = selected,
                                    onToggle = {
                                        if (selected) selectedPaddockIds.remove(p.id)
                                        else selectedPaddockIds.add(p.id)
                                        result = null
                                    },
                                )
                            }
                            if (selectedPaddockIds.isNotEmpty()) {
                                Box(Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
                                Row(Modifier.fillMaxWidth()) {
                                    StatCell("${selectedPaddockIds.size}", if (selectedPaddockIds.size == 1) "Block" else "Blocks", Modifier.weight(1f))
                                    StatCell(fmtNum(totalArea, 2), "Hectares", Modifier.weight(1f))
                                    StatCell(fmtNum(averageRowSpacing, 1) + "m", "Row spacing", Modifier.weight(1f))
                                }
                            }
                        }
                    }
                }
            }

            // Equipment
            item { SectionHeader("Equipment", onLight = true) }
            item {
                var menu by remember { mutableStateOf(false) }
                val label = selectedEquipment?.let {
                    val cap = it.tankCapacityLitres?.takeIf { c -> c > 0 }?.let { c -> " · ${fmtNum(c, 0)} L" } ?: ""
                    it.displayName + cap
                } ?: "Select spray equipment"
                ExposedDropdownMenuBox(expanded = menu, onExpandedChange = { menu = it }) {
                    OutlinedTextField(
                        value = label,
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Spray equipment") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = menu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        if (state.sprayEquipment.isEmpty()) {
                            DropdownMenuItem(text = { Text("No equipment configured") }, onClick = { menu = false })
                        }
                        state.sprayEquipment.forEach { eq ->
                            val cap = eq.tankCapacityLitres?.takeIf { it > 0 }?.let { " · ${fmtNum(it, 0)} L" } ?: ""
                            DropdownMenuItem(
                                text = { Text(eq.displayName + cap) },
                                onClick = { sprayEquipmentId = eq.id; menu = false; result = null },
                            )
                        }
                    }
                }
            }

            // Water rate
            item { SectionHeader("Calculated Water Rate", onLight = true) }
            item {
                Text(
                    "Based on row widths & canopy status",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp),
                )
            }
            item {
                VineyardCard {
                    Text("VSP Canopy Size", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
                    Spacer8()
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        SprayCalculator.CanopySize.entries.forEachIndexed { i, sz ->
                            SegmentedButton(
                                selected = canopySize == sz,
                                onClick = { canopySize = sz; result = null },
                                shape = SegmentedButtonDefaults.itemShape(i, SprayCalculator.CanopySize.entries.size),
                            ) { Text(sz.label, fontSize = 13.sp) }
                        }
                    }
                    Text(canopySize.description, fontSize = 11.sp, color = vine.textSecondary, modifier = Modifier.padding(top = 4.dp))

                    Spacer8()
                    Box(
                        Modifier.fillMaxWidth().height(140.dp).clip(RoundedCornerShape(8.dp))
                            .background(Color.White).padding(8.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        SubcomposeAsyncImage(
                            model = canopySize.referenceImageUrl,
                            contentDescription = "${canopySize.label} canopy reference diagram",
                            contentScale = ContentScale.Fit,
                            modifier = Modifier.fillMaxWidth().height(124.dp),
                        ) {
                            when (painter.state.collectAsState().value) {
                                is AsyncImagePainter.State.Loading -> CircularProgressIndicator(
                                    modifier = Modifier.size(28.dp),
                                    strokeWidth = 2.5.dp,
                                    color = VineColors.DarkGreen,
                                )
                                is AsyncImagePainter.State.Error -> Text(
                                    "Reference image unavailable. Use the canopy description above.",
                                    fontSize = 11.sp,
                                    color = vine.textSecondary,
                                    textAlign = TextAlign.Center,
                                    modifier = Modifier.padding(horizontal = 16.dp),
                                )
                                else -> SubcomposeAsyncImageContent()
                            }
                        }
                    }

                    Spacer12()
                    Text("Canopy Density", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
                    Spacer8()
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        SprayCalculator.CanopyDensity.entries.forEachIndexed { i, d ->
                            SegmentedButton(
                                selected = canopyDensity == d,
                                onClick = { canopyDensity = d; result = null },
                                shape = SegmentedButtonDefaults.itemShape(i, SprayCalculator.CanopyDensity.entries.size),
                            ) { Text(d.label, fontSize = 13.sp) }
                        }
                    }
                    Text(canopyDensity.description, fontSize = 11.sp, color = vine.textSecondary, modifier = Modifier.padding(top = 4.dp))

                    Spacer12()
                    OutlinedTextField(
                        value = if (hasEditedRowSpacing) rowSpacingText else fmtNum(averageRowSpacing, 1),
                        onValueChange = { rowSpacingText = it.filter { c -> c.isDigit() || c == '.' }; hasEditedRowSpacing = true; result = null },
                        label = { Text("Row spacing (m)") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )

                    Spacer12()
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                            .background(VineColors.LeafGreen.copy(alpha = 0.10f)).padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("Volume", fontSize = 12.sp, color = vine.textSecondary)
                            Text("${fmtNum(recommendedRate, 0)} L/ha", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = VineColors.DarkGreen)
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text("Per 100m row", fontSize = 12.sp, color = vine.textSecondary)
                            Text("${fmtNum(per100m, 0)} L", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        }
                    }

                    if (usesCF) {
                        Spacer12()
                        Text("Spray Rate & Concentration Factor", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
                        Spacer8()
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedTextField(
                                value = if (hasEditedSprayRate) sprayRateText else fmtNum(recommendedRate, 0),
                                onValueChange = { sprayRateText = it.filter { c -> c.isDigit() || c == '.' }; hasEditedSprayRate = true; result = null },
                                label = { Text("Chosen Spray Rate (L/ha)") },
                                singleLine = true,
                                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                modifier = Modifier.weight(1f),
                            )
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Text("CF", fontSize = 12.sp, color = vine.textSecondary)
                                Text(
                                    "%.2f".format(concentrationFactor),
                                    fontSize = 20.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = if (concentrationFactor == 1.0) VineColors.DarkGreen else VineColors.Orange,
                                )
                            }
                        }
                    }
                }
            }

            // Row plan (used when saving a job for later)
            item { SectionHeader("Row Plan", onLight = true) }
            item {
                VineyardCard {
                    var patternMenu by remember { mutableStateOf(false) }
                    Text("Tracking pattern", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
                    Spacer8()
                    ExposedDropdownMenuBox(expanded = patternMenu, onExpandedChange = { patternMenu = it }) {
                        OutlinedTextField(
                            value = trackingPattern.title,
                            onValueChange = {},
                            readOnly = true,
                            label = { Text("Pattern") },
                            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = patternMenu) },
                            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                        )
                        ExposedDropdownMenu(expanded = patternMenu, onDismissRequest = { patternMenu = false }) {
                            TrackingPattern.entries.forEach { p ->
                                DropdownMenuItem(
                                    text = {
                                        Column {
                                            Text(p.title)
                                            Text(p.subtitle, fontSize = 12.sp, color = vine.textSecondary)
                                        }
                                    },
                                    onClick = { trackingPattern = p; patternMenu = false },
                                )
                            }
                        }
                    }
                    Text(trackingPattern.subtitle, fontSize = 11.sp, color = vine.textSecondary, modifier = Modifier.padding(top = 4.dp))

                    when {
                        !hasRowGeometry -> {
                            Spacer12()
                            Text(
                                "Row guidance unavailable — selected blocks have no row geometry. The job will be saved as Free Drive.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                        trackingPattern == TrackingPattern.FREE_DRIVE -> {
                            Spacer12()
                            Text(
                                "No planned row sequence — rows are detected live from GPS while you drive.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                        else -> {
                            Spacer12()
                            Text(rowGuidanceHelperText, fontSize = 11.sp, color = vine.textSecondary)

                            Spacer8()
                            var pathMenu by remember { mutableStateOf(false) }
                            ExposedDropdownMenuBox(expanded = pathMenu, onExpandedChange = { pathMenu = it }) {
                                OutlinedTextField(
                                    value = TripRowSequencePlanner.pathMenuLabel(startPath, orderedSelectedPaddocks),
                                    onValueChange = {},
                                    readOnly = true,
                                    label = { Text("Start path") },
                                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = pathMenu) },
                                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                                )
                                ExposedDropdownMenu(expanded = pathMenu, onDismissRequest = { pathMenu = false }) {
                                    availablePaths.forEach { path ->
                                        DropdownMenuItem(
                                            text = { Text(TripRowSequencePlanner.pathMenuLabel(path, orderedSelectedPaddocks)) },
                                            onClick = { startPath = path; pathMenu = false },
                                        )
                                    }
                                }
                            }

                            Spacer12()
                            Text("Sequence direction", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
                            Spacer8()
                            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                                SegmentedButton(
                                    selected = !directionHigherFirst,
                                    onClick = { directionHigherFirst = false },
                                    shape = SegmentedButtonDefaults.itemShape(0, 2),
                                ) { Text("Higher to lower", fontSize = 13.sp) }
                                SegmentedButton(
                                    selected = directionHigherFirst,
                                    onClick = { directionHigherFirst = true },
                                    shape = SegmentedButtonDefaults.itemShape(1, 2),
                                ) { Text("Lower to higher", fontSize = 13.sp) }
                            }

                            Spacer12()
                            TripRowSequencePlanner.patternPreviewNote(trackingPattern)?.let { note ->
                                Text(note, fontSize = 11.sp, color = vine.textSecondary)
                                Spacer8()
                            }
                            if (pathSequence.isEmpty()) {
                                Text("No sequence available for the current selection.", fontSize = 12.sp, color = vine.textSecondary)
                            } else {
                                Column(
                                    Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                                        .background(VineColors.Indigo.copy(alpha = 0.08f)).padding(12.dp),
                                ) {
                                    Text(
                                        TripRowSequencePlanner.sequencePreviewText(pathSequence),
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.Medium,
                                        color = vine.textPrimary,
                                    )
                                    Text(
                                        "${pathSequence.size} path${if (pathSequence.size == 1) "" else "s"} planned",
                                        fontSize = 11.sp,
                                        color = vine.textSecondary,
                                        modifier = Modifier.padding(top = 2.dp),
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // Chemicals
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SectionHeader("Chemicals · ${chemLines.size}", onLight = true, modifier = Modifier.weight(1f))
                    TextButton(
                        onClick = {
                            chemLines.add(CalcChemLine("", "", "Litres", SprayCalculator.RateBasis.PER_HECTARE, "", null))
                            result = null
                        },
                        enabled = state.savedChemicals.isNotEmpty(),
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp), tint = VineColors.PrimaryAccent)
                        Text("  Add", color = VineColors.PrimaryAccent, fontSize = 13.sp)
                    }
                }
            }
            if (state.savedChemicals.isEmpty()) {
                item {
                    Text(
                        "Add saved chemicals from Spray Management to use them here.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                }
            }
            itemsIndexed(chemLines) { idx, line ->
                ChemLineEditor(
                    line = line,
                    savedChemicals = state.savedChemicals,
                    canEditCost = canEditCost,
                    usesCF = usesCF,
                    onChanged = { result = null },
                    onRemove = { chemLines.removeAt(idx); result = null },
                )
            }

            errorMessage?.let { msg ->
                item {
                    Text(
                        msg,
                        fontSize = 13.sp,
                        color = VineColors.Warning,
                        modifier = Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .background(VineColors.Warning.copy(alpha = 0.12f))
                            .padding(10.dp),
                    )
                }
            }

            item {
                Button(
                    onClick = { runCalculation() },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.PrimaryAccent),
                ) {
                    Icon(Icons.Filled.Calculate, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Calculate mix")
                }
            }

            result?.let { r ->
                item { ResultsCard(r) }
                if (canEditCost && r.hasCostData) {
                    item { CostingCard(r) }
                }
                item {
                    val hasActiveTrip = state.activeTrip != null
                    Button(
                        onClick = { startJobNow() },
                        enabled = !saving && !hasActiveTrip,
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.PrimaryAccent),
                    ) {
                        if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                        else {
                            Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                            Text("  Start now")
                        }
                    }
                    if (hasActiveTrip) {
                        Text(
                            "Finish the active trip before starting this spray job.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.padding(top = 6.dp),
                        )
                    }
                }
                item {
                    Button(
                        onClick = { saveRecord(asTemplate = false) },
                        enabled = !saving,
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.DarkGreen),
                    ) {
                        if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                        else {
                            Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                            Text("  Save as spray record")
                        }
                    }
                }
                item {
                    androidx.compose.material3.OutlinedButton(
                        onClick = { saveJobForLater() },
                        enabled = !saving,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Schedule, contentDescription = null, modifier = Modifier.size(18.dp), tint = VineColors.DarkGreen)
                        Text("  Save job for later", color = VineColors.DarkGreen)
                    }
                }
                item {
                    androidx.compose.material3.OutlinedButton(
                        onClick = {
                            templateNameText = sprayName.trim()
                            showTemplateDialog = true
                        },
                        enabled = !saving,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.ContentCopy, contentDescription = null, modifier = Modifier.size(18.dp), tint = VineColors.Indigo)
                        Text("  Save as template", color = VineColors.Indigo)
                    }
                }
                item {
                    Text(
                        "Start now begins tracking an active spray trip right away, using the row plan above. Save as spray record logs the spray now without starting a trip. Save job for later creates a Not Started job you can start from the field. Save as template saves a reusable setup for your Spray Program.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
            }
        }
    }

    if (showTemplateDialog) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showTemplateDialog = false },
            title = { Text("Save as template") },
            text = {
                Column {
                    Text(
                        "Save this calculated mix as a reusable template in your Spray Program.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                    Spacer12()
                    OutlinedTextField(
                        value = templateNameText,
                        onValueChange = { templateNameText = it },
                        label = { Text("Template name") },
                        placeholder = { Text("e.g. Downy Mildew Program") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = templateNameText.isNotBlank() && !saving,
                    onClick = {
                        val name = templateNameText.trim()
                        showTemplateDialog = false
                        saveRecord(asTemplate = true, templateName = name)
                    },
                ) { Text("Save template") }
            },
            dismissButton = {
                TextButton(onClick = { showTemplateDialog = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun BlockSelectRow(paddock: Paddock, selected: Boolean, onToggle: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onToggle() }.padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            if (selected) Icons.Filled.Check else Icons.Filled.Add,
            contentDescription = null,
            tint = if (selected) VineColors.PrimaryAccent else vine.textSecondary,
            modifier = Modifier.size(20.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(paddock.name, fontWeight = FontWeight.Medium, color = vine.textPrimary, fontSize = 15.sp)
            if (paddock.areaHectares > 0) {
                Text("${fmtNum(paddock.areaHectares, 2)} ha", fontSize = 12.sp, color = vine.textSecondary)
            }
        }
    }
}

@Composable
private fun StatCell(value: String, label: String, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontWeight = FontWeight.Bold, color = vine.textPrimary, fontSize = 16.sp)
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChemLineEditor(
    line: CalcChemLine,
    savedChemicals: List<SavedChemical>,
    canEditCost: Boolean,
    usesCF: Boolean,
    onChanged: () -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    var menu by remember { mutableStateOf(false) }
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ExposedDropdownMenuBox(expanded = menu, onExpandedChange = { menu = it }, modifier = Modifier.weight(1f)) {
                OutlinedTextField(
                    value = line.name.ifBlank { "Select chemical" },
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Chemical") },
                    leadingIcon = { Icon(Icons.Filled.Science, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp)) },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = menu) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                )
                ExposedDropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    savedChemicals.forEach { saved ->
                        DropdownMenuItem(
                            text = {
                                Column {
                                    Text(saved.displayName)
                                    val sub = buildList {
                                        if (saved.ratePerHa > 0) add("${fmtNum(saved.ratePerHa, 1)} ${saved.unit}/ha")
                                        if (canEditCost) saved.costPerUnit?.takeIf { it > 0 }?.let { add("$${fmtNum(it, 2)}/${saved.unit}") }
                                    }.joinToString(" · ")
                                    if (sub.isNotEmpty()) Text(sub, fontSize = 12.sp, color = vine.textSecondary)
                                }
                            },
                            onClick = {
                                line.savedChemicalId = saved.id
                                line.name = saved.displayName
                                line.unit = saved.unit
                                if (saved.ratePerHa > 0 && line.rate.isBlank()) line.rate = fmtNum(saved.ratePerHa, 1)
                                line.costPerUnit = if (canEditCost) saved.costPerUnit?.takeIf { it > 0 } else null
                                menu = false
                                onChanged()
                            },
                        )
                    }
                }
            }
            IconButton(onClick = onRemove, modifier = Modifier.size(36.dp)) {
                Icon(Icons.Filled.Delete, contentDescription = "Remove", tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
            }
        }

        if (usesCF) {
            Spacer8()
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    selected = line.basis == SprayCalculator.RateBasis.PER_HECTARE,
                    onClick = { line.basis = SprayCalculator.RateBasis.PER_HECTARE; onChanged() },
                    label = { Text("Per ha", fontSize = 12.sp) },
                )
                FilterChip(
                    selected = line.basis == SprayCalculator.RateBasis.PER_100L,
                    onClick = { line.basis = SprayCalculator.RateBasis.PER_100L; onChanged() },
                    label = { Text("Per 100L", fontSize = 12.sp) },
                )
            }
        }

        Spacer8()
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(
                value = line.rate,
                onValueChange = { line.rate = it.filter { c -> c.isDigit() || c == '.' }; onChanged() },
                label = {
                    val basisLabel = if (line.basis == SprayCalculator.RateBasis.PER_100L) "/100L" else "/ha"
                    Text("Rate (${line.unit}$basisLabel)")
                },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.weight(1f),
            )
            if (canEditCost) {
                OutlinedTextField(
                    value = line.costPerUnit?.let { fmtNum(it, 2) } ?: "",
                    onValueChange = { txt ->
                        line.costPerUnit = txt.filter { c -> c.isDigit() || c == '.' }.toDoubleOrNull()
                        onChanged()
                    },
                    label = { Text("Cost/${line.unit}") },
                    placeholder = { Text("0.00") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun ResultsCard(r: SprayCalculator.Result) {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("Mix results", fontWeight = FontWeight.Bold, color = vine.textPrimary, fontSize = 16.sp)
        Spacer8()
        SummaryRow("Total area", "${fmtNum(r.totalAreaHectares, 2)} ha")
        SummaryRow("Total water", "${fmtNum(r.totalWaterLitres, 0)} L")
        SummaryRow("Tank capacity", "${fmtNum(r.tankCapacityLitres, 0)} L")
        SummaryRow(
            "Tanks",
            buildString {
                append("${r.totalTanks}")
                if (r.fullTankCount > 0) append(" (${r.fullTankCount} full")
                if (r.lastTankLitres > 0 && r.fullTankCount > 0) append(" + ${fmtNum(r.lastTankLitres, 0)} L last)")
                else if (r.fullTankCount > 0) append(")")
            },
        )
        if (r.concentrationFactor != 1.0) SummaryRow("Concentration factor", "%.2f".format(r.concentrationFactor))

        if (r.chemicalResults.isNotEmpty()) {
            Spacer12()
            Box(Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
            Spacer8()
            Text("Per chemical", fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 14.sp)
            r.chemicalResults.forEach { cr ->
                Spacer8()
                Text(cr.name, fontWeight = FontWeight.Medium, color = vine.textPrimary, fontSize = 14.sp)
                SummaryRow("Total required", "${fmtNum(cr.totalAmount, 1)} ${cr.unit}")
                SummaryRow("Per full tank", "${fmtNum(cr.amountPerFullTank, 1)} ${cr.unit}")
                if (cr.amountInLastTank > 0 && cr.amountInLastTank != cr.amountPerFullTank) {
                    SummaryRow("In last tank", "${fmtNum(cr.amountInLastTank, 1)} ${cr.unit}")
                }
            }
        }
    }
}

@Composable
private fun CostingCard(r: SprayCalculator.Result) {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("Costing", fontWeight = FontWeight.Bold, color = vine.textPrimary, fontSize = 16.sp)
        Spacer8()
        r.chemicalResults.forEach { cr ->
            cr.totalCost?.let { cost ->
                SummaryRow(cr.name, "$${fmtNum(cost, 2)}")
            }
        }
        r.totalChemicalCost?.let { total ->
            Spacer8()
            Box(Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
            Spacer8()
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Total chemical cost", fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 14.sp)
                Text("$${fmtNum(total, 2)}", fontWeight = FontWeight.Bold, color = VineColors.DarkGreen, fontSize = 14.sp)
            }
            r.costPerHectare?.let { perHa ->
                SummaryRow("Cost per hectare", "$${fmtNum(perHa, 2)}/ha")
            }
        }
    }
}

@Composable
private fun SummaryRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(
        Modifier.fillMaxWidth().padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontSize = 13.sp, color = vine.textSecondary)
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
    }
}

@Composable
private fun Spacer8() = androidx.compose.foundation.layout.Spacer(Modifier.height(8.dp))

@Composable
private fun Spacer12() = androidx.compose.foundation.layout.Spacer(Modifier.height(12.dp))

private fun fmtNum(value: Double, decimals: Int): String =
    if (decimals == 0) value.toLong().toString() else String.format(Locale.US, "%.${decimals}f", value)
