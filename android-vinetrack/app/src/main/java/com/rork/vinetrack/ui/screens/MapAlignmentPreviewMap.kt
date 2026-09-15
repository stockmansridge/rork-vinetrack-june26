package com.rork.vinetrack.ui.screens

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.model.LatLng
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
import com.rork.vinetrack.data.mapalignment.MapAlignmentSolver
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.components.estimatedCameraPosition
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

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

/**
 * The capture map: canonical geometry drawn UNALIGNED over satellite imagery,
 * plus the operator's pending tap.
 *
 * Geometry is deliberately drawn with no alignment during capture. The operator
 * is being asked to observe the raw discrepancy between imagery and truth; pre-
 * correcting the overlay would hide the very thing they are measuring.
 */
@Composable
fun MapAlignmentCaptureMap(
    state: AppUiState,
    draft: MapAlignmentDraft,
    pendingTap: AndroidDisplayCoordinate?,
    tapEnabled: Boolean,
    onTap: (AndroidDisplayCoordinate) -> Unit,
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
        // Satellite/hybrid is the presentation this feature exists to correct.
        properties = MapProperties(mapType = MapType.HYBRID),
        uiSettings = MapUiSettings(
            zoomControlsEnabled = false,
            mapToolbarEnabled = false,
            tiltGesturesEnabled = false,
            rotationGesturesEnabled = false,
            myLocationButtonEnabled = false,
        ),
        onMapClick = { latLng ->
            // A map tap is DISPLAY space by definition. It is typed as such so
            // it can never be mistaken for a canonical position.
            if (tapEnabled) onTap(AndroidDisplayCoordinate(latLng.latitude, latLng.longitude))
        },
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

        // Already-captured evidence: the recorded GPS position and the tap that
        // was matched to it, joined so the discrepancy is visible.
        draft.referencePoints.forEach { point ->
            val gps = LatLng(point.canonicalCoordinate.latitude, point.canonicalCoordinate.longitude)
            val tapped = LatLng(
                point.selectedMapCoordinate.latitude,
                point.selectedMapCoordinate.longitude,
            )
            Polyline(points = listOf(gps, tapped), color = Color.White, width = 3f)
            Marker(state = MarkerState(position = gps), title = "Recorded GPS", alpha = 0.9f)
            Marker(state = MarkerState(position = tapped), title = "Marked on image", alpha = 0.6f)
        }

        pendingTap?.let {
            Marker(
                state = MarkerState(position = LatLng(it.latitude, it.longitude)),
                title = "This reference point",
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Step 4 — review, with the private before/after preview
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
    onDiscard: () -> Unit,
) {
    val vine = LocalVineColors.current
    val solution = draft.solution
    var showAligned by remember { mutableStateOf(true) }

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

        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SectionTitle("Calculated alignment")
                Text(
                    offsetDescription(
                        solution.alignment.eastOffsetMetres,
                        solution.alignment.northOffsetMetres,
                    ),
                    fontSize = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                )
                Text(
                    "The Android satellite map is drawn this far from your GPS position. " +
                        "Derived from ${solution.pointCount} reference points spread over " +
                        "${solution.widestSpanMetres.toInt()} m.",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                )
                StatRow("Typical remaining error", "±${metres(solution.meanResidualMetres)} m")
                StatRow("Worst point", "±${metres(solution.maxResidualMetres)} m")
            }
        }

        if (solution.needsReview) {
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
                            "Worth a closer look",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                        )
                        Text(
                            "One or more points still disagree by more than " +
                                "${MapAlignmentSolver.RESIDUAL_REVIEW_METRES.toInt()} m after " +
                                "alignment. A simple shift may not fully explain this imagery — " +
                                "it can also mean a point was marked in the wrong place. Check " +
                                "the points below before trusting this result.",
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
                SectionTitle(if (showAligned) "After alignment" else "Before alignment")
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
                    )
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        onClick = { showAligned = false },
                        modifier = Modifier.weight(1f),
                    ) { Text("Before") }
                    Button(
                        onClick = { showAligned = true },
                        modifier = Modifier.weight(1f),
                    ) { Text("After") }
                }
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
                solution.calibration.referencePoints.forEachIndexed { index, point ->
                    val residual = solution.calibration.residuals()[index]
                    StatRow(
                        label = "Point ${index + 1}",
                        value = "±${metres(residual.magnitudeMetres)} m remaining",
                        highlight = residual.magnitudeMetres > MapAlignmentSolver.RESIDUAL_REVIEW_METRES,
                    )
                }
            }
        }

        OutlinedButton(onClick = onCaptureMore, modifier = Modifier.fillMaxWidth()) {
            Text("Add more reference points")
        }
        OutlinedButton(onClick = onDiscard, modifier = Modifier.fillMaxWidth()) {
            Text("Discard calibration")
        }
        CanonicalInvariantNote()
        DraftOnlyNote()
    }
}

/**
 * Canonical geometry and captured GPS positions drawn through [alignment].
 *
 * With [MapAlignment.none] this is identical to production rendering, which is
 * what makes the before/after comparison honest.
 */
@Composable
private fun MapAlignmentBeforeAfterMap(
    state: AppUiState,
    draft: MapAlignmentDraft,
    alignment: MapAlignment,
    modifier: Modifier = Modifier,
) {
    val blocks = remember(state.paddocks, draft.scope) { scopeBlocks(state, draft) }
    // Frame on the unaligned geometry so the camera does NOT move between the
    // before and after views — otherwise the shift would be invisible.
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
        // The recorded GPS positions move with the alignment too, since they are
        // canonical truth being drawn on a corrected map.
        draft.referencePoints.forEach { point ->
            val display = point.canonicalCoordinate.toDisplay(alignment)
            Marker(
                state = MarkerState(position = LatLng(display.latitude, display.longitude)),
                title = "Recorded GPS",
                alpha = 0.9f,
            )
        }
    }
}

@Composable
private fun StatRow(label: String, value: String, highlight: Boolean = false) {
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
