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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import com.rork.vinetrack.data.AndroidInstallationIdentity
import com.rork.vinetrack.data.PinLocationResult
import com.rork.vinetrack.data.QualifiedLocationFix
import com.rork.vinetrack.data.mapalignment.AndroidDisplayCoordinate
import com.rork.vinetrack.data.mapalignment.CanonicalCoordinate
import com.rork.vinetrack.data.mapalignment.MapAlignmentCaptureQuality
import com.rork.vinetrack.data.mapalignment.MapAlignmentDraft
import com.rork.vinetrack.data.mapalignment.MapAlignmentReferencePoint
import com.rork.vinetrack.data.mapalignment.MapAlignmentReferenceType
import com.rork.vinetrack.data.mapalignment.MapAlignmentScope
import com.rork.vinetrack.data.mapalignment.MapAlignmentSolver
import com.rork.vinetrack.data.mapalignment.MapAlignmentWizardStep
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Vineyard
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.util.Locale
import java.util.UUID

/**
 * System Admin onsite calibration wizard for Android Map Alignment.
 *
 * ## What this phase does, and deliberately does not do
 *
 * It lets a System Admin walk the vineyard, record well-separated reference
 * points, derive a candidate translation and inspect it in a PRIVATE
 * before/after preview. That is all.
 *
 * * **No production map is aligned.** No vineyard or block map consults the
 *   candidate. The only thing it affects is the preview inside this screen.
 * * **Nothing is persisted.** The draft is session memory only — no SQL,
 *   Supabase table, RPC, RLS, API endpoint, sync entity, SharedPreferences or
 *   local database write exists for it. Leaving the wizard discards it.
 * * **No canonical coordinate is altered.** Capture only ever creates new
 *   reference points. Vineyard coordinates, block boundaries, rows, pins,
 *   routes and raw GPS fixes are read-only here.
 *
 * ## GPS
 *
 * Capture reuses the existing location pipeline
 * (`AppViewModel.fetchCurrentFix` -> `LocationTracker` ->
 * `PinLocationFixValidator`). No competing location manager, request or
 * subscription is created. [MapAlignmentCaptureQuality] then applies a stricter
 * wizard-only accuracy rule on top of that unchanged production result.
 */
@Composable
fun MapAlignmentWizard(
    state: AppUiState,
    onRequestFix: (onResult: (PinLocationResult) -> Unit) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val installationId = remember { AndroidInstallationIdentity.current(context) }

    var step by remember { mutableStateOf(MapAlignmentWizardStep.Scope) }
    var draft by remember { mutableStateOf<MapAlignmentDraft?>(null) }

    val current = draft
    when {
        step == MapAlignmentWizardStep.Scope || current == null -> ScopeStep(
            state = state,
            installationId = installationId,
            modifier = modifier,
            onScopeChosen = {
                draft = it
                step = MapAlignmentWizardStep.Introduction
            },
        )

        step == MapAlignmentWizardStep.Introduction -> IntroductionStep(
            draft = current,
            modifier = modifier,
            onStart = { step = MapAlignmentWizardStep.Capture },
            onCancel = {
                // Discarding the wizard discards the candidate. Intentional.
                draft = null
                step = MapAlignmentWizardStep.Scope
            },
        )

        step == MapAlignmentWizardStep.Capture -> MapAlignmentCaptureStep(
            state = state,
            draft = current,
            onRequestFix = onRequestFix,
            modifier = modifier,
            onDraftChanged = { draft = it },
            onCalculate = {
                draft = current.solved(
                    alignmentId = "draft-${UUID.randomUUID()}",
                    nowEpochMillis = System.currentTimeMillis(),
                )
                step = MapAlignmentWizardStep.Review
            },
            onBackToIntro = { step = MapAlignmentWizardStep.Introduction },
        )

        else -> MapAlignmentReviewStep(
            state = state,
            draft = current,
            modifier = modifier,
            onCaptureMore = { step = MapAlignmentWizardStep.Capture },
            onDiscard = {
                draft = null
                step = MapAlignmentWizardStep.Scope
            },
        )
    }
}

// ---------------------------------------------------------------------------
// Step 1 — scope selection
// ---------------------------------------------------------------------------

@Composable
private fun ScopeStep(
    state: AppUiState,
    installationId: String,
    modifier: Modifier,
    onScopeChosen: (MapAlignmentDraft) -> Unit,
) {
    var vineyardId by remember { mutableStateOf(state.selectedVineyardId) }
    var blockId by remember { mutableStateOf<String?>(null) }

    val vineyard: Vineyard? = state.vineyards.firstOrNull { it.id == vineyardId }
    val blocks: List<Paddock> = remember(state.paddocks, vineyardId) {
        state.paddocks.filter { it.vineyardId == vineyardId }
    }
    val block: Paddock? = blocks.firstOrNull { it.id == blockId }

    WizardScaffold(modifier = modifier) {
        SystemAdminPreviewBadge()

        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionTitle("Vineyard")
                Text(
                    "Choose the vineyard whose Android satellite imagery you are aligning.",
                    fontSize = 13.sp,
                    color = LocalVineColors.current.textSecondary,
                )
                if (state.vineyards.isEmpty()) {
                    Text(
                        "No vineyards are loaded on this device.",
                        fontSize = 14.sp,
                        color = LocalVineColors.current.textSecondary,
                    )
                }
                state.vineyards.forEach { candidate ->
                    SelectableRow(
                        label = candidate.name,
                        selected = candidate.id == vineyardId,
                        onClick = {
                            vineyardId = candidate.id
                            blockId = null
                        },
                    )
                }
            }
        }

        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionTitle("Calibration level")
                SelectableRow(
                    label = "Whole vineyard",
                    detail = "The normal choice. Corrects the imagery across this vineyard.",
                    selected = blockId == null,
                    onClick = { blockId = null },
                )
                Text(
                    "Specific block — override-level calibration",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    color = VineColors.Orange,
                )
                Text(
                    "A block calibration is an OVERRIDE. It replaces the whole-vineyard " +
                        "alignment for that block only, and is needed just when one block's " +
                        "imagery is offset differently from the rest of the vineyard.",
                    fontSize = 12.sp,
                    color = LocalVineColors.current.textSecondary,
                )
                when {
                    vineyardId == null -> Unit
                    blocks.isEmpty() -> Text(
                        "No blocks are loaded for this vineyard on this device. Open the " +
                            "vineyard first if you need a block-level calibration.",
                        fontSize = 12.sp,
                        color = LocalVineColors.current.textSecondary,
                    )
                    else -> blocks.forEach { candidate ->
                        SelectableRow(
                            label = candidate.name,
                            detail = if (candidate.hasGeometry) null else "No mapped boundary",
                            selected = candidate.id == blockId,
                            onClick = { blockId = candidate.id },
                        )
                    }
                }
            }
        }

        Button(
            onClick = {
                val chosen = vineyard ?: return@Button
                onScopeChosen(
                    MapAlignmentDraft(
                        scope = MapAlignmentScope(
                            androidInstallationId = installationId,
                            vineyardId = chosen.id,
                            blockId = blockId,
                        ),
                        vineyardName = chosen.name,
                        blockName = block?.name,
                    ),
                )
            },
            enabled = vineyard != null,
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Continue") }

        InstallationScopeNote(installationId)
    }
}

// ---------------------------------------------------------------------------
// Step 2 — introduction
// ---------------------------------------------------------------------------

@Composable
private fun IntroductionStep(
    draft: MapAlignmentDraft,
    modifier: Modifier,
    onStart: () -> Unit,
    onCancel: () -> Unit,
) {
    val vine = LocalVineColors.current
    WizardScaffold(modifier = modifier) {
        SystemAdminPreviewBadge()

        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "Align this Android map",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
                ScopeSummary(draft)
                Text(
                    "Android satellite imagery can sometimes appear slightly offset from " +
                        "your actual GPS position.",
                    fontSize = 14.sp,
                    color = vine.textSecondary,
                )
                Text(
                    "You'll record at least ${MapAlignmentSolver.MIN_POINTS} well-separated " +
                        "reference points around the vineyard.",
                    fontSize = 14.sp,
                    color = vine.textSecondary,
                )
                Text(
                    "At each point:",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = vine.textPrimary,
                )
                NumberedStep(1, "Stand at a location you can clearly identify, such as a boundary corner, row end, post or gate.")
                NumberedStep(2, "Allow VineTrack to record your GPS position.")
                NumberedStep(3, "Mark that same physical point on the satellite image.")
                Text(
                    "VineTrack will use these reference points to calculate the map alignment.",
                    fontSize = 14.sp,
                    color = vine.textSecondary,
                )
                Text(
                    "Your saved GPS coordinates will not be changed.",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
            }
        }

        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                SectionTitle("Accuracy needed")
                Text(
                    "Alignment needs a fix of ±${MapAlignmentCaptureQuality.MAX_ACCURACY_METRES.toInt()} m " +
                        "or better — stricter than normal pin dropping. The offset being measured " +
                        "may itself be only a few metres, so a poor fix could be larger than the " +
                        "discrepancy it is meant to measure.",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                )
            }
        }

        Button(onClick = onStart, modifier = Modifier.fillMaxWidth()) { Text("Start alignment") }
        OutlinedButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
        DraftOnlyNote()
    }
}

// ---------------------------------------------------------------------------
// Step 3 — capture
// ---------------------------------------------------------------------------

@Composable
private fun MapAlignmentCaptureStep(
    state: AppUiState,
    draft: MapAlignmentDraft,
    onRequestFix: (onResult: (PinLocationResult) -> Unit) -> Unit,
    modifier: Modifier,
    onDraftChanged: (MapAlignmentDraft) -> Unit,
    onCalculate: () -> Unit,
    onBackToIntro: () -> Unit,
) {
    val vine = LocalVineColors.current
    var pendingFix by remember { mutableStateOf<QualifiedLocationFix?>(null) }
    var pendingTap by remember { mutableStateOf<AndroidDisplayCoordinate?>(null) }
    var status by remember { mutableStateOf<String?>(null) }
    var isRecording by remember { mutableStateOf(false) }
    var referenceType by remember { mutableStateOf<MapAlignmentReferenceType?>(null) }

    val readiness = draft.readiness

    WizardScaffold(modifier = modifier) {
        SystemAdminPreviewBadge()
        ScopeSummary(draft)

        // --- The map: canonical geometry, and the operator's taps ---
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionTitle("Mark the point on the satellite image")
                Text(
                    if (pendingFix == null) {
                        "Record your GPS position first."
                    } else {
                        "Now tap the satellite image at the SAME physical place you are standing."
                    },
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(320.dp)
                        .clip(RoundedCornerShape(12.dp)),
                ) {
                    MapAlignmentCaptureMap(
                        state = state,
                        draft = draft,
                        pendingTap = pendingTap,
                        tapEnabled = pendingFix != null,
                        onTap = { pendingTap = it },
                    )
                }
            }
        }

        // --- Capture controls ---
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionTitle("Reference point ${draft.pointCount + 1}")

                PendingFixRow(pendingFix)

                Button(
                    onClick = {
                        isRecording = true
                        status = null
                        onRequestFix { production ->
                            isRecording = false
                            // Existing production pipeline first, then the
                            // stricter wizard-only gate on top of its result.
                            when (val quality = MapAlignmentCaptureQuality.evaluate(production)) {
                                is MapAlignmentCaptureQuality.Result.Accepted -> {
                                    pendingFix = quality.fix
                                    pendingTap = null
                                    status = quality.operatorMessage()
                                }
                                else -> {
                                    pendingFix = null
                                    status = quality.operatorMessage()
                                }
                            }
                        }
                    },
                    enabled = !isRecording,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (isRecording) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp,
                            color = Color.White,
                        )
                        Spacer(Modifier.size(8.dp))
                        Text("Recording GPS…")
                    } else {
                        Icon(Icons.Filled.GpsFixed, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text(if (pendingFix == null) "Record my GPS position" else "Record again")
                    }
                }

                status?.let {
                    Text(it, fontSize = 13.sp, color = vine.textSecondary)
                }

                ReferenceTypeChips(referenceType) { referenceType = it }

                Button(
                    onClick = {
                        val fix = pendingFix ?: return@Button
                        val tap = pendingTap ?: return@Button
                        val point = MapAlignmentReferencePoint(
                            id = UUID.randomUUID().toString(),
                            scope = draft.scope,
                            // Canonical truth, straight from the existing pipeline.
                            canonicalCoordinate = CanonicalCoordinate(fix.latitude, fix.longitude),
                            // Display space: where the operator had to tap for it
                            // to LOOK like the same place. Never stored as truth.
                            selectedMapCoordinate = tap,
                            gpsAccuracyMetres = fix.accuracyMetres,
                            capturedAtEpochMillis = fix.fixTimeEpochMs,
                            referenceType = referenceType,
                        )
                        onDraftChanged(draft.withReferencePoint(point))
                        pendingFix = null
                        pendingTap = null
                        referenceType = null
                        status = "Reference point added."
                    },
                    enabled = pendingFix != null && pendingTap != null,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.TouchApp, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("Add reference point")
                }
            }
        }

        // --- Progress and collected evidence ---
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionTitle("Reference points (${draft.pointCount})")
                Text(
                    readiness.operatorMessage(),
                    fontSize = 13.sp,
                    color = if (readiness.isReady) VineColors.Orange else vine.textSecondary,
                )
                if (draft.referencePoints.isEmpty()) {
                    Text(
                        "None recorded yet.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                }
                draft.referencePoints.forEachIndexed { index, point ->
                    CapturedPointRow(
                        index = index + 1,
                        point = point,
                        onRemove = { onDraftChanged(draft.withoutReferencePoint(point.id)) },
                    )
                }
            }
        }

        Button(
            onClick = onCalculate,
            enabled = readiness.isReady,
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Calculate alignment") }

        OutlinedButton(onClick = onBackToIntro, modifier = Modifier.fillMaxWidth()) {
            Text("Back to instructions")
        }
        CanonicalInvariantNote()
        DraftOnlyNote()
    }
}

@Composable
private fun PendingFixRow(fix: QualifiedLocationFix?) {
    val vine = LocalVineColors.current
    if (fix == null) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Filled.MyLocation,
                contentDescription = null,
                tint = vine.textSecondary,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.size(8.dp))
            Text("No GPS position recorded yet.", fontSize = 13.sp, color = vine.textSecondary)
        }
        return
    }
    val comfortable = MapAlignmentCaptureQuality.isComfortable(fix.accuracyMetres)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            Icons.Filled.CheckCircle,
            contentDescription = null,
            tint = if (comfortable) VineColors.Orange else vine.textSecondary,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.size(8.dp))
        Column {
            Text(
                "GPS recorded — ±${metres(fix.accuracyMetres)} m",
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = vine.textPrimary,
            )
            if (!comfortable) {
                Text(
                    "Waiting a moment for ±${MapAlignmentCaptureQuality.GOOD_ACCURACY_METRES.toInt()} m " +
                        "or better will give a stronger alignment.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun ReferenceTypeChips(
    selected: MapAlignmentReferenceType?,
    onSelect: (MapAlignmentReferenceType?) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            "What is this point? (optional)",
            fontSize = 12.sp,
            color = LocalVineColors.current.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf(
                MapAlignmentReferenceType.BlockCorner to "Corner",
                MapAlignmentReferenceType.RowEnd to "Row end",
                MapAlignmentReferenceType.Infrastructure to "Post/gate",
            ).forEach { (type, label) ->
                FilterChip(
                    selected = selected == type,
                    onClick = { onSelect(if (selected == type) null else type) },
                    label = { Text(label, fontSize = 12.sp) },
                    colors = FilterChipDefaults.filterChipColors(),
                )
            }
        }
    }
}

@Composable
private fun CapturedPointRow(
    index: Int,
    point: MapAlignmentReferencePoint,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                "Point $index — ${offsetDescription(point.observedOffset.eastMetres, point.observedOffset.northMetres)}",
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = vine.textPrimary,
            )
            Text(
                buildString {
                    append("±${metres(point.gpsAccuracyMetres ?: 0.0)} m")
                    point.referenceType?.let { append(" · ${it.name}") }
                },
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
        }
        TextButton(onClick = onRemove) {
            Icon(Icons.Filled.Delete, contentDescription = "Remove point", modifier = Modifier.size(16.dp))
        }
    }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

@Composable
internal fun WizardScaffold(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) { content() }
}

@Composable
internal fun SystemAdminPreviewBadge() {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .background(VineColors.Orange.copy(alpha = 0.16f))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Filled.Info,
            contentDescription = null,
            tint = VineColors.Orange,
            modifier = Modifier.size(14.dp),
        )
        Spacer(Modifier.size(6.dp))
        Text(
            "System Admin Preview — not released",
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = VineColors.Orange,
        )
    }
}

@Composable
internal fun SectionTitle(text: String) {
    Text(
        text,
        fontSize = 15.sp,
        fontWeight = FontWeight.SemiBold,
        color = LocalVineColors.current.textPrimary,
    )
}

@Composable
internal fun ScopeSummary(draft: MapAlignmentDraft) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            draft.vineyardName,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = vine.textPrimary,
        )
        Text(
            if (draft.isBlockOverride) {
                "Block override — ${draft.blockName ?: draft.scope.blockId}"
            } else {
                "Whole vineyard"
            },
            fontSize = 12.sp,
            color = if (draft.isBlockOverride) VineColors.Orange else vine.textSecondary,
        )
    }
}

@Composable
private fun NumberedStep(number: Int, text: String) {
    val vine = LocalVineColors.current
    Row {
        Text(
            "$number.",
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = vine.textPrimary,
            modifier = Modifier.width(20.dp),
        )
        Text(text, fontSize = 14.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun SelectableRow(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    detail: String? = null,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(if (selected) VineColors.Orange.copy(alpha = 0.14f) else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                label,
                fontSize = 14.sp,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                color = vine.textPrimary,
            )
            detail?.let { Text(it, fontSize = 12.sp, color = vine.textSecondary) }
        }
        if (selected) {
            Icon(
                Icons.Filled.CheckCircle,
                contentDescription = null,
                tint = VineColors.Orange,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

/** States the invariant this whole feature is built around. */
@Composable
internal fun CanonicalInvariantNote() {
    val vine = LocalVineColors.current
    Text(
        "Your saved GPS coordinates are not changed. Alignment only affects how the " +
            "Android satellite map is drawn.",
        fontSize = 12.sp,
        color = vine.textSecondary,
    )
}

/** States, in the UI, that this phase intentionally keeps nothing. */
@Composable
internal fun DraftOnlyNote() {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(vine.cardBackground)
            .padding(10.dp),
    ) {
        Icon(
            Icons.Filled.Warning,
            contentDescription = null,
            tint = VineColors.Orange,
            modifier = Modifier.size(14.dp),
        )
        Spacer(Modifier.size(8.dp))
        Text(
            "Field-test draft. This calibration is not saved and is discarded when you " +
                "leave or close the app. It is not applied to any vineyard or block map.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun InstallationScopeNote(installationId: String) {
    Text(
        "This alignment applies to THIS Android installation only " +
            "(${installationId.take(8)}…). It never becomes a vineyard-wide correction, " +
            "and never reaches iOS or the Portal.",
        fontSize = 12.sp,
        color = LocalVineColors.current.textSecondary,
    )
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

internal fun metres(value: Double): String =
    if (value >= 10.0) value.toInt().toString() else String.format(Locale.US, "%.1f", value)

/** Plain-language east/north description, e.g. "12 m east, 4 m south". */
internal fun offsetDescription(eastMetres: Double, northMetres: Double): String {
    val ew = if (eastMetres >= 0) "east" else "west"
    val ns = if (northMetres >= 0) "north" else "south"
    return "${metres(kotlin.math.abs(eastMetres))} m $ew, " +
        "${metres(kotlin.math.abs(northMetres))} m $ns"
}
