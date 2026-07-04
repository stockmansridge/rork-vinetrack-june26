package com.rork.vinetrack.ui.screens

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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.MapDefaults
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** True when this pin is a repair-mode pin (case-insensitive, iOS parity). */
private fun Pin.isRepair(): Boolean = mode?.equals("Repairs", ignoreCase = true) == true

/** True when this pin is a growth-mode pin (case-insensitive, iOS parity). */
private fun Pin.isGrowth(): Boolean = mode?.equals("Growth", ignoreCase = true) == true

/**
 * Read-only vineyard overview dashboard, the Android twin of iOS
 * `VineyardDetailsView`. Reached from the Home "Vineyard Overview" card, it
 * aggregates the whole-vineyard picture: an embedded blocks mini-map, headline
 * metrics (area, vines, trellis length, rows), a tappable blocks list with
 * per-block detail, a pins-by-block breakdown and a season activity roll-up.
 *
 * Purely presentational — performs no database writes. [onOpenFullMap] hands off
 * to the full-screen [VineyardMapScreen] so the satellite map stays reachable.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VineyardOverviewScreen(
    state: AppUiState,
    modifier: Modifier = Modifier,
    defaults: MapDefaults = MapDefaults.factory,
    onBack: () -> Unit,
    onOpenFullMap: () -> Unit,
) {
    val vine = LocalVineColors.current
    val fmt = state.regionFormatter
    val paddocks = state.paddocks
    val pins = state.pins

    var selectedBlock by remember { mutableStateOf<Paddock?>(null) }

    val totalAreaHa = remember(paddocks) { paddocks.sumOf { it.areaHectares } }
    val totalVines = remember(paddocks) { paddocks.sumOf { it.effectiveVineCount } }
    val totalTrellis = remember(paddocks) { paddocks.sumOf { it.effectiveTotalRowLength } }
    val totalRows = remember(paddocks) { paddocks.sumOf { it.rowCount } }

    val openRepairPins = remember(pins) { pins.count { it.isRepair() && !it.isCompleted } }
    val growthPins = remember(pins) { pins.count { it.isGrowth() } }
    val sprayCount = remember(state.sprayRecords) { state.sprayRecords.count { !it.isTemplate } }
    val completedTrips = remember(state.trips) { state.trips.count { !it.isActive } }
    val hasMappable = remember(paddocks, pins) {
        paddocks.any { it.hasGeometry } || pins.any { it.latitude != null && it.longitude != null }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(state.selectedVineyard?.name ?: "Vineyard Details") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // Map section
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(280.dp)
                            .clip(RoundedCornerShape(14.dp))
                            .background(vine.cardBackground),
                    ) {
                        VineyardMapContent(
                            state = state,
                            pins = pins,
                            defaults = defaults,
                            modifier = Modifier.fillMaxSize(),
                        )
                        if (hasMappable) {
                            Box(
                                modifier = Modifier
                                    .align(Alignment.TopEnd)
                                    .padding(10.dp)
                                    .size(36.dp)
                                    .clip(CircleShape)
                                    .background(Color.Black.copy(alpha = 0.55f))
                                    .clickable { onOpenFullMap() },
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    Icons.Filled.Fullscreen,
                                    contentDescription = "Open full map",
                                    tint = Color.White,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        }
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.Outlined.TouchApp,
                            contentDescription = null,
                            tint = vine.textSecondary,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.size(6.dp))
                        Text("Tap a block below for details", fontSize = 12.sp, color = vine.textSecondary)
                    }
                }
            }

            // Vineyard summary stats (2x2 grid)
            item {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OverviewHeading("Vineyard Summary")
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                        StatCard("Total Area", fmt.formatArea(totalAreaHa), Icons.Filled.Map, VineColors.LeafGreen, Modifier.weight(1f))
                        StatCard("Total Vines", formatLargeCount(totalVines), Icons.Filled.Spa, VineColors.Olive, Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                        StatCard("Trellis Length", fmt.formatShortDistance(totalTrellis), Icons.Filled.Straighten, VineColors.EarthBrown, Modifier.weight(1f))
                        StatCard("Total Rows", "$totalRows", Icons.Outlined.GridView, VineColors.Cyan, Modifier.weight(1f))
                    }
                }
            }

            // Blocks list
            item { OverviewHeading(fmt.blockTermPluralCapitalised) }
            if (paddocks.isEmpty()) {
                item {
                    EmptyCard("No ${fmt.blockTermPlural} configured", "Set up ${fmt.blockTermPlural} on the web portal or iOS app.")
                }
            } else {
                items(paddocks, key = { it.id }) { block ->
                    BlockInfoCard(block = block, fmt = fmt, onClick = { selectedBlock = block })
                }
            }

            // Pins by block
            item { OverviewHeading("Pins by ${fmt.blockTermCapitalised}") }
            if (pins.isEmpty()) {
                item { EmptyCard("No pins recorded", null) }
            } else {
                val blocksWithPins = paddocks.filter { block -> pins.any { it.paddockId == block.id } }
                items(blocksWithPins, key = { "pins-${it.id}" }) { block ->
                    PinsSummaryCard(block = block, pins = pins.filter { it.paddockId == block.id })
                }
                val unassigned = pins.filter { it.paddockId == null }
                if (unassigned.isNotEmpty()) {
                    item {
                        VineyardCard {
                            Text("Unassigned", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                            Spacer(Modifier.height(8.dp))
                            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                PinCount("Repairs", unassigned.count { it.isRepair() }, VineColors.Orange)
                                PinCount("Growth", unassigned.count { it.isGrowth() }, VineColors.LeafGreen)
                            }
                        }
                    }
                }
            }

            // Activity roll-up
            item {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OverviewHeading("Activity")
                    VineyardCard {
                        ActivityRow(Icons.Filled.Grass, VineColors.Purple, "Spray Records", "$sprayCount")
                        Spacer(Modifier.height(10.dp))
                        ActivityRow(Icons.AutoMirrored.Filled.DirectionsRun, VineColors.Info, "Completed Trips", "$completedTrips")
                        Spacer(Modifier.height(10.dp))
                        ActivityRow(Icons.Filled.Build, VineColors.Orange, "Open Repair Pins", "$openRepairPins")
                        Spacer(Modifier.height(10.dp))
                        ActivityRow(Icons.Filled.Spa, VineColors.LeafGreen, "Growth Pins", "$growthPins")
                    }
                }
            }

            item { Spacer(Modifier.height(8.dp)) }
        }
    }

    selectedBlock?.let { block ->
        val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = false)
        ModalBottomSheet(
            onDismissRequest = { selectedBlock = null },
            sheetState = sheetState,
            containerColor = vine.cardBackground,
        ) {
            BlockDetailSheetContent(block = block, fmt = fmt, state = state)
        }
    }
}

@Composable
private fun OverviewHeading(text: String) {
    Text(
        text,
        fontSize = 18.sp,
        fontWeight = FontWeight.Bold,
        color = LocalVineColors.current.textPrimary,
    )
}

@Composable
private fun StatCard(label: String, value: String, icon: ImageVector, color: Color, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier.size(32.dp).clip(RoundedCornerShape(8.dp)).background(color.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        }
        Column {
            Text(value, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(label, fontSize = 11.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun BlockInfoCard(block: Paddock, fmt: RegionFormatter, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    val rowNumbers = remember(block) { block.rows?.map { it.number }?.sorted() ?: emptyList() }
    val varieties = remember(block) { block.varietyAllocations?.filter { it.displayName != null } ?: emptyList() }
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Grass, contentDescription = null, tint = VineColors.Olive, modifier = Modifier.size(16.dp))
            Spacer(Modifier.size(6.dp))
            Text(block.name, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary, modifier = Modifier.weight(1f))
            Text(fmt.formatArea(block.areaHectares), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = VineColors.LeafGreen)
        }
        if (varieties.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            varieties.forEach { v ->
                val pct = v.displayPercent?.let { " · ${"%.0f".format(it)}%" } ?: ""
                Text("${v.displayName}$pct", fontSize = 12.sp, color = vine.textSecondary)
            }
        }
        Spacer(Modifier.height(10.dp))
        Row(modifier = Modifier.fillMaxWidth()) {
            BlockStat("Vines", "${block.effectiveVineCount}", Modifier.weight(1f))
            BlockStat("Trellis", fmt.formatShortDistance(block.effectiveTotalRowLength), Modifier.weight(1f))
            BlockStat("Rows", "${block.rowCount}", Modifier.weight(1f))
        }
        if (rowNumbers.size > 1) {
            val first = rowNumbers.first()
            val last = rowNumbers.last()
            if (first != last) {
                Spacer(Modifier.height(8.dp))
                Text("Rows $first–$last", fontSize = 12.sp, color = vine.textSecondary)
            }
        }
    }
}

@Composable
private fun BlockStat(label: String, value: String, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
    }
}

@Composable
private fun PinsSummaryCard(block: Paddock, pins: List<Pin>) {
    val vine = LocalVineColors.current
    val repairs = pins.count { it.isRepair() }
    val growth = pins.count { it.isGrowth() }
    val open = pins.count { it.isRepair() && !it.isCompleted }
    val resolved = pins.count { it.isRepair() && it.isCompleted }
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Grass, contentDescription = null, tint = VineColors.Olive, modifier = Modifier.size(14.dp))
            Spacer(Modifier.size(6.dp))
            Text(block.name, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
            Text("${pins.size} pin${if (pins.size == 1) "" else "s"}", fontSize = 12.sp, color = vine.textSecondary)
        }
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            PinCount("Repairs", repairs, VineColors.Orange)
            PinCount("Growth", growth, VineColors.LeafGreen)
            if (open > 0) PinCount("Open", open, VineColors.Destructive)
            if (resolved > 0) PinCount("Resolved", resolved, VineColors.Success)
        }
    }
}

@Composable
private fun PinCount(label: String, count: Int, color: Color) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(color))
        Text("$count", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
    }
}

@Composable
private fun ActivityRow(icon: ImageVector, color: Color, label: String, value: String) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(color.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.size(12.dp))
        Text(label, fontSize = 14.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
    }
}

@Composable
private fun EmptyCard(title: String, subtitle: String?) {
    Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        VineyardCard {
            Column(
                modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(title, fontSize = 14.sp, color = LocalVineColors.current.textSecondary)
                if (subtitle != null) {
                    Text(subtitle, fontSize = 12.sp, color = LocalVineColors.current.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun BlockDetailSheetContent(block: Paddock, fmt: RegionFormatter, state: AppUiState) {
    val vine = LocalVineColors.current
    val blockPins = state.pins.filter { it.paddockId == block.id }
    val blockTrips = state.trips.filter { !it.isActive && (it.paddockId == block.id || it.paddockIds.contains(block.id)) }
    val varieties = block.varietyAllocations?.filter { it.displayName != null } ?: emptyList()

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 32.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Text(block.name, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

        DetailSection("Overview") {
            DetailRow("Area", fmt.formatArea(block.areaHectares))
            DetailRow("Vines", "${block.effectiveVineCount}")
            DetailRow("Trellis Length", fmt.formatShortDistance(block.effectiveTotalRowLength))
            DetailRow("Rows", "${block.rowCount}")
            block.rowWidth?.let { DetailRow("Row Spacing", "${"%.1f".format(it)} m") }
            block.vineSpacing?.let { DetailRow("Vine Spacing", "${"%.1f".format(it)} m") }
        }

        if (block.hasIrrigationSetup) {
            DetailSection("Irrigation") {
                block.flowPerEmitter?.let { DetailRow("Emitter Rate", "${"%.1f".format(it)} L/hr") }
                block.emitterSpacing?.let { DetailRow("Emitter Spacing", "${"%.1f".format(it)} m") }
                block.litresPerHaPerHour?.let { DetailRow("L/ha/hr", "%.0f".format(it)) }
            }
        }

        DetailSection("Pins") {
            DetailRow("Total Pins", "${blockPins.size}")
            DetailRow("Repair Pins", "${blockPins.count { it.isRepair() }}")
            DetailRow("Growth Pins", "${blockPins.count { it.isGrowth() }}")
            DetailRow("Unresolved", "${blockPins.count { it.isRepair() && !it.isCompleted }}")
        }

        if (varieties.isNotEmpty()) {
            DetailSection("Varieties") {
                varieties.forEach { v ->
                    val pct = v.displayPercent?.let { "${"%.0f".format(it)}%" }
                    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(v.displayName ?: "Variety", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            v.clone?.let { Text("Clone: $it", fontSize = 12.sp, color = vine.textSecondary) }
                            v.rootstock?.let { Text("Rootstock: $it", fontSize = 12.sp, color = vine.textSecondary) }
                        }
                        if (pct != null) {
                            Text(pct, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.LeafGreen)
                        }
                    }
                }
            }
        }

        DetailSection("Activity") {
            DetailRow("Trips", "${blockTrips.size}")
        }
    }
}

@Composable
private fun DetailSection(title: String, content: @Composable () -> Unit) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title.uppercase(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.5.sp, color = vine.textSecondary)
        content()
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 14.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
    }
}

private fun formatLargeCount(value: Int): String =
    if (value >= 1000) "%.1fk".format(value / 1000.0) else "$value"
