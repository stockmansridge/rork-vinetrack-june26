package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.FormatListNumbered
import androidx.compose.material.icons.filled.Gesture
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.LocalFlorist
import androidx.compose.material.icons.filled.LowPriority
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImagePainter
import coil3.compose.SubcomposeAsyncImage
import coil3.compose.SubcomposeAsyncImageContent
import com.rork.vinetrack.data.CanopyWaterRates
import com.rork.vinetrack.data.CanopyWaterRatesStore
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.SprayCalculator
import com.rork.vinetrack.data.SprayRecordRepository
import com.rork.vinetrack.data.TrackingPattern
import com.rork.vinetrack.data.TripRowSequencePlanner
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_100L
import com.rork.vinetrack.data.model.CHEMICAL_RATE_PER_HECTARE
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.chemical.ChemicalLineSnapshot
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import com.rork.vinetrack.data.model.resolveSprayTrip
import com.rork.vinetrack.data.model.sprayOperationTypes
import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayGeometryResolver
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.SprayJobRowPlan
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.data.spray.SprayCarrierBasis
import com.rork.vinetrack.data.spray.SprayGuidedFlow
import com.rork.vinetrack.data.spray.SprayGuidedInputs
import com.rork.vinetrack.data.spray.SprayGuidedStep
import com.rork.vinetrack.data.spray.SprayHeadTarget
import com.rork.vinetrack.data.spray.SprayOperationType
import com.rork.vinetrack.data.spray.SprayProductLineInput
import com.rork.vinetrack.data.spray.SprayProductRateBasis
import com.rork.vinetrack.data.spray.SprayTarget
import com.rork.vinetrack.data.spray.SprayVineyardProfile
import com.rork.vinetrack.ui.LocalRegionFormatter
import com.rork.vinetrack.data.spray.SprayApplicationPlan
import com.rork.vinetrack.data.spray.SprayProductLineResult
import com.rork.vinetrack.ui.components.GuidedBlockerBanner
import com.rork.vinetrack.ui.components.GuidedCalculatedPanel
import com.rork.vinetrack.ui.components.GuidedCalculatedRow
import com.rork.vinetrack.ui.components.GuidedChip
import com.rork.vinetrack.ui.components.GuidedProductBasisPicker
import com.rork.vinetrack.ui.components.GuidedProductCalculationRow
import com.rork.vinetrack.ui.components.GuidedReviewGroup
import com.rork.vinetrack.ui.components.GuidedReviewRow
import com.rork.vinetrack.ui.components.GuidedStepCard
import com.rork.vinetrack.ui.components.ResistanceCheckSlot
import com.rork.vinetrack.ui.components.SprayGuidedFormat
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.Instant
import java.util.Locale
import java.util.UUID
import kotlin.math.abs

/**
 * Mutable editor state for one chemical line — Android port of the iOS
 * `ChemicalLine`. The line references a saved chemical and one of its stored
 * rates; an optional override replaces the recommended rate value.
 */
private class CalcChemLine(
    chemicalId: String,
    selectedRateId: String?,
    basis: SprayCalculator.RateBasis,
) {
    val uid: String = UUID.randomUUID().toString()
    var chemicalId by mutableStateOf(chemicalId)
    var selectedRateId by mutableStateOf(selectedRateId)
    var basis by mutableStateOf(basis)
    var overrideText by mutableStateOf("")
}

/**
 * The plan's calculated line for the chemical line at [index] on screen.
 *
 * Walks [chemLines] in the SAME order and with the same skip rule the guided
 * inputs use, so two lines sharing one chemical stay distinct — matching on
 * product id alone would collapse them into one.
 */
private fun guidedPlanLineFor(
    plan: SprayApplicationPlan,
    chemLines: List<CalcChemLine>,
    savedChemicals: List<SavedChemical>,
    index: Int,
): SprayProductLineResult? {
    var planIndex = 0
    chemLines.forEachIndexed { i, line ->
        val exists = savedChemicals.any { it.id == line.chemicalId }
        if (!exists) return@forEachIndexed
        if (i == index) return plan.productLines.getOrNull(planIndex)
        planIndex += 1
    }
    return null
}

private fun basisOf(raw: String): SprayCalculator.RateBasis =
    if (raw == CHEMICAL_RATE_PER_100L) SprayCalculator.RateBasis.PER_100L else SprayCalculator.RateBasis.PER_HECTARE

/** Recommended rate for the line in the chemical's display unit. */
private fun recommendedRateDisplay(chem: SavedChemical, line: CalcChemLine): Double {
    chem.rates.firstOrNull { it.id == line.selectedRateId }?.let {
        return chemicalUnitFromBase(chem.unit, it.value)
    }
    return when (line.basis) {
        SprayCalculator.RateBasis.PER_HECTARE -> chem.ratePerHaDisplay ?: 0.0
        SprayCalculator.RateBasis.PER_100L -> chem.ratePer100LDisplay ?: 0.0
    }
}

/** Effective rate: manual override (when valid) else the recommended rate. */
private fun effectiveRateDisplay(chem: SavedChemical, line: CalcChemLine): Double =
    line.overrideText.toDoubleOrNull()?.takeIf { it > 0 } ?: recommendedRateDisplay(chem, line)

/** New chemical line seeded from a saved chemical's first stored rate. */
private fun newLineFor(chem: SavedChemical): CalcChemLine {
    val first = chem.rates.firstOrNull()
    return CalcChemLine(
        chemicalId = chem.id,
        selectedRateId = first?.id,
        basis = first?.let { basisOf(it.basis) } ?: SprayCalculator.RateBasis.PER_HECTARE,
    )
}

/** Prefix bare URLs with https:// so they open reliably. */
private fun normalizedUrl(raw: String?): String? {
    val trimmed = raw?.trim().orEmpty()
    if (trimmed.isEmpty()) return null
    val lower = trimmed.lowercase()
    return if (lower.startsWith("http://") || lower.startsWith("https://")) trimmed else "https://$trimmed"
}

/**
 * Android Spray Calculator — full port of the iOS `SprayCalculatorView`.
 *
 * Sections mirror iOS exactly: spray name, operation type, compact block
 * selector (picker sheet + stat strip), growth stage (Same for All / Per
 * Block), equipment with an inline add (+) sheet, calculated water rate with a
 * display-only row spacing, iOS-style chemical cards (rate picker + override),
 * and notes. Two actions match iOS: "Create Spray Job & View Tank Mix" opens
 * the Spray Tank Mixing review step (tank mix preview + machine + tracking
 * pattern + start path) which starts the live trip; "Save Job for Future Use"
 * saves a Not Started job with the current row-plan defaults.
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
    prefillRecordId: String? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val canopyRates = remember { CanopyWaterRatesStore(context).load() }
    val canEditCost = state.currentRole == "owner" || state.currentRole == "manager"

    var sprayName by remember { mutableStateOf("") }
    var operationType by remember { mutableStateOf(sprayOperationTypes.first()) }
    val selectedPaddockIds = remember { mutableStateListOf<String>() }
    var showBlockPicker by remember { mutableStateOf(false) }

    // Growth stage (informational selection, matching iOS — not persisted).
    var growthExpanded by remember { mutableStateOf(false) }
    var growthModeSame by remember { mutableStateOf(true) }
    var sharedStageCode by remember { mutableStateOf<String?>(null) }
    val perBlockStages = remember { mutableStateMapOf<String, String>() }

    // Equipment
    var sprayEquipmentId by remember { mutableStateOf<String?>(null) }
    var equipmentExpanded by remember { mutableStateOf(false) }
    var showAddEquipment by remember { mutableStateOf(false) }

    // Water rate
    var canopySize by remember { mutableStateOf(SprayCalculator.CanopySize.MEDIUM) }
    var canopyDensity by remember { mutableStateOf(SprayCalculator.CanopyDensity.LOW) }
    var sprayRateText by remember { mutableStateOf("") }
    var hasEditedSprayRate by remember { mutableStateOf(false) }

    // Chemicals & notes
    val chemLines = remember { mutableStateListOf<CalcChemLine>() }
    var showAddChemicalToList by remember { mutableStateOf(false) }
    var notes by remember { mutableStateOf("") }

    // Guided flow — Step 3 Target, Step 6 Carrier. Mirrors iOS `SprayCalculatorView`.
    val sprayTargets = remember { mutableStateListOf<SprayTarget>() }
    var sprayHeadTarget by remember { mutableStateOf<SprayHeadTarget?>(null) }
    var bandWidthText by remember { mutableStateOf("") }
    var carrierBasisChoice by remember { mutableStateOf(SprayCarrierBasis.LITRES_PER_HECTARE) }
    var diluteLitresPer100mText by remember { mutableStateOf("") }
    var appliedLitresPer100mText by remember { mutableStateOf("") }
    /**
     * Per-product-line area basis for banded jobs, keyed by `CalcChemLine.uid`
     * because the decision belongs to the individual product, never the job.
     */
    val productAreaBasis = remember { mutableStateMapOf<String, SprayProductRateBasis>() }

    // Review step (Spray Tank Mixing)
    var showReview by remember { mutableStateOf(false) }
    var machineId by remember { mutableStateOf<String?>(null) }
    var fansJets by remember { mutableStateOf("") }
    var trackingPattern by remember { mutableStateOf(TrackingPattern.SEQUENTIAL) }
    var startPath by remember { mutableStateOf(0.5) }
    var directionHigherFirst by remember { mutableStateOf(true) }

    var result by remember { mutableStateOf<SprayCalculator.Result?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }

    val selectedPaddocks = remember(selectedPaddockIds.toList(), state.paddocks) {
        state.paddocks.filter { selectedPaddockIds.contains(it.id) }
    }
    val totalArea = selectedPaddocks.sumOf { it.areaHectares }
    val totalRows = selectedPaddocks.sumOf { it.rows.orEmpty().size }

    // Canonical geometry for the selection — single source of truth for row
    // length and row spacing. Mirrors iOS `SprayCalculatorView`.
    val applicationGeometry = remember(selectedPaddocks) {
        SprayGeometryResolver.resolve(selectedPaddocks.map { SprayBlockInput.from(it) })
    }

    // Row spacing ONLY when every selected block has an explicitly entered
    // spacing and they agree. Deliberately null rather than falling back to
    // 2.5 m or averaging differing spacings: L/ha is derived as
    // `L/100m × 10_000 / rowSpacing / 100`, so an assumed spacing propagates
    // straight into the water rate and every product quantity built on it.
    val resolvedRowSpacing: Double? = applicationGeometry.uniformRowSpacingMetres

    val per100m = SprayCalculator.litresPer100m(canopyRates, canopySize, canopyDensity)
    val recommendedRate: Double? = resolvedRowSpacing?.let { CanopyWaterRates.litresPerHa(per100m, it) }
    val chosenRate = if (hasEditedSprayRate) {
        sprayRateText.toDoubleOrNull() ?: (recommendedRate ?: 0.0)
    } else {
        recommendedRate ?: 0.0
    }
    val concentrationFactor =
        if (chosenRate > 0 && recommendedRate != null) recommendedRate / chosenRate else 1.0
    val usesCF = SprayCalculator.usesConcentrationFactor(operationType)

    val selectedEquipment = state.sprayEquipment.firstOrNull { it.id == sprayEquipmentId }
    val tankCapacity = selectedEquipment?.tankCapacityLitres?.takeIf { it > 0 } ?: 0.0

    val selectedMachine = state.machines.firstOrNull { it.id == machineId }

    /**
     * The vineyard's spray profile — read from the vineyard, never re-derived
     * here.
     *
     * `Vineyard.sprayProfile` owns the whole resolution order (stored sql/192
     * value -> country fallback -> safe default), so this screen must NOT inspect
     * country or region settings itself: a vineyard that has deliberately chosen
     * the AU profile while sitting in NZ would otherwise be silently forced back
     * onto SWNZ by its own address.
     *
     * The region country is used ONLY when no vineyard is selected at all, which
     * is the same safe default the vineyard accessor would apply. Resolution
     * never writes anything back to the database.
     */
    val regionCountryCode = LocalRegionFormatter.current.settings.countryCode
    val selectedVineyard = state.selectedVineyard
    val sprayProfile = remember(selectedVineyard, regionCountryCode) {
        selectedVineyard?.sprayProfile ?: SprayVineyardProfile(countryCode = regionCountryCode)
    }

    /**
     * Maps the operator's chemical lines onto engine product inputs. Each line
     * carries its OWN rate basis: a per-100 L label stays per-100 L, and an
     * area-rated label resolves to whole-block unless the operator chose the
     * treated band for that specific line.
     */
    val guidedProducts: List<SprayProductLineInput> = chemLines.mapNotNull { line ->
        val chem = state.savedChemicals.firstOrNull { it.id == line.chemicalId }
            ?: return@mapNotNull null
        val basis = if (line.basis == SprayCalculator.RateBasis.PER_100L) {
            SprayProductRateBasis.PER_100_LITRES
        } else {
            // Legacy `per_hectare` means WHOLE BLOCK — never treated area.
            productAreaBasis[line.uid] ?: SprayProductRateBasis.WHOLE_BLOCK_AREA
        }
        SprayProductLineInput(
            productId = chem.id,
            name = chem.displayName,
            unit = chem.unit.toString(),
            basis = basis,
            rate = effectiveRateDisplay(chem, line),
            costPerUnit = if (canEditCost) chem.costPerUnit else null,
        )
    }

    /**
     * THE single bridge to `SprayApplicationPlanner.plan`. Every calculated figure
     * this screen displays is read back off `guidedPlan` — the screen does no
     * arithmetic of its own.
     */
    val guidedFlow = SprayGuidedFlow(
        inputs = SprayGuidedInputs(
            sprayName = sprayName,
            operationType = SprayOperationType.from(operationType)
                ?: SprayOperationType.FOLIAR_SPRAY,
            blocks = selectedPaddocks.map { SprayBlockInput.from(it) },
            targets = sprayTargets.toSet(),
            sprayHeadTarget = sprayHeadTarget,
            bandWidthTotalMetres = bandWidthText.toDoubleOrNull(),
            isGrowthStageAssigned = if (growthModeSame) {
                sharedStageCode != null && selectedPaddockIds.isNotEmpty()
            } else {
                selectedPaddockIds.isNotEmpty() &&
                    selectedPaddockIds.all { perBlockStages[it] != null }
            },
            isEquipmentSelected = sprayEquipmentId != null,
            tankCapacityLitres = tankCapacity,
            carrierBasis = carrierBasisChoice,
            litresPerHectare = chosenRate.takeIf { it > 0 },
            diluteLitresPerHectare = recommendedRate,
            diluteLitresPer100Metres = diluteLitresPer100mText.toDoubleOrNull(),
            appliedLitresPer100Metres = appliedLitresPer100mText.toDoubleOrNull(),
            products = guidedProducts,
            notes = notes,
        ),
        profile = sprayProfile,
    )
    val guidedPlan = guidedFlow.plan

    /**
     * The section the operator has explicitly opened. Null means "follow the
     * flow", so the screen lands on whatever still needs attention rather than
     * on a step that is already done.
     */
    var openedStep by remember { mutableStateOf<SprayGuidedStep?>(null) }
    val expandedStep = openedStep ?: guidedFlow.activeStep
    val toggleStep: (SprayGuidedStep) -> Unit = { step ->
        openedStep = if (expandedStep == step) null else step
    }

    // One-line recaps for collapsed sections. Every figure comes off the plan.
    val applicationSummary = if (sprayName.isBlank()) operationType else "$operationType \u2014 $sprayName"
    val blocksSummary = if (selectedPaddocks.isEmpty()) {
        "No blocks selected"
    } else {
        selectedPaddocks.joinToString(", ") { it.name } +
            " \u2014 ${SprayGuidedFormat.hectares(guidedPlan.grossAreaHectares)} gross"
    }
    val targetSummary = when {
        sprayTargets.isEmpty() -> "Not set"
        else -> {
            val names = guidedFlow.orderedTargets.joinToString(", ") { it.label }
            val treated = guidedPlan.treatedAreaHectares
            when {
                guidedFlow.requiresBandWidth && treated != null ->
                    "$names \u2014 ${SprayGuidedFormat.hectares(treated)} treated"
                sprayHeadTarget != null -> "$names \u2014 ${sprayHeadTarget?.label}"
                else -> names
            }
        }
    }
    val growthStageSummary = when {
        selectedPaddocks.isEmpty() -> "Select blocks first"
        growthModeSame -> GrowthStage.byCode(sharedStageCode)?.displayName ?: "Not set"
        else -> {
            val assigned = selectedPaddocks.count { perBlockStages.containsKey(it.id) }
            "Per block \u2014 $assigned/${selectedPaddocks.size} assigned"
        }
    }
    val equipmentSummary = selectedEquipment?.let { equipment ->
        if (fansJets.isBlank()) equipment.displayName else "${equipment.displayName} \u2014 $fansJets fans/jets"
    } ?: "Not selected"
    val carrierSummary = if (!guidedFlow.isCarrierResolved) {
        "Not set"
    } else {
        val carrier = guidedPlan.carrier
        val entered = when (carrier.basis) {
            SprayCarrierBasis.LITRES_PER_HECTARE ->
                SprayGuidedFormat.litresPerHectare(carrier.litresPerHectare)
            SprayCarrierBasis.LITRES_PER_100_METRES ->
                SprayGuidedFormat.litresPer100m(carrier.appliedLitresPer100Metres)
        }
        "$entered \u2014 ${SprayGuidedFormat.litres(carrier.totalLitres)} total"
    }
    val productsSummary = when {
        guidedPlan.productLines.isEmpty() -> "No products added"
        else -> {
            val unresolved = guidedPlan.productLines.count { it.isUnresolved }
            val base = if (guidedPlan.productLines.size == 1) {
                "1 product"
            } else {
                "${guidedPlan.productLines.size} products"
            }
            if (unresolved > 0) "$base \u2014 $unresolved unavailable" else base
        }
    }
    val reviewSummary = if (guidedFlow.isComplete) {
        "Ready to save or start"
    } else {
        guidedFlow.firstBlocker?.title ?: "Incomplete"
    }

    // Row plan geometry — blocks ordered lowest row first, matching iOS.
    val orderedSelectedPaddocks = remember(selectedPaddocks) {
        selectedPaddocks.sortedWith(TripRowSequencePlanner.rowOrderComparator)
    }
    val hasRowGeometry = remember(orderedSelectedPaddocks) {
        TripRowSequencePlanner.hasAnyRowGeometry(orderedSelectedPaddocks)
    }
    val availablePaths = remember(orderedSelectedPaddocks) {
        TripRowSequencePlanner.availablePaths(orderedSelectedPaddocks)
    }
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

    // Auto-select the only spray unit so the operator can't skip the section.
    LaunchedEffect(state.sprayEquipment) {
        if (sprayEquipmentId == null && state.sprayEquipment.size == 1) {
            sprayEquipmentId = state.sprayEquipment.first().id
        }
    }

    // Template / record prefill (Start from Template, re-run a completed job).
    val prefillRecord = remember(prefillRecordId, state.sprayRecords, state.sprayJobTemplates) {
        prefillRecordId?.let { id ->
            state.sprayRecords.firstOrNull { it.id == id }
                ?: state.sprayJobTemplates.firstOrNull { it.id == id }
        }
    }
    var prefillApplied by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(prefillRecord) {
        val r = prefillRecord ?: return@LaunchedEffect
        if (prefillApplied) return@LaunchedEffect
        prefillApplied = true
        val base = r.sprayReference.orEmpty()
        sprayName = if (r.isTemplate) base else if (base.isNotBlank()) "$base (Copy)" else ""
        r.operationType?.takeIf { it in sprayOperationTypes }?.let { operationType = it }
        notes = r.notes.orEmpty()
        fansJets = r.numberOfFansJets.orEmpty()
        sprayEquipmentId = r.sprayEquipmentId?.takeIf { id -> state.sprayEquipment.any { it.id == id } }
            ?: state.sprayEquipment.firstOrNull {
                it.name.isNotBlank() && it.name.equals(r.equipmentType ?: "", ignoreCase = true)
            }?.id
            ?: sprayEquipmentId
        resolveSprayTrip(r, state.trips)?.let { trip ->
            val ids = trip.paddockIds.ifEmpty { listOfNotNull(trip.paddockId) }
                .filter { pid -> state.paddocks.any { it.id == pid } }
            if (ids.isNotEmpty()) {
                selectedPaddockIds.clear()
                selectedPaddockIds.addAll(ids)
            }
        }
        r.tanks?.firstOrNull()?.let { tank ->
            if (tank.sprayRatePerHa > 0) {
                sprayRateText = fmtNum(tank.sprayRatePerHa, 0)
                hasEditedSprayRate = true
            }
            tank.chemicals.forEach { chem ->
                val saved = chem.savedChemicalId?.let { scid -> state.savedChemicals.firstOrNull { it.id == scid } }
                    ?: state.savedChemicals.firstOrNull { it.name.equals(chem.name, ignoreCase = true) }
                    ?: return@forEach
                val wantBasis = if (chem.ratePer100L > 0) CHEMICAL_RATE_PER_100L else CHEMICAL_RATE_PER_HECTARE
                val rate = saved.rates.firstOrNull { it.basis == wantBasis } ?: saved.rates.firstOrNull()
                chemLines.add(
                    CalcChemLine(
                        chemicalId = saved.id,
                        selectedRateId = rate?.id,
                        basis = rate?.let { basisOf(it.basis) } ?: basisOf(wantBasis),
                    ),
                )
            }
        }
    }

    fun buildLines(): List<SprayCalculator.Line> = chemLines.mapNotNull { line ->
        val chem = state.savedChemicals.firstOrNull { it.id == line.chemicalId } ?: return@mapNotNull null
        SprayCalculator.Line(
            savedChemicalId = chem.id,
            name = chem.displayName,
            unit = chem.unit,
            basis = line.basis,
            rate = effectiveRateDisplay(chem, line),
            costPerUnit = if (canEditCost) chem.costPerUnit else null,
        )
    }

    /** Validate the form and compute the tank mix. Returns null after setting an error. */
    fun runCalculation(): SprayCalculator.Result? {
        errorMessage = null
        if (selectedPaddockIds.isEmpty()) {
            errorMessage = "Select at least one block."
            return null
        }
        if (totalArea <= 0) {
            errorMessage = "Selected blocks have no mapped area to calculate against."
            return null
        }
        if (tankCapacity <= 0) {
            errorMessage = "Select spray equipment with a tank capacity."
            return null
        }
        if (chosenRate <= 0) {
            errorMessage = "Water rate must be greater than zero."
            return null
        }
        val lines = buildLines().filter { it.rate > 0 }
        if (lines.isEmpty()) {
            errorMessage = "Add at least one chemical with a rate to calculate the mix."
            return null
        }
        val computed = SprayCalculator.calculate(
            selectedPaddocks = selectedPaddocks,
            waterRateLitresPerHectare = chosenRate,
            tankCapacity = tankCapacity,
            lines = lines,
            concentrationFactor = if (usesCF) concentrationFactor else 1.0,
            operationType = operationType,
        )
        result = computed
        return computed
    }

    fun buildInput(): SprayRecordRepository.SprayInput {
        val r = result!!
        val iso = Instant.now().toString()
        return SprayRecordRepository.SprayInput(
            date = iso,
            startTime = iso,
            temperature = null,
            windSpeed = null,
            windDirection = null,
            humidity = null,
            sprayReference = sprayName.trim().ifBlank { null },
            notes = notes.trim().ifBlank { null },
            numberOfFansJets = fansJets.trim().ifBlank { null },
            averageSpeed = null,
            equipmentType = selectedEquipment?.displayName,
            tractor = selectedMachine?.displayName,
            tractorGear = null,
            machineId = machineId,
            sprayEquipmentId = sprayEquipmentId,
            operationType = operationType,
            tripId = null,
            isTemplate = false,
            // Each product line carries the area basis the operator chose for
            // THAT line, keyed by saved-chemical id so a banded treated-band
            // quantity reloads as a treated-band one.
            tanks = SprayCalculator.buildTanks(
                result = r,
                chosenSprayRate = chosenRate,
                rateBases = chemLines.mapNotNull { line ->
                    productAreaBasis[line.uid]?.let { line.chemicalId to it }
                }.toMap(),
                // Chemical Intelligence frozen at save time (sql/194). The store is
                // read HERE, once, so the historical line keeps today's chemistry
                // even after the product is re-classified tomorrow.
                snapshots = chemLines.mapNotNull { line ->
                    val chem = state.savedChemicals.firstOrNull { it.id == line.chemicalId }
                        ?: return@mapNotNull null
                    ChemicalLineSnapshot.capture(
                        intelligence = chem.resolvedIntelligence,
                        legacyChemicalGroup = chem.chemicalGroup,
                        savedChemicalId = chem.id,
                        productName = chem.name,
                        capturedAt = java.time.Instant.now().toString(),
                    )?.let { chem.id to it }
                }.toMap(),
            ),
            // Projection of the SAME plan the Review step displayed. The 17
            // sql/191 + sql/192 columns are never populated from UI state.
            applicationGeometry = guidedFlow.snapshot,
        )
    }

    fun buildRowPlan(totalTanks: Int): SprayJobRowPlan {
        val effectivePattern = if (hasRowGeometry) trackingPattern else TrackingPattern.FREE_DRIVE
        return SprayJobRowPlan(
            trackingPattern = effectivePattern.rawValue,
            rowSequence = pathSequence,
            totalTanks = totalTanks,
        )
    }

    fun saveJobForLater() {
        val r = runCalculation() ?: return
        if (saving) return
        saving = true
        val firstPaddock = selectedPaddocks.firstOrNull()
        val paddockNames = selectedPaddocks.joinToString(", ") { it.name }
        vm.createSprayJobForLater(
            input = buildInput(),
            paddockId = firstPaddock?.id,
            paddockName = paddockNames,
            rowPlan = buildRowPlan(r.totalTanks),
        ) { ok ->
            saving = false
            if (ok) onSaved()
        }
    }

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
            input = buildInput(),
            paddockId = firstPaddock?.id,
            paddockName = paddockNames,
            rowPlan = buildRowPlan(r.totalTanks),
        ) { ok ->
            saving = false
            if (ok) {
                val startedId = vm.activeTripIdOrNull()
                showReview = false
                onSaved()
                if (startedId != null) onJobStarted?.invoke(startedId)
            } else {
                errorMessage = state.sprayError ?: "Couldn't start the spray job."
            }
        }
    }

    val formIsValid = selectedPaddockIds.isNotEmpty() && selectedEquipment != null && chemLines.isNotEmpty()

    // ── Spray Tank Mixing review step ────────────────────────────────────────
    val reviewResult = result
    if (showReview && reviewResult != null) {
        BackHandler { if (!saving) showReview = false }
        SprayTankMixReview(
            state = state,
            result = reviewResult,
            operatorName = vm.userName ?: "—",
            equipmentLabel = selectedEquipment?.displayName ?: "—",
            savedChemicals = state.savedChemicals,
            canEditCost = canEditCost,
            machineId = machineId,
            onMachineChange = { machineId = it },
            fansJets = fansJets,
            onFansJetsChange = { fansJets = it },
            trackingPattern = trackingPattern,
            onPatternChange = { trackingPattern = it },
            hasRowGeometry = hasRowGeometry,
            availablePaths = availablePaths,
            startPath = startPath,
            onStartPathChange = { startPath = it },
            directionHigherFirst = directionHigherFirst,
            onDirectionChange = { directionHigherFirst = it },
            orderedSelectedPaddocks = orderedSelectedPaddocks,
            pathSequence = pathSequence,
            errorMessage = errorMessage,
            saving = saving,
            hasActiveTrip = state.activeTrip != null,
            onStart = { startJobNow() },
            onCancel = { if (!saving) showReview = false },
            modifier = modifier,
        )
        return
    }

    // ── Calculator form ──────────────────────────────────────────────────────
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
            // Step 1 — Application. Same sequence, wording and gating as iOS.
            item {
                GuidedStepCard(
                    step = SprayGuidedStep.APPLICATION,
                    index = 1,
                    isLocked = !guidedFlow.isUnlocked(SprayGuidedStep.APPLICATION),
                    isDone = guidedFlow.isComplete(SprayGuidedStep.APPLICATION),
                    isExpanded = expandedStep == SprayGuidedStep.APPLICATION,
                    summary = applicationSummary,
                    accent = VineColors.Olive,
                    doneAccent = VineColors.Olive,
                    onToggle = { toggleStep(SprayGuidedStep.APPLICATION) },
                ) {
                OutlinedTextField(
                    value = sprayName,
                    onValueChange = { sprayName = it },
                    label = { Text("Spray name (optional)") },
                    placeholder = { Text("e.g. Downy Mildew Spray #3") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
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
                            DropdownMenuItem(
                                text = { Text(op) },
                                onClick = {
                                    if (op != operationType) {
                                        operationType = op
                                        // Changing the application invalidates the
                                        // decisions that belonged to the old one:
                                        // a banded pass has no spray head target,
                                        // a foliar pass has no band width, and an
                                        // area basis chosen for a band means
                                        // nothing once the band is gone. Clearing
                                        // here keeps the screen honest; the flow
                                        // enforces the same rule for what gets
                                        // persisted.
                                        sprayHeadTarget = null
                                        bandWidthText = ""
                                        productAreaBasis.clear()
                                        result = null
                                    }
                                    menu = false
                                },
                            )
                        }
                    }
                }
                }
            }

            // Step 2 — Blocks.
            item {
                GuidedStepCard(
                    step = SprayGuidedStep.BLOCKS,
                    index = 2,
                    isLocked = !guidedFlow.isUnlocked(SprayGuidedStep.BLOCKS),
                    isDone = guidedFlow.isComplete(SprayGuidedStep.BLOCKS),
                    isExpanded = expandedStep == SprayGuidedStep.BLOCKS,
                    summary = blocksSummary,
                    accent = VineColors.Olive,
                    doneAccent = VineColors.Olive,
                    onToggle = { toggleStep(SprayGuidedStep.BLOCKS) },
                ) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    BlocksSummaryCard(
                        selectedPaddocks = selectedPaddocks,
                        anyConfigured = state.paddocks.isNotEmpty(),
                        totalArea = totalArea,
                        totalRows = totalRows,
                        onClick = { showBlockPicker = true },
                    )
                    if (selectedPaddocks.isNotEmpty()) {
                        VineyardCard {
                            Row(Modifier.fillMaxWidth()) {
                                // Canonical hectares converted to the vineyard's
                                // unit; the caption follows that unit instead of
                                // being hardcoded to "Hectares".
                                val areaFmt = LocalRegionFormatter.current
                                StatCell("${selectedPaddocks.size}", if (selectedPaddocks.size == 1) "Block" else "Blocks", Modifier.weight(1f))
                                StatCell(fmtNum(areaFmt.areaValue(totalArea), 2), areaFmt.areaUnitName, Modifier.weight(1f))
                                StatCell("$totalRows", "Rows", Modifier.weight(1f))
                            }
                        }
                    }
                }
                }
            }

            // Step 3 — Target. Multi-select intent, then the ONE application
            // specific question: foliar asks where the head is aimed, banded asks
            // for the treated width, spreader asks neither.
            item {
                GuidedStepCard(
                    step = SprayGuidedStep.TARGET,
                    index = 3,
                    isLocked = !guidedFlow.isUnlocked(SprayGuidedStep.TARGET),
                    isDone = guidedFlow.isComplete(SprayGuidedStep.TARGET),
                    isExpanded = expandedStep == SprayGuidedStep.TARGET,
                    summary = targetSummary,
                    accent = VineColors.Olive,
                    doneAccent = VineColors.Olive,
                    onToggle = { toggleStep(SprayGuidedStep.TARGET) },
                ) {
                    Text(
                        "What are you targeting?",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    Text(
                        "Select every pest, disease or purpose this spray addresses.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                    SprayTarget.presentationOrder.chunked(2).forEach { pair ->
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            pair.forEach { target ->
                                GuidedChip(
                                    label = target.label,
                                    isSelected = sprayTargets.contains(target),
                                    accent = VineColors.Olive,
                                    modifier = Modifier.weight(1f),
                                    onClick = {
                                        if (sprayTargets.contains(target)) {
                                            sprayTargets.remove(target)
                                        } else {
                                            sprayTargets.add(target)
                                        }
                                    },
                                )
                            }
                            if (pair.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }

                    if (guidedFlow.requiresSprayHeadTarget) {
                        Text(
                            "Spray Head Target",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        SprayHeadTarget.entries.chunked(2).forEach { pair ->
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                pair.forEach { head ->
                                    GuidedChip(
                                        label = head.label,
                                        isSelected = sprayHeadTarget == head,
                                        accent = VineColors.Olive,
                                        modifier = Modifier.weight(1f),
                                        onClick = { sprayHeadTarget = head },
                                    )
                                }
                                if (pair.size == 1) Spacer(Modifier.weight(1f))
                            }
                        }
                        sprayHeadTarget?.let { head ->
                            Text(head.detail, fontSize = 11.sp, color = vine.textSecondary)
                        }
                    }

                    if (guidedFlow.requiresBandWidth) {
                        Text(
                            "Total Treated Band Width",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        OutlinedTextField(
                            value = bandWidthText,
                            onValueChange = {
                                bandWidthText = it.filter { c -> c.isDigit() || c == '.' }
                                result = null
                            },
                            label = { Text("Band width (m)") },
                            placeholder = { Text("0.80") },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text(
                            "Total sprayed width per row, both sides combined.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                        // Gross AND treated both come out of the plan the moment a
                        // band width exists. The screen computes neither.
                        if (guidedFlow.bandWidth != null) {
                            GuidedCalculatedPanel(
                                title = "Application geometry",
                                accent = VineColors.Olive,
                            ) {
                                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    GuidedCalculatedRow(
                                        label = "Gross area",
                                        value = SprayGuidedFormat.hectares(guidedPlan.grossAreaHectares),
                                        accent = VineColors.Olive,
                                    )
                                    GuidedCalculatedRow(
                                        label = "Treated area",
                                        value = SprayGuidedFormat.hectares(guidedPlan.treatedAreaHectares),
                                        accent = VineColors.Olive,
                                        emphasis = true,
                                    )
                                }
                            }
                        }
                    }

                    guidedFlow.blocker(SprayGuidedStep.TARGET)?.let { blocker ->
                        GuidedBlockerBanner(
                            blocker = blocker,
                            onFix = { showBlockPicker = true },
                        )
                    }
                }
            }

            // Step 4 — Growth stage.
            item {
                GuidedStepCard(
                    step = SprayGuidedStep.GROWTH_STAGE,
                    index = 4,
                    isLocked = !guidedFlow.isUnlocked(SprayGuidedStep.GROWTH_STAGE),
                    isDone = guidedFlow.isComplete(SprayGuidedStep.GROWTH_STAGE),
                    isExpanded = expandedStep == SprayGuidedStep.GROWTH_STAGE,
                    summary = growthStageSummary,
                    accent = VineColors.Olive,
                    doneAccent = VineColors.Olive,
                    onToggle = { toggleStep(SprayGuidedStep.GROWTH_STAGE) },
                ) {
                GrowthStageSection(
                    selectedPaddocks = selectedPaddocks,
                    expanded = growthExpanded,
                    onToggleExpanded = {
                        if (selectedPaddocks.isNotEmpty()) growthExpanded = !growthExpanded
                    },
                    modeSame = growthModeSame,
                    onModeChange = { same ->
                        growthModeSame = same
                        if (same) {
                            sharedStageCode?.let { code ->
                                selectedPaddocks.forEach { perBlockStages[it.id] = code }
                            }
                        }
                    },
                    sharedStageCode = sharedStageCode,
                    onSharedStageChange = { code ->
                        sharedStageCode = code
                        if (code == null) {
                            selectedPaddocks.forEach { perBlockStages.remove(it.id) }
                        } else {
                            selectedPaddocks.forEach { perBlockStages[it.id] = code }
                        }
                    },
                    perBlockStages = perBlockStages,
                )
                }
            }

            // Step 5 — Equipment.
            item {
                GuidedStepCard(
                    step = SprayGuidedStep.EQUIPMENT,
                    index = 5,
                    isLocked = !guidedFlow.isUnlocked(SprayGuidedStep.EQUIPMENT),
                    isDone = guidedFlow.isComplete(SprayGuidedStep.EQUIPMENT),
                    isExpanded = expandedStep == SprayGuidedStep.EQUIPMENT,
                    summary = equipmentSummary,
                    accent = VineColors.Olive,
                    doneAccent = VineColors.Olive,
                    onToggle = { toggleStep(SprayGuidedStep.EQUIPMENT) },
                ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SectionHeader("Equipment", onLight = true, modifier = Modifier.weight(1f))
                    IconButton(onClick = { showAddEquipment = true }) {
                        Icon(
                            Icons.Filled.AddCircle,
                            contentDescription = "Add equipment",
                            tint = VineColors.Olive,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                }
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    EquipmentSummaryCard(
                        equipmentName = selectedEquipment?.displayName,
                        tankCapacity = selectedEquipment?.tankCapacityLitres,
                        anyConfigured = state.sprayEquipment.isNotEmpty(),
                        expanded = equipmentExpanded,
                        onClick = { equipmentExpanded = !equipmentExpanded },
                    )
                    if (equipmentExpanded) {
                        VineyardCard {
                            if (state.sprayEquipment.isEmpty()) {
                                Row(
                                    modifier = Modifier.fillMaxWidth().clickable { showAddEquipment = true }.padding(vertical = 8.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Icon(Icons.Filled.AddCircle, contentDescription = null, tint = VineColors.Olive, modifier = Modifier.size(20.dp))
                                    Text("Add Equipment", fontSize = 14.sp, color = vine.textPrimary)
                                }
                            }
                            state.sprayEquipment.forEachIndexed { i, eq ->
                                if (i > 0) Box(Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
                                val isSelected = sprayEquipmentId == eq.id
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable {
                                            sprayEquipmentId = eq.id
                                            equipmentExpanded = false
                                            result = null
                                        }
                                        .padding(vertical = 10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    Icon(
                                        if (isSelected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                                        contentDescription = null,
                                        tint = if (isSelected) VineColors.Olive else vine.textSecondary,
                                        modifier = Modifier.size(20.dp),
                                    )
                                    Text(eq.displayName, fontSize = 14.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                                    eq.tankCapacityLitres?.takeIf { it > 0 }?.let {
                                        Text("${fmtNum(it, 0)} L", fontSize = 12.sp, color = vine.textSecondary)
                                    }
                                }
                            }
                        }
                    }
                }
                }
            }

            // Step 6 — Carrier Volume.
            item {
                GuidedStepCard(
                    step = SprayGuidedStep.CARRIER,
                    index = 6,
                    isLocked = !guidedFlow.isUnlocked(SprayGuidedStep.CARRIER),
                    isDone = guidedFlow.isComplete(SprayGuidedStep.CARRIER),
                    isExpanded = expandedStep == SprayGuidedStep.CARRIER,
                    summary = carrierSummary,
                    accent = VineColors.Olive,
                    doneAccent = VineColors.Olive,
                    onToggle = { toggleStep(SprayGuidedStep.CARRIER) },
                ) {
                // Only offer a choice when the vineyard profile genuinely allows
                // one. An NZ/SWNZ vineyard is locked to L/100 m and never sees an
                // L/ha option or an "allow either" selector, so a compliance
                // spray cannot be switched onto the wrong basis by accident.
                if (guidedFlow.isCarrierBasisLocked) {
                    Text(
                        "This vineyard records carrier volume in " +
                            "${SprayGuidedFormat.carrierBasisLabel(guidedFlow.effectiveCarrierBasis)}.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                } else {
                    Text(
                        "Carrier volume basis",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        val bases = listOf(
                            SprayCarrierBasis.LITRES_PER_100_METRES,
                            SprayCarrierBasis.LITRES_PER_HECTARE,
                        )
                        bases.forEachIndexed { i, basis ->
                            SegmentedButton(
                                selected = guidedFlow.effectiveCarrierBasis == basis,
                                onClick = { carrierBasisChoice = basis; result = null },
                                shape = SegmentedButtonDefaults.itemShape(i, bases.size),
                            ) { Text(SprayGuidedFormat.carrierBasisLabel(basis), fontSize = 13.sp) }
                        }
                    }
                }

                if (guidedFlow.effectiveCarrierBasis == SprayCarrierBasis.LITRES_PER_100_METRES) {
                    // Row-length entry: the operator types ONLY the two rates.
                    // Concentration factor, total litres and the equivalent L/ha
                    // are all read back from the plan.
                    OutlinedTextField(
                        value = diluteLitresPer100mText,
                        onValueChange = {
                            diluteLitresPer100mText = it.filter { c -> c.isDigit() || c == '.' }
                            result = null
                        },
                        label = { Text("Dilute / Runoff Volume (L/100 m)") },
                        placeholder = { Text("40") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = appliedLitresPer100mText,
                        onValueChange = {
                            appliedLitresPer100mText = it.filter { c -> c.isDigit() || c == '.' }
                            result = null
                        },
                        label = { Text("Actual Applied Volume (L/100 m)") },
                        placeholder = { Text("20") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (guidedFlow.isCarrierResolved) {
                        val carrier = guidedPlan.carrier
                        GuidedCalculatedPanel(
                            title = "Calculated carrier volume",
                            accent = VineColors.Olive,
                        ) {
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                GuidedCalculatedRow(
                                    label = "Concentration factor",
                                    value = SprayGuidedFormat.factor(carrier.concentrationFactor),
                                    accent = VineColors.Olive,
                                )
                                GuidedCalculatedRow(
                                    label = "Total carrier",
                                    value = SprayGuidedFormat.litres(carrier.totalLitres),
                                    accent = VineColors.Olive,
                                    emphasis = true,
                                )
                                GuidedCalculatedRow(
                                    label = "Equivalent applied volume",
                                    value = SprayGuidedFormat.litresPerHectare(carrier.litresPerHectare),
                                    accent = VineColors.Olive,
                                    caption = if (carrier.litresPerHectare != null) {
                                        "Derived from row spacing \u2014 not entered"
                                    } else {
                                        "Needs one matching row spacing across blocks"
                                    },
                                )
                            }
                        }
                    }
                } else {
                Text(
                    "Based on row widths & canopy status",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp),
                )
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
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                            .background(VineColors.LeafGreen.copy(alpha = 0.10f)).padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text("Volume", fontSize = 12.sp, color = vine.textSecondary)
                            Text(
                                recommendedRate?.let { LocalRegionFormatter.current.formatVolumePerArea(it) } ?: "—",
                                fontSize = 20.sp,
                                fontWeight = FontWeight.Bold,
                                color = if (recommendedRate != null) VineColors.DarkGreen else vine.textSecondary,
                            )
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text("Per 100m row", fontSize = 12.sp, color = vine.textSecondary)
                            Text("${fmtNum(per100m, 0)} L", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        }
                    }

                    // Row spacing — display only, matching iOS. When it cannot be
                    // resolved we say so instead of showing an assumed 2.5 m.
                    if (resolvedRowSpacing != null) {
                        Text(
                            "Row spacing: ${fmtNum(resolvedRowSpacing, 1)}m",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.padding(top = 8.dp),
                        )
                    } else {
                        Text(
                            if (selectedPaddocks.size > 1) {
                                "Selected blocks have missing or differing row spacing — set a matching row spacing in block details to calculate L/ha."
                            } else {
                                "Set row spacing in block details to calculate L/ha."
                            },
                            fontSize = 12.sp,
                            color = VineColors.Warning,
                            modifier = Modifier.padding(top = 8.dp),
                        )
                    }

                    if (usesCF) {
                        Spacer12()
                        Text("Spray Rate & Concentration Factor", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
                        Spacer8()
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedTextField(
                                value = if (hasEditedSprayRate) sprayRateText else recommendedRate?.let { fmtNum(it, 0) } ?: "",
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

                guidedFlow.blocker(SprayGuidedStep.CARRIER)?.let { blocker ->
                    GuidedBlockerBanner(
                        blocker = blocker,
                        onFix = { showBlockPicker = true },
                    )
                }
                }
            }

            // Step 7 — Products.
            item {
                GuidedStepCard(
                    step = SprayGuidedStep.PRODUCTS,
                    index = 7,
                    isLocked = !guidedFlow.isUnlocked(SprayGuidedStep.PRODUCTS),
                    isDone = guidedFlow.isComplete(SprayGuidedStep.PRODUCTS),
                    isExpanded = expandedStep == SprayGuidedStep.PRODUCTS,
                    summary = productsSummary,
                    accent = VineColors.Olive,
                    doneAccent = VineColors.Olive,
                    onToggle = { toggleStep(SprayGuidedStep.PRODUCTS) },
                ) {
                chemLines.forEachIndexed { idx, line ->
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        CalcChemicalLineCard(
                            line = line,
                            savedChemicals = state.savedChemicals,
                            onChanged = { result = null },
                            onRemove = { chemLines.removeAt(idx); result = null },
                        )

                        // The area question is asked ONLY where it is genuinely
                        // ambiguous: an area-rated label on a banded pass. A
                        // per-100 L product is never asked — its basis is the
                        // carrier, not the ground — and a whole-block pass is
                        // never asked because treated and gross are the same.
                        if (guidedFlow.requiresBandWidth &&
                            line.basis != SprayCalculator.RateBasis.PER_100L
                        ) {
                            GuidedProductBasisPicker(
                                selected = productAreaBasis[line.uid]
                                    ?: SprayProductRateBasis.WHOLE_BLOCK_AREA,
                                accent = VineColors.Olive,
                            ) { basis ->
                                productAreaBasis[line.uid] = basis
                                result = null
                            }
                            if (productAreaBasis[line.uid] == null) {
                                Text(
                                    "Choose an area basis for this product before continuing.",
                                    fontSize = 11.sp,
                                    color = VineColors.Warning,
                                )
                            }
                        }

                        // The calculated explanation, straight off the plan.
                        guidedPlanLineFor(guidedPlan, chemLines, state.savedChemicals, idx)?.let { planLine ->
                            GuidedProductCalculationRow(
                                line = planLine,
                                accent = VineColors.Olive,
                            )
                        }

                        // Reserved insertion point for the future Resistance
                        // Check, immediately beneath the chemistry it will judge.
                        // Renders nothing today — a fabricated "no issues" verdict
                        // would be worse than silence.
                        ResistanceCheckSlot(guidedFlow.isResistanceCheckApplicable)
                    }
                }

                guidedFlow.blocker(SprayGuidedStep.PRODUCTS)?.let { blocker ->
                    GuidedBlockerBanner(
                        blocker = blocker,
                        onFix = { showBlockPicker = true },
                    )
                }

                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(
                        onClick = {
                            state.savedChemicals.firstOrNull()?.let {
                                chemLines.add(newLineFor(it))
                                result = null
                            }
                        },
                        enabled = state.savedChemicals.isNotEmpty(),
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = VineColors.Olive.copy(alpha = 0.12f),
                            contentColor = VineColors.Olive,
                            disabledContainerColor = VineColors.Olive.copy(alpha = 0.06f),
                            disabledContentColor = vine.textSecondary,
                        ),
                    ) {
                        Icon(Icons.Filled.AddCircle, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("  Add Chemical", fontWeight = FontWeight.Medium)
                    }
                    Button(
                        onClick = { showAddChemicalToList = true },
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = VineColors.LeafGreen.copy(alpha = 0.12f),
                            contentColor = VineColors.LeafGreen,
                        ),
                    ) {
                        Icon(Icons.Filled.Science, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("  Add New Chemical to List", fontWeight = FontWeight.Medium)
                    }
                    if (state.savedChemicals.isEmpty()) {
                        Text(
                            "No chemicals configured. Tap \u201CAdd New Chemical to List\u201D to create one.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
                }
            }

            // Step 8 — Review. A REVIEW, not another editable form: every figure
            // is read off the SAME plan the record is built from, so what the
            // operator signs off and what is persisted cannot disagree.
            item {
                GuidedStepCard(
                    step = SprayGuidedStep.REVIEW,
                    index = 8,
                    isLocked = !guidedFlow.isUnlocked(SprayGuidedStep.REVIEW),
                    isDone = guidedFlow.isComplete,
                    isExpanded = expandedStep == SprayGuidedStep.REVIEW,
                    summary = reviewSummary,
                    accent = VineColors.Olive,
                    doneAccent = VineColors.Olive,
                    onToggle = { toggleStep(SprayGuidedStep.REVIEW) },
                ) {
                    val carrier = guidedPlan.carrier

                    GuidedReviewGroup(
                        title = "Application",
                        accent = VineColors.Olive,
                        onEdit = { toggleStep(SprayGuidedStep.APPLICATION) },
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            GuidedReviewRow("Method", operationType)
                            if (sprayName.isNotBlank()) GuidedReviewRow("Name", sprayName)
                        }
                    }

                    GuidedReviewGroup(
                        title = "Blocks & geometry",
                        accent = VineColors.Olive,
                        onEdit = { toggleStep(SprayGuidedStep.BLOCKS) },
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            GuidedReviewRow(
                                "Blocks",
                                selectedPaddocks.joinToString(", ") { it.name },
                            )
                            GuidedReviewRow(
                                "Gross area",
                                SprayGuidedFormat.hectares(guidedPlan.grossAreaHectares),
                            )
                            guidedPlan.geometry.totalRowLengthMetres?.let { metres ->
                                GuidedReviewRow(
                                    "Canonical row length",
                                    SprayGuidedFormat.metres(metres),
                                )
                            }
                        }
                    }

                    GuidedReviewGroup(
                        title = "Target",
                        accent = VineColors.Olive,
                        onEdit = { toggleStep(SprayGuidedStep.TARGET) },
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            GuidedReviewRow(
                                "Target(s)",
                                guidedFlow.orderedTargets.joinToString(", ") { it.label },
                            )
                            guidedFlow.effectiveSprayHeadTarget?.let { head ->
                                GuidedReviewRow("Spray head", head.label)
                            }
                            if (guidedFlow.requiresBandWidth) {
                                GuidedReviewRow(
                                    "Band width",
                                    SprayGuidedFormat.metres(
                                        guidedPlan.treatedArea.bandWidth?.totalMetres,
                                        decimals = 2,
                                    ),
                                )
                                GuidedReviewRow(
                                    "Treated area",
                                    SprayGuidedFormat.hectares(guidedPlan.treatedAreaHectares),
                                )
                            }
                        }
                    }

                    GuidedReviewGroup(
                        title = "Growth stage",
                        accent = VineColors.Olive,
                        onEdit = { toggleStep(SprayGuidedStep.GROWTH_STAGE) },
                    ) {
                        GuidedReviewRow("Stage", growthStageSummary)
                    }

                    GuidedReviewGroup(
                        title = "Equipment",
                        accent = VineColors.Olive,
                        onEdit = { toggleStep(SprayGuidedStep.EQUIPMENT) },
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            GuidedReviewRow(
                                "Spray unit",
                                selectedEquipment?.displayName ?: "Not selected",
                            )
                            GuidedReviewRow(
                                "Fans / jets",
                                fansJets.ifBlank { "Not set" },
                            )
                            GuidedReviewRow(
                                "Machine",
                                selectedMachine?.displayName ?: "Not selected",
                            )
                        }
                    }

                    GuidedReviewGroup(
                        title = "Carrier volume",
                        accent = VineColors.Olive,
                        onEdit = { toggleStep(SprayGuidedStep.CARRIER) },
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            GuidedReviewRow(
                                "Basis",
                                SprayGuidedFormat.carrierBasisLabel(carrier.basis),
                            )
                            if (carrier.basis == SprayCarrierBasis.LITRES_PER_100_METRES) {
                                GuidedReviewRow(
                                    "Dilute / runoff",
                                    SprayGuidedFormat.litresPer100m(carrier.diluteLitresPer100Metres),
                                )
                                GuidedReviewRow(
                                    "Actual applied",
                                    SprayGuidedFormat.litresPer100m(carrier.appliedLitresPer100Metres),
                                )
                            }
                            GuidedReviewRow(
                                "Concentration",
                                SprayGuidedFormat.factor(carrier.concentrationFactor),
                            )
                            GuidedReviewRow(
                                "Total carrier",
                                SprayGuidedFormat.litres(carrier.totalLitres),
                            )
                            GuidedReviewRow(
                                "Equivalent L/ha",
                                SprayGuidedFormat.litresPerHectare(carrier.litresPerHectare),
                            )
                            GuidedReviewRow(
                                "Tanks",
                                "${guidedPlan.tankSplit.totalTanks} \u00D7 " +
                                    SprayGuidedFormat.litres(guidedPlan.tankSplit.tankCapacityLitres),
                            )
                        }
                    }

                    GuidedReviewGroup(
                        title = "Products",
                        accent = VineColors.Olive,
                        onEdit = { toggleStep(SprayGuidedStep.PRODUCTS) },
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            guidedPlan.productLines.forEach { line ->
                                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Row(Modifier.fillMaxWidth()) {
                                        Text(
                                            line.name,
                                            fontSize = 13.sp,
                                            fontWeight = FontWeight.SemiBold,
                                            color = vine.textPrimary,
                                            modifier = Modifier.weight(1f),
                                        )
                                        Text(
                                            SprayGuidedFormat.quantity(line.totalQuantity, line.unit),
                                            fontSize = 13.sp,
                                            fontWeight = FontWeight.Bold,
                                            color = if (line.isUnresolved) {
                                                VineColors.Warning
                                            } else {
                                                VineColors.Olive
                                            },
                                        )
                                    }
                                    Text(
                                        SprayGuidedFormat.productBasisLabel(line.basis),
                                        fontSize = 11.sp,
                                        color = vine.textSecondary,
                                    )
                                    // The same arithmetic the Products step showed,
                                    // from the same plan — Review never recalculates.
                                    SprayGuidedFormat.productCalculation(line)?.let { calculation ->
                                        Text(
                                            calculation,
                                            fontSize = 11.sp,
                                            color = vine.textSecondary,
                                        )
                                    }
                                    line.quantityPerFullTank?.let { perTank ->
                                        if (guidedPlan.tankSplit.totalTanks > 1) {
                                            Text(
                                                "Per full tank: " +
                                                    SprayGuidedFormat.quantity(perTank, line.unit),
                                                fontSize = 11.sp,
                                                color = vine.textSecondary,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if (notes.isNotBlank()) {
                        GuidedReviewGroup(title = "Notes", accent = VineColors.Olive) {
                            Text(notes, fontSize = 13.sp, color = vine.textPrimary)
                        }
                    }

                    guidedFlow.firstBlocker?.let { blocker ->
                        GuidedBlockerBanner(blocker = blocker)
                    }
                }
            }

            // Notes
            item { SectionHeader("Notes", onLight = true) }
            item {
                OutlinedTextField(
                    value = notes,
                    onValueChange = { notes = it },
                    placeholder = { Text("Add notes about this spray job...") },
                    minLines = 3,
                    maxLines = 6,
                    modifier = Modifier.fillMaxWidth(),
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

            // Actions — exactly two buttons, matching iOS.
            item {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(
                        onClick = {
                            if (runCalculation() != null) showReview = true
                        },
                        enabled = formIsValid && !saving,
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.Olive),
                    ) {
                        Icon(Icons.Filled.Science, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("  Create Spray Job & View Tank Mix", fontWeight = FontWeight.SemiBold)
                    }
                    OutlinedButton(
                        onClick = { saveJobForLater() },
                        enabled = formIsValid && !saving,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (saving) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = VineColors.LeafGreen)
                        } else {
                            Icon(Icons.Filled.Schedule, contentDescription = null, modifier = Modifier.size(18.dp), tint = VineColors.LeafGreen)
                        }
                        Text("  Save Job for Future Use", color = VineColors.LeafGreen, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }

    if (showBlockPicker) {
        BlockPickerSheet(
            paddocks = state.paddocks,
            selectedIds = selectedPaddockIds.toSet(),
            onToggle = { id ->
                if (selectedPaddockIds.contains(id)) selectedPaddockIds.remove(id) else selectedPaddockIds.add(id)
                result = null
            },
            onSelectAll = { all ->
                selectedPaddockIds.clear()
                if (all) selectedPaddockIds.addAll(state.paddocks.map { it.id })
                result = null
            },
            onDismiss = { showBlockPicker = false },
        )
    }

    if (showAddEquipment) {
        // Full Settings form (Spray Rigs & Tanks) — includes Serial number and
        // VIN, matching iOS. Auto-select whatever rig appears while it's open.
        val equipmentIdsBefore = remember { state.sprayEquipment.map { it.id }.toSet() }
        LaunchedEffect(state.sprayEquipment) {
            state.sprayEquipment.firstOrNull { it.id !in equipmentIdsBefore }?.let { added ->
                sprayEquipmentId = added.id
            }
        }
        SprayEquipmentFormSheet(
            vm = vm,
            existing = null,
            onDismiss = { showAddEquipment = false },
        )
    }

    if (showAddChemicalToList) {
        // Full Settings chemical form — all fields plus Search with AI, matching iOS.
        ChemicalFormSheet(
            vm = vm,
            existing = null,
            canViewFinancials = canEditCost,
            onDismiss = { showAddChemicalToList = false },
        )
    }
}

// ── Blocks ────────────────────────────────────────────────────────────────────

/** Contiguous row ranges, e.g. [1,2,3,5,6] → "Rows 1–3, 5–6" (iOS parity). */
private fun rowRangeSummary(paddocks: List<Paddock>): String {
    val nums = paddocks.flatMap { it.rows.orEmpty().map { r -> r.number } }.toSortedSet().toList()
    if (nums.isEmpty()) return "Rows not set"
    val ranges = mutableListOf<Pair<Int, Int>>()
    var start = nums.first()
    var prev = nums.first()
    for (n in nums.drop(1)) {
        if (n == prev + 1) { prev = n; continue }
        ranges.add(start to prev)
        start = n
        prev = n
    }
    ranges.add(start to prev)
    if (ranges.size == 1) {
        val (lo, hi) = ranges[0]
        return if (lo == hi) "Row $lo" else "Rows $lo\u2013$hi"
    }
    val joined = "Rows " + ranges.joinToString(", ") { (lo, hi) -> if (lo == hi) "$lo" else "$lo\u2013$hi" }
    return if (joined.length <= 48) joined else "Multiple row ranges"
}

@Composable
private fun BlocksSummaryCard(
    selectedPaddocks: List<Paddock>,
    anyConfigured: Boolean,
    totalArea: Double,
    totalRows: Int,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .clickable { onClick() }
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(VineColors.LeafGreen.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.GridView, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(22.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            if (selectedPaddocks.isEmpty()) {
                Text("No blocks selected", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Text(
                    if (anyConfigured) "Tap to choose one or more blocks" else "No blocks configured",
                    fontSize = 12.sp,
                    color = VineColors.Orange,
                )
            } else {
                val n = selectedPaddocks.size
                Text(
                    "$n block${if (n == 1) "" else "s"} · ${LocalRegionFormatter.current.formatArea(totalArea)} · $totalRows row${if (totalRows == 1) "" else "s"} · ${rowRangeSummary(selectedPaddocks)}",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                    maxLines = 2,
                )
                Text(
                    selectedPaddocks.joinToString(", ") { it.name },
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                    maxLines = 2,
                )
            }
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(20.dp))
    }
}

/** Multi-select block picker, mirroring the iOS `SprayPaddockPickerSheet`. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BlockPickerSheet(
    paddocks: List<Paddock>,
    selectedIds: Set<String>,
    onToggle: (String) -> Unit,
    onSelectAll: (Boolean) -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var search by remember { mutableStateOf("") }
    val sorted = remember(paddocks) { paddocks.sortedBy { it.name.lowercase() } }
    val filtered = remember(sorted, search) {
        if (search.isBlank()) sorted else sorted.filter { it.name.contains(search.trim(), ignoreCase = true) }
    }
    val allSelected = paddocks.isNotEmpty() && selectedIds.size == paddocks.size

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            contentPadding = PaddingValues(bottom = 32.dp),
        ) {
            item {
                Text("Select Blocks", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    placeholder = { Text("Search blocks") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null, modifier = Modifier.size(18.dp)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(10.dp))
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(vine.cardBackground)
                        .clickable { onSelectAll(!allSelected) }
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        if (allSelected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                        contentDescription = null,
                        tint = if (allSelected) VineColors.Olive else vine.textSecondary,
                        modifier = Modifier.size(20.dp),
                    )
                    Text(if (allSelected) "Deselect All" else "Select All", fontSize = 14.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                    Text("${selectedIds.size} of ${paddocks.size}", fontSize = 12.sp, color = vine.textSecondary)
                }
                Spacer(Modifier.height(10.dp))
            }
            items(filtered, key = { it.id }) { paddock ->
                val isSelected = selectedIds.contains(paddock.id)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(vine.cardBackground)
                        .clickable { onToggle(paddock.id) }
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        if (isSelected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                        contentDescription = null,
                        tint = if (isSelected) VineColors.Olive else vine.textSecondary,
                        modifier = Modifier.size(20.dp),
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(paddock.name, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        Text(paddockMetaLine(paddock, LocalRegionFormatter.current), fontSize = 12.sp, color = vine.textSecondary)
                    }
                }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}

/**
 * Per-row meta line: "1.20 ha · 12 rows · Rows 1–12" (iOS parity).
 *
 * Takes the formatter so the area follows the vineyard's configured unit rather
 * than printing canonical hectares under a hardcoded " ha" suffix.
 */
private fun paddockMetaLine(paddock: Paddock, fmt: RegionFormatter): String {
    val ha = fmt.formatArea(paddock.areaHectares)
    val nums = paddock.rows.orEmpty().map { it.number }
    val lo = nums.minOrNull()
    val hi = nums.maxOrNull()
    if (lo == null || hi == null) return "$ha \u00B7 Rows not set"
    val range = if (lo == hi) "Row $lo" else "Rows $lo\u2013$hi"
    return "$ha \u00B7 ${nums.size} row${if (nums.size == 1) "" else "s"} \u00B7 $range"
}

// ── Growth stage ─────────────────────────────────────────────────────────────

@Composable
private fun GrowthStageSection(
    selectedPaddocks: List<Paddock>,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    modeSame: Boolean,
    onModeChange: (Boolean) -> Unit,
    sharedStageCode: String?,
    onSharedStageChange: (String?) -> Unit,
    perBlockStages: MutableMap<String, String>,
) {
    val vine = LocalVineColors.current
    val paddocksMissing = selectedPaddocks.isEmpty()
    val summary = when {
        paddocksMissing -> "Select blocks first"
        modeSame -> GrowthStage.byCode(sharedStageCode)?.displayName ?: "Not set"
        else -> {
            val assigned = selectedPaddocks.count { perBlockStages.containsKey(it.id) }
            "Per block \u2014 $assigned/${selectedPaddocks.size} assigned"
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(vine.cardBackground)
                .clickable(enabled = !paddocksMissing) { onToggleExpanded() }
                .padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(VineColors.LeafGreen.copy(alpha = if (paddocksMissing) 0.08f else 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.LocalFlorist,
                    contentDescription = null,
                    tint = VineColors.LeafGreen.copy(alpha = if (paddocksMissing) 0.5f else 1f),
                    modifier = Modifier.size(22.dp),
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("Growth Stage", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Text(
                    summary,
                    fontSize = 12.sp,
                    color = if (paddocksMissing) VineColors.Orange else vine.textSecondary,
                    maxLines = 2,
                )
            }
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = vine.textSecondary,
                modifier = Modifier.size(20.dp),
            )
        }

        if (expanded && !paddocksMissing) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                SegmentedButton(
                    selected = modeSame,
                    onClick = { onModeChange(true) },
                    shape = SegmentedButtonDefaults.itemShape(0, 2),
                ) { Text("Same for All", fontSize = 13.sp) }
                SegmentedButton(
                    selected = !modeSame,
                    onClick = { onModeChange(false) },
                    shape = SegmentedButtonDefaults.itemShape(1, 2),
                ) { Text("Per Block", fontSize = 13.sp) }
            }

            if (modeSame) {
                VineyardCard {
                    Text("E-L Growth Stages", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
                    Spacer8()
                    GrowthStageRadioRow(
                        label = "Not Set",
                        code = null,
                        selected = sharedStageCode == null,
                        onClick = { onSharedStageChange(null) },
                    )
                    GrowthStage.allStages.forEach { stage ->
                        Box(Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
                        GrowthStageRadioRow(
                            label = stage.description,
                            code = stage.code,
                            selected = sharedStageCode == stage.code,
                            onClick = { onSharedStageChange(stage.code) },
                        )
                    }
                }
            } else {
                VineyardCard {
                    selectedPaddocks.forEachIndexed { i, paddock ->
                        if (i > 0) Box(Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
                        var menu by remember(paddock.id) { mutableStateOf(false) }
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(paddock.name, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
                                GrowthStage.byCode(perBlockStages[paddock.id])?.let { stage ->
                                    Text("${stage.description} (${stage.code})", fontSize = 11.sp, color = VineColors.LeafGreen)
                                }
                            }
                            Box {
                                Row(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(8.dp))
                                        .background(VineColors.Olive.copy(alpha = 0.10f))
                                        .clickable { menu = true }
                                        .padding(horizontal = 10.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                                ) {
                                    Text(
                                        perBlockStages[paddock.id] ?: "Select",
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = VineColors.Olive,
                                    )
                                    Icon(
                                        Icons.Filled.SwapVert,
                                        contentDescription = null,
                                        tint = VineColors.Olive,
                                        modifier = Modifier.size(12.dp),
                                    )
                                }
                                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                    DropdownMenuItem(
                                        text = { Text("Not Set") },
                                        onClick = { perBlockStages.remove(paddock.id); menu = false },
                                    )
                                    GrowthStage.allStages.forEach { stage ->
                                        DropdownMenuItem(
                                            text = { Text(stage.displayName, fontSize = 13.sp) },
                                            onClick = { perBlockStages[paddock.id] = stage.code; menu = false },
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GrowthStageRadioRow(
    label: String,
    code: String?,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (selected) VineColors.Olive else vine.textSecondary,
            modifier = Modifier.size(20.dp),
        )
        if (code != null) {
            Text(code, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.width(44.dp))
        }
        Text(label, fontSize = 13.sp, color = vine.textPrimary, maxLines = 2, modifier = Modifier.weight(1f))
    }
}

// ── Equipment ────────────────────────────────────────────────────────────────

@Composable
private fun EquipmentSummaryCard(
    equipmentName: String?,
    tankCapacity: Double?,
    anyConfigured: Boolean,
    expanded: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .clickable { onClick() }
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(VineColors.Olive.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Build, contentDescription = null, tint = VineColors.Olive, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            if (equipmentName != null) {
                Text(equipmentName, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, maxLines = 1)
                Text(
                    tankCapacity?.takeIf { it > 0 }?.let { "${fmtNum(it, 0)} L tank" } ?: "No tank capacity set",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            } else {
                Text(
                    if (anyConfigured) "Select equipment" else "No equipment configured",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
                Text(
                    if (anyConfigured) "Required to continue" else "Tap + to add equipment",
                    fontSize = 12.sp,
                    color = VineColors.Orange,
                )
            }
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = vine.textSecondary,
            modifier = Modifier.size(20.dp),
        )
    }
}

// ── Chemicals ────────────────────────────────────────────────────────────────

/** iOS-style chemical line card: picker, rate menu, override, label links. */
@Composable
private fun CalcChemicalLineCard(
    line: CalcChemLine,
    savedChemicals: List<SavedChemical>,
    onChanged: () -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    val uriHandler = LocalUriHandler.current
    val chem = savedChemicals.firstOrNull { it.id == line.chemicalId }
    val recommended = chem?.let { recommendedRateDisplay(it, line) } ?: 0.0
    val basisSuffix = if (line.basis == SprayCalculator.RateBasis.PER_100L) "/100L" else "/ha"
    val isOverridden = line.overrideText.toDoubleOrNull()?.let { it > 0 } == true

    VineyardCard {
        // Header
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Filled.Science, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
            Text(
                chem?.displayName ?: "Select Chemical",
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
                modifier = Modifier.weight(1f),
                maxLines = 1,
            )
            normalizedUrl(chem?.labelUrl)?.let { url ->
                IconButton(onClick = { uriHandler.openUri(url) }, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.Description, contentDescription = "Open chemical label", tint = VineColors.Olive, modifier = Modifier.size(18.dp))
                }
            }
            normalizedUrl(chem?.productUrl)?.let { url ->
                IconButton(onClick = { uriHandler.openUri(url) }, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.Language, contentDescription = "Open product page", tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                }
            }
            // Basis chip
            Text(
                if (line.basis == SprayCalculator.RateBasis.PER_100L) "Per 100L" else "Per Ha",
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                color = if (line.basis == SprayCalculator.RateBasis.PER_100L) VineColors.Indigo else VineColors.Olive,
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background((if (line.basis == SprayCalculator.RateBasis.PER_100L) VineColors.Indigo else VineColors.Olive).copy(alpha = 0.12f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            )
            IconButton(onClick = onRemove, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Filled.Cancel, contentDescription = "Remove chemical", tint = vine.textSecondary, modifier = Modifier.size(20.dp))
            }
        }

        Spacer8()

        // Chemical picker
        Text("Chemical", fontSize = 11.sp, color = vine.textSecondary)
        Box {
            var menu by remember { mutableStateOf(false) }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(vine.appBackground)
                    .clickable { menu = true }
                    .padding(horizontal = 10.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    chem?.displayName ?: "Select chemical",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = vine.textPrimary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                )
                Icon(Icons.Filled.SwapVert, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(14.dp))
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                savedChemicals.forEach { saved ->
                    DropdownMenuItem(
                        text = {
                            Column {
                                Text(saved.displayName, fontSize = 13.sp)
                                // Actives, derived group and trust state (sql/194).
                                // Never blocks selection: an unverified product is
                                // still a real product the operator is spraying.
                                com.rork.vinetrack.ui.components.ChemicalPickerIntelligenceRow(saved)
                            }
                        },
                        onClick = {
                            if (line.chemicalId != saved.id) {
                                line.chemicalId = saved.id
                                val first = saved.rates.firstOrNull()
                                line.selectedRateId = first?.id
                                line.basis = first?.let { basisOf(it.basis) } ?: SprayCalculator.RateBasis.PER_HECTARE
                                line.overrideText = ""
                                onChanged()
                            }
                            menu = false
                        },
                    )
                }
            }
        }

        if (chem != null) {
            Spacer8()
            // Rate picker
            Text("Rate", fontSize = 11.sp, color = vine.textSecondary)
            Box {
                var menu by remember { mutableStateOf(false) }
                val haRates = chem.rates.filter { it.basis == CHEMICAL_RATE_PER_HECTARE }
                val per100Rates = chem.rates.filter { it.basis == CHEMICAL_RATE_PER_100L }
                val selectedRate = chem.rates.firstOrNull { it.id == line.selectedRateId }
                val rateLabel: String = when {
                    selectedRate != null -> {
                        val suffix = if (selectedRate.basis == CHEMICAL_RATE_PER_100L) "/100L" else "/ha"
                        "${selectedRate.label.ifBlank { "Rate" }}: ${fmtRate(chemicalUnitFromBase(chem.unit, selectedRate.value))} ${chem.unit}$suffix"
                    }
                    recommended > 0 -> "Default: ${fmtRate(recommended)} ${chem.unit}$basisSuffix"
                    else -> "Select rate"
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(vine.appBackground)
                        .clickable(enabled = chem.rates.isNotEmpty()) { menu = true }
                        .padding(horizontal = 10.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        rateLabel,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = vine.textPrimary,
                        modifier = Modifier.weight(1f),
                        maxLines = 1,
                    )
                    if (chem.rates.isNotEmpty()) {
                        Icon(Icons.Filled.SwapVert, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(14.dp))
                    }
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    if (haRates.isNotEmpty()) {
                        DropdownMenuItem(
                            text = { Text("PER HECTARE", fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary) },
                            onClick = {},
                            enabled = false,
                        )
                        haRates.forEach { rate ->
                            DropdownMenuItem(
                                text = {
                                    // Product pack unit stays canonical; the area denominator follows the vineyard.
                                    val region = LocalRegionFormatter.current
                                    Text(
                                        "${rate.label.ifBlank { "Rate" }}: ${fmtRate(region.sprayRateValue(chemicalUnitFromBase(chem.unit, rate.value)))} ${chem.unit}/${region.sprayRateAreaAbbreviation}",
                                        fontSize = 13.sp,
                                    )
                                },
                                onClick = {
                                    line.selectedRateId = rate.id
                                    line.basis = SprayCalculator.RateBasis.PER_HECTARE
                                    line.overrideText = ""
                                    onChanged()
                                    menu = false
                                },
                            )
                        }
                    }
                    if (per100Rates.isNotEmpty()) {
                        DropdownMenuItem(
                            text = { Text("PER 100L WATER", fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary) },
                            onClick = {},
                            enabled = false,
                        )
                        per100Rates.forEach { rate ->
                            DropdownMenuItem(
                                text = { Text("${rate.label.ifBlank { "Rate" }}: ${fmtRate(chemicalUnitFromBase(chem.unit, rate.value))} ${chem.unit}/100L", fontSize = 13.sp) },
                                onClick = {
                                    line.selectedRateId = rate.id
                                    line.basis = SprayCalculator.RateBasis.PER_100L
                                    line.overrideText = ""
                                    onChanged()
                                    menu = false
                                },
                            )
                        }
                    }
                }
            }

            Spacer8()
            // Override rate
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Override Rate", fontSize = 11.sp, color = vine.textSecondary)
                if (isOverridden) {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "Manual",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.Orange,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(VineColors.Orange.copy(alpha = 0.15f))
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                if (isOverridden) {
                    TextButton(onClick = { line.overrideText = ""; onChanged() }) {
                        Text("Reset", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Olive)
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = line.overrideText,
                    onValueChange = { line.overrideText = it.filter { c -> c.isDigit() || c == '.' }; onChanged() },
                    placeholder = { Text(fmtRate(recommended)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                Text("${chem.unit}$basisSuffix", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
            }
            Text(
                "Recommended: ${fmtRate(recommended)} ${chem.unit}$basisSuffix",
                fontSize = 11.sp,
                color = vine.textSecondary,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

// ── Spray Tank Mixing review ─────────────────────────────────────────────────

private fun patternIcon(pattern: TrackingPattern): ImageVector = when (pattern) {
    TrackingPattern.SEQUENTIAL -> Icons.Filled.FormatListNumbered
    TrackingPattern.EVERY_SECOND_ROW -> Icons.Filled.LowPriority
    TrackingPattern.FIVE_THREE -> Icons.Filled.Shuffle
    TrackingPattern.UP_AND_BACK -> Icons.Filled.SwapVert
    TrackingPattern.TWO_ROW_UP_BACK -> Icons.Filled.Repeat
    TrackingPattern.CUSTOM -> Icons.Filled.Tune
    TrackingPattern.FREE_DRIVE -> Icons.Filled.Gesture
}

/**
 * Spray Tank Mixing — the pre-start review step, mirroring the iOS
 * `startConfirmationSheet`: operator/equipment, tank mix preview, machine
 * picker, fans/jets, tracking pattern, start path/direction, sequence preview
 * and the Start Spray Trip action.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayTankMixReview(
    state: AppUiState,
    result: SprayCalculator.Result,
    operatorName: String,
    equipmentLabel: String,
    savedChemicals: List<SavedChemical>,
    canEditCost: Boolean,
    machineId: String?,
    onMachineChange: (String?) -> Unit,
    fansJets: String,
    onFansJetsChange: (String) -> Unit,
    trackingPattern: TrackingPattern,
    onPatternChange: (TrackingPattern) -> Unit,
    hasRowGeometry: Boolean,
    availablePaths: List<Double>,
    startPath: Double,
    onStartPathChange: (Double) -> Unit,
    directionHigherFirst: Boolean,
    onDirectionChange: (Boolean) -> Unit,
    orderedSelectedPaddocks: List<Paddock>,
    pathSequence: List<Double>,
    errorMessage: String?,
    saving: Boolean,
    hasActiveTrip: Boolean,
    onStart: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val uriHandler = LocalUriHandler.current
    val selectedMachine = state.machines.firstOrNull { it.id == machineId }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Spray Tank Mixing") },
                navigationIcon = { BackNavIcon(onCancel) },
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
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Filled.WaterDrop, contentDescription = null, tint = VineColors.Olive, modifier = Modifier.size(40.dp))
                    Spacer(Modifier.height(8.dp))
                    Text("Spray Tank Mixing", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Review the tank mix and trip setup before starting.",
                        fontSize = 14.sp,
                        color = vine.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }

            // Operator + equipment
            item {
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(vertical = 4.dp)) {
                        Icon(Icons.Filled.Person, contentDescription = null, tint = VineColors.Olive, modifier = Modifier.size(18.dp))
                        Text("Operator", fontSize = 14.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
                        Text(operatorName, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
                    }
                    Box(Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(vertical = 4.dp)) {
                        Icon(Icons.Filled.Build, contentDescription = null, tint = VineColors.Olive, modifier = Modifier.size(18.dp))
                        Text("Equipment", fontSize = 14.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
                        Text(equipmentLabel, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
                    }
                }
            }

            // Tank mix preview
            item { SectionHeader("Tank Mix", onLight = true) }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        MixStatTile("Total Area", LocalRegionFormatter.current.formatArea(result.totalAreaHectares), VineColors.Olive, Modifier.weight(1f))
                        MixStatTile("Total Water", "${fmtNum(result.totalWaterLitres, 0)} L", VineColors.Indigo, Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        MixStatTile("Full Tanks", "${result.fullTankCount}", VineColors.DarkGreen, Modifier.weight(1f))
                        MixStatTile("Last Tank", "${fmtNum(result.lastTankLitres, 0)} L", VineColors.Orange, Modifier.weight(1f))
                    }
                }
            }
            itemsIndexed(result.chemicalResults, key = { i, cr -> "mix-$i-${cr.savedChemicalId}" }) { _, cr ->
                val saved = savedChemicals.firstOrNull { it.id == cr.savedChemicalId }
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(Icons.Filled.Science, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(16.dp))
                        Text(cr.name, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
                        normalizedUrl(saved?.labelUrl)?.let { url ->
                            IconButton(onClick = { uriHandler.openUri(url) }, modifier = Modifier.size(30.dp)) {
                                Icon(Icons.Filled.Description, contentDescription = "Open chemical label", tint = VineColors.Olive, modifier = Modifier.size(16.dp))
                            }
                        }
                        normalizedUrl(saved?.productUrl)?.let { url ->
                            IconButton(onClick = { uriHandler.openUri(url) }, modifier = Modifier.size(30.dp)) {
                                Icon(Icons.Filled.Language, contentDescription = "Open product page", tint = vine.textSecondary, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                    Spacer8()
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Column {
                            Text("Rate", fontSize = 11.sp, color = vine.textSecondary)
                            Text(
                                "${fmtRate(cr.rate)} ${cr.unit}${if (cr.basis == SprayCalculator.RateBasis.PER_100L) "/100L" else "/ha"}",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Medium,
                                color = vine.textPrimary,
                            )
                        }
                        Column(horizontalAlignment = Alignment.End) {
                            Text("Total", fontSize = 11.sp, color = vine.textSecondary)
                            Text("${fmtNum(cr.totalAmount, 1)} ${cr.unit}", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Olive)
                        }
                    }
                    Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text("Per full tank: ${fmtNum(cr.amountPerFullTank, 1)} ${cr.unit}", fontSize = 11.sp, color = vine.textSecondary)
                        if (cr.amountInLastTank > 0 && cr.amountInLastTank != cr.amountPerFullTank) {
                            Text("Last tank: ${fmtNum(cr.amountInLastTank, 1)} ${cr.unit}", fontSize = 11.sp, color = vine.textSecondary)
                        }
                    }
                }
            }
            if (result.concentrationFactor != 1.0) {
                item {
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp))
                            .background(VineColors.Orange.copy(alpha = 0.08f)).padding(10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(Icons.Filled.SwapVert, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(16.dp))
                        Text(
                            "Concentration Factor ${"%.2f".format(result.concentrationFactor)}\u00D7",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            if (result.concentrationFactor > 1.0) "Concentrate" else "Dilute",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                            color = VineColors.Orange,
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(VineColors.Orange.copy(alpha = 0.15f))
                                .padding(horizontal = 8.dp, vertical = 3.dp),
                        )
                    }
                }
            }
            if (canEditCost && result.hasCostData) {
                item { CostingCard(result) }
            }

            // Machine (optional, for fuel costing)
            item { SectionHeader("Machine", onLight = true) }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    var menu by remember { mutableStateOf(false) }
                    Box {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(12.dp))
                                .background(vine.cardBackground)
                                .clickable(enabled = state.machines.isNotEmpty()) { menu = true }
                                .padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Icon(Icons.Filled.Agriculture, contentDescription = null, tint = VineColors.Indigo, modifier = Modifier.size(20.dp))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text("Machine / Tractor", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                                Text(
                                    selectedMachine?.displayName
                                        ?: if (state.machines.isEmpty()) "No machines configured" else "No machine selected",
                                    fontSize = 12.sp,
                                    color = vine.textSecondary,
                                )
                            }
                            Icon(Icons.Filled.SwapVert, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
                        }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(text = { Text("No machine") }, onClick = { onMachineChange(null); menu = false })
                            state.machines.forEach { machine ->
                                DropdownMenuItem(
                                    text = { Text(machine.displayName) },
                                    onClick = { onMachineChange(machine.id); menu = false },
                                )
                            }
                        }
                    }
                    Text(
                        if (state.machines.isEmpty()) "Add machines in Equipment to enable fuel cost estimates."
                        else "Optional \u2014 select a machine so fuel cost can be estimated.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
                }
            }

            // Fans / jets
            item { SectionHeader("Equipment Settings", onLight = true) }
            item {
                OutlinedTextField(
                    value = fansJets,
                    onValueChange = { onFansJetsChange(it.filter { c -> c.isDigit() }) },
                    label = { Text("No. Fans / Jets") },
                    placeholder = { Text("e.g. 6") },
                    supportingText = { Text("Optional \u2014 recorded for compliance") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            // Tracking pattern
            item { SectionHeader("Tracking Pattern", onLight = true) }
            items(TrackingPattern.entries, key = { "pattern-${it.rawValue}" }) { pattern ->
                val isSelected = trackingPattern == pattern
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(vine.cardBackground)
                        .clickable { onPatternChange(pattern) }
                        .padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background((if (isSelected) VineColors.Purple else vine.textSecondary).copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            patternIcon(pattern),
                            contentDescription = null,
                            tint = if (isSelected) VineColors.Purple else vine.textSecondary,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(pattern.title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        Text(pattern.subtitle, fontSize = 12.sp, color = vine.textSecondary, maxLines = 2)
                    }
                    Icon(
                        if (isSelected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                        contentDescription = null,
                        tint = if (isSelected) VineColors.Purple else vine.textSecondary.copy(alpha = 0.5f),
                        modifier = Modifier.size(22.dp),
                    )
                }
            }

            // Start path + direction + sequence preview
            if (hasRowGeometry && trackingPattern != TrackingPattern.FREE_DRIVE) {
                item { SectionHeader("Start Path & Direction", onLight = true) }
                item {
                    VineyardCard {
                        val n = TripRowSequencePlanner.combinedTotalRows(orderedSelectedPaddocks)
                        val helper = if (n <= 0) {
                            "Row guidance unavailable for the selected blocks"
                        } else {
                            val range = TripRowSequencePlanner.combinedRangeLabel(orderedSelectedPaddocks)
                            val paths = TripRowSequencePlanner.combinedPathsLabel(orderedSelectedPaddocks)
                            if (orderedSelectedPaddocks.size > 1) "Row guidance follows all selected blocks ($range \u00B7 $paths)"
                            else "Row guidance follows selected block ($range \u00B7 $paths)"
                        }
                        Text(helper, fontSize = 11.sp, color = vine.textSecondary)
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
                                        onClick = { onStartPathChange(path); pathMenu = false },
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
                                onClick = { onDirectionChange(false) },
                                shape = SegmentedButtonDefaults.itemShape(0, 2),
                            ) { Text("Higher to lower", fontSize = 13.sp) }
                            SegmentedButton(
                                selected = directionHigherFirst,
                                onClick = { onDirectionChange(true) },
                                shape = SegmentedButtonDefaults.itemShape(1, 2),
                            ) { Text("Lower to higher", fontSize = 13.sp) }
                        }
                    }
                }
                item { SectionHeader("Proposed Row Sequence", onLight = true) }
                item {
                    VineyardCard {
                        TripRowSequencePlanner.patternPreviewNote(trackingPattern)?.let { note ->
                            Text(note, fontSize = 11.sp, color = vine.textSecondary)
                            Spacer8()
                        }
                        if (pathSequence.isEmpty()) {
                            Text("No sequence available for the current selection.", fontSize = 12.sp, color = vine.textSecondary)
                        } else {
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
            } else if (trackingPattern == TrackingPattern.FREE_DRIVE) {
                item {
                    VineyardCard {
                        Text("No planned row sequence", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        Spacer8()
                        Text(
                            "Drive freely \u2014 the app detects the row/path you are in from GPS, ticks it off when covered, and keeps recording distance, pins and trip history.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            } else {
                item {
                    VineyardCard {
                        Text(
                            "Row guidance unavailable \u2014 selected blocks have no row geometry. The trip will run as Free Drive.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
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
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = onStart,
                        enabled = !saving && !hasActiveTrip,
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.Olive),
                    ) {
                        if (saving) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = Color.White)
                            Text("  Starting\u2026", fontWeight = FontWeight.SemiBold)
                        } else {
                            Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                            Text("  Start Spray Trip", fontWeight = FontWeight.SemiBold)
                        }
                    }
                    if (hasActiveTrip) {
                        Text(
                            "Finish the active trip before starting this spray job.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                    TextButton(onClick = onCancel, enabled = !saving, modifier = Modifier.fillMaxWidth()) {
                        Text("Cancel", color = vine.textSecondary)
                    }
                }
            }
        }
    }
}

@Composable
private fun MixStatTile(label: String, value: String, tint: Color, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.size(8.dp).clip(RoundedCornerShape(50)).background(tint))
        Column {
            Text(label, fontSize = 11.sp, color = vine.textSecondary)
            Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
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
                // Canonical per-hectare cost, re-based over the vineyard's area unit.
                val region = LocalRegionFormatter.current
                SummaryRow("Cost per ${region.areaUnitAbbreviation}", region.formatCostPerArea(perHa))
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
private fun Spacer8() = Spacer(Modifier.height(8.dp))

@Composable
private fun Spacer12() = Spacer(Modifier.height(12.dp))

private fun fmtNum(value: Double, decimals: Int): String =
    if (decimals == 0) value.toLong().toString() else String.format(Locale.US, "%.${decimals}f", value)

/**
 * Chemical-rate formatting: up to 3 decimals with trailing zeros trimmed, so
 * a 0.15 L/100L rate shows as "0.15" (never "0" or "0.2") and 200 stays "200".
 */
private fun fmtRate(value: Double): String =
    if (value % 1.0 == 0.0) value.toLong().toString()
    else String.format(Locale.US, "%.3f", value).trimEnd('0').trimEnd('.')
