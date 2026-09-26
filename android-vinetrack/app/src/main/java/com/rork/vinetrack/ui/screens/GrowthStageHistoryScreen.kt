package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.LocalRegionFormatter
import com.rork.vinetrack.ui.theme.LocalVineColors

/** Complete observation history for a block in the selected vintage. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GrowthStageHistoryScreen(
    vm: AppViewModel,
    state: AppUiState,
    blockName: String,
    records: List<GrowthStageRecord>,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val fmt = LocalRegionFormatter.current
    val ordered = remember(records) { records.sortedBy { it.observedEpochMs ?: 0L } }
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("$blockName · All Stages") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            if (ordered.isEmpty()) {
                item { Text("Capture a growth stage to start the seasonal history.", color = vine.textSecondary) }
            }
            items(ordered, key = { it.id }) { record ->
                val code = growthCode(record)
                val stage = GrowthStage.byCode(code)
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    StageReferenceImage(vm, state, code, Modifier.size(58.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            code.drop(2).toDoubleOrNull()?.let(ElRipenessHeatmap::formatEl) ?: record.stageCode,
                            fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary,
                        )
                        stage?.let { Text(it.description, fontSize = 14.sp, color = vine.textPrimary) }
                        record.observedEpochMs?.let { Text(fmt.formatDate(it), fontSize = 12.sp, color = vine.textSecondary) }
                        record.notes?.takeIf(String::isNotBlank)?.let { Text(it, fontSize = 12.sp, color = vine.textSecondary) }
                    }
                }
            }
        }
    }
}
