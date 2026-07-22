package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Calculate
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayStatus
import com.rork.vinetrack.data.model.resolveSprayTrip
import com.rork.vinetrack.data.model.sprayOperationTypes
import com.rork.vinetrack.data.model.sprayRecordStatus
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Spray Trip setup chooser — Android port of the iOS `SprayTripSetupSheet`.
 *
 * Offers the same three entry points before anything is created:
 *  1. Start from Template — pick a saved template (local `spray_records`
 *     templates plus read-only portal `spray_jobs` templates, deduped by id)
 *     to pre-fill a new job in the Spray Calculator.
 *  2. Custom Spray Job — open the Spray Calculator from scratch.
 *  3. Resume a Spray Program — pick an existing spray record (grouped by
 *     status like the iOS program picker) and continue it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SprayTripSetupScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onOpenCalculator: (prefillRecordId: String?) -> Unit,
    onOpenTrip: (tripId: String) -> Unit,
) {
    val vine = LocalVineColors.current
    var showTemplatePicker by remember { mutableStateOf(false) }
    var showProgramPicker by remember { mutableStateOf(false) }
    var startingRecordId by remember { mutableStateOf<String?>(null) }

    // Legacy templates in spray_records plus portal templates from spray_jobs,
    // deduped by id — matches the iOS `activeTemplates` merge.
    val templates = remember(state.sprayRecords, state.sprayJobTemplates) {
        val local = state.sprayRecords.filter { it.isTemplate }
        val localIds = local.map { it.id }.toSet()
        (local + state.sprayJobTemplates.filter { it.id !in localIds })
            .sortedBy { it.displayLabel.lowercase() }
    }
    val nonTemplateRecords = remember(state.sprayRecords) {
        state.sprayRecords.filter { !it.isTemplate }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Spray Setup") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(20.dp))
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(
                    Icons.Filled.WaterDrop,
                    contentDescription = null,
                    tint = VineColors.LeafGreen,
                    modifier = Modifier.size(44.dp),
                )
                Spacer(Modifier.height(12.dp))
                Text("Spray Trip Setup", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Spacer(Modifier.height(4.dp))
                Text(
                    "How would you like to set up this spray?",
                    fontSize = 14.sp,
                    color = vine.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }
            Spacer(Modifier.height(24.dp))

            SprayTripSetupCard(
                icon = { tint -> Icon(Icons.Filled.ContentCopy, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp)) },
                title = "Start from Template",
                subtitle = if (templates.isEmpty()) {
                    "No templates available — create one in the Spray Program"
                } else {
                    "Use a saved spray template to pre-fill a new job (${templates.size} available)"
                },
                tint = VineColors.Purple,
                enabled = templates.isNotEmpty(),
                onClick = { showTemplatePicker = true },
            )
            Spacer(Modifier.height(12.dp))
            SprayTripSetupCard(
                icon = { tint -> Icon(Icons.Filled.Calculate, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp)) },
                title = "Custom Spray Job",
                subtitle = "Open the spray calculator and configure a new job from scratch",
                tint = VineColors.LeafGreen,
                enabled = true,
                onClick = { onOpenCalculator(null) },
            )
            if (nonTemplateRecords.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                SprayTripSetupCard(
                    icon = { tint -> Icon(Icons.Filled.Schedule, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp)) },
                    title = "Resume a Spray Program",
                    subtitle = "Continue an in-progress or saved spray record",
                    tint = VineColors.Indigo,
                    enabled = true,
                    onClick = { showProgramPicker = true },
                )
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    if (showTemplatePicker) {
        SprayTemplatePickerSheet(
            templates = templates,
            onDismiss = { showTemplatePicker = false },
            onSelect = { template ->
                showTemplatePicker = false
                onOpenCalculator(template.id)
            },
        )
    }

    if (showProgramPicker) {
        SprayProgramPickerSheet(
            state = state,
            templates = templates,
            records = nonTemplateRecords,
            startingRecordId = startingRecordId,
            onDismiss = { if (startingRecordId == null) showProgramPicker = false },
            onSelect = { record ->
                when {
                    record.isTemplate -> {
                        showProgramPicker = false
                        onOpenCalculator(record.id)
                    }
                    else -> when (sprayRecordStatus(record, state.trips)) {
                        SprayStatus.IN_PROGRESS -> {
                            showProgramPicker = false
                            record.tripId?.let(onOpenTrip)
                        }
                        SprayStatus.NOT_STARTED -> {
                            val tripId = record.tripId
                            if (tripId == null) {
                                showProgramPicker = false
                                onOpenCalculator(record.id)
                            } else if (startingRecordId == null) {
                                startingRecordId = record.id
                                vm.startSprayJob(tripId) { ok ->
                                    startingRecordId = null
                                    showProgramPicker = false
                                    if (ok) onOpenTrip(tripId)
                                }
                            }
                        }
                        // Completed jobs are re-run as a fresh job pre-filled
                        // from the record (same mix, new trip).
                        SprayStatus.COMPLETED -> {
                            showProgramPicker = false
                            onOpenCalculator(record.id)
                        }
                    }
                }
            },
        )
    }
}

@Composable
private fun SprayTripSetupCard(
    icon: @Composable (Color) -> Unit,
    title: String,
    subtitle: String,
    tint: Color,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val effectiveTint = if (enabled) tint else vine.textSecondary
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .then(if (enabled) Modifier.clickable { onClick() } else Modifier)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(effectiveTint.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            icon(effectiveTint)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                title,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (enabled) vine.textPrimary else vine.textSecondary,
            )
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = vine.textSecondary,
            modifier = Modifier.size(20.dp),
        )
    }
}

/** Template chooser, grouped by operation type like the iOS `SprayTemplatePickerSheet`. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayTemplatePickerSheet(
    templates: List<SprayRecord>,
    onDismiss: () -> Unit,
    onSelect: (SprayRecord) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val grouped = remember(templates) {
        val byType = templates.groupBy { it.operationType?.takeIf { t -> t.isNotBlank() } ?: "Other" }
        val ordered = sprayOperationTypes.filter { byType.containsKey(it) }
        (ordered + byType.keys.filter { it !in ordered }).map { it to byType.getValue(it) }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp),
        ) {
            item {
                Text("Choose a Template", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Spacer(Modifier.height(4.dp))
                Text(
                    "Selecting a template pre-fills a new spray job. The original template is not changed.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                Spacer(Modifier.height(12.dp))
            }
            grouped.forEach { (type, items) ->
                item(key = "header-$type") {
                    Text(
                        type.uppercase(Locale.getDefault()),
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textSecondary,
                        modifier = Modifier.padding(top = 8.dp, bottom = 6.dp),
                    )
                }
                items(items, key = { "tmpl-${it.id}" }) { template ->
                    SprayPickerRecordRow(
                        record = template,
                        subtitleOverride = null,
                        trailing = null,
                        onClick = { onSelect(template) },
                    )
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

/**
 * Existing spray program chooser — sections mirror the iOS
 * `SprayTripProgramPickerSheet`: Templates, In Progress, Not Started, Completed.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayProgramPickerSheet(
    state: AppUiState,
    templates: List<SprayRecord>,
    records: List<SprayRecord>,
    startingRecordId: String?,
    onDismiss: () -> Unit,
    onSelect: (SprayRecord) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    val linked = remember(records, state.trips) {
        records.filter { resolveSprayTrip(it, state.trips) != null }
            .sortedByDescending { it.dateEpochMs ?: 0L }
    }
    val inProgress = remember(linked, state.trips) { linked.filter { sprayRecordStatus(it, state.trips) == SprayStatus.IN_PROGRESS } }
    val notStarted = remember(linked, state.trips) { linked.filter { sprayRecordStatus(it, state.trips) == SprayStatus.NOT_STARTED } }
    val completed = remember(linked, state.trips) { linked.filter { sprayRecordStatus(it, state.trips) == SprayStatus.COMPLETED } }

    val sections: List<Triple<String, androidx.compose.ui.graphics.vector.ImageVector, List<SprayRecord>>> = listOf(
        Triple("Templates", Icons.Filled.ContentCopy, templates),
        Triple("In Progress", Icons.Filled.PlayCircle, inProgress),
        Triple("Not Started", Icons.Filled.Schedule, notStarted),
        Triple("Completed", Icons.Filled.CheckCircle, completed),
    ).filter { it.third.isNotEmpty() }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp),
        ) {
            item {
                Text("Spray Program", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Spacer(Modifier.height(12.dp))
            }
            if (sections.isEmpty()) {
                item {
                    Text(
                        "No spray programs yet. Create spray records first, then select them here.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                }
            }
            sections.forEach { (title, icon, items) ->
                item(key = "section-$title") {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp, bottom = 6.dp)) {
                        Icon(icon, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.size(6.dp))
                        Text(
                            title.uppercase(Locale.getDefault()),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textSecondary,
                        )
                    }
                }
                items(items, key = { "$title-${it.id}" }) { record ->
                    val paddockName = resolveSprayTrip(record, state.trips)?.paddockName
                    SprayPickerRecordRow(
                        record = record,
                        subtitleOverride = paddockName,
                        trailing = if (startingRecordId == record.id) {
                            { CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = VineColors.DarkGreen) }
                        } else null,
                        onClick = { onSelect(record) },
                    )
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

/** Shared picker row: name, date, block, chemicals and tank/equipment meta. */
@Composable
private fun SprayPickerRecordRow(
    record: SprayRecord,
    subtitleOverride: String?,
    trailing: (@Composable () -> Unit)?,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    val dateLabel = remember(record.dateEpochMs) {
        record.dateEpochMs?.let { SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(it)) }
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .clickable { onClick() }
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (record.isTemplate) {
            Icon(Icons.Filled.ContentCopy, contentDescription = null, tint = VineColors.Purple, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(record.displayLabel, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            if (!record.isTemplate && dateLabel != null) {
                Text(dateLabel, fontSize = 12.sp, color = vine.textSecondary)
            }
            subtitleOverride?.takeIf { it.isNotBlank() }?.let {
                Text(it, fontSize = 12.sp, color = VineColors.Olive)
            }
            val chems = record.chemicalNames.joinToString(", ")
            if (chems.isNotEmpty()) {
                Text(chems, fontSize = 12.sp, color = vine.textSecondary, maxLines = 1)
            }
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                "${record.tankCount} tank${if (record.tankCount == 1) "" else "s"}",
                fontSize = 11.sp,
                color = vine.textSecondary,
            )
            record.equipmentType?.takeIf { it.isNotBlank() }?.let {
                Text(it, fontSize = 11.sp, color = vine.textSecondary)
            }
        }
        if (trailing != null) {
            trailing()
        } else {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = vine.textSecondary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}
