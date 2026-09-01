package com.rork.vinetrack.ui.screens

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
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
import androidx.core.net.toUri
import com.rork.vinetrack.data.VintageResolver
import com.rork.vinetrack.data.YieldVintageReport
import com.rork.vinetrack.data.model.GrapeAllocation
import com.rork.vinetrack.data.model.GrapeAllocationBlock
import com.rork.vinetrack.data.model.GrapeAllocationCalculator
import com.rork.vinetrack.data.model.GrapeAllocationFormLogic
import com.rork.vinetrack.data.model.GrapePurchaser
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.TeamRole
import com.rork.vinetrack.data.model.canonicalVarietyName
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.LocalDate
import java.util.Locale
import java.util.UUID

/**
 * Grape Allocation tool (Yields hub), mirroring iOS `GrapeAllocationView`:
 * allocate the current Yield Estimate for a vintage to Own Use destinations
 * or external Sale/Commitment contracts. Supply always comes from the latest
 * completed Bunch Count Trip ([YieldVintageReport]), so a new estimate
 * automatically moves every balance. Money (price, contract values, income)
 * is Owner/Manager only — sql/187-style masking means lower-role devices
 * never even receive prices, and this UI additionally renders no money
 * fields for them.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GrapeAllocationScreen(
    vm: AppViewModel,
    state: AppUiState,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val canViewFinancials = TeamRole.from(state.currentRole).canViewCosting

    val currentVintage = remember(state.seasonStartMonth, state.seasonStartDay) {
        VintageResolver.vintageYear(LocalDate.now(), state.seasonStartMonth, state.seasonStartDay)
    }
    var selectedVintage by remember { mutableStateOf<Int?>(null) }
    val reportVintage = selectedVintage ?: currentVintage

    var editing by remember { mutableStateOf<GrapeAllocation?>(null) }
    var creating by remember { mutableStateOf(false) }
    var deleteCandidate by remember { mutableStateOf<GrapeAllocation?>(null) }

    LaunchedEffect(state.selectedVineyardId) { vm.refreshGrapeAllocations() }

    val availableVintages = remember(state.yieldSessions, state.yieldRecords, state.pickingRecords, state.grapeAllocations, currentVintage) {
        (
            YieldVintageReport.availableVintages(
                currentVintage, state.yieldSessions, state.yieldRecords, state.pickingRecords,
                state.seasonStartMonth, state.seasonStartDay,
            ) + state.grapeAllocations.map { it.vintage }
            ).distinct().sortedDescending()
    }

    val estimateRows = remember(state.yieldSessions, state.paddocks, state.damageRecords, reportVintage) {
        YieldVintageReport.estimateRows(
            state.yieldSessions, state.paddocks, state.damageRecords,
            reportVintage, state.seasonStartMonth, state.seasonStartDay,
        )
    }
    val estimates = remember(estimateRows, state.paddocks) {
        GrapeAllocationCalculator.varietyEstimates(estimateRows, state.paddocks)
    }
    val summary = remember(estimates, state.grapeAllocations, reportVintage) {
        GrapeAllocationCalculator.summary(estimates, state.grapeAllocations, reportVintage)
    }
    val varietyRows = remember(estimates, state.grapeAllocations, reportVintage) {
        GrapeAllocationCalculator.varietyRows(estimates, state.grapeAllocations, reportVintage)
    }
    val vintageAllocations = state.grapeAllocations.filter { it.vintage == reportVintage }
    val fmt = state.regionFormatter

    if (creating || editing != null) {
        GrapeAllocationEditor(
            vm = vm,
            state = state,
            existing = editing,
            defaultVintage = reportVintage,
            currentVintage = currentVintage,
            canViewFinancials = canViewFinancials,
            onClose = { creating = false; editing = null },
            modifier = modifier,
        )
        return
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Grape Allocation") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { creating = true }, containerColor = VineColors.LeafGreen) {
                Icon(Icons.Filled.Add, contentDescription = "Add Allocation")
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 96.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            SectionHeader("Vintage")
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                availableVintages.forEach { vintage ->
                    val isSelected = vintage == reportVintage
                    Text(
                        text = if (vintage == currentVintage) "$vintage · Current" else "$vintage",
                        fontSize = 12.sp,
                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (isSelected) Color.White else vine.textSecondary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(16.dp))
                            .background(if (isSelected) VineColors.LeafGreen else vine.cardBackground)
                            .clickable { selectedVintage = if (vintage == currentVintage) null else vintage }
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                    )
                }
            }

            // Vintage summary.
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        SummaryStat("Estimated", summary.estimatedTonnes, VineColors.Indigo, Modifier.weight(1f))
                        SummaryStat("Own Use", summary.ownUseTonnes, VineColors.Purple, Modifier.weight(1f))
                        SummaryStat("Committed", summary.committedTonnes, VineColors.Orange, Modifier.weight(1f))
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            if (summary.isShortfall) Icons.Filled.Warning else Icons.Filled.CheckCircle,
                            contentDescription = null,
                            tint = if (summary.isShortfall) VineColors.Destructive else VineColors.LeafGreen,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            if (summary.isShortfall) "Shortfall" else "Available",
                            fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                            color = if (summary.isShortfall) VineColors.Destructive else VineColors.LeafGreen,
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            tonnesText(kotlin.math.abs(summary.balanceTonnes)),
                            fontSize = 17.sp, fontWeight = FontWeight.Bold,
                            color = if (summary.isShortfall) VineColors.Destructive else vine.textPrimary,
                        )
                    }
                    if (canViewFinancials) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Contracted Income", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                            Spacer(Modifier.weight(1f))
                            Text(
                                fmt.formatCurrency(
                                    GrapeAllocationCalculator.totalContractedIncome(state.grapeAllocations, reportVintage),
                                ),
                                fontSize = 17.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary,
                            )
                        }
                    }
                }
            }

            if (canViewFinancials) {
                val byPurchaser = GrapeAllocationCalculator.incomeByPurchaser(state.grapeAllocations, reportVintage)
                val byVariety = GrapeAllocationCalculator.incomeByVariety(state.grapeAllocations, reportVintage)
                val byBlock = GrapeAllocationCalculator.incomeByBlock(state.grapeAllocations, reportVintage)
                if (byPurchaser.isNotEmpty()) {
                    SectionHeader("Income Breakdown")
                    IncomeGroup("By Purchaser", byPurchaser, state)
                    IncomeGroup("By Variety", byVariety, state)
                    IncomeGroup("By Block", byBlock, state)
                }
            }

            SectionHeader("Varieties")
            if (varietyRows.isEmpty()) {
                VineyardCard {
                    Text(
                        "No completed Bunch Count Trip and no allocations for this vintage yet. Complete a trip to see the estimated supply per variety.",
                        fontSize = 12.sp, color = vine.textSecondary,
                    )
                }
            } else {
                varietyRows.forEach { row ->
                    VineyardCard {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(row.displayName, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                                Spacer(Modifier.weight(1f))
                                if (row.isShortfall) {
                                    Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Destructive, modifier = Modifier.size(14.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text("Shortfall", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Destructive)
                                }
                            }
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                SummaryStat("Estimated", row.estimatedTonnes, VineColors.Indigo, Modifier.weight(1f))
                                SummaryStat("Own Use", row.ownUseTonnes, VineColors.Purple, Modifier.weight(1f))
                                SummaryStat("External", row.externalTonnes, VineColors.Orange, Modifier.weight(1f))
                                SummaryStat(
                                    "Balance", row.balanceTonnes,
                                    if (row.isShortfall) VineColors.Destructive else VineColors.LeafGreen,
                                    Modifier.weight(1f),
                                )
                            }
                        }
                    }
                }
            }

            SectionHeader("Allocations")
            if (state.grapeAllocationBusy) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                    CircularProgressIndicator(modifier = Modifier.size(22.dp))
                }
            }
            state.grapeAllocationError?.let {
                Text(it, fontSize = 12.sp, color = VineColors.Destructive)
            }
            if (vintageAllocations.isEmpty() && !state.grapeAllocationBusy) {
                VineyardCard {
                    Text(
                        "No allocations for Vintage $reportVintage yet. Tap + to add an Own Use allocation or a Sale / Commitment.",
                        fontSize = 12.sp, color = vine.textSecondary,
                    )
                }
            } else {
                vintageAllocations.forEach { allocation ->
                    AllocationCard(
                        allocation = allocation,
                        canViewFinancials = canViewFinancials,
                        state = state,
                        onEdit = { editing = allocation },
                        onDelete = { deleteCandidate = allocation },
                    )
                }
            }
        }
    }

    deleteCandidate?.let { candidate ->
        AlertDialog(
            onDismissRequest = { deleteCandidate = null },
            title = { Text("Delete this allocation?") },
            text = { Text("${candidate.varietyName} · ${tonnesText(candidate.quantityTonnes)} will be removed.") },
            confirmButton = {
                TextButton(onClick = {
                    vm.deleteGrapeAllocation(candidate.id)
                    deleteCandidate = null
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { deleteCandidate = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SummaryStat(label: String, tonnes: Double, color: androidx.compose.ui.graphics.Color, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(tonnesText(tonnes), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = color)
        Text(label, fontSize = 10.sp, color = vine.textSecondary)
    }
}

@Composable
private fun IncomeGroup(title: String, lines: List<GrapeAllocationCalculator.IncomeLine>, state: AppUiState) {
    if (lines.isEmpty()) return
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
            lines.forEach { line ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(line.label, fontSize = 12.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                    Text(tonnesText(line.tonnes), fontSize = 12.sp, color = vine.textSecondary)
                    Spacer(Modifier.width(10.dp))
                    Text(
                        state.regionFormatter.formatCurrency(line.value),
                        fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary,
                    )
                }
            }
        }
    }
}

@Composable
private fun AllocationCard(
    allocation: GrapeAllocation,
    canViewFinancials: Boolean,
    state: AppUiState,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val isExternal = allocation.isExternal
    val badgeColor = if (isExternal) VineColors.Orange else VineColors.Purple
    VineyardCard(modifier = Modifier.clickable(onClick = onEdit)) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (isExternal) "Sale / Commitment" else "Own Use",
                    fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = badgeColor,
                    modifier = Modifier
                        .clip(RoundedCornerShape(10.dp))
                        .background(badgeColor.copy(alpha = 0.15f))
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                )
                Spacer(Modifier.weight(1f))
                Text(tonnesText(allocation.quantityTonnes), fontSize = 14.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                IconButton(onClick = onDelete, modifier = Modifier.size(28.dp)) {
                    Icon(Icons.Filled.Delete, contentDescription = "Delete allocation", tint = vine.textSecondary, modifier = Modifier.size(16.dp))
                }
            }
            Text(allocation.varietyName, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            if (isExternal) {
                allocation.purchaserName?.takeIf { it.isNotBlank() }?.let {
                    Text(it, fontSize = 12.sp, color = vine.textSecondary)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    allocation.contactEmail?.takeIf { it.isNotBlank() }?.let { email ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.clickable {
                                runCatching {
                                    context.startActivity(Intent(Intent.ACTION_SENDTO, "mailto:$email".toUri()))
                                }
                            },
                        ) {
                            Icon(Icons.Filled.Email, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(13.dp))
                            Spacer(Modifier.width(4.dp))
                            Text(email, fontSize = 12.sp, color = VineColors.Info)
                        }
                    }
                    allocation.contactPhone?.takeIf { it.isNotBlank() }?.let { phone ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.clickable {
                                runCatching {
                                    context.startActivity(Intent(Intent.ACTION_DIAL, "tel:${phone.replace(" ", "")}".toUri()))
                                }
                            },
                        ) {
                            Icon(Icons.Filled.Call, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(13.dp))
                            Spacer(Modifier.width(4.dp))
                            Text(phone, fontSize = 12.sp, color = VineColors.Info)
                        }
                    }
                }
                if (canViewFinancials && allocation.pricePerTonne != null) {
                    Row {
                        Text(
                            "${state.regionFormatter.formatCurrency(allocation.pricePerTonne)} / t",
                            fontSize = 12.sp, color = vine.textSecondary,
                        )
                        Spacer(Modifier.weight(1f))
                        allocation.contractValue?.let {
                            Text(
                                state.regionFormatter.formatCurrency(it),
                                fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary,
                            )
                        }
                    }
                }
            } else {
                allocation.destinationName?.takeIf { it.isNotBlank() }?.let {
                    Text(it, fontSize = 12.sp, color = vine.textSecondary)
                }
            }
            if (allocation.blocks.isNotEmpty()) {
                Text(
                    allocation.blocks.joinToString(" · ") { block ->
                        block.quantityTonnes?.let { "${block.paddockName} (${tonnesText(it)})" } ?: block.paddockName
                    },
                    fontSize = 11.sp, color = vine.textSecondary,
                )
            }
        }
    }
}

/** Add / edit form for one allocation, mirroring the iOS editor sheet. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GrapeAllocationEditor(
    vm: AppViewModel,
    state: AppUiState,
    existing: GrapeAllocation?,
    defaultVintage: Int,
    currentVintage: Int,
    canViewFinancials: Boolean,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    var allocationType by rememberSaveable { mutableStateOf(existing?.allocationType ?: GrapeAllocation.TYPE_OWN_USE) }
    var vintage by rememberSaveable { mutableStateOf(existing?.vintage ?: defaultVintage) }
    var varietyName by rememberSaveable { mutableStateOf(existing?.varietyName ?: "") }
    var varietyKey by remember { mutableStateOf(existing?.varietyKey) }
    var varietyId by remember { mutableStateOf(existing?.varietyId) }
    var destination by rememberSaveable { mutableStateOf(existing?.destinationName ?: "") }
    var tonnesText by rememberSaveable { mutableStateOf(existing?.quantityTonnes?.let { fmtNumber(it) } ?: "") }
    var notes by rememberSaveable { mutableStateOf(existing?.notes ?: "") }
    var purchaser by rememberSaveable { mutableStateOf(existing?.purchaserName ?: "") }
    var contactName by rememberSaveable { mutableStateOf(existing?.contactName ?: "") }
    var contactEmail by rememberSaveable { mutableStateOf(existing?.contactEmail ?: "") }
    var contactPhone by rememberSaveable { mutableStateOf(existing?.contactPhone ?: "") }
    var contactAddress by rememberSaveable { mutableStateOf(existing?.contactAddress ?: "") }
    var priceText by rememberSaveable { mutableStateOf(existing?.pricePerTonne?.let { fmtNumber(it) } ?: "") }
    var varietyMenuOpen by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var purchaserId by rememberSaveable { mutableStateOf(existing?.purchaserId) }
    var purchaserMenuOpen by remember { mutableStateOf(false) }
    var purchaserFormOpen by remember { mutableStateOf(false) }
    var purchaserFormExisting by remember { mutableStateOf<GrapePurchaser?>(null) }
    // Additive block-assignment rows: block dropdown + tonnes + remove.
    var blockRows by remember {
        mutableStateOf<List<GrapeBlockRowDraft>>(
            existing?.blocks?.map { b ->
                GrapeBlockRowDraft(b.id, b.paddockId, b.quantityTonnes?.let { q -> fmtNumber(q) } ?: "")
            } ?: emptyList(),
        )
    }

    val isExternal = allocationType == GrapeAllocation.TYPE_EXTERNAL
    val tonnes = tonnesText.replace(",", ".").toDoubleOrNull()
    val assignment = GrapeAllocationFormLogic.blockAssignmentSummary(
        tonnes ?: 0.0,
        blockRows.filter { it.paddockId != null }.map { it.tonnesText.replace(",", ".").toDoubleOrNull() },
    )
    val canSave = (tonnes ?: 0.0) > 0.0 && varietyName.isNotBlank() &&
        (!isExternal || purchaser.isNotBlank()) && !assignment.exceedsQuantity && !saving

    val varietyOptions = remember(state.paddocks) {
        val seen = HashSet<String>()
        state.paddocks.flatMap { it.varietyAllocations.orEmpty() }
            .mapNotNull { alloc ->
                val name = alloc.displayName?.trim().orEmpty()
                if (name.isEmpty() || !seen.add(canonicalVarietyName(name))) null
                else Triple(name, alloc.varietyKey, alloc.varietyId)
            }
            .sortedBy { it.first.lowercase() }
    }

    val vintageOptions = remember(state.grapeAllocations, currentVintage, defaultVintage, vintage) {
        (state.grapeAllocations.map { it.vintage } + listOf(currentVintage, currentVintage + 1, defaultVintage, vintage))
            .filter { it > 0 }.distinct().sortedDescending()
    }

    // Blocks compatible with the chosen variety — falls back to ALL blocks
    // when no variety is chosen or nothing matches (a block without variety
    // data must never be unselectable).
    val compatiblePaddocks = remember(state.paddocks, varietyName) {
        if (varietyName.isBlank()) {
            state.paddocks
        } else {
            val canonical = canonicalVarietyName(varietyName.trim())
            val matching = state.paddocks.filter { paddock ->
                paddock.varietyAllocations.orEmpty().any {
                    canonicalVarietyName(it.displayName.orEmpty()) == canonical
                }
            }
            matching.ifEmpty { state.paddocks }
        }
    }
    val selectedPurchaser = state.grapePurchasers.firstOrNull { it.id == purchaserId }

    /** Copies the purchaser's CURRENT details into the snapshot fields. */
    fun applyPurchaser(p: GrapePurchaser) {
        purchaserId = p.id
        purchaser = p.wineryName
        contactName = p.contactName.orEmpty()
        contactEmail = p.contactEmail.orEmpty()
        contactPhone = p.contactPhone.orEmpty()
        contactAddress = p.contactAddress.orEmpty()
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(if (existing == null) "Add Allocation" else "Edit Allocation") },
                navigationIcon = { BackNavIcon(onClose) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                SegmentedButton(
                    selected = !isExternal,
                    onClick = { allocationType = GrapeAllocation.TYPE_OWN_USE },
                    shape = SegmentedButtonDefaults.itemShape(index = 0, count = 2),
                ) { Text("Own Use") }
                SegmentedButton(
                    selected = isExternal,
                    onClick = { allocationType = GrapeAllocation.TYPE_EXTERNAL },
                    shape = SegmentedButtonDefaults.itemShape(index = 1, count = 2),
                ) { Text("Sale / Commitment") }
            }

            SectionHeader("Vintage")
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                vintageOptions.forEach { option ->
                    val isSelected = option == vintage
                    Text(
                        text = if (option == currentVintage) "$option · Current" else "$option",
                        fontSize = 12.sp,
                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (isSelected) Color.White else vine.textSecondary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(16.dp))
                            .background(if (isSelected) VineColors.LeafGreen else vine.cardBackground)
                            .clickable { vintage = option }
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                    )
                }
            }

            // Variety is SELECTED from the vineyard's configured varieties —
            // never free text. A legacy value still displays, but any change
            // goes through the configured list.
            ExposedDropdownMenuBox(expanded = varietyMenuOpen, onExpandedChange = { varietyMenuOpen = it }) {
                OutlinedTextField(
                    value = varietyName,
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Variety") },
                    placeholder = { Text("Select\u2026") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = varietyMenuOpen) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    singleLine = true,
                )
                ExposedDropdownMenu(expanded = varietyMenuOpen, onDismissRequest = { varietyMenuOpen = false }) {
                    varietyOptions.forEach { (name, key, id) ->
                        DropdownMenuItem(
                            text = { Text(name) },
                            onClick = {
                                varietyName = name
                                varietyKey = key
                                varietyId = id
                                varietyMenuOpen = false
                            },
                        )
                    }
                }
            }

            OutlinedTextField(
                value = tonnesText,
                onValueChange = { tonnesText = it },
                label = { Text("Tonnes") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                trailingIcon = {
                    FieldInfoIcon("Quantity", "Total tonnes committed under this allocation.")
                },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            OutlinedTextField(
                value = destination,
                onValueChange = { destination = it },
                label = { Text(if (isExternal) "Destination (optional)" else "Destination / use (e.g. Estate wine)") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )

            if (isExternal) {
                SectionHeader("Purchaser")
                ExposedDropdownMenuBox(expanded = purchaserMenuOpen, onExpandedChange = { purchaserMenuOpen = it }) {
                    OutlinedTextField(
                        value = selectedPurchaser?.wineryName ?: "",
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Saved purchaser") },
                        placeholder = { Text("Select\u2026") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = purchaserMenuOpen) },
                        supportingText = {
                            Text("Details are saved as a snapshot on this commitment — later edits to the saved purchaser never change existing allocations.")
                        },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                        singleLine = true,
                    )
                    ExposedDropdownMenu(expanded = purchaserMenuOpen, onDismissRequest = { purchaserMenuOpen = false }) {
                        state.grapePurchasers.forEach { p ->
                            DropdownMenuItem(
                                text = { Text(p.wineryName) },
                                onClick = {
                                    applyPurchaser(p)
                                    purchaserMenuOpen = false
                                },
                            )
                        }
                        if (purchaserId != null) {
                            DropdownMenuItem(
                                text = { Text("Unlink saved purchaser") },
                                onClick = { purchaserId = null; purchaserMenuOpen = false },
                            )
                        }
                        DropdownMenuItem(
                            text = { Text("+ New Purchaser") },
                            onClick = {
                                purchaserFormExisting = null
                                purchaserFormOpen = true
                                purchaserMenuOpen = false
                            },
                        )
                    }
                }
                if (selectedPurchaser != null) {
                    TextButton(onClick = {
                        purchaserFormExisting = selectedPurchaser
                        purchaserFormOpen = true
                    }) { Text("Edit Purchaser") }
                }
                OutlinedTextField(purchaser, { purchaser = it }, label = { Text("Purchaser name") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                OutlinedTextField(contactName, { contactName = it }, label = { Text("Contact person") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                OutlinedTextField(
                    contactEmail, { contactEmail = it }, label = { Text("Email") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    modifier = Modifier.fillMaxWidth(), singleLine = true,
                )
                OutlinedTextField(
                    contactPhone, { contactPhone = it }, label = { Text("Phone") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
                    modifier = Modifier.fillMaxWidth(), singleLine = true,
                )
                OutlinedTextField(contactAddress, { contactAddress = it }, label = { Text("Address") }, modifier = Modifier.fillMaxWidth(), singleLine = true)

                if (canViewFinancials) {
                    SectionHeader("Pricing")
                    OutlinedTextField(
                        value = priceText,
                        onValueChange = { priceText = it },
                        label = { Text("Price per tonne (${state.regionFormatter.currencySymbol})") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        supportingText = { Text("Visible to Owner and Manager only.") },
                        trailingIcon = {
                            FieldInfoIcon(
                                "Price per tonne",
                                "Agreed price for this individual commitment. Contract value is calculated from quantity \u00d7 price per tonne.",
                            )
                        },
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                    )
                    val price = priceText.replace(",", ".").toDoubleOrNull()
                    if (tonnes != null && price != null) {
                        Text(
                            "Contract value: ${state.regionFormatter.formatCurrency(tonnes * price)}",
                            fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary,
                        )
                    }
                }
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionHeader("Block allocations (optional)")
                FieldInfoIcon(
                    "Block allocations",
                    "Optionally nominate which blocks will supply this commitment. Enter the tonnes expected from each block. Assigned tonnes cannot exceed the committed quantity.",
                )
            }
            blockRows.forEach { row ->
                val usedElsewhere = blockRows.filter { it.id != row.id }.mapNotNull { it.paddockId }.toSet()
                BlockAssignmentRow(
                    row = row,
                    availablePaddocks = compatiblePaddocks.filter { it.id !in usedElsewhere },
                    allPaddocks = state.paddocks,
                    onPaddockSelected = { paddockId ->
                        blockRows = blockRows.map { if (it.id == row.id) it.copy(paddockId = paddockId) else it }
                    },
                    onTonnesChange = { text ->
                        blockRows = blockRows.map { if (it.id == row.id) it.copy(tonnesText = text) else it }
                    },
                    onRemove = { blockRows = blockRows.filterNot { it.id == row.id } },
                )
            }
            TextButton(onClick = {
                blockRows = blockRows + GrapeBlockRowDraft(UUID.randomUUID().toString(), null, "")
            }) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("Add block")
            }
            if (blockRows.isNotEmpty() && (tonnes ?: 0.0) > 0.0) {
                Text(
                    "Assigned ${tonnesText(assignment.assignedTonnes)} of ${tonnesText(tonnes ?: 0.0)} \u00b7 Unassigned ${tonnesText(assignment.unassignedTonnes)}",
                    fontSize = 12.sp,
                    color = if (assignment.exceedsQuantity) VineColors.Destructive else vine.textSecondary,
                )
                if (assignment.exceedsQuantity) {
                    Text(
                        "Assigned tonnes exceed the committed quantity.",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = VineColors.Destructive,
                    )
                }
            }

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes") },
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
            )

            Button(
                onClick = {
                    val vineyardId = state.selectedVineyardId ?: return@Button
                    saving = true
                    val paddockById = state.paddocks.associateBy { it.id }
                    val existingBlockIds = existing?.blocks?.associate { it.paddockId to it.id }.orEmpty()
                    val seenPaddocks = HashSet<String>()
                    val blocks = blockRows.mapNotNull { rowDraft ->
                        val paddockId = rowDraft.paddockId ?: return@mapNotNull null
                        val paddock = paddockById[paddockId] ?: return@mapNotNull null
                        if (!seenPaddocks.add(paddockId)) return@mapNotNull null
                        val quantity = rowDraft.tonnesText.replace(",", ".").toDoubleOrNull()?.takeIf { it > 0 }
                        GrapeAllocationBlock(
                            id = existingBlockIds[paddockId] ?: UUID.randomUUID().toString(),
                            allocationId = existing?.id ?: "",
                            vineyardId = vineyardId,
                            paddockId = paddockId,
                            paddockName = paddock.name,
                            quantityTonnes = quantity,
                        )
                    }.sortedBy { it.paddockName.lowercase() }

                    val allocation = GrapeAllocation(
                        id = existing?.id ?: UUID.randomUUID().toString(),
                        vineyardId = vineyardId,
                        vintage = vintage,
                        allocationType = allocationType,
                        varietyId = varietyId,
                        varietyKey = varietyKey,
                        varietyName = varietyName.trim(),
                        destinationName = destination.trim().ifEmpty { null },
                        quantityTonnes = tonnes ?: 0.0,
                        notes = notes.trim().ifEmpty { null },
                        purchaserId = if (isExternal) purchaserId else null,
                        purchaserName = if (isExternal) purchaser.trim().ifEmpty { null } else null,
                        contactName = if (isExternal) contactName.trim().ifEmpty { null } else null,
                        contactEmail = if (isExternal) contactEmail.trim().ifEmpty { null } else null,
                        contactPhone = if (isExternal) contactPhone.trim().ifEmpty { null } else null,
                        contactAddress = if (isExternal) contactAddress.trim().ifEmpty { null } else null,
                        pricePerTonne = when {
                            !isExternal -> null
                            canViewFinancials -> priceText.replace(",", ".").toDoubleOrNull()
                            else -> existing?.pricePerTonne
                        },
                        blocks = blocks,
                    )
                    vm.saveGrapeAllocation(allocation) { ok ->
                        saving = false
                        if (ok) onClose()
                    }
                },
                enabled = canSave,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(if (saving) "Saving…" else "Save Allocation")
            }
        }
    }

    if (purchaserFormOpen) {
        GrapePurchaserFormDialog(
            existing = purchaserFormExisting,
            vineyardId = state.selectedVineyardId.orEmpty(),
            onSave = { p ->
                vm.saveGrapePurchaser(p) { ok ->
                    if (ok) applyPurchaser(p)
                }
                purchaserFormOpen = false
            },
            onDismiss = { purchaserFormOpen = false },
        )
    }
}

/** One additive block-assignment row draft: block dropdown + tonnes + remove. */
private data class GrapeBlockRowDraft(
    val id: String,
    val paddockId: String?,
    val tonnesText: String,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BlockAssignmentRow(
    row: GrapeBlockRowDraft,
    availablePaddocks: List<Paddock>,
    allPaddocks: List<Paddock>,
    onPaddockSelected: (String) -> Unit,
    onTonnesChange: (String) -> Unit,
    onRemove: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ExposedDropdownMenuBox(
            expanded = menuOpen,
            onExpandedChange = { menuOpen = it },
            modifier = Modifier.weight(1f),
        ) {
            OutlinedTextField(
                value = allPaddocks.firstOrNull { it.id == row.paddockId }?.name ?: "",
                onValueChange = {},
                readOnly = true,
                label = { Text("Block") },
                placeholder = { Text("Select\u2026") },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = menuOpen) },
                modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                singleLine = true,
            )
            ExposedDropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                availablePaddocks.forEach { paddock ->
                    DropdownMenuItem(
                        text = { Text(paddock.name) },
                        onClick = {
                            onPaddockSelected(paddock.id)
                            menuOpen = false
                        },
                    )
                }
            }
        }
        OutlinedTextField(
            value = row.tonnesText,
            onValueChange = onTonnesChange,
            label = { Text("Tonnes") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.width(100.dp),
            singleLine = true,
        )
        IconButton(onClick = onRemove, modifier = Modifier.size(32.dp)) {
            Icon(
                Icons.Filled.Delete,
                contentDescription = "Remove block row",
                tint = VineColors.Destructive,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

/**
 * Small, unobtrusive inline help affordance: an info glyph opening a native
 * dialog with a short explanation. Mirrors the iOS `FieldInfoButton`.
 */
@Composable
private fun FieldInfoIcon(title: String, message: String) {
    val vine = LocalVineColors.current
    var open by remember { mutableStateOf(false) }
    IconButton(onClick = { open = true }, modifier = Modifier.size(28.dp)) {
        Icon(
            Icons.Filled.Info,
            contentDescription = "$title help",
            tint = vine.textSecondary,
            modifier = Modifier.size(16.dp),
        )
    }
    if (open) {
        AlertDialog(
            onDismissRequest = { open = false },
            title = { Text(title) },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { open = false }) { Text("OK") } },
        )
    }
}

/**
 * Simple add / edit form for one saved purchaser (sql/219): winery name +
 * optional contact details. Deliberately NOT a CRM. Editing a purchaser
 * never rewrites the snapshots already stored on existing allocations.
 */
@Composable
private fun GrapePurchaserFormDialog(
    existing: GrapePurchaser?,
    vineyardId: String,
    onSave: (GrapePurchaser) -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    var winery by remember { mutableStateOf(existing?.wineryName ?: "") }
    var contactName by remember { mutableStateOf(existing?.contactName ?: "") }
    var contactEmail by remember { mutableStateOf(existing?.contactEmail ?: "") }
    var contactPhone by remember { mutableStateOf(existing?.contactPhone ?: "") }
    var contactAddress by remember { mutableStateOf(existing?.contactAddress ?: "") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (existing == null) "New Purchaser" else "Edit Purchaser") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(winery, { winery = it }, label = { Text("Winery / purchaser name") }, singleLine = true)
                OutlinedTextField(contactName, { contactName = it }, label = { Text("Contact name (optional)") }, singleLine = true)
                OutlinedTextField(
                    contactEmail, { contactEmail = it }, label = { Text("Email (optional)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email), singleLine = true,
                )
                OutlinedTextField(
                    contactPhone, { contactPhone = it }, label = { Text("Phone (optional)") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone), singleLine = true,
                )
                OutlinedTextField(contactAddress, { contactAddress = it }, label = { Text("Address (optional)") }, singleLine = true)
                Text(
                    "Saved for reuse across allocations. Existing allocations keep the details they were created with.",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = winery.isNotBlank(),
                onClick = {
                    onSave(
                        GrapePurchaser(
                            id = existing?.id ?: UUID.randomUUID().toString(),
                            vineyardId = existing?.vineyardId ?: vineyardId,
                            wineryName = winery.trim(),
                            contactName = contactName.trim().ifEmpty { null },
                            contactEmail = contactEmail.trim().ifEmpty { null },
                            contactPhone = contactPhone.trim().ifEmpty { null },
                            contactAddress = contactAddress.trim().ifEmpty { null },
                            updatedAt = existing?.updatedAt,
                        ),
                    )
                },
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

private fun tonnesText(tonnes: Double): String = String.format(Locale.US, "%.2f t", tonnes)

private fun fmtNumber(value: Double): String =
    if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()
