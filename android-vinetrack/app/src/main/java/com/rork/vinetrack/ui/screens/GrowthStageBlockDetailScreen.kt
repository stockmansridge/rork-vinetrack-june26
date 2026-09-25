package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GrowthStageBlockDetailScreen(
    vm: AppViewModel,
    state: AppUiState,
    blockName: String,
    currentEl: Double?,
    records: List<GrowthStageRecord>,
    onBack: () -> Unit,
    onUpdate: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val current = records.filter { it.stageCode.filter(Char::isDigit).toDoubleOrNull() == currentEl }
        .maxByOrNull { it.observedEpochMs ?: 0L }
    val currentStage = currentEl?.let { el -> GrowthStage.allStages.firstOrNull { it.code.drop(2).toDoubleOrNull() == el } }
    val rgb = currentEl?.let(ElRipenessHeatmap::elColour)
    val tint = rgb?.let { Color(it.r, it.g, it.b) } ?: VineColors.LeafGreen

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Growth Stage") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(blockName, fontSize = 24.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Row(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                    .background(vine.cardBackground).horizontalScroll(rememberScrollState()).padding(14.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                listOf("EL4", "EL12", "EL23", "EL27", "EL35").forEach { code ->
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        StageReferenceImage(vm, state, code, Modifier.size(70.dp))
                        Text(code, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                    }
                }
            }
            Column(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                    .background(vine.cardBackground).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Current Growth Stage", fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                if (currentEl != null) {
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        currentStage?.let { StageReferenceImage(vm, state, it.code, Modifier.size(108.dp)) }
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(ElRipenessHeatmap.formatEl(currentEl), fontSize = 24.sp, fontWeight = FontWeight.Bold, color = tint)
                            currentStage?.let { Text(it.description, fontSize = 13.sp, color = vine.textPrimary) }
                            current?.observedAt?.take(10)?.let { Text("Recorded $it", fontSize = 12.sp, color = vine.textSecondary) }
                            current?.notes?.takeIf(String::isNotBlank)?.let { Text(it, fontSize = 12.sp, color = vine.textSecondary) }
                        }
                    }
                } else {
                    Text("No eligible recent observation for this block and vintage.", color = vine.textSecondary)
                }
                Button(onClick = onUpdate, modifier = Modifier.fillMaxWidth()) { Text("Update Stage") }
            }
            Column(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp))
                    .background(vine.cardBackground).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Seasonal Development", fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                if (records.isEmpty()) Text("No observations recorded for this block this vintage.", color = vine.textSecondary)
                records.sortedBy { it.observedEpochMs ?: 0L }.forEach { record ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        StageReferenceImage(vm, state, record.stageCode.filter(Char::isDigit).let { "EL$it" }, Modifier.size(48.dp))
                        Column {
                            Text(record.stageCode, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            record.observedAt?.take(10)?.let { Text(it, fontSize = 12.sp, color = vine.textSecondary) }
                        }
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun StageReferenceImage(vm: AppViewModel, state: AppUiState, code: String, modifier: Modifier = Modifier) {
    val image = state.growthStageImages.firstOrNull { it.stageCode == code && it.deletedAt == null }
    var url by remember(image?.imagePath) { mutableStateOf<String?>(null) }
    LaunchedEffect(image?.imagePath) {
        url = null
        image?.imagePath?.let { vm.requestGrowthStageImageUrl(it) { resolved -> url = resolved } }
    }
    val model: Any? = url ?: GrowthStageBundledImages.resFor(code)
    if (model != null) {
        AsyncImage(
            model = model,
            contentDescription = "$code reference image",
            contentScale = ContentScale.Crop,
            modifier = modifier.clip(RoundedCornerShape(10.dp)),
        )
    } else {
        Icon(Icons.Filled.Spa, contentDescription = null, tint = VineColors.LeafGreen, modifier = modifier)
    }
}
