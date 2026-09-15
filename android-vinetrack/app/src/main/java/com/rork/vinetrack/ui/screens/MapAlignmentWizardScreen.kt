package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
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
import android.os.SystemClock
import com.rork.vinetrack.data.AndroidInstallationIdentity
import com.rork.vinetrack.data.PinLocationResult
import com.rork.vinetrack.data.mapalignment.AndroidDisplayCoordinate
import com.rork.vinetrack.data.mapalignment.CanonicalCoordinate
import com.rork.vinetrack.data.mapalignment.MapAlignmentDraft
import com.rork.vinetrack.data.mapalignment.MapAlignmentExitGuard
import com.rork.vinetrack.data.mapalignment.MapAlignmentGpsEvidence
import com.rork.vinetrack.data.mapalignment.MapAlignmentGpsRules
import com.rork.vinetrack.data.mapalignment.MapAlignmentGpsSampling
import com.rork.vinetrack.data.mapalignment.MapAlignmentLiveGpsSession
import com.rork.vinetrack.data.mapalignment.MapAlignmentLiveUpdateDiagnostic
import com.rork.vinetrack.data.mapalignment.MapAlignmentReferencePoint
import com.rork.vinetrack.data.mapalignment.MapAlignmentReferenceType
import com.rork.vinetrack.data.mapalignment.MapAlignmentRowPosition
import com.rork.vinetrack.data.mapalignment.MapAlignmentScope
import com.rork.vinetrack.data.mapalignment.MapAlignmentSolver
import com.rork.vinetrack.data.mapalignment.MapAlignmentWizardStep
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Vineyard
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.delay
import java.util.Locale
import java.util.UUID

/**
 * System Admin onsite calibration wizard for Android Map Alignment.
 *
 * ## What this phase does, and deliberately does not do
 *
 * It lets a System Admin walk the vineyard, record reference points, derive a
 * candidate translation and inspect it in a PRIVATE before/after preview. That
 * is all.
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
 * Capture reuses the existing live foreground location mechanism
 * (`LocationTracker.startPinFixUpdates` -> `PinLocationFixValidator`), opened
 * as exactly ONE subscription per sampling attempt and closed the moment the
 * attempt ends. [MapAlignmentGpsSampling] then requires several unique,
 * agreeing fixes before a reference may be created, because a single fix is not
 * sufficient evidence for a measurement of this size.
 *
 * A live subscription rather than repeated one-shot requests: the one-shot pin
 * API may legitimately return its cached fix while it is still fresh, so
 * polling it re-delivered ONE observation and sampling stalled at `1 of 5` in
 * the field. Production admission rules are untouched — this layer only ever
 * narrows them.
 */
@Composable
fun MapAlignmentWizard(
    state: AppUiState,
    onStartFixUpdates: (onFix: (PinLocationResult) -> Unit) -> Unit,
    onStopFixUpdates: () -> Unit,
    modifier: Modifier = Modifier,
    exitGuard: MapAlignmentExitGuard = remember { MapAlignmentExitGuard() },
) {
    val context = LocalContext.current
    val installationId = remember { AndroidInstallationIdentity.current(context) }

    var step by remember { mutableStateOf(MapAlignmentWizardStep.Scope) }
    var draft by remember { mutableStateOf<MapAlignmentDraft?>(null) }

    // Keep the shared guard in step with the session draft, so the host's
    // toolbar Back and system Back protect exactly the same evidence as the
    // wizard's own Cancel and Discard actions.
    LaunchedEffect(draft?.referencePoints?.size) { exitGuard.onDraftChanged(draft) }

    /** Route a discard through confirmation whenever evidence would be lost. */
    fun requestDiscard(andThen: () -> Unit) {
        exitGuard.requestExit(andThen)
    }

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
                requestDiscard {
                    draft = null
                    step = MapAlignmentWizardStep.Scope
                }
            },
        )

        step == MapAlignmentWizardStep.Capture -> MapAlignmentCaptureStep(
            state = state,
            draft = current,
            onStartFixUpdates = onStartFixUpdates,
            onStopFixUpdates = onStopFixUpdates,
            modifier = modifier,
            onDraftChanged = { draft = it },
            onCalculate = {
                draft = current.solved(
                    alignmentId = "draft-${UUID.randomUUID()}",
                    nowEpochMillis = System.currentTimeMillis(),
                )
                step = MapAlignmentWizardStep.Review
            },
            onExit = {
                requestDiscard {
                    draft = null
                    step = MapAlignmentWizardStep.Scope
                }
            },
        )

        step == MapAlignmentWizardStep.Review -> MapAlignmentReviewStep(
            state = state,
            draft = current,
            modifier = modifier,
            onCaptureMore = { step = MapAlignmentWizardStep.Capture },
            onFinish = { step = MapAlignmentWizardStep.Complete },
            onDiscard = {
                requestDiscard {
                    draft = null
                    step = MapAlignmentWizardStep.Scope
                }
            },
        )

        else -> CompletionStep(
            modifier = modifier,
            onViewAgain = { step = MapAlignmentWizardStep.Review },
            onDiscardAndFinish = {
                // Explicit discard: the operator has already been told, on this
                // very screen, that nothing was saved. No second prompt.
                draft = null
                step = MapAlignmentWizardStep.Scope
            },
        )
    }

    if (exitGuard.isConfirmingDiscard) {
        DiscardCalibrationDialog(
            onKeep = exitGuard::keepCalibrating,
            onDiscard = exitGuard::discard,
        )
    }
}

/**
 * Confirmation shown before collected references are thrown away.
 *
 * Reference points cost real walking, so Back or Cancel must never silently
 * drop them. The wording also settles the operator's obvious worry — that
 * leaving might have changed vineyard data.
 */
@Composable
internal fun DiscardCalibrationDialog(onKeep: () -> Unit, onDiscard: () -> Unit) {
    AlertDialog(
        onDismissRequest = onKeep,
        title = { Text("Discard calibration?") },
        text = {
            Text(
                "This calibration has not been saved. Leaving now will discard the " +
                    "reference points collected in this session.\n\nNo vineyard data will " +
                    "be changed.",
                fontSize = 14.sp,
            )
        },
        confirmButton = { TextButton(onClick = onKeep) { Text("Keep calibrating") } },
        dismissButton = { TextButton(onClick = onDiscard) { Text("Discard") } },
    )
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
                    "You'll record at least ${MapAlignmentSolver.MIN_POINTS} reference points. " +
                        MapAlignmentSolver.SPREAD_ADVICE,
                    fontSize = 14.sp,
                    color = vine.textSecondary,
                )
                Text(
                    "At each point:",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = vine.textPrimary,
                )
                NumberedStep(
                    1,
                    "Stand at a location you can clearly identify, such as a boundary " +
                        "corner, row end, post or gate.",
                )
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
                SectionTitle("How the GPS reading is taken")
                Text(
                    "At each point VineTrack collects at least " +
                        "${MapAlignmentGpsRules.MIN_SAMPLES} separate GPS readings over about " +
                        "${MapAlignmentGpsRules.MIN_SAMPLING_MILLIS / 1000} seconds and uses " +
                        "the middle of them. Stand still while it does.",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                )
                Text(
                    "One single reading is not enough. The offset being measured may itself " +
                        "be only a few metres, so a single reading could be as large as the " +
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

/** What the capture step is currently doing. */
private sealed interface CaptureMode {
    /** Showing the collected references. */
    data object Overview : CaptureMode

    /** Running the multi-sample GPS process. [editingId] is set when retaking. */
    data class Sampling(val editingId: String?) : CaptureMode

    /** Marking the imagery with the crosshair. */
    data class Marking(
        val editingId: String?,
        val gps: CanonicalCoordinate,
        val evidence: MapAlignmentGpsEvidence?,
        val capturedAtEpochMillis: Long,
        /** Set when only the image point is being replaced. */
        val existingMark: AndroidDisplayCoordinate? = null,
        /** True when the canonical GPS evidence must be preserved as-is. */
        val remarkOnly: Boolean = false,
    ) : CaptureMode
}

@Composable
private fun MapAlignmentCaptureStep(
    state: AppUiState,
    draft: MapAlignmentDraft,
    onStartFixUpdates: (onFix: (PinLocationResult) -> Unit) -> Unit,
    onStopFixUpdates: () -> Unit,
    modifier: Modifier,
    onDraftChanged: (MapAlignmentDraft) -> Unit,
    onCalculate: () -> Unit,
    onExit: () -> Unit,
) {
    var mode by remember { mutableStateOf<CaptureMode>(CaptureMode.Overview) }

    when (val currentMode = mode) {
        is CaptureMode.Sampling -> GpsSamplingStep(
            draft = draft,
            editingId = currentMode.editingId,
            onStartFixUpdates = onStartFixUpdates,
            onStopFixUpdates = onStopFixUpdates,
            modifier = modifier,
            onCancel = { mode = CaptureMode.Overview },
            onStable = { coordinate, evidence, capturedAt ->
                val editing = currentMode.editingId
                if (editing != null) {
                    // A retake obeys the same near-duplicate rule as a new
                    // point. Excluding its own id is what stops the reference
                    // colliding with the position it is replacing.
                    if (draft.isNearDuplicate(coordinate, excludingId = editing)) {
                        // Rejected: the original reference is left untouched
                        // and the operator stays here to retry or cancel.
                        false
                    } else {
                        // Retake: keep the marked image point, replace the GPS.
                        onDraftChanged(
                            draft.withRetakenGps(
                                pointId = editing,
                                canonicalCoordinate = coordinate,
                                gpsAccuracyMetres = evidence?.representativeAccuracyMetres,
                                gpsEvidence = evidence,
                                capturedAtEpochMillis = capturedAt,
                            ),
                        )
                        mode = CaptureMode.Overview
                        true
                    }
                } else {
                    mode = CaptureMode.Marking(
                        editingId = null,
                        gps = coordinate,
                        evidence = evidence,
                        capturedAtEpochMillis = capturedAt,
                    )
                    true
                }
            },
        )

        is CaptureMode.Marking -> MarkOnImageStep(
            state = state,
            draft = draft,
            mode = currentMode,
            modifier = modifier,
            onCancel = { mode = CaptureMode.Overview },
            onConfirmed = { updated ->
                onDraftChanged(updated)
                mode = CaptureMode.Overview
            },
        )

        CaptureMode.Overview -> CaptureOverviewStep(
            state = state,
            draft = draft,
            modifier = modifier,
            onDraftChanged = onDraftChanged,
            onStartNewPoint = { mode = CaptureMode.Sampling(editingId = null) },
            onRetakeGps = { mode = CaptureMode.Sampling(editingId = it.id) },
            onRemark = { point ->
                mode = CaptureMode.Marking(
                    editingId = point.id,
                    gps = point.canonicalCoordinate,
                    evidence = point.gpsEvidence,
                    capturedAtEpochMillis = point.capturedAtEpochMillis,
                    existingMark = point.selectedMapCoordinate,
                    remarkOnly = true,
                )
            },
            onCalculate = onCalculate,
            onExit = onExit,
        )
    }
}

// --- 3a. Multi-sample GPS ---------------------------------------------------

/**
 * Collects several unique, agreeing GPS fixes for one reference point.
 *
 * Opens exactly ONE live subscription per attempt through the existing
 * `LocationTracker.startPinFixUpdates` mechanism, so the receiver delivers
 * genuinely independent observations of the stationary point. Repeated one-shot
 * requests could not do this: the one-shot pin API returns its cached fix while
 * that fix is still fresh, so the same observation arrived over and over and
 * sampling stalled at `1 of 5` in the field. Production admission rules are
 * untouched; this layer only narrows them.
 *
 * The subscription is stopped as soon as the group is Stable, and on cancel,
 * retry, timeout and disposal — so the accepted evidence is frozen while the
 * operator decides, and no subscription can outlive the step.
 *
 * A separate [MapAlignmentLiveUpdateDiagnostic] records only whether callbacks
 * are ARRIVING, so "delivering readings that are not good enough yet" can be
 * told apart from "Android is delivering nothing". It is display state: it
 * cannot accept, reject, restart or stop anything.
 */
@Composable
private fun GpsSamplingStep(
    draft: MapAlignmentDraft,
    editingId: String?,
    onStartFixUpdates: (onFix: (PinLocationResult) -> Unit) -> Unit,
    onStopFixUpdates: () -> Unit,
    modifier: Modifier,
    onCancel: () -> Unit,
    onStable: (CanonicalCoordinate, MapAlignmentGpsEvidence?, Long) -> Boolean,
) {
    val vine = LocalVineColors.current
    var attempt by remember { mutableStateOf(0) }
    var sampling by remember(attempt) { mutableStateOf(MapAlignmentGpsSampling()) }
    var lastRejection by remember(attempt) { mutableStateOf<String?>(null) }
    var timedOut by remember(attempt) { mutableStateOf(false) }
    // Set when a retaken position lands on top of a DIFFERENT reference.
    var duplicateConflict by remember(attempt) { mutableStateOf(false) }
    // Arrival-only diagnostic for THIS attempt. Never read back into sampling.
    var liveUpdates by remember(attempt) {
        mutableStateOf(MapAlignmentLiveUpdateDiagnostic.started(SystemClock.elapsedRealtime()))
    }
    // Re-evaluates the silence line on a monotonic clock while the step is open.
    var nowElapsedMillis by remember(attempt) {
        mutableStateOf(SystemClock.elapsedRealtime())
    }

    val progress = sampling.progress
    val stable = progress as? MapAlignmentGpsSampling.Progress.Stable

    // One owner for the subscription. Retry replaces it rather than stacking a
    // second one, and leaving the step always closes it.
    val session = remember {
        MapAlignmentLiveGpsSession(
            start = { onFix -> onStartFixUpdates(onFix) },
            stop = { onStopFixUpdates() },
        )
    }
    DisposableEffect(session) { onDispose { session.end() } }

    // Freeze at Stable: once the group qualifies, further fixes must not move
    // the representative coordinate under the operator while they decide.
    val isStable = progress.isStable
    LaunchedEffect(isStable) { if (isStable) session.end() }

    LaunchedEffect(attempt) {
        session.begin { production ->
            // A late fix from a superseded attempt is already filtered by the
            // session; ignore anything arriving after the group froze.
            if (sampling.isStable) return@begin
            // Count the ARRIVAL first, before any calibration judgement: a
            // rejected or duplicate fix is still proof the receiver is alive.
            liveUpdates = liveUpdates.onCallbackReceived(SystemClock.elapsedRealtime())
            when (val outcome = sampling.offer(production)) {
                is MapAlignmentGpsSampling.Outcome.Accepted -> {
                    sampling = outcome.sampling
                    lastRejection = null
                }
                // A redelivered observation is routine, not a failure.
                is MapAlignmentGpsSampling.Outcome.Duplicate -> Unit
                else -> lastRejection = outcome.calibrationMessage()
            }
            if (sampling.isStable) session.end()
        }
        // Never block indefinitely: fall through to an explicit Retry.
        delay(MapAlignmentGpsRules.SAMPLING_TIMEOUT_MILLIS)
        if (!sampling.isStable) {
            session.end()
            timedOut = true
        }
    }

    // Ticks the displayed silence duration only. Stops once the group is stable
    // or the attempt has timed out; it never touches the session or sampling.
    LaunchedEffect(attempt, isStable, timedOut) {
        while (!isStable && !timedOut) {
            nowElapsedMillis = SystemClock.elapsedRealtime()
            delay(1_000L)
        }
    }

    WizardScaffold(modifier = modifier) {
        SystemAdminPreviewBadge()
        ScopeSummary(draft)

        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SectionTitle(
                    if (editingId != null) {
                        "Retake GPS"
                    } else {
                        "Reference point ${draft.pointCount + 1} — GPS"
                    },
                )
                Text(
                    "Stand still at the point you can identify on the satellite image.",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                )

                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (!progress.isStable && !timedOut) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                        )
                        Spacer(Modifier.size(10.dp))
                    } else if (progress.isStable) {
                        Icon(
                            Icons.Filled.CheckCircle,
                            contentDescription = null,
                            tint = VineColors.Orange,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.size(10.dp))
                    }
                    Text(
                        progress.message(),
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                        color = vine.textPrimary,
                    )
                }

                LinearProgressIndicator(
                    progress = {
                        (sampling.sampleCount.toFloat() /
                            MapAlignmentGpsRules.MIN_SAMPLES.toFloat()).coerceIn(0f, 1f)
                    },
                    modifier = Modifier.fillMaxWidth(),
                )

                sampling.evidence?.let { evidence ->
                    AlignmentStatRow("Samples", "${evidence.sampleCount}")
                    AlignmentStatRow(
                        "Sampling time",
                        "${evidence.samplingDurationMillis / 1000} s",
                    )
                    AlignmentStatRow(
                        "Representative accuracy",
                        "±${metres(evidence.representativeAccuracyMetres)} m",
                    )
                    AlignmentStatRow("Worst reading", "±${metres(evidence.worstAccuracyMetres)} m")
                    AlignmentStatRow(
                        "Spread of readings",
                        "${metres(evidence.stabilityRadiusMetres)} m",
                        highlight = evidence.stabilityRadiusMetres >
                            MapAlignmentGpsRules.MAX_STABILITY_RADIUS_METRES,
                    )
                }

                lastRejection?.let {
                    Text(it, fontSize = 12.sp, color = vine.textSecondary)
                }

                // Quiet, and only after several seconds of true silence. It
                // clears itself the moment any callback arrives.
                if (!progress.isStable && !timedOut) {
                    liveUpdates.message(nowElapsedMillis)?.let { silence ->
                        Text(silence, fontSize = 12.sp, color = vine.textSecondary)
                    }
                }

                // System Admin preview only; not customer-facing wording yet.
                AlignmentStatRow("Live updates received", "${liveUpdates.callbackCount}")

                if (timedOut && !progress.isStable) {
                    Text(
                        "A stable GPS reading could not be obtained here. Move into clearer " +
                            "sky if you can, then try again.",
                        fontSize = 13.sp,
                        color = VineColors.Orange,
                    )
                }

                if (duplicateConflict) {
                    Row(verticalAlignment = Alignment.Top) {
                        Icon(
                            Icons.Filled.Warning,
                            contentDescription = null,
                            tint = VineColors.Orange,
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.size(8.dp))
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(
                                "This reference is too close to an existing point. Choose " +
                                    "another identifiable location further away.",
                                fontSize = 13.sp,
                                color = VineColors.Orange,
                            )
                            Text(
                                "The original reference point has not been changed. Retry here " +
                                    "if you believe this was GPS drift, or cancel to leave it " +
                                    "exactly as it is.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                }
            }
        }

        Button(
            onClick = {
                val coordinate = sampling.representative ?: return@Button
                // A rejected retake reports back rather than updating the draft.
                duplicateConflict =
                    !onStable(coordinate, stable?.evidence, System.currentTimeMillis())
            },
            enabled = stable != null,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.GpsFixed, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(8.dp))
            Text(if (editingId != null) "Use this GPS position" else "Continue to the map")
        }

        OutlinedButton(
            // Stop the old subscription before the new attempt starts one, so
            // two can never feed the sampler at once.
            onClick = {
                session.end()
                attempt += 1
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(8.dp))
            Text(if (duplicateConflict) "Retry GPS at this location" else "Retry")
        }
        OutlinedButton(
            onClick = {
                session.end()
                onCancel()
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (editingId != null) "Cancel retake" else "Cancel")
        }
        CanonicalInvariantNote()
    }
}

// --- 3b. Precision crosshair marking ---------------------------------------

@Composable
private fun MarkOnImageStep(
    state: AppUiState,
    draft: MapAlignmentDraft,
    mode: CaptureMode.Marking,
    modifier: Modifier,
    onCancel: () -> Unit,
    onConfirmed: (MapAlignmentDraft) -> Unit,
) {
    val vine = LocalVineColors.current
    var target by remember {
        mutableStateOf(
            mode.existingMark
                ?: AndroidDisplayCoordinate(mode.gps.latitude, mode.gps.longitude),
        )
    }
    var referenceType by remember { mutableStateOf<MapAlignmentReferenceType?>(null) }
    var description by remember { mutableStateOf("") }
    var rowNumber by remember { mutableStateOf("") }
    var rowPosition by remember { mutableStateOf<MapAlignmentRowPosition?>(null) }

    val duplicate = !mode.remarkOnly &&
        draft.isNearDuplicate(mode.gps, excludingId = mode.editingId)

    MarkingScaffold(
        modifier = modifier,
        title = if (mode.remarkOnly) "Re-mark the image point" else "Mark the image point",
        instruction = "Pan and pinch the satellite image until the crosshair sits on the " +
            "exact point where you are standing. Zoom right in — the image is uncorrected, " +
            "and that discrepancy is what you are measuring.",
        map = {
            MapAlignmentCrosshairMap(
                state = state,
                draft = draft,
                gpsPosition = mode.gps,
                initialTarget = mode.existingMark,
                onTargetChanged = { target = it },
            )
        },
    ) {
        if (duplicate) {
            Row {
                Icon(
                    Icons.Filled.Warning,
                    contentDescription = null,
                    tint = VineColors.Orange,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.size(8.dp))
                Text(
                    MapAlignmentSolver.NEAR_DUPLICATE_MESSAGE,
                    fontSize = 13.sp,
                    color = vine.textPrimary,
                )
            }
        }

        if (!mode.remarkOnly) {
            SectionTitle("About this point (optional)")
            ReferenceTypeChips(referenceType) { referenceType = it }
            OutlinedTextField(
                value = description,
                onValueChange = { description = it },
                label = { Text("Description") },
                placeholder = { Text("e.g. north-west corner post") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            // Row metadata only where it means something. A gate or a block
            // corner has no row, and asking for one invites junk.
            if (referenceType == MapAlignmentReferenceType.RowEnd) {
                OutlinedTextField(
                    value = rowNumber,
                    onValueChange = { entered ->
                        rowNumber = entered.filter { it.isDigit() }
                    },
                    label = { Text("Row number") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                RowPositionChips(rowPosition) { rowPosition = it }
            }
        }

        Button(
            onClick = {
                val updated = if (mode.remarkOnly && mode.editingId != null) {
                    draft.withRemarkedImagePoint(mode.editingId, target)
                } else {
                    draft.withReferencePoint(
                        MapAlignmentReferencePoint(
                            id = UUID.randomUUID().toString(),
                            scope = draft.scope,
                            // Canonical truth: the robust centre of the sample group.
                            canonicalCoordinate = mode.gps,
                            // Display space: where the imagery had to be moved for
                            // this to LOOK like the same place. Never stored as truth.
                            selectedMapCoordinate = target,
                            gpsAccuracyMetres = mode.evidence?.representativeAccuracyMetres,
                            gpsEvidence = mode.evidence,
                            capturedAtEpochMillis = mode.capturedAtEpochMillis,
                            referenceType = referenceType,
                            description = description.takeIf { it.isNotBlank() },
                            rowNumber = rowNumber.toIntOrNull(),
                            rowPosition = rowPosition,
                        ),
                    )
                }
                onConfirmed(updated)
            },
            enabled = !duplicate,
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Use this map point") }

        OutlinedButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) { Text("Cancel") }
    }
}

/**
 * Layout for the marking step only — deliberately NOT [WizardScaffold].
 *
 * ## Why this exists
 *
 * [WizardScaffold] applies `verticalScroll` to the whole page. A Google Map
 * nested inside a vertically scrolling parent loses the drag contest: the
 * scroll container consumes the vertical component of every one-finger pan, so
 * in the field the imagery could not be moved and pinch was unreliable. The
 * fix is structural rather than a pointer-event hack — the map is given its own
 * interaction area with no scrolling ancestor at all, so Google's own gesture
 * detector receives the raw stream and pan, pinch and fling behave natively.
 *
 * ## Structure
 *
 * A fixed compact header, then the map claiming all remaining height via
 * `weight`, then the controls. Only the controls row scrolls, and it is a
 * SIBLING of the map, never its parent — so the optional metadata fields and
 * the keyboard can never re-introduce a scrolling ancestor over the map. The
 * map keeps a sensible minimum height so a small screen with the keyboard open
 * degrades by scrolling the controls rather than crushing the imagery.
 *
 * This is a precision task, so the map gets the screen: no surrounding card,
 * no duplicated instruction text below it, and the standing note about
 * canonical coordinates is dropped from this step only (it is still shown on
 * the GPS and overview steps).
 */
@Composable
private fun MarkingScaffold(
    modifier: Modifier,
    title: String,
    instruction: String,
    map: @Composable () -> Unit,
    controls: @Composable ColumnScope.() -> Unit,
) {
    val vine = LocalVineColors.current
    Column(modifier = modifier.fillMaxSize()) {
        // Compact, fixed: enough to say what to do, no more.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            SectionTitle(title)
            Text(instruction, fontSize = 12.sp, color = vine.textSecondary)
        }

        // The map owns its area. No scrolling ancestor, so Google Maps receives
        // pan and pinch directly.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .heightIn(min = 240.dp)
                .padding(horizontal = 12.dp)
                .clip(RoundedCornerShape(12.dp)),
        ) { map() }

        // Sibling of the map, never an ancestor: scrolls on its own if the
        // optional fields or the keyboard need the room.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 300.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            content = controls,
        )
    }
}

// --- 3c. Overview and reference management ---------------------------------

@Composable
private fun CaptureOverviewStep(
    state: AppUiState,
    draft: MapAlignmentDraft,
    modifier: Modifier,
    onDraftChanged: (MapAlignmentDraft) -> Unit,
    onStartNewPoint: () -> Unit,
    onRetakeGps: (MapAlignmentReferencePoint) -> Unit,
    onRemark: (MapAlignmentReferencePoint) -> Unit,
    onCalculate: () -> Unit,
    onExit: () -> Unit,
) {
    val vine = LocalVineColors.current
    val readiness = draft.readiness

    WizardScaffold(modifier = modifier) {
        SystemAdminPreviewBadge()
        ScopeSummary(draft)

        if (draft.referencePoints.isNotEmpty()) {
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionTitle("Collected reference points")
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(260.dp)
                            .clip(RoundedCornerShape(12.dp)),
                    ) {
                        MapAlignmentCaptureOverviewMap(state = state, draft = draft)
                    }
                }
            }
        }

        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionTitle("Reference points (${draft.pointCount})")
                Text(
                    readiness.operatorMessage(),
                    fontSize = 13.sp,
                    color = if (readiness.isReady) VineColors.Orange else vine.textSecondary,
                )
                if (draft.referencePoints.isEmpty()) {
                    Text("None recorded yet.", fontSize = 13.sp, color = vine.textSecondary)
                } else {
                    Text(
                        "Spread over ${draft.widestSpanMetres.toInt()} m. " +
                            MapAlignmentSolver.SPREAD_ADVICE,
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
                draft.referencePoints.forEachIndexed { index, point ->
                    CapturedPointRow(
                        index = index + 1,
                        point = point,
                        onRetakeGps = { onRetakeGps(point) },
                        onRemark = { onRemark(point) },
                        onRemove = { onDraftChanged(draft.withoutReferencePoint(point.id)) },
                    )
                }
            }
        }

        Button(onClick = onStartNewPoint, modifier = Modifier.fillMaxWidth()) {
            Icon(Icons.Filled.GpsFixed, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(8.dp))
            Text("Record reference point ${draft.pointCount + 1}")
        }

        Button(
            onClick = onCalculate,
            enabled = readiness.isReady,
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Calculate alignment") }

        OutlinedButton(onClick = onExit, modifier = Modifier.fillMaxWidth()) {
            Text("Cancel calibration")
        }
        CanonicalInvariantNote()
        DraftOnlyNote()
    }
}

@Composable
private fun CapturedPointRow(
    index: Int,
    point: MapAlignmentReferencePoint,
    onRetakeGps: () -> Unit,
    onRemark: () -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    val offset = point.observedOffset
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.appBackground)
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            buildString {
                append("Point $index")
                point.referenceLabel()?.let { append(" — $it") }
            },
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = vine.textPrimary,
        )
        // Enough detail to diagnose a problem point without opening anything.
        Text(
            offsetDescription(offset.eastMetres, offset.northMetres) +
                " · ${metres(offset.magnitudeMetres)} m total",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        Text(
            buildString {
                append("GPS ±${metres(point.gpsAccuracyMetres ?: 0.0)} m")
                point.gpsEvidence?.let {
                    append(" · ${it.sampleCount} samples")
                    append(" · spread ${metres(it.stabilityRadiusMetres)} m")
                }
            },
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = onRetakeGps) {
                Icon(
                    Icons.Filled.Refresh,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.size(4.dp))
                Text("Retake GPS", fontSize = 12.sp)
            }
            TextButton(onClick = onRemark) {
                Icon(
                    Icons.Filled.Edit,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                )
                Spacer(Modifier.size(4.dp))
                Text("Re-mark", fontSize = 12.sp)
            }
            TextButton(onClick = onRemove) {
                Icon(
                    Icons.Filled.Delete,
                    contentDescription = "Delete point",
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Step 5 — completion
// ---------------------------------------------------------------------------

@Composable
private fun CompletionStep(
    modifier: Modifier,
    onViewAgain: () -> Unit,
    onDiscardAndFinish: () -> Unit,
) {
    val vine = LocalVineColors.current
    WizardScaffold(modifier = modifier) {
        SystemAdminPreviewBadge()
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "Calibration preview complete",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
                Text(
                    "This calibration was created for testing on this Android device.",
                    fontSize = 14.sp,
                    color = vine.textSecondary,
                )
                Text(
                    "No vineyard, block, row, pin, route or GPS coordinates have been changed.",
                    fontSize = 14.sp,
                    color = vine.textSecondary,
                )
                Text(
                    "The alignment has not yet been enabled on VineTrack's normal maps.",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = vine.textPrimary,
                )
            }
        }
        Button(onClick = onViewAgain, modifier = Modifier.fillMaxWidth()) {
            Text("View preview again")
        }
        OutlinedButton(onClick = onDiscardAndFinish, modifier = Modifier.fillMaxWidth()) {
            Text("Discard and finish")
        }
    }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

/** Short human label for a reference: its description, or its type and row. */
internal fun MapAlignmentReferencePoint.referenceLabel(): String? {
    description?.takeIf { it.isNotBlank() }?.let { return it }
    val type = referenceType?.let {
        when (it) {
            MapAlignmentReferenceType.RowEnd -> "Row end"
            MapAlignmentReferenceType.BlockCorner -> "Block corner"
            MapAlignmentReferenceType.Infrastructure -> "Post/gate"
            MapAlignmentReferenceType.Landmark -> "Landmark"
            MapAlignmentReferenceType.Other -> "Other"
        }
    }
    val row = rowNumber?.let { number ->
        buildString {
            append("Row $number")
            rowPosition?.let { append(" ${it.name.lowercase(Locale.US)}") }
        }
    }
    return listOfNotNull(type, row).takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

@Composable
private fun ReferenceTypeChips(
    selected: MapAlignmentReferenceType?,
    onSelect: (MapAlignmentReferenceType?) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            "What is this point?",
            fontSize = 12.sp,
            color = LocalVineColors.current.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf(
                MapAlignmentReferenceType.BlockCorner to "Corner",
                MapAlignmentReferenceType.RowEnd to "Row end",
                MapAlignmentReferenceType.Infrastructure to "Post/gate",
                MapAlignmentReferenceType.Landmark to "Landmark",
            ).forEach { (type, label) ->
                FilterChip(
                    selected = selected == type,
                    onClick = { onSelect(if (selected == type) null else type) },
                    label = { Text(label, fontSize = 12.sp) },
                )
            }
        }
    }
}

@Composable
private fun RowPositionChips(
    selected: MapAlignmentRowPosition?,
    onSelect: (MapAlignmentRowPosition?) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            "Where along the row?",
            fontSize = 12.sp,
            color = LocalVineColors.current.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            MapAlignmentRowPosition.entries.forEach { position ->
                FilterChip(
                    selected = selected == position,
                    onClick = { onSelect(if (selected == position) null else position) },
                    label = { Text(position.name, fontSize = 12.sp) },
                )
            }
        }
    }
}

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
