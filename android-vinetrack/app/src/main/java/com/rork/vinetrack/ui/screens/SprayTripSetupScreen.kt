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
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
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
import com.rork.vinetrack.data.model.sprayRecordStatus
import com.rork.vinetrack.data.spray.SprayProgramLanding
import com.rork.vinetrack.data.spray.SprayResumeSection
import com.rork.vinetrack.data.spray.SprayTargetLibrary
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
 * Offers the same two entry points as iOS:
 *  1. Resume a Spray Program — active spray jobs first, then reusable Program
 *     Steps grouped in numeric E-L order.
 *  2. One-off Spray — open the Spray Calculator from scratch.
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
    var showProgramPicker by remember { mutableStateOf(false) }
    var startingRecordId by remember { mutableStateOf<String?>(null) }

    // Local and portal Program Steps share the canonical merge rules. Ordering
    // is applied by the Resume picker using numeric E-L stages, never names.
    val templates = remember(state.sprayRecords, state.sprayJobTemplates) {
        SprayProgramLanding.mergedProgramSteps(state.sprayRecords, state.sprayJobTemplates)
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
                icon = { tint -> Icon(Icons.Filled.Schedule, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp)) },
                title = "Resume a Spray Program",
                subtitle = "Continue an in-progress spray or start from a Program Step",
                tint = VineColors.Indigo,
                enabled = true,
                onClick = { showProgramPicker = true },
            )
            Spacer(Modifier.height(12.dp))
            SprayTripSetupCard(
                icon = { tint -> Icon(Icons.Filled.Calculate, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp)) },
                title = "One-off Spray",
                subtitle = "Open the spray calculator and configure a new job from scratch",
                tint = VineColors.LeafGreen,
                enabled = true,
                onClick = { onOpenCalculator(null) },
            )
            Spacer(Modifier.height(24.dp))
        }
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
                        onOpenCalculator(SprayProgramLanding.calculatorPrefillId(record))
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

/**
 * iOS-parity program chooser: active jobs first, followed by reusable Program
 * Steps grouped under ascending numeric E-L headings. Completed history is not
 * offered as reusable configuration.
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

    var search by remember { mutableStateOf("") }
    val targetLabels = remember(state.sprayTargetLibrary, state.selectedVineyardId) {
        SprayTargetLibrary.labels(state.sprayTargetLibrary, state.selectedVineyardId)
    }
    val sections = remember(records, templates, state.trips, search, targetLabels) {
        SprayProgramLanding.resumeSections(
            localRecords = records,
            portalTemplates = templates,
            trips = state.trips,
            query = search,
            labels = targetLabels,
        )
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp),
        ) {
            item {
                Text("Resume a Spray Program", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text("Search programs") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                )
                Spacer(Modifier.height(12.dp))
            }
            if (sections.isEmpty()) {
                item {
                    Text(
                        if (search.isBlank()) "No in-progress sprays or Program Steps yet." else "No matching spray programs.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                }
            }
            sections.forEach { section ->
                item(key = "section-${section.kind}-${section.stageNumber ?: section.title}") {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 8.dp, bottom = 6.dp)) {
                        Icon(
                            if (section.kind == SprayResumeSection.Kind.IN_PROGRESS) Icons.Filled.PlayCircle else Icons.Filled.ContentCopy,
                            contentDescription = null,
                            tint = vine.textSecondary,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.size(6.dp))
                        Text(
                            section.title.uppercase(Locale.getDefault()),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textSecondary,
                        )
                    }
                }
                items(section.records, key = { "${section.kind}-${section.stageNumber}-${it.id}" }) { record ->
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
