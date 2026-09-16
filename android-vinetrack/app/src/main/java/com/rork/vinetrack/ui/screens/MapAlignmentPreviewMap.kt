package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.Circle
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.mapalignment.AndroidDisplayCoordinate
import com.rork.vinetrack.data.mapalignment.CanonicalCoordinate
import com.rork.vinetrack.data.mapalignment.MapAlignment
import com.rork.vinetrack.data.mapalignment.MapAlignmentDraft
import com.rork.vinetrack.data.mapalignment.MapAlignmentOutliers
import com.rork.vinetrack.data.mapalignment.MapAlignmentReferencePoint
import com.rork.vinetrack.data.mapalignment.MapAlignmentSaveFlow
import com.rork.vinetrack.data.mapalignment.MapAlignmentSolver
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.components.estimatedCameraPosition
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

/** Close field zoom used when framing a single GPS position for marking. */
private const val CROSSHAIR_ZOOM = 20f

/**
 * Ground radius of the recorded-position ring, in metres.
 *
 * Small enough to indicate one spot, large enough to stay visible at field
 * zoom, and hollow so it never hides the imagery feature under the crosshair.
 */
private const val GPS_RING_RADIUS_METRES = 1.5

/**
 * Canonical geometry for the draft's scope, read-only.
 *
 * A block-override draft frames just that block; a vineyard draft frames every
 * block with a mapped boundary. Nothing here writes to a block, and no polygon
 * point is modified — the alignment is applied at DRAW time only.
 */
private fun scopeBlocks(state: AppUiState, draft: MapAlignmentDraft): List<Paddock> {
    val inVineyard = state.paddocks.filter {
        it.vineyardId == draft.scope.vineyardId && it.hasGeometry
    }
    val blockId = draft.scope.blockId ?: return inVineyard
    return inVineyard.filter { it.id == blockId }
}

/**
 * Draw one block's canonical boundary through [alignment].
 *
 * Every vertex goes through `CanonicalCoordinate.toDisplay(alignment)`, so with
 * an identity alignment this is pixel-identical to production rendering. The
 * resulting display coordinates are converted to `LatLng` purely to hand them
 * to the map — they are never returned to domain code or stored.
 */
private fun Paddock.displayRing(alignment: MapAlignment): List<LatLng> =
    (polygonPoints ?: emptyList()).map { point ->
        val display = CanonicalCoordinate(point.latitude, point.longitude).toDisplay(alignment)
        LatLng(display.latitude, display.longitude)
    }

// ---------------------------------------------------------------------------
// Precision crosshair selector
// ---------------------------------------------------------------------------

/**
 * The precision selector used to mark a reference point on the imagery.
 *
 * ## Why a fixed crosshair rather than a map tap
 *
 * A tap is limited by fingertip size: at field zoom the contact patch covers
 * several metres, which is the same magnitude as the offset being measured, and
 * the finger hides the target at the moment of selection. A fixed centre
 * crosshair inverts the interaction — the operator moves the *imagery* under a
 * stationary reticle and can zoom in as far as they like to refine it, with
 * nothing obscuring the point. The selected coordinate is the camera target.
 *
 * The map is deliberately drawn UNALIGNED: the operator is observing the raw
 * discrepancy, and pre-correcting the imagery would hide the very thing being
 * measured. The resulting coordinate is therefore display space and is NOT
 * inverse-transformed during capture.
 *
 * The recorded position is drawn as a small hollow ring rather than a dropped
 * pin. A pin's teardrop is tens of metres wide at field zoom, sits ABOVE its
 * coordinate and is opaque, so it covered the crosshair and hid the very
 * imagery feature being aimed at. A stroked ring at a true ground radius marks
 * the same position, leaves the imagery visible through it, scales honestly
 * with zoom, and can never be mistaken for the selection control. The Google
 * "my location" dot stays disabled for the same reason.
 *
 * ## Gesture ownership
 *
 * Pan and pinch are set EXPLICITLY below rather than left to defaults, and this
 * composable requires a parent with no vertically scrolling ancestor — see
 * `MarkingScaffold` in the wizard. Inside a `verticalScroll` parent the scroll
 * container wins the drag and the imagery cannot be moved at all.
 */
@Composable
fun MapAlignmentCrosshairMap(
    state: AppUiState,
    draft: MapAlignmentDraft,
    gpsPosition: CanonicalCoordinate,
    /** Where the crosshair should start; the previous mark when re-marking. */
    initialTarget: AndroidDisplayCoordinate?,
    onTargetChanged: (AndroidDisplayCoordinate) -> Unit,
    modifier: Modifier = Modifier,
) {
    val blocks = remember(state.paddocks, draft.scope) { scopeBlocks(state, draft) }
    val unaligned = MapAlignment.none(draft.scope)
    val start = initialTarget?.let { LatLng(it.latitude, it.longitude) }
        ?: LatLng(gpsPosition.latitude, gpsPosition.longitude)

    val camera = rememberCameraPositionState {
        position = CameraPosition.fromLatLngZoom(start, CROSSHAIR_ZOOM)
    }

    // The selection IS the camera target: whatever sits under the reticle. Read
    // in composition so the reported coordinate stays exactly in step with the
    // imagery the operator can see.
    val target = camera.position.target
    LaunchedEffect(target.latitude, target.longitude) {
        onTargetChanged(AndroidDisplayCoordinate(target.latitude, target.longitude))
    }

    Box(modifier = modifier.fillMaxSize()) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = camera,
            properties = MapProperties(mapType = MapType.HYBRID, isMyLocationEnabled = false),
            // Stated explicitly, not inherited: this step is unusable if pan or
            // pinch is off, and a rotated or tilted view would corrupt a
            // precision judgement about north/east offsets.
            uiSettings = MapUiSettings(
                scrollGesturesEnabled = true,
                zoomGesturesEnabled = true,
                rotationGesturesEnabled = false,
                tiltGesturesEnabled = false,
                myLocationButtonEnabled = false,
                mapToolbarEnabled = false,
                // Left hidden: pinch is the primary zoom and Google's buttons
                // would land on top of the Recentre control in this corner.
                zoomControlsEnabled = false,
            ),
        ) {
            blocks.forEach { block ->
                val ring = block.displayRing(unaligned)
                if (ring.size >= 3) {
                    Polygon(
                        points = ring,
                        strokeColor = VineColors.Orange,
                        strokeWidth = 4f,
                        fillColor = VineColors.Orange.copy(alpha = 0.08f),
                    )
                }
            }
            // VineTrack's own recorded position: hollow, at a real ground
            // radius, so the imagery under the crosshair is never obscured.
            // White casing under an orange stroke, legible on dirt and canopy.
            Circle(
                center = LatLng(gpsPosition.latitude, gpsPosition.longitude),
                radius = GPS_RING_RADIUS_METRES,
                strokeColor = Color.Black.copy(alpha = 0.55f),
                strokeWidth = 6f,
                fillColor = Color.Transparent,
            )
            Circle(
                center = LatLng(gpsPosition.latitude, gpsPosition.longitude),
                radius = GPS_RING_RADIUS_METRES,
                strokeColor = VineColors.Orange,
                strokeWidth = 3f,
                fillColor = Color.Transparent,
            )
            // Already-captured evidence, for context while marking the next one.
            draft.referencePoints.forEach { point ->
                val gps = LatLng(
                    point.canonicalCoordinate.latitude,
                    point.canonicalCoordinate.longitude,
                )
                val marked = LatLng(
                    point.selectedMapCoordinate.latitude,
                    point.selectedMapCoordinate.longitude,
                )
                Polyline(points = listOf(gps, marked), color = Color.White, width = 3f)
            }
        }

        // The reticle. Fixed to the centre of the viewport while imagery moves
        // underneath it.
        CrosshairReticle(modifier = Modifier.align(Alignment.Center))

        // Recentre on the recorded GPS position, since panning far away is easy.
        OutlinedButton(
            onClick = {
                camera.position = CameraPosition.fromLatLngZoom(
                    LatLng(gpsPosition.latitude, gpsPosition.longitude),
                    CROSSHAIR_ZOOM,
                )
            },
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(10.dp),
        ) { Text("Recentre", fontSize = 12.sp) }
    }
}

/**
 * A stationary precision reticle: four hairlines around a hollow centre ring.
 *
 * The operator is aiming at a specific feature in the imagery — a post, a
 * corner, an end assembly — so the target itself must stay visible. Nothing is
 * filled: the ring is stroked, and the hairlines stop short of the centre so
 * the exact pixel under the camera target is never covered.
 *
 * Each stroke is drawn twice, a dark casing under a white line, so the reticle
 * reads over both pale dirt and dark canopy. It is a passive overlay and takes
 * no input — selection remains the map camera target.
 */
@Composable
private fun CrosshairReticle(modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(72.dp)) {
        val centre = Offset(size.width / 2f, size.height / 2f)
        val ringRadius = 9.dp.toPx()
        val armOuter = size.width / 2f
        // Hairlines stop at the ring, leaving the target clear.
        val armInner = ringRadius + 3.dp.toPx()
        val line = 1.5.dp.toPx()
        val casing = line + 2.dp.toPx()

        fun hairlines(colour: Color, stroke: Float) {
            // Left, right, top, bottom — all stopping short of the centre.
            drawLine(colour, Offset(centre.x - armOuter, centre.y), Offset(centre.x - armInner, centre.y), stroke)
            drawLine(colour, Offset(centre.x + armInner, centre.y), Offset(centre.x + armOuter, centre.y), stroke)
            drawLine(colour, Offset(centre.x, centre.y - armOuter), Offset(centre.x, centre.y - armInner), stroke)
            drawLine(colour, Offset(centre.x, centre.y + armInner), Offset(centre.x, centre.y + armOuter), stroke)
        }

        // Dark casing first, so the white strokes stay legible on pale imagery.
        hairlines(Color.Black.copy(alpha = 0.55f), casing)
        drawCircle(
            color = Color.Black.copy(alpha = 0.55f),
            radius = ringRadius,
            center = centre,
            style = Stroke(width = casing),
        )

        hairlines(Color.White, line)
        drawCircle(
            color = VineColors.Orange,
            radius = ringRadius,
            center = centre,
            style = Stroke(width = line),
        )
    }
}

// ---------------------------------------------------------------------------
// Overview map: all captured evidence
// ---------------------------------------------------------------------------

/** Read-only overview of every captured reference, for orientation during capture. */
@Composable
fun MapAlignmentCaptureOverviewMap(
    state: AppUiState,
    draft: MapAlignmentDraft,
    modifier: Modifier = Modifier,
) {
    val blocks = remember(state.paddocks, draft.scope) { scopeBlocks(state, draft) }
    val unaligned = MapAlignment.none(draft.scope)
    val framePoints = remember(blocks, draft.referencePoints) {
        blocks.flatMap { it.displayRing(unaligned) } +
            draft.referencePoints.map {
                LatLng(it.canonicalCoordinate.latitude, it.canonicalCoordinate.longitude)
            }
    }
    val camera = rememberCameraPositionState {
        estimatedCameraPosition(framePoints, singlePointZoom = 19f)?.let { position = it }
    }

    GoogleMap(
        modifier = modifier.fillMaxSize(),
        cameraPositionState = camera,
        properties = MapProperties(mapType = MapType.HYBRID),
        uiSettings = MapUiSettings(
            zoomControlsEnabled = false,
            mapToolbarEnabled = false,
            tiltGesturesEnabled = false,
            rotationGesturesEnabled = false,
            myLocationButtonEnabled = false,
        ),
    ) {
        blocks.forEach { block ->
            val ring = block.displayRing(unaligned)
            if (ring.size >= 3) {
                Polygon(
                    points = ring,
                    strokeColor = VineColors.Orange,
                    strokeWidth = 4f,
                    fillColor = VineColors.Orange.copy(alpha = 0.08f),
                )
            }
        }
        draft.referencePoints.forEachIndexed { index, point ->
            val gps = LatLng(point.canonicalCoordinate.latitude, point.canonicalCoordinate.longitude)
            val marked = LatLng(
                point.selectedMapCoordinate.latitude,
                point.selectedMapCoordinate.longitude,
            )
            Polyline(points = listOf(gps, marked), color = Color.White, width = 3f)
            Marker(
                state = MarkerState(position = gps),
                title = "Point ${index + 1} — recorded GPS",
                alpha = 0.9f,
            )
            Marker(
                state = MarkerState(position = marked),
                title = "Point ${index + 1} — marked on image",
                alpha = 0.55f,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Review, with the private before/after preview
// ---------------------------------------------------------------------------

/**
 * Review the derived candidate and inspect it in a private before/after preview.
 *
 * The preview is the whole point of this phase: it applies the candidate to the
 * canonical geometry AT DRAW TIME, inside this screen only. No production
 * vineyard or block map consults the candidate, and nothing is persisted.
 */
@Composable
fun MapAlignmentReviewStep(
    state: AppUiState,
    draft: MapAlignmentDraft,
    modifier: Modifier = Modifier,
    onCaptureMore: () -> Unit,
    onReviewPoint: (MapAlignmentReferencePoint) -> Unit,
    onSave: () -> Unit,
    onDiscard: () -> Unit,
) {
    val vine = LocalVineColors.current
    val solution = draft.solution
    var showAligned by remember { mutableStateOf(true) }

    // Advisory only: this reads the candidate and forms an opinion. It removes,
    // reweights and reorders nothing, and the median estimator is untouched.
    val review = remember(solution) { solution?.let { MapAlignmentOutliers.review(it) } }
    // Raised once per candidate. Recalculating after a retake or re-mark
    // produces a new solution, so a genuinely fixed point stops warning.
    var warningDismissed by remember(solution) { mutableStateOf(false) }

    WizardScaffold(modifier = modifier) {
        SystemAdminPreviewBadge()
        ScopeSummary(draft)

        if (solution == null) {
            VineyardCard {
                Text(
                    "No alignment has been calculated yet.",
                    fontSize = 14.sp,
                    color = vine.textSecondary,
                )
            }
            OutlinedButton(onClick = onCaptureMore, modifier = Modifier.fillMaxWidth()) {
                Text("Back to reference points")
            }
            return@WizardScaffold
        }

        val quality = solution.quality
        val alignment = solution.alignment

        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SectionTitle("Calculated alignment")
                // Numeric values as well as the classification, so the result is
                // never reduced to a single reassuring word.
                AlignmentStatRow(
                    "East/West adjustment",
                    "${metres(kotlin.math.abs(alignment.eastOffsetMetres))} m " +
                        if (alignment.eastOffsetMetres >= 0) "east" else "west",
                )
                AlignmentStatRow(
                    "North/South adjustment",
                    "${metres(kotlin.math.abs(alignment.northOffsetMetres))} m " +
                        if (alignment.northOffsetMetres >= 0) "north" else "south",
                )
                AlignmentStatRow("Total adjustment", "${metres(alignment.magnitudeMetres)} m")
                AlignmentStatRow("Reference points", solution.pointCount.toString())
                AlignmentStatRow(
                    "RMS residual",
                    "${metres(solution.rmsResidualMetres)} m",
                    highlight = solution.rmsResidualMetres >
                        MapAlignmentSolver.GOOD_RMS_RESIDUAL_METRES,
                )
                AlignmentStatRow(
                    "Maximum residual",
                    "${metres(solution.maxResidualMetres)} m",
                    highlight = solution.maxResidualMetres >
                        MapAlignmentSolver.GOOD_MAX_RESIDUAL_METRES,
                )
                AlignmentStatRow(
                    "Alignment quality",
                    quality.label,
                    highlight = quality != MapAlignmentSolver.Quality.Good,
                )
                Text(
                    "Reference points spread over ${solution.widestSpanMetres.toInt()} m.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                if (solution.spreadIsNarrow) {
                    Text(
                        MapAlignmentSolver.SPREAD_ADVICE,
                        fontSize = 12.sp,
                        color = VineColors.Orange,
                    )
                }
            }
        }

        if (quality != MapAlignmentSolver.Quality.Good) {
            VineyardCard {
                Row {
                    Icon(
                        Icons.Filled.Warning,
                        contentDescription = null,
                        tint = VineColors.Orange,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.size(8.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            "Check alignment",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        Text(
                            "The reference points do not all agree with this single shift " +
                                "(RMS ${metres(solution.rmsResidualMetres)} m, worst " +
                                "${metres(solution.maxResidualMetres)} m). That can mean one " +
                                "point was marked in the wrong place, or that a simple shift " +
                                "does not fully explain this imagery. Check the highlighted " +
                                "points below before trusting this result.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }
        }

        // --- The private before/after preview ---
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionTitle(if (showAligned) "Aligned" else "Original")
                Text(
                    if (showAligned) {
                        "Your vineyard geometry drawn with the calculated alignment applied."
                    } else {
                        "Your vineyard geometry drawn exactly as it appears today."
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
                    MapAlignmentBeforeAfterMap(
                        state = state,
                        draft = draft,
                        alignment = if (showAligned) draft.previewAfter else draft.previewBefore,
                        showAligned = showAligned,
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        onClick = { showAligned = false },
                        modifier = Modifier.weight(1f),
                    ) { Text("Original") }
                    Button(
                        onClick = { showAligned = true },
                        modifier = Modifier.weight(1f),
                    ) { Text("Aligned") }
                }
                MarkerLegend()
                Text(
                    "This preview is private to this screen. Your vineyard and block maps " +
                        "are unchanged.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
        }

        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SectionTitle("Reference points")
                val worst = solution.worstPointIndex
                solution.calibration.referencePoints.forEachIndexed { index, point ->
                    val residual = solution.residualMagnitudesMetres[index]
                    AlignmentStatRow(
                        label = buildString {
                            append("Point ${index + 1}")
                            point.referenceLabel()?.let { append(" — $it") }
                            if (index == worst && solution.pointCount > 1) append("  (largest)")
                        },
                        value = "${metres(residual)} m",
                        highlight = index == worst &&
                            residual > MapAlignmentSolver.GOOD_MAX_RESIDUAL_METRES,
                    )
                }
                Text(
                    "Every reference is kept. Nothing is removed automatically — if one point " +
                        "is wrong, retake or re-mark it yourself.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
        }

        // Saving is explicit and deliberate. Reaching this screen, or having
        // been warned about a point, never saves anything on its own.
        Button(onClick = onSave, modifier = Modifier.fillMaxWidth()) {
            Text(MapAlignmentSaveFlow.SAVE_ACTION_LABEL)
        }
        OutlinedButton(onClick = onCaptureMore, modifier = Modifier.fillMaxWidth()) {
            Text("Back to reference points")
        }
        OutlinedButton(onClick = onDiscard, modifier = Modifier.fillMaxWidth()) {
            Text("Leave calibration")
        }
        CanonicalInvariantNote()
        DraftOnlyNote()
    }

    // Shown BEFORE review is treated as complete, so a suspect point is raised
    // while the operator can still do something about it.
    if (review != null && review.hasSuspects && !warningDismissed) {
        OutlierWarningDialog(
            review = review,
            onReview = {
                warningDismissed = true
                review.suspects.firstOrNull()?.let { onReviewPoint(it.point) }
            },
            onContinueAnyway = { warningDismissed = true },
        )
    }
}

/**
 * Advisory warning that one or more references disagree with the others.
 *
 * ## What it deliberately does not do
 *
 * Nothing is deleted, reweighted or recalculated by either action. "Continue
 * anyway" is a real, respected choice: the operator may well know the point is
 * correct and the imagery is simply poor there. The warning exists to make sure
 * they SAW the discrepancy, not to overrule them.
 *
 * The wording names the measurement and both plausible causes without asserting
 * which one it is, because we genuinely cannot tell from the residual whether
 * the GPS position or the image mark is at fault.
 */
@Composable
private fun OutlierWarningDialog(
    review: MapAlignmentOutliers.Review,
    onReview: () -> Unit,
    onContinueAnyway: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onContinueAnyway,
        icon = {
            Icon(
                Icons.Filled.Warning,
                contentDescription = null,
                tint = VineColors.Orange,
                modifier = Modifier.size(20.dp),
            )
        },
        title = { Text(review.title()) },
        text = { Text(review.message(), fontSize = 14.sp) },
        confirmButton = {
            TextButton(onClick = onReview) { Text(review.reviewActionLabel()) }
        },
        dismissButton = {
            TextButton(onClick = onContinueAnyway) { Text("Continue anyway") }
        },
    )
}

@Composable
private fun MarkerLegend() {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            "Recorded GPS position · marked image point · aligned result",
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = vine.textPrimary,
        )
        Text(
            "The line between a reference's GPS position and the point you marked shows " +
                "what that point contributed. A line that disagrees with the others is why a " +
                "residual is large.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
    }
}

/**
 * Canonical geometry and captured evidence drawn through [alignment].
 *
 * With [MapAlignment.none] this is identical to production rendering, which is
 * what makes the Original/Aligned comparison honest. The camera is framed on
 * the UNALIGNED geometry in both states and never re-framed, so the geometry
 * visibly shifts against fixed Google imagery rather than the map chasing it.
 */
@Composable
private fun MapAlignmentBeforeAfterMap(
    state: AppUiState,
    draft: MapAlignmentDraft,
    alignment: MapAlignment,
    showAligned: Boolean,
    modifier: Modifier = Modifier,
) {
    val blocks = remember(state.paddocks, draft.scope) { scopeBlocks(state, draft) }
    val framePoints = remember(blocks) {
        blocks.flatMap { it.displayRing(MapAlignment.none(draft.scope)) }
    }
    val camera = rememberCameraPositionState {
        estimatedCameraPosition(framePoints, singlePointZoom = 19f)?.let { position = it }
    }

    GoogleMap(
        modifier = modifier.fillMaxSize(),
        cameraPositionState = camera,
        properties = MapProperties(mapType = MapType.HYBRID),
        uiSettings = MapUiSettings(
            zoomControlsEnabled = false,
            mapToolbarEnabled = false,
            tiltGesturesEnabled = false,
            rotationGesturesEnabled = false,
            myLocationButtonEnabled = false,
        ),
    ) {
        blocks.forEach { block ->
            val ring = block.displayRing(alignment)
            if (ring.size >= 3) {
                Polygon(
                    points = ring,
                    strokeColor = VineColors.Orange,
                    strokeWidth = 4f,
                    fillColor = VineColors.Orange.copy(alpha = 0.10f),
                )
            }
        }
        draft.referencePoints.forEachIndexed { index, point ->
            // Canonical GPS truth, drawn through the alignment currently shown.
            val gpsDisplay = point.canonicalCoordinate.toDisplay(alignment)
            val gps = LatLng(gpsDisplay.latitude, gpsDisplay.longitude)
            // The operator's marked image point never moves: it is already an
            // observation of the imagery itself.
            val marked = LatLng(
                point.selectedMapCoordinate.latitude,
                point.selectedMapCoordinate.longitude,
            )
            Marker(
                state = MarkerState(position = gps),
                title = "Point ${index + 1} — ${if (showAligned) "aligned" else "recorded"} GPS",
                alpha = 0.9f,
            )
            Marker(
                state = MarkerState(position = marked),
                title = "Point ${index + 1} — marked on image",
                alpha = 0.55f,
            )
            Polyline(
                points = listOf(gps, marked),
                color = if (showAligned) VineColors.Orange else Color.White,
                width = 3f,
            )
        }
    }
}

@Composable
internal fun AlignmentStatRow(label: String, value: String, highlight: Boolean = false) {
    val vine = LocalVineColors.current
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(label, fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
        Text(
            value,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = if (highlight) VineColors.Orange else vine.textPrimary,
        )
    }
}
