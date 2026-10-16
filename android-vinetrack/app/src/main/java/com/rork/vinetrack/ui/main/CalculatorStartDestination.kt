package com.rork.vinetrack.ui.main

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel

/** Re-deliver the existing Start result after a disposed callback; selection is idempotent, never activation. */
@Composable
fun CalculatorStartDestination(vm: AppViewModel, state: AppUiState, work: WorkContextViewModel) {
    val outcome by vm.calculatorStartOutcome.collectAsStateWithLifecycle()
    LaunchedEffect(outcome, state.currentUserId, state.selectedVineyardId) {
        val result = outcome ?: return@LaunchedEffect
        val id = result.tripId ?: return@LaunchedEffect
        if (result.isStarted && result.ownerId == state.currentUserId && result.vineyardId == state.selectedVineyardId) {
            work.openCalculatorTrip(id)
        }
    }
}
