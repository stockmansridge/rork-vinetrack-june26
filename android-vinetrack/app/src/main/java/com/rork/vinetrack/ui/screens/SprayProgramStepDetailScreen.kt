package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.chemical.ChemicalSnapshotCapture
import com.rork.vinetrack.data.chemical.legacyGroupProjection
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.resolveSprayEquipmentName
import com.rork.vinetrack.data.spray.SprayProgramLanding
import com.rork.vinetrack.data.spray.SprayProgramStepPermissions
import com.rork.vinetrack.data.spray.SprayProgramTerminology
import com.rork.vinetrack.data.spray.SprayTargetLibrary
import com.rork.vinetrack.data.spray.SprayTargetVocabulary
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.ChemicalVerificationBadge
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Reusable configuration only. Planning and editing remain owned by the existing parent flows. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun SprayProgramStepDetailScreen(
    record: SprayRecord,
    state: AppUiState,
    isPortalManaged: Boolean,
    onBack: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onPlanSpray: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val canEdit = SprayProgramStepPermissions.canEdit(isPortalManaged, state.canManageSprayProgram, canEditRecords = true)
    val canDelete = SprayProgramStepPermissions.canDelete(isPortalManaged, canDeleteRecords = true)
    var menuExpanded by remember(record.id) { mutableStateOf(false) }
    var confirmDelete by remember(record.id) { mutableStateOf(false) }
    val products = remember(record.tanks) { SprayProgramStepPresentation.products(record) }
    val targetLabels = remember(state.sprayTargetLibrary, record.vineyardId) {
        SprayTargetLibrary.labels(state.sprayTargetLibrary, record.vineyardId)
    }
    val targets = remember(record.targets, targetLabels) {
        SprayTargetVocabulary.tags(record.targets.orEmpty(), null, targetLabels)
    }
    val stageLabel = SprayProgramLanding.elStageLabel(record)
    val stage = GrowthStage.byCode(stageLabel)
        ?: SprayProgramLanding.elStageNumber(record)?.let { GrowthStage.byCode("EL$it") }
    val equipment = resolveSprayEquipmentName(record, state.sprayEquipment)
    val tractor = state.machines.firstOrNull {
        (it.id == record.tractorId || (record.tractorId != null && it.legacyTractorId == record.tractorId)) &&
            it.vineyardId == record.vineyardId
    }?.displayName ?: record.tractor?.takeIf { it.isNotBlank() }
        ?: record.tractorId?.let { "Tractor unavailable" }
    val chemistry = remember(products, state.savedChemicals) {
        products.map { product ->
            product to ChemicalSnapshotCapture.resolve(
                savedChemicalId = product.savedChemicalId,
                productName = product.name,
                registrationIdentityKey = product.chemicalSnapshot?.registrationIdentityKey,
                library = state.savedChemicals,
            ).first
        }
    }

    BackHandler(onBack = onBack)
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text(SprayProgramTerminology.PROGRAM_STEP, fontSize = 17.sp, fontWeight = FontWeight.SemiBold) },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    if (canEdit || canDelete) {
                        androidx.compose.foundation.layout.Box {
                            IconButton(onClick = { menuExpanded = true }) {
                                Icon(Icons.Filled.MoreHoriz, contentDescription = "Program Step actions")
                            }
                            DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                                if (canEdit) DropdownMenuItem(
                                    text = { Text(SprayProgramTerminology.EDIT_PROGRAM_STEP) },
                                    leadingIcon = { Icon(Icons.Filled.Edit, contentDescription = null) },
                                    onClick = { menuExpanded = false; onEdit() },
                                )
                                if (canDelete) DropdownMenuItem(
                                    text = { Text("Delete Program Step", color = VineColors.Destructive) },
                                    leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive) },
                                    onClick = { menuExpanded = false; confirmDelete = true },
                                )
                            }
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        bottomBar = {
            Column(Modifier.fillMaxWidth().background(vine.cardBackground).navigationBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp)) {
                Button(
                    onClick = onPlanSpray,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                    contentPadding = PaddingValues(vertical = 14.dp, horizontal = 16.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen, contentColor = Color.White),
                ) {
                    Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null, modifier = Modifier.size(20.dp))
                    Text(SprayProgramTerminology.PLAN_SPRAY, modifier = Modifier.padding(start = 8.dp), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SprayProgramStageBadge(stageLabel, capsule = true)
                    stage?.description?.let { Text(it, fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.weight(1f)) }
                }
                Text(SprayProgramStepPresentation.name(record), fontSize = 26.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            }
            if (isPortalManaged) {
                Row(
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(vine.cardBackground).padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(if (canEdit) Icons.Filled.Sync else Icons.Filled.Lock, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
                    Text(SprayProgramTerminology.SYNCED_WITH_ADMIN_PORTAL, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
                }
            }
            if (targets.isNotEmpty()) {
                ProgramStepSection("Targets", Icons.Filled.GpsFixed) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        targets.forEach { tag ->
                            Text(tag.label, fontSize = 13.sp, fontWeight = FontWeight.Medium, color = VineColors.Info,
                                modifier = Modifier.clip(RoundedCornerShape(50)).background(VineColors.Info.copy(alpha = 0.12f)).padding(horizontal = 10.dp, vertical = 6.dp))
                        }
                    }
                }
            }
            if (products.isNotEmpty()) {
                ProgramStepSection("Products & Rates", Icons.Filled.Science) {
                    products.forEach { product ->
                        val stored = SprayProgramStepPresentation.rate(product)
                        val preference = state.savedChemicals.firstOrNull { it.id == product.savedChemicalId }?.vineyardPreferredRate?.takeIf { it.isValid }
                        val rate = stored?.let { "Planned rate: $it" } ?: preference?.let { "${it.text} — preferred vineyard rate" }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(product.name, fontSize = 15.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                            Text(rate ?: "Rate set when planning", fontSize = if (rate == null) 12.sp else 15.sp,
                                fontWeight = if (rate == null) FontWeight.Normal else FontWeight.Medium,
                                color = if (rate == null) vine.textSecondary else VineColors.Olive,
                                textAlign = TextAlign.End, modifier = Modifier.weight(1f))
                        }
                    }
                }
            }
            ProgramStepSection("Application", Icons.Filled.Settings) {
                record.operationType?.takeIf { it.isNotBlank() }?.let { ProgramStepDetailLine("Method", it) }
                stageLabel?.let { ProgramStepDetailLine("Growth stage", if (stage == null) it else "$it — ${stage.description}") }
                equipment?.let { ProgramStepDetailLine("Spray unit", it) }
                tractor?.let { ProgramStepDetailLine("Tractor", it) }
            }
            if (chemistry.isNotEmpty()) {
                ProgramStepSection("Chemical Information", Icons.Filled.Info) {
                    chemistry.forEach { (product, saved) ->
                        if (saved == null) {
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(16.dp))
                                Text("${product.name} is not in your Chemical Store", fontSize = 13.sp, color = VineColors.Warning)
                            }
                        } else {
                            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(saved.name, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary, modifier = Modifier.weight(1f, fill = false))
                                    ChemicalVerificationBadge(saved, compact = true)
                                }
                                val groups = saved.resolvedIntelligence.activityGroups.legacyGroupProjection()
                                if (groups.isNotBlank()) Text(groups, fontSize = 13.sp, color = VineColors.Olive)
                                if (saved.activeIngredient.isNotBlank()) Text(saved.activeIngredient, fontSize = 12.sp, color = vine.textSecondary)
                            }
                        }
                    }
                    Text("Resistance is assessed against the spray you actually plan, in the calculator.", fontSize = 12.sp, color = vine.textSecondary.copy(alpha = 0.75f))
                }
            }
            record.notes?.takeIf { it.isNotBlank() }?.let { notes ->
                ProgramStepSection("Notes", Icons.Filled.Notes) {
                    Text(notes, fontSize = 15.sp, color = vine.textSecondary)
                }
            }
            Text("Blocks, carrier volume and quantities are set when you plan the spray.", fontSize = 12.sp, color = vine.textSecondary.copy(alpha = 0.75f))
        }
    }
    if (confirmDelete && canDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete Program Step") },
            text = { Text("This removes the step from your spray program. Sprays already recorded from it are not affected.") },
            confirmButton = { TextButton(onClick = { confirmDelete = false; onDelete() }) { Text("Delete", color = VineColors.Destructive) } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ProgramStepSection(title: String, icon: ImageVector, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val vine = LocalVineColors.current
    Column(
        modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(vine.cardBackground).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(icon, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
            Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
        }
        content()
    }
}

@Composable
private fun ProgramStepDetailLine(label: String, value: String, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.weight(0.4f))
        Text(value, fontSize = 15.sp, color = vine.textPrimary, textAlign = TextAlign.End, modifier = Modifier.weight(0.6f))
    }
}
