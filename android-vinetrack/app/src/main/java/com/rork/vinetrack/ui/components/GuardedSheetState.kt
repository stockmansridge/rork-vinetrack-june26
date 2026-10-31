package com.rork.vinetrack.ui.components

import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SheetState
import androidx.compose.material3.SheetValue
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest

/** Fraction of the visible sheet height the user must drag down before a gesture dismisses. */
private const val DISMISS_DRAG_FRACTION = 0.75f

/** How long the sheet offset must hold still before we treat it as the settled resting position. */
private const val SETTLE_STABILITY_MS = 200L

/**
 * Drop-in replacement for [rememberModalBottomSheetState] that makes pull-down
 * dismissal deliberate: a drag gesture only closes the sheet after the user has
 * pulled it down at least [DISMISS_DRAG_FRACTION] (~75%) of its visible height.
 * Small and medium drags — including fast flings, which the default Material 3
 * state dismisses on — settle back open.
 *
 * Explicit dismissal still works immediately: scrim tap, system back, Cancel/X
 * buttons, programmatic `hide()`, and removing the sheet from composition all
 * occur while the sheet is settled (drag distance ~0), so the guard lets them
 * through untouched.
 *
 * The settled resting offset is re-tracked continuously (offset stable for
 * [SETTLE_STABILITY_MS]), so keyboard-driven re-anchoring or partial/expanded
 * transitions do not confuse the drag-distance measurement.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun rememberGuardedSheetState(skipPartiallyExpanded: Boolean = true): SheetState {
    val density = LocalDensity.current
    val containerHeightPx = with(density) { LocalConfiguration.current.screenHeightDp.dp.toPx() }
    val settledEpsilonPx = with(density) { 6.dp.toPx() }
    val tracker = remember { SheetDragTracker() }
    val sheetState = rememberModalBottomSheetState(
        skipPartiallyExpanded = skipPartiallyExpanded,
        confirmValueChange = { target ->
            if (target != SheetValue.Hidden) {
                true
            } else {
                val current = tracker.readCurrentOffset()
                val settled = tracker.settledOffset
                if (com.rork.vinetrack.BuildConfig.DEBUG) {
                    com.rork.vinetrack.data.auth.CleanExitDiagnostics.checkpoint("sheet.dismiss.current.$current.settled.$settled")
                }
                if (current == null || settled == null) {
                    // Sheet hasn't finished animating in yet — don't trap it open.
                    true
                } else {
                    val dragged = current - settled
                    if (dragged <= settledEpsilonPx) {
                        // Not mid-drag: scrim tap, back press, or programmatic hide.
                        true
                    } else {
                        val sheetHeight = (containerHeightPx - settled).coerceAtLeast(1f)
                        dragged >= sheetHeight * DISMISS_DRAG_FRACTION
                    }
                }
            }
        },
    )
    // confirmValueChange may run in the same input dispatch as the last drag event,
    // before snapshotFlow collects. Measure the current offset synchronously there.
    tracker.readCurrentOffset = { runCatching { sheetState.requireOffset() }.getOrNull() }
    LaunchedEffect(sheetState) {
        // Observe actual offset/anchor changes rather than requesting frames forever.
        // An always-awaiting frame loop keeps the Recomposer pending even at rest.
        snapshotFlow { runCatching { sheetState.requireOffset() }.getOrNull() to sheetState.targetValue }
            .collectLatest { (offset, target) ->
                if (offset != null && target != SheetValue.Hidden) {
                    // Any motion or re-anchoring cancels this settling observation.
                    delay(SETTLE_STABILITY_MS)
                    tracker.settledOffset = offset
                    com.rork.vinetrack.data.auth.CleanExitDiagnostics.checkpoint("sheet.offset.settled")
                }
            }
    }
    return sheetState
}

/** Mutable holder read from inside `confirmValueChange` (which is not composable). */
private class SheetDragTracker {
    var readCurrentOffset: () -> Float? = { null }
    var settledOffset: Float? = null
}
