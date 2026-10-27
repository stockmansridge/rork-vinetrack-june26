package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.CurrentYieldEstimate
import com.rork.vinetrack.data.model.YieldEstimationSession
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors

/** Shared server masters are read-only here; device-only defaults are not current authority. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun YieldSettingsScreen(state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val weights = rememberYieldMasterWeights(state)
    Scaffold(modifier = modifier, containerColor = vine.appBackground,
        topBar = { TopAppBar(title = { Text("Yield Settings") }, navigationIcon = { if (onBack != null) BackNavIcon(onBack) }) },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Master Bunch Weights", style = MaterialTheme.typography.titleMedium)
            Text("Shared weights are managed in the Portal. Block overrides take priority over vineyard variety masters. Offline uses only last server-confirmed values for this account and vineyard.")
            state.paddocks.forEach { paddock ->
                val observation = YieldEstimationSession(id = "settings", vineyardId = state.selectedVineyardId ?: "", createdAt = "", selectedPaddockIds = listOf(paddock.id))
                CurrentYieldEstimateSummary(CurrentYieldEstimate.trip(observation, listOf(paddock), weights), detailed = false)
            }
        }
    }
}
