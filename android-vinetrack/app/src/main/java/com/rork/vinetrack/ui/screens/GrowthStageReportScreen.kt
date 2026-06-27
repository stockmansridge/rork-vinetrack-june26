package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.GrowthStageReportPdfExporter
import com.rork.vinetrack.data.OperationPrefsStore
import com.rork.vinetrack.data.RegionDateFormat
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.util.Calendar
import java.util.TimeZone

/**
 * Vintage growth-stage report, mirroring the iOS `GrowthStageReportView`. Lets
 * the user filter by block and vintage, view an E-L stage × vintage timeline of
 * first-observed dates, and export the same multi-page PDF (table + season
 * timeline graph) iOS produces. Read-only; never writes to the backend.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GrowthStageReportScreen(
    state: AppUiState,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    canExport: Boolean = true,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val fmt = state.regionFormatter
    val ops = remember { OperationPrefsStore(context).load() }
    val seasonMonth = ops.seasonStartMonth
    val seasonDay = ops.seasonStartDay
    val dateFormat = remember(state.regionSettings) { RegionDateFormat.from(state.regionSettings.dateFormat) }

    var selectedPaddockId by remember { mutableStateOf<String?>(null) }
    var selectedVintages by remember { mutableStateOf<Set<Int>>(emptySet()) }
    var exporting by remember { mutableStateOf(false) }

    // Growth observations carrying a real E-L code and date (pins are already
    // mirrored into growthRecords).
    val growthRecords = remember(state.growthRecords) {
        state.growthRecords.filter { it.stageCode.isNotBlank() && it.observedEpochMs != null }
    }
    val filteredRecords = remember(growthRecords, selectedPaddockId) {
        if (selectedPaddockId == null) growthRecords
        else growthRecords.filter { it.paddockId == selectedPaddockId }
    }
    val availableVintages = remember(filteredRecords, seasonMonth, seasonDay) {
        filteredRecords.mapNotNull { it.observedEpochMs?.let { ms -> vintageYear(ms, seasonMonth, seasonDay) } }
            .toSortedSet(compareByDescending { it }).toList()
    }
    val activeVintages = remember(availableVintages, selectedVintages) {
        if (selectedVintages.isEmpty()) availableVintages
        else availableVintages.filter { selectedVintages.contains(it) }
    }
    val enabledCodes = remember { OperationPrefsStore(context).load().enabledGrowthStageCodes.toSet() }
    val allStageCodes = remember(filteredRecords, enabledCodes) {
        val used = filteredRecords.map { it.stageCode }.toSet()
        GrowthStage.allStages.map { it.code }
            .filter { used.contains(it) && (enabledCodes.isEmpty() || enabledCodes.contains(it)) }
    }

    fun colorForVintage(vintage: Int): Color {
        val idx = availableVintages.indexOf(vintage)
        if (idx < 0) return vine.textPrimary
        return vintagePalette[idx % vintagePalette.size]
    }

    fun runExport() {
        if (exporting) return
        exporting = true
        val blocks = buildBlockReports(state.paddocks, filteredRecords, selectedPaddockId, seasonMonth, seasonDay)
        GrowthStageReportPdfExporter.exportAndShare(
            context = context,
            blocks = blocks,
            vineyardName = state.selectedVineyard?.name ?: "Vineyard",
            seasonStartMonth = seasonMonth,
            seasonStartDay = seasonDay,
            dateFormat = dateFormat,
            logo = state.selectedVineyardLogo,
        )
        exporting = false
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Export PDF") },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    if (canExport) {
                        IconButton(
                            onClick = { runExport() },
                            enabled = !exporting && growthRecords.isNotEmpty() && availableVintages.isNotEmpty(),
                        ) {
                            if (exporting) CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = VineColors.LeafGreen)
                            else Icon(Icons.Filled.IosShare, contentDescription = "Export PDF", tint = VineColors.LeafGreen)
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        when {
            growthRecords.isEmpty() -> Box(modifier = Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                EmptyState(
                    icon = Icons.Filled.Spa,
                    title = "No growth data",
                    message = "Record growth-stage observations to build your vintage report.",
                )
            }
            availableVintages.isEmpty() -> Box(modifier = Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                EmptyState(
                    icon = Icons.Filled.Spa,
                    title = "No matching data",
                    message = "No growth-stage entries found for the selected block.",
                )
            }
            else -> LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                item {
                    FilterSection("Block") {
                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            FilterChip(
                                selected = selectedPaddockId == null,
                                onClick = { selectedPaddockId = null },
                                label = { Text("All Blocks") },
                            )
                            state.paddocks.forEach { p ->
                                FilterChip(
                                    selected = selectedPaddockId == p.id,
                                    onClick = { selectedPaddockId = if (selectedPaddockId == p.id) null else p.id },
                                    label = { Text(p.name) },
                                )
                            }
                        }
                    }
                }

                item {
                    FilterSection("Vintages", leadingIcon = Icons.Filled.CalendarMonth) {
                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            FilterChip(
                                selected = selectedVintages.isEmpty(),
                                onClick = { selectedVintages = emptySet() },
                                label = { Text("All Vintages") },
                            )
                            availableVintages.forEach { vintage ->
                                val selected = selectedVintages.contains(vintage)
                                FilterChip(
                                    selected = selected,
                                    onClick = {
                                        selectedVintages = if (selected) selectedVintages - vintage else selectedVintages + vintage
                                    },
                                    leadingIcon = {
                                        Box(modifier = Modifier.size(10.dp).clip(CircleShape).background(colorForVintage(vintage)))
                                    },
                                    label = { Text("Vintage $vintage") },
                                    colors = FilterChipDefaults.filterChipColors(
                                        selectedContainerColor = colorForVintage(vintage).copy(alpha = 0.15f),
                                        selectedLabelColor = colorForVintage(vintage),
                                    ),
                                )
                            }
                        }
                        availableVintages.firstOrNull()?.let { first ->
                            val (start, end) = vintageRange(first, seasonMonth, seasonDay)
                            Text(
                                "Vintage $first: ${fmt.formatDate(start)} \u2013 ${fmt.formatDate(end)}",
                                color = vine.textSecondary, fontSize = 12.sp,
                                modifier = Modifier.padding(top = 6.dp),
                            )
                        }
                    }
                }

                item {
                    FilterSection("E-L Growth Stages", leadingIcon = Icons.Filled.Spa) {
                        Text(
                            "Showing ${allStageCodes.size} stage${if (allStageCodes.size == 1) "" else "s"} with observations. Enable or hide E-L stages in Settings › E-L Growth Stages.",
                            color = vine.textSecondary,
                            fontSize = 12.sp,
                        )
                    }
                }
                items(allStageCodes.size) { idx ->
                    StageRow(
                        code = allStageCodes[idx],
                        activeVintages = activeVintages,
                        selectedVintages = selectedVintages,
                        records = filteredRecords,
                        paddocks = state.paddocks,
                        seasonMonth = seasonMonth,
                        seasonDay = seasonDay,
                        colorFor = ::colorForVintage,
                        formatDate = { fmt.formatDate(it) },
                    )
                }
            }
        }
    }
}

@Composable
private fun FilterSection(
    title: String,
    leadingIcon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    content: @Composable () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (leadingIcon != null) {
                Icon(leadingIcon, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(15.dp))
            }
            Text(title.uppercase(), color = vine.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
        content()
    }
}

@Composable
private fun StageRow(
    code: String,
    activeVintages: List<Int>,
    selectedVintages: Set<Int>,
    records: List<GrowthStageRecord>,
    paddocks: List<Paddock>,
    seasonMonth: Int,
    seasonDay: Int,
    colorFor: (Int) -> Color,
    formatDate: (Long) -> String,
) {
    val vine = LocalVineColors.current
    val stage = GrowthStage.allStages.firstOrNull { it.code == code }
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(
                modifier = Modifier.clip(RoundedCornerShape(6.dp)).background(VineColors.LeafGreen).padding(horizontal = 8.dp, vertical = 3.dp),
            ) {
                Text(code, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
            stage?.let {
                Text(it.description, color = vine.textSecondary, fontSize = 12.sp, maxLines = 2, modifier = Modifier.weight(1f))
            }
        }

        activeVintages.forEach { vintage ->
            val color = colorFor(vintage)
            val pins = stageEntries(records, vintage, seasonMonth, seasonDay)[code].orEmpty()
            if (pins.isNotEmpty()) {
                pins.forEach { rec ->
                    val blockName = paddocks.firstOrNull { it.id == rec.paddockId }?.name
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(modifier = Modifier.width(3.dp).height(20.dp).clip(RoundedCornerShape(2.dp)).background(color))
                        Text("$vintage", color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(38.dp))
                        Text(rec.observedEpochMs?.let { formatDate(it) } ?: "", color = vine.textPrimary, fontSize = 12.sp)
                        Spacer(Modifier.weight(1f))
                        blockName?.let {
                            Box(
                                modifier = Modifier.clip(CircleShape).background(vine.textSecondary.copy(alpha = 0.12f)).padding(horizontal = 6.dp, vertical = 2.dp),
                            ) {
                                Text(it, color = vine.textSecondary, fontSize = 10.sp)
                            }
                        }
                    }
                }
            } else if (selectedVintages.isEmpty() || selectedVintages.contains(vintage)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(modifier = Modifier.width(3.dp).height(20.dp).clip(RoundedCornerShape(2.dp)).background(color.copy(alpha = 0.3f)))
                    Text("$vintage", color = color.copy(alpha = 0.4f), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(38.dp))
                    Text("\u2014", color = vine.textSecondary.copy(alpha = 0.4f), fontSize = 12.sp)
                }
            }
        }
        Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
    }
}

// MARK: - Vintage helpers (shared with the PDF exporter logic, ported from iOS)

private val vintagePalette: List<Color> = listOf(
    Color(0xFF007AFF), Color(0xFF34C759), Color(0xFFFF9500), Color(0xFFAF52DE), Color(0xFFFF3B30),
    Color(0xFF30B0C7), Color(0xFFFF2D55), Color(0xFF5856D6), Color(0xFF00C7BE), Color(0xFF32ADE6),
)

private fun calendar(): Calendar = Calendar.getInstance(TimeZone.getDefault())

/** Vintage year for an observation date relative to the season start (month/day). */
internal fun vintageYear(epochMs: Long, seasonMonth: Int, seasonDay: Int): Int {
    val cal = calendar().apply { timeInMillis = epochMs }
    val month = cal.get(Calendar.MONTH) + 1
    val day = cal.get(Calendar.DAY_OF_MONTH)
    val year = cal.get(Calendar.YEAR)
    return if (month > seasonMonth || (month == seasonMonth && day >= seasonDay)) year + 1 else year
}

/** Inclusive [start, end] epoch ms for a vintage's season window. */
internal fun vintageRange(vintage: Int, seasonMonth: Int, seasonDay: Int): Pair<Long, Long> {
    val cal = calendar()
    cal.clear(); cal.set(vintage - 1, seasonMonth - 1, seasonDay, 0, 0, 0)
    val start = cal.timeInMillis
    cal.clear(); cal.set(vintage, seasonMonth - 1, seasonDay, 0, 0, 0)
    cal.add(Calendar.DAY_OF_MONTH, -1)
    cal.set(Calendar.HOUR_OF_DAY, 23); cal.set(Calendar.MINUTE, 59); cal.set(Calendar.SECOND, 59)
    return start to cal.timeInMillis
}

/** Records grouped by stage code for a vintage window, sorted by observation time. */
private fun stageEntries(
    records: List<GrowthStageRecord>,
    vintage: Int,
    seasonMonth: Int,
    seasonDay: Int,
): Map<String, List<GrowthStageRecord>> {
    val (start, end) = vintageRange(vintage, seasonMonth, seasonDay)
    return records
        .filter { (it.observedEpochMs ?: return@filter false) in start..end }
        .groupBy { it.stageCode }
        .mapValues { (_, recs) -> recs.sortedBy { it.observedEpochMs ?: 0L } }
}

/** Build per-block report payloads (first-observed date per stage/vintage) for the PDF. */
internal fun buildBlockReports(
    paddocks: List<Paddock>,
    filteredRecords: List<GrowthStageRecord>,
    selectedPaddockId: String?,
    seasonMonth: Int,
    seasonDay: Int,
): List<GrowthStageReportPdfExporter.BlockReport> {
    val targetPaddocks = if (selectedPaddockId != null) paddocks.filter { it.id == selectedPaddockId } else paddocks
    return targetPaddocks.mapNotNull { paddock ->
        val recs = filteredRecords.filter { it.paddockId == paddock.id }
        if (recs.isEmpty()) return@mapNotNull null
        val vintages = recs.mapNotNull { it.observedEpochMs?.let { ms -> vintageYear(ms, seasonMonth, seasonDay) } }
            .toSortedSet(compareByDescending { it }).toList()
        val usedCodes = recs.map { it.stageCode }.toSet()
        val stageCodes = GrowthStage.allStages.map { it.code }.filter { usedCodes.contains(it) }
        val entries = vintages.associateWith { vintage ->
            val (start, end) = vintageRange(vintage, seasonMonth, seasonDay)
            val codeMap = mutableMapOf<String, Long>()
            recs.filter { (it.observedEpochMs ?: return@filter false) in start..end }.forEach { rec ->
                val ms = rec.observedEpochMs ?: return@forEach
                val existing = codeMap[rec.stageCode]
                if (existing == null || ms < existing) codeMap[rec.stageCode] = ms
            }
            codeMap.toMap()
        }
        GrowthStageReportPdfExporter.BlockReport(paddock.name, vintages, stageCodes, entries)
    }
}
