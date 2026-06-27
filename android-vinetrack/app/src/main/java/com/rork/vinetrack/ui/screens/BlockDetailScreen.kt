package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.Highlight
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.model.parseIsoToEpochMs
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import com.rork.vinetrack.data.PaddockReferenceCounts
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.StatusBadge
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BlockDetailView(
    block: Paddock,
    state: AppUiState,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    canEdit: Boolean = false,
    canDelete: Boolean = false,
    onEdit: () -> Unit = {},
    onArchive: () -> Unit = {},
    onDelete: () -> Unit = {},
    loadReferenceCounts: ((PaddockReferenceCounts?) -> Unit) -> Unit = {},
) {
    val vine = LocalVineColors.current
    var showArchive by remember { mutableStateOf(false) }
    var refCounts by remember { mutableStateOf<PaddockReferenceCounts?>(null) }
    var refLoading by remember { mutableStateOf(false) }
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(block.name, maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    if (canEdit) {
                        IconButton(onClick = onEdit) {
                            Icon(Icons.Filled.Edit, contentDescription = "Edit block", tint = VineColors.LeafGreen)
                        }
                    }
                    if (canDelete) {
                        IconButton(onClick = {
                            showArchive = true
                            refCounts = null
                            refLoading = true
                            loadReferenceCounts { counts -> refCounts = counts; refLoading = false }
                        }) {
                            Icon(Icons.Filled.Delete, contentDescription = "Archive block", tint = VineColors.Destructive)
                        }
                    }
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
            KeyStatsGrid(block)

            VarietySection(block.varietyAllocations.orEmpty())

            if (block.varietyAllocations.orEmpty().isNotEmpty()) {
                BlockRipenessChip(state = state, block = block)
            }

            PhenologySection(block)

            GrowthObservationsSection(block, state.growthRecords)

            GeometrySection(block)

            IrrigationSection(block)

            if (block.plantingYear != null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Planting", onLight = true)
                    VineyardCard {
                        DetailRow("Planting year", block.plantingYear.toString())
                    }
                }
            }

            ActivitySection(block, state)

            Spacer(Modifier.height(8.dp))
        }
    }

    if (showArchive) {
        ArchiveBlockDialog(
            blockName = block.name,
            loading = refLoading,
            counts = refCounts,
            onArchive = { showArchive = false; onArchive() },
            onDeletePermanently = { showArchive = false; onDelete() },
            onDismiss = { showArchive = false },
        )
    }
}

/**
 * Archive / permanent-delete confirmation, mirroring iOS `BlocksHubView`:
 * archiving is always available; permanent delete is only offered once the
 * reference-count check confirms the block has no linked records.
 */
@Composable
private fun ArchiveBlockDialog(
    blockName: String,
    loading: Boolean,
    counts: PaddockReferenceCounts?,
    onArchive: () -> Unit,
    onDeletePermanently: () -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val canHardDelete = counts?.isEmpty == true
    val message = when {
        loading -> "Checking for linked records…"
        counts == null -> "Archiving keeps this block available for historical reports but hides it from active selectors."
        counts.isEmpty -> "This block has no linked records. You can archive it, or delete it permanently."
        else -> {
            val preview = counts.summaryLines.take(4).joinToString(", ")
            "This block has linked records ($preview). Archiving keeps it available for historical reports but hides it from active selectors."
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Archive $blockName?") },
        text = { Text(message, color = vine.textSecondary, fontSize = 14.sp) },
        confirmButton = {
            TextButton(onClick = onArchive) { Text("Archive block", color = VineColors.Destructive) }
        },
        dismissButton = {
            if (canHardDelete) {
                TextButton(onClick = onDeletePermanently) { Text("Delete permanently", color = VineColors.Destructive) }
            } else {
                TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

@Composable
private fun KeyStatsGrid(block: Paddock) {
    val ha = if (block.areaHectares > 0) "%.2f ha".format(block.areaHectares) else "—"
    val vines = if (block.effectiveVineCount > 0) "%,d".format(block.effectiveVineCount) else "—"
    val cards = listOf(
        StatCard("Area", ha, Icons.Filled.Map, VineColors.LeafGreen),
        StatCard("Rows", if (block.rowCount > 0) block.rowCount.toString() else "—", Icons.Filled.Straighten, VineColors.Indigo),
        StatCard("Vines", vines, Icons.Filled.Grass, VineColors.DarkGreen),
        StatCard("Row spacing", block.rowWidth?.let { "%.1f m".format(it) } ?: "—", Icons.Filled.Highlight, VineColors.Orange),
    )
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        cards.chunked(2).forEach { rowCards ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                rowCards.forEach { card ->
                    StatCardCell(card, Modifier.weight(1f))
                }
            }
        }
    }
}

private data class StatCard(val label: String, val value: String, val icon: ImageVector, val tint: Color)

@Composable
private fun StatCardCell(card: StatCard, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(vine.cardBackground)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(card.tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(card.icon, contentDescription = null, tint = card.tint, modifier = Modifier.size(20.dp))
        }
        Text(card.value, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        Text(card.label, fontSize = 12.sp, color = vine.textSecondary)
    }
}

@Composable
private fun VarietySection(allocations: List<PaddockVarietyAllocation>) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Varieties", onLight = true)
        VineyardCard {
            if (allocations.isEmpty()) {
                Text("No varieties recorded for this block.", color = vine.textSecondary, fontSize = 14.sp)
            } else {
                allocations.forEachIndexed { index, alloc ->
                    VarietyRow(alloc)
                    if (index < allocations.lastIndex) {
                        Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder).padding(vertical = 4.dp))
                        Spacer(Modifier.height(8.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun VarietyRow(alloc: PaddockVarietyAllocation) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                alloc.displayName ?: alloc.varietyKey ?: "Unknown variety",
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
                modifier = Modifier.weight(1f),
            )
            alloc.displayPercent?.let {
                StatusBadge("${"%.0f".format(it)}%", VineColors.LeafGreen)
            }
        }
        val meta = buildList {
            alloc.clone?.takeIf { it.isNotBlank() }?.let { add("Clone $it") }
            alloc.rootstock?.takeIf { it.isNotBlank() }?.let { add("Rootstock $it") }
        }
        if (meta.isNotEmpty()) {
            Text(meta.joinToString(" · "), fontSize = 13.sp, color = vine.textSecondary)
        }
    }
}

/**
 * Block phenology milestones (read-only here). Dates remain editable from the
 * Growth screen via the safe partial PATCH path; this profile just surfaces them.
 */
@Composable
private fun PhenologySection(block: Paddock) {
    val vine = LocalVineColors.current
    val milestones = listOf(
        "Budburst" to block.budburstDate,
        "Flowering" to block.floweringDate,
        "Veraison" to block.veraisonDate,
        "Harvest" to block.harvestDate,
    )
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Phenology", onLight = true)
        VineyardCard {
            if (!block.hasPhenology) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(Icons.Filled.Info, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                    Text("No phenology dates yet. Add them from the Growth screen.", color = vine.textSecondary, fontSize = 14.sp)
                }
            } else {
                milestones.forEachIndexed { index, (label, iso) ->
                    val date = formatBlockDate(iso)
                    DetailRow(label, date ?: "Not set")
                    if (index < milestones.lastIndex) DividerLine()
                }
            }
        }
    }
}

/**
 * Recent E-L growth-stage observations recorded against this block. Read-only
 * summary (top 5 by observed date); full detail/editing lives on the Growth screen.
 */
@Composable
private fun GrowthObservationsSection(block: Paddock, records: List<GrowthStageRecord>) {
    val vine = LocalVineColors.current
    val blockRecords = records
        .filter { it.paddockId == block.id }
        .sortedByDescending { it.observedEpochMs ?: 0L }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Growth observations", onLight = true)
        VineyardCard {
            if (blockRecords.isEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(Icons.Filled.Info, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                    Text("No growth-stage observations for this block yet.", color = vine.textSecondary, fontSize = 14.sp)
                }
            } else {
                blockRecords.take(5).forEachIndexed { index, record ->
                    GrowthObservationRow(record)
                    if (index < minOf(blockRecords.size, 5) - 1) DividerLine()
                }
                if (blockRecords.size > 5) {
                    Spacer(Modifier.height(8.dp))
                    Text("+ ${blockRecords.size - 5} more on the Growth screen", color = vine.textSecondary, fontSize = 12.sp)
                }
            }
        }
    }
}

@Composable
private fun GrowthObservationRow(record: GrowthStageRecord) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(10.dp)).background(VineColors.LeafGreen.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Text(record.stageCode.ifBlank { "EL" }, color = VineColors.DarkGreen, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                GrowthStage.byCode(record.stageCode)?.description ?: record.displayStage,
                color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 2,
            )
            val meta = buildList {
                formatBlockDate(record.observedAt)?.let { add(it) }
                record.variety?.takeIf { it.isNotBlank() }?.let { add(it) }
            }
            if (meta.isNotEmpty()) {
                Text(meta.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp, maxLines = 1)
            }
        }
    }
}

/**
 * Lightweight cross-reference: how many trips and work tasks are linked to this
 * block. Uses data already loaded in state — no extra fetches, no reporting surface.
 */
@Composable
private fun ActivitySection(block: Paddock, state: AppUiState) {
    val vine = LocalVineColors.current
    val tripCount = state.trips.count { it.paddockId == block.id }
    val taskCount = state.workTasks.count { it.paddockId == block.id }
    if (tripCount == 0 && taskCount == 0) return
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Linked activity", onLight = true)
        VineyardCard {
            DetailRow("Trips", tripCount.toString())
            DividerLine()
            DetailRow("Work tasks", taskCount.toString())
        }
    }
}

@Composable
private fun GeometrySection(block: Paddock) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Geometry & Row Setup", onLight = true)
        VineyardCard {
            StatusLine("Boundary mapped", block.hasGeometry)
            DividerLine()
            StatusLine("Rows laid out", block.hasRows)
            if (block.rowCount > 0) {
                DividerLine()
                DetailRow("Row count", block.rowCount.toString())
            }
            if (block.totalRowLengthMetres > 0 || block.rowLengthOverride != null) {
                DividerLine()
                DetailRow("Total row length", "${"%.0f".format(block.effectiveTotalRowLength)} m")
            }
            block.vineSpacing?.let {
                DividerLine()
                DetailRow("Vine spacing", "%.2f m".format(it))
            }
            block.rowWidth?.let {
                DividerLine()
                DetailRow("Row width", "%.2f m".format(it))
            }
            block.rowDirection?.takeIf { it != 0.0 }?.let {
                DividerLine()
                DetailRow("Row direction", "%.0f°".format(it))
            }
        }
    }
}

@Composable
private fun IrrigationSection(block: Paddock) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Irrigation", onLight = true)
        VineyardCard {
            if (!block.hasIrrigationSetup) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(Icons.Filled.Info, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                    Text("No drip setup recorded for this block.", color = vine.textSecondary, fontSize = 14.sp)
                }
            } else {
                block.flowPerEmitter?.let {
                    DetailRow("Flow per emitter", "%.1f L/h".format(it))
                    DividerLine()
                }
                block.emitterSpacing?.let {
                    DetailRow("Emitter spacing", "%.2f m".format(it))
                }
                block.litresPerHaPerHour?.let {
                    DividerLine()
                    DetailRow("Application rate", "${"%,.0f".format(it)} L/ha/h")
                }
                block.mmPerHour?.let {
                    DividerLine()
                    DetailRow("Rate", "%.2f mm/h".format(it))
                }
            }
        }
    }
}

@Composable
private fun StatusLine(label: String, on: Boolean) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (on) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.Success, modifier = Modifier.size(20.dp))
        } else {
            Icon(Icons.Outlined.Circle, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(20.dp))
        }
        Text(label, color = vine.textPrimary, modifier = Modifier.weight(1f))
        Text(if (on) "Yes" else "Not set", color = if (on) VineColors.Success else vine.textSecondary, fontSize = 13.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = vine.textSecondary, modifier = Modifier.weight(1f), fontSize = 14.sp)
        Text(value, color = vine.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
    }
}

private val blockDateFormatter: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM yyyy", Locale.getDefault())

/** Format an ISO timestamp to a short local date, or null when absent/unparseable. */
private fun formatBlockDate(iso: String?): String? {
    val ms = parseIsoToEpochMs(iso) ?: return null
    return Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).format(blockDateFormatter)
}

@Composable
private fun DividerLine() {
    val vine = LocalVineColors.current
    Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(vine.cardBorder))
}
