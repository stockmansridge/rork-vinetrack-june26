package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.CostReportBuilder
import com.rork.vinetrack.data.CostReportBuilder.CostAllocationRow
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.model.tripFunctionDisplayName
import androidx.compose.foundation.shape.CircleShape
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Owner/manager-only Cost Reports screen mirroring the iOS `CostReportsView`.
 * Rebuilds Season × Block × Variety cost breakdowns on the fly from completed
 * trips (via the pure cost estimator) since Android has no synced allocation
 * table. Cost per tonne uses recorded/estimated season yields, counted once per
 * block. Non-financial roles see a locked state and never any figures.
 */

/** A grouped breakdown bucket keyed by season, block, variety and (optionally) operation. */
private data class CostGroup(
    val seasonYear: Int,
    val paddockId: String?,
    val paddockName: String,
    val variety: String,
    val varietyFraction: Double,
    val tripFunction: String?,
    val area: Double,
    val labour: Double,
    val fuel: Double,
    val chemical: Double,
    val total: Double,
    val rows: List<CostAllocationRow>,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CostReportsScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenTool: ((ToolRoute) -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val fmt = state.regionFormatter
    val canViewCosting = state.currentRole == "owner" || state.currentRole == "manager"

    val costingSetup = remember(
        state.operatorCategories, state.machines, state.fuelPurchases,
        state.savedChemicals, state.paddocks, state.trips, state.yieldRecords,
    ) {
        if (!canViewCosting) null else buildCostingSetup(state)
    }

    val allRows = remember(state.trips, state.sprayRecords, state.operatorCategories, state.machines, state.fuelPurchases, state.paddocks) {
        if (!canViewCosting) emptyList()
        else CostReportBuilder.build(
            trips = state.trips,
            sprayRecords = state.sprayRecords,
            operatorCategories = state.operatorCategories,
            machines = state.machines,
            fuelPurchases = state.fuelPurchases,
            paddocks = state.paddocks,
        )
    }

    val seasons = remember(allRows) { allRows.map { it.seasonYear }.distinct().sortedDescending() }
    val blocks = remember(allRows) {
        allRows.mapNotNull { row -> row.paddockId?.let { it to row.paddockName } }
            .distinctBy { it.first }
            .sortedBy { it.second.lowercase() }
    }
    val varieties = remember(allRows) { allRows.map { it.variety }.distinct().sorted() }
    val operations = remember(allRows) { allRows.mapNotNull { it.tripFunction }.distinct().sorted() }

    var selectedSeason by remember(seasons) { mutableStateOf(seasons.firstOrNull()) }
    var selectedBlock by remember { mutableStateOf<String?>(null) }
    var selectedVariety by remember { mutableStateOf<String?>(null) }
    var selectedOperation by remember { mutableStateOf<String?>(null) }
    var groupByFunction by remember { mutableStateOf(false) }
    var selectedGroup by remember { mutableStateOf<CostGroup?>(null) }

    val filtered = remember(allRows, selectedSeason, selectedBlock, selectedVariety, selectedOperation) {
        allRows.filter { row ->
            (selectedSeason == null || row.seasonYear == selectedSeason) &&
                (selectedBlock == null || row.paddockId == selectedBlock) &&
                (selectedVariety == null || row.variety == selectedVariety) &&
                (selectedOperation == null || row.tripFunction == selectedOperation)
        }
    }

    val groups = remember(filtered, groupByFunction) { aggregate(filtered, groupByFunction) }

    // Season summary, counting each (season, block) yield only once.
    val totalCost = filtered.sumOf { it.totalCost }
    val totalArea = filtered.sumOf { it.areaHa }
    val totalYield = remember(filtered, state.yieldRecords) {
        filtered.map { it.seasonYear to it.paddockId }.distinct().sumOf { (season, pid) ->
            CostReportBuilder.seasonBlockYieldTonnes(state.yieldRecords, season, pid)
        }
    }
    val costPerHa = if (totalArea > 0 && totalCost > 0) totalCost / totalArea else null
    val costPerTonne = if (totalYield > 0 && totalCost > 0) totalCost / totalYield else null

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(selectedGroup?.let { "${it.paddockName} · ${it.variety}" } ?: "Cost Reports") },
                navigationIcon = {
                    val back = if (selectedGroup != null) ({ selectedGroup = null }) else onBack
                    if (back != null) BackNavIcon(back)
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        if (!canViewCosting) {
            Column(modifier = Modifier.fillMaxSize().padding(padding), verticalArrangement = Arrangement.Center) {
                EmptyState(
                    icon = Icons.Filled.Lock,
                    title = "Cost Reports unavailable",
                    message = "Cost reports are visible to vineyard owners and managers only.",
                )
            }
            return@Scaffold
        }

        AnimatedContent(
            targetState = selectedGroup,
            transitionSpec = { fadeIn() togetherWith fadeOut() },
            label = "cost-reports-nav",
            modifier = Modifier.padding(padding),
        ) { group ->
            if (group != null) {
                GroupDetailView(group = group, fmt = fmt, paddocks = state.paddocks, trips = state.trips)
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(20.dp),
                ) {
                    // Costing setup wizard (owner/manager only)
                    costingSetup?.let { setup ->
                        item {
                            CostingSetupWizardSection(
                                setup = setup,
                                onOpenTopic = { topic ->
                                    val route = when (topic) {
                                        CostingTopic.Labour -> ToolRoute.TeamAccess
                                        CostingTopic.Fuel -> ToolRoute.Equipment
                                        CostingTopic.Chemicals -> ToolRoute.SprayManagement
                                        CostingTopic.Area -> ToolRoute.Blocks
                                        CostingTopic.Yield -> ToolRoute.Yield
                                    }
                                    onOpenTool?.invoke(route)
                                },
                            )
                        }
                    }

                    // Filters
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            SectionHeader("Filters", onLight = true)
                            FilterPicker(
                                label = "Season",
                                value = selectedSeason?.toString(),
                                allLabel = "All seasons",
                                options = seasons.map { it.toString() to it.toString() },
                                onSelect = { selectedSeason = it?.toIntOrNull() },
                            )
                            FilterPicker(
                                label = "Block",
                                value = blocks.firstOrNull { it.first == selectedBlock }?.second,
                                allLabel = "All blocks",
                                options = blocks.map { it.first to it.second },
                                onSelect = { selectedBlock = it },
                            )
                            FilterPicker(
                                label = "Variety",
                                value = selectedVariety,
                                allLabel = "All varieties",
                                options = varieties.map { it to it },
                                onSelect = { selectedVariety = it },
                            )
                            FilterPicker(
                                label = "Operation",
                                value = selectedOperation?.let { opLabel(it) },
                                allLabel = "All operations",
                                options = operations.map { it to opLabel(it) },
                                onSelect = { selectedOperation = it },
                            )
                        }
                    }

                    // Season summary
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            SectionHeader("Season Summary", onLight = true)
                            VineyardCard {
                                SummaryRow("Total estimated cost", fmt.formatCurrency(totalCost), emphasise = true)
                                DividerC(vine.cardBorder)
                                SummaryRow("Treated area", "${formatHaC(fmt.areaValue(totalArea))} ${fmt.areaUnitAbbreviation}")
                                DividerC(vine.cardBorder)
                                SummaryRow("Cost / ${fmt.areaUnitAbbreviation}", costPerHa?.let { "${fmt.formatCurrency(fmt.perAreaValue(it))}/${fmt.areaUnitAbbreviation}" } ?: "—")
                                DividerC(vine.cardBorder)
                                SummaryRow("Yield", if (totalYield > 0) "${formatTonnesC(totalYield)} t" else "—")
                                DividerC(vine.cardBorder)
                                SummaryRow("Cost / tonne", costPerTonne?.let { "${fmt.formatCurrency(it)}/t" } ?: "—")
                                if (filtered.isEmpty()) {
                                    DividerC(vine.cardBorder)
                                    Text(
                                        "No completed trips match these filters yet.",
                                        color = vine.textSecondary, fontSize = 12.sp,
                                        modifier = Modifier.padding(vertical = 8.dp),
                                    )
                                }
                            }
                            Text(
                                "Treated area is the mapped block area from the trips in this report; a block treated multiple times contributes per trip. Yield is the recorded or estimated season yield, counted once per block.",
                                color = vine.textSecondary, fontSize = 11.sp,
                            )
                        }
                    }

                    // Breakdown
                    item {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            SectionHeader("Season × Block × Variety", onLight = true)
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(vine.cardBackground)
                                    .padding(horizontal = 14.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text("Group by operation", color = vine.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                                Switch(checked = groupByFunction, onCheckedChange = { groupByFunction = it })
                            }
                            Text(
                                "Rows are grouped by season, block and variety. Tap a row to see the contributing trips.",
                                color = vine.textSecondary, fontSize = 11.sp,
                            )
                            if (groups.any { it.variety == CostReportBuilder.UNASSIGNED_VARIETY }) {
                                Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(13.dp))
                                    Text(
                                        "Unassigned variety means the block has no variety allocation, or VineTrack could not match it to a recognised variety. Add or fix variety allocations in Block Settings.",
                                        color = vine.textSecondary, fontSize = 11.sp,
                                    )
                                }
                            }
                        }
                    }

                    if (groups.isEmpty()) {
                        item {
                            VineyardCard {
                                Text("No breakdown rows for the current filter.", color = vine.textSecondary, fontSize = 13.sp)
                            }
                        }
                    } else {
                        items(groups.size) { index ->
                            val group = groups[index]
                            BreakdownCard(
                                group = group,
                                fmt = fmt,
                                yieldTonnes = if (!groupByFunction) {
                                    CostReportBuilder.seasonBlockYieldTonnes(state.yieldRecords, group.seasonYear, group.paddockId) * group.varietyFraction
                                } else 0.0,
                                onClick = { selectedGroup = group },
                            )
                        }
                    }

                    item { Box(modifier = Modifier.height(8.dp)) }
                }
            }
        }
    }
}

/** Aggregate allocation rows into Season × Block × Variety (× Operation) buckets. */
private fun aggregate(rows: List<CostAllocationRow>, groupByFunction: Boolean): List<CostGroup> {
    data class Key(val season: Int, val pid: String?, val name: String, val variety: String, val fn: String?)
    val buckets = LinkedHashMap<Key, MutableList<CostAllocationRow>>()
    rows.forEach { row ->
        val key = Key(row.seasonYear, row.paddockId, row.paddockName, row.variety, if (groupByFunction) row.tripFunction else null)
        buckets.getOrPut(key) { mutableListOf() }.add(row)
    }
    return buckets.map { (key, list) ->
        CostGroup(
            seasonYear = key.season,
            paddockId = key.pid,
            paddockName = key.name,
            variety = key.variety,
            varietyFraction = list.firstOrNull()?.varietyFraction ?: 1.0,
            tripFunction = key.fn,
            area = list.sumOf { it.areaHa },
            labour = list.sumOf { it.labourCost },
            fuel = list.sumOf { it.fuelCost },
            chemical = list.sumOf { it.chemicalCost },
            total = list.sumOf { it.totalCost },
            rows = list,
        )
    }.sortedWith(
        compareByDescending<CostGroup> { it.seasonYear }
            .thenBy { it.paddockName.lowercase() }
            .thenBy { it.variety.lowercase() }
            .thenBy { it.tripFunction ?: "" },
    )
}

@Composable
private fun BreakdownCard(group: CostGroup, fmt: RegionFormatter, yieldTonnes: Double, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    val tripCount = group.rows.map { it.tripId }.distinct().size
    val isUnassigned = group.variety == CostReportBuilder.UNASSIGNED_VARIETY
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    "${group.seasonYear} · ${group.paddockName}",
                    color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
                )
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (isUnassigned) {
                        Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(13.dp))
                    }
                    val meta = buildList {
                        add(group.variety)
                        group.tripFunction?.let { add(opLabel(it)) }
                        if (group.area > 0) add("${formatHaC(fmt.areaValue(group.area))} ${fmt.areaUnitAbbreviation}")
                        if (yieldTonnes > 0) add("${formatTonnesC(yieldTonnes)} t")
                        add("$tripCount trip${if (tripCount == 1) "" else "s"}")
                    }
                    Text(meta.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp, maxLines = 2)
                }
                val perUnit = buildList {
                    if (group.area > 0) add("${fmt.formatCurrency(fmt.perAreaValue(group.total / group.area))}/${fmt.areaUnitAbbreviation}")
                    if (yieldTonnes > 0) add("${fmt.formatCurrency(group.total / yieldTonnes)}/t")
                }
                if (perUnit.isNotEmpty()) {
                    Text(perUnit.joinToString(" · "), color = vine.textSecondary.copy(alpha = 0.8f), fontSize = 11.sp)
                }
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(fmt.formatCurrency(group.total), color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
            }
        }
    }
}

@Composable
private fun GroupDetailView(
    group: CostGroup,
    fmt: RegionFormatter,
    paddocks: List<com.rork.vinetrack.data.model.Paddock>,
    trips: List<com.rork.vinetrack.data.model.Trip>,
) {
    val vine = LocalVineColors.current
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            VineyardCard {
                SummaryRow("Total cost", fmt.formatCurrency(group.total), emphasise = true)
                DividerC(vine.cardBorder)
                SummaryRow("Labour", fmt.formatCurrency(group.labour))
                DividerC(vine.cardBorder)
                SummaryRow("Fuel", fmt.formatCurrency(group.fuel))
                DividerC(vine.cardBorder)
                SummaryRow("Chemical", fmt.formatCurrency(group.chemical))
                DividerC(vine.cardBorder)
                SummaryRow("Treated area", "${formatHaC(fmt.areaValue(group.area))} ${fmt.areaUnitAbbreviation}")
            }
        }
        item { SectionHeader("Contributing trips · ${group.rows.map { it.tripId }.distinct().size}", onLight = true) }
        val sorted = group.rows.sortedByDescending { it.tripDateEpochMs ?: 0L }
        items(sorted.size) { index ->
            val row = sorted[index]
            val trip = trips.firstOrNull { it.id == row.tripId }
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            trip?.displayLabel ?: row.tripFunction?.let { opLabel(it) } ?: "Trip",
                            color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f),
                        )
                        Text(fmt.formatCurrency(row.totalCost), color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    }
                    val meta = buildList {
                        formatCostDate(row.tripDateEpochMs)?.let { add(it) }
                        row.tripFunction?.let { add(opLabel(it)) }
                        if (row.areaHa > 0) add("${formatHaC(fmt.areaValue(row.areaHa))} ${fmt.areaUnitAbbreviation}")
                    }
                    if (meta.isNotEmpty()) Text(meta.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp)
                    row.warnings.forEach { w ->
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(12.dp))
                            Text(w, color = VineColors.Orange, fontSize = 11.sp)
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FilterPicker(
    label: String,
    value: String?,
    allLabel: String,
    options: List<Pair<String, String>>,
    onSelect: (String?) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = value ?: allLabel,
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text(allLabel) }, onClick = { onSelect(null); expanded = false })
            options.forEach { (id, display) ->
                DropdownMenuItem(text = { Text(display) }, onClick = { onSelect(id); expanded = false })
            }
        }
    }
}

@Composable
private fun SummaryRow(label: String, value: String, emphasise: Boolean = false) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = vine.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Text(
            value,
            color = if (emphasise) VineColors.PrimaryAccent else vine.textSecondary,
            fontSize = if (emphasise) 16.sp else 14.sp,
            fontWeight = if (emphasise) FontWeight.Bold else FontWeight.SemiBold,
        )
    }
}

@Composable
private fun DividerC(color: androidx.compose.ui.graphics.Color) {
    Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(color))
}

private fun opLabel(raw: String): String =
    tripFunctionDisplayName(raw) ?: raw.replaceFirstChar { it.uppercase() }

private fun formatHaC(value: Double): String =
    if (value >= 10) value.toInt().toString() else String.format(Locale.getDefault(), "%.1f", value)

private fun formatTonnesC(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else String.format(Locale.getDefault(), "%.1f", value)

private fun formatCostDate(epochMs: Long?): String? {
    epochMs ?: return null
    return SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(epochMs))
}

// MARK: - Costing setup wizard

/** Audit topics mirroring the iOS `CostingSetupAnalysis.Topic` (sans `inputs`, which Android does not model). */
enum class CostingTopic { Labour, Fuel, Chemicals, Area, Yield }

/** A single readiness check shown in the costing setup wizard. */
data class CostingSetupItem(
    val topic: CostingTopic,
    val title: String,
    val isComplete: Boolean,
    val detail: String,
    val icon: ImageVector,
)

/** Result of auditing the data needed for reliable cost reports. */
data class CostingSetup(val items: List<CostingSetupItem>) {
    val allComplete: Boolean get() = items.all { it.isComplete }
    val missingCount: Int get() = items.count { !it.isComplete }
}

/**
 * Audit the same store data the cost estimator consumes so the wizard always
 * matches the warnings users see in Cost Reports. Mirrors the iOS
 * `CostingSetupAnalysis.make`.
 */
private fun buildCostingSetup(state: AppUiState): CostingSetup {
    val trips = state.trips
    val tractors = state.machines.filter { it.machineType == "tractor" }
    val cats = state.operatorCategories
    val chems = state.savedChemicals
    val paddocks = state.paddocks

    // Labour
    val catsWithRate = cats.filter { (it.costPerHour ?: 0.0) > 0.0 }
    val labourComplete = cats.isNotEmpty() && catsWithRate.isNotEmpty()
    val labourDetail = when {
        cats.isEmpty() -> "Assign worker types and hourly rates in Team & Access."
        catsWithRate.isEmpty() -> "Worker types have no hourly rate. Open Team & Access to add one."
        else -> "${catsWithRate.size} worker type${if (catsWithRate.size == 1) "" else "s"} with hourly rate."
    }

    // Fuel
    val tractorsWithUsage = tractors.filter { it.hasFuelUsageRate }
    val tripsWithoutTractor = trips.count { it.machineId == null && it.tractorId == null }
    val fuelComplete = tractors.isNotEmpty() && tractorsWithUsage.isNotEmpty() &&
        state.fuelPurchases.isNotEmpty() && tripsWithoutTractor == 0
    val fuelDetail = when {
        tractors.isEmpty() -> "Select tractors on trips, set fuel use in L/hr, and add fuel purchases."
        tractorsWithUsage.isEmpty() -> "Tractors are missing fuel use (L/hr). Open Equipment to set."
        state.fuelPurchases.isEmpty() -> "No fuel purchases recorded yet. Add one to enable fuel cost."
        tripsWithoutTractor > 0 -> "$tripsWithoutTractor trip${if (tripsWithoutTractor == 1) "" else "s"} missing a tractor link."
        else -> "Tractors, fuel use and purchases configured."
    }

    // Chemicals
    val chemsWithCost = chems.filter { (it.purchase?.costPerBaseUnit ?: 0.0) > 0.0 }
    val chemicalComplete = chems.isNotEmpty() && chemsWithCost.size == chems.size
    val chemicalDetail = when {
        chems.isEmpty() -> "Add purchase information to Saved Chemicals so spray costs can be calculated."
        chemsWithCost.isEmpty() -> "Saved chemicals are missing purchase costs. Open Spray Management."
        chemsWithCost.size < chems.size -> {
            val n = chems.size - chemsWithCost.size
            "$n saved chemical${if (n == 1) "" else "s"} missing purchase cost."
        }
        else -> "${chemsWithCost.size} saved chemical${if (chemsWithCost.size == 1) "" else "s"} with purchase cost."
    }

    // Area
    val paddocksWithGeometry = paddocks.filter { it.hasGeometry }
    val tripsWithoutPaddock = trips.count { it.paddockId == null }
    val areaComplete = paddocksWithGeometry.isNotEmpty() && tripsWithoutPaddock == 0
    val areaDetail = when {
        paddocksWithGeometry.isEmpty() -> "Link trips to mapped blocks so treated area and cost/ha can be calculated."
        tripsWithoutPaddock > 0 -> "$tripsWithoutPaddock trip${if (tripsWithoutPaddock == 1) "" else "s"} not linked to a block."
        else -> "${paddocksWithGeometry.size} block${if (paddocksWithGeometry.size == 1) "" else "s"} mapped."
    }

    // Yield
    val hasActuals = state.yieldRecords.any { rec ->
        rec.blocks.any { (it.actualYieldTonnes ?: 0.0) > 0.0 }
    }
    val yieldDetail = if (hasActuals) {
        "Actual yield records found for cost-per-tonne."
    } else {
        "Add actual yield records so cost/tonne can be calculated."
    }

    return CostingSetup(
        items = listOf(
            CostingSetupItem(CostingTopic.Labour, "Operator labour", labourComplete, labourDetail, Icons.Filled.Warning),
            CostingSetupItem(CostingTopic.Fuel, "Fuel costing", fuelComplete, fuelDetail, Icons.Filled.Warning),
            CostingSetupItem(CostingTopic.Chemicals, "Chemical costing", chemicalComplete, chemicalDetail, Icons.Filled.Warning),
            CostingSetupItem(CostingTopic.Area, "Treated area", areaComplete, areaDetail, Icons.Filled.Warning),
            CostingSetupItem(CostingTopic.Yield, "Yield tonnes", hasActuals, yieldDetail, Icons.Filled.Warning),
        ),
    )
}

/**
 * Collapsible owner/manager-only audit of the inputs needed for reliable cost
 * reports. Tapping a row navigates to the relevant management tool. Mirrors the
 * iOS `CostingSetupWizardSection`.
 */
@Composable
private fun CostingSetupWizardSection(
    setup: CostingSetup,
    onOpenTopic: (CostingTopic) -> Unit,
) {
    val vine = LocalVineColors.current
    var expanded by remember { mutableStateOf(true) }
    val headerTint = if (setup.allComplete) VineColors.LeafGreen else VineColors.Orange

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Costing Setup", onLight = true)
        VineyardCard(modifier = Modifier.animateContentSize()) {
            Row(
                modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(
                    modifier = Modifier.size(30.dp).clip(CircleShape).background(headerTint.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (setup.allComplete) Icons.Filled.CheckCircle else Icons.Filled.Warning,
                        contentDescription = null, tint = headerTint, modifier = Modifier.size(17.dp),
                    )
                }
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        if (setup.allComplete) "Costing setup complete" else "Costing setup",
                        color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        if (setup.allComplete) "All required cost inputs are configured"
                        else "${setup.missingCount} item${if (setup.missingCount == 1) "" else "s"} need attention",
                        color = vine.textSecondary, fontSize = 12.sp,
                    )
                }
                Icon(
                    if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = null, tint = vine.textSecondary,
                )
            }
            if (expanded) {
                Text(
                    "Complete these setup items so VineTrack can calculate cost by block, variety, hectare and tonne.",
                    color = vine.textSecondary, fontSize = 12.sp,
                    modifier = Modifier.padding(top = 12.dp, bottom = 4.dp),
                )
                setup.items.forEach { item ->
                    DividerC(vine.cardBorder)
                    CostingSetupRow(item = item, onClick = { onOpenTopic(item.topic) })
                }
            }
        }
    }
}

@Composable
private fun CostingSetupRow(item: CostingSetupItem, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    val tint = if (item.isComplete) VineColors.LeafGreen else VineColors.Orange
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(28.dp).clip(CircleShape).background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (item.isComplete) Icons.Filled.Check else item.icon,
                contentDescription = null, tint = tint, modifier = Modifier.size(15.dp),
            )
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(item.title, color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                if (!item.isComplete) {
                    Box(
                        modifier = Modifier.clip(RoundedCornerShape(6.dp))
                            .background(VineColors.Orange.copy(alpha = 0.15f))
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    ) {
                        Text("Needs setup", color = VineColors.Orange, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
            Text(item.detail, color = vine.textSecondary, fontSize = 12.sp)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
    }
}
