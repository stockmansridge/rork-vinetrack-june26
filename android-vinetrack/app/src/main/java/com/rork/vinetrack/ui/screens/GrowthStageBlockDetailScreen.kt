package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.LocalRegionFormatter
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val growthMilestones = listOf(4, 12, 19, 27, 35)
private val stageGreen = Color(0xFF0D5736)

internal fun growthCode(record: GrowthStageRecord): String = "EL${record.stageCode.filter(Char::isDigit)}"

internal fun growthStageName(stage: GrowthStage): String = when (stage.code) {
    "EL4" -> "Budburst"
    "EL12" -> "Shoots"
    "EL19", "EL23" -> "Flowering"
    "EL27" -> "Fruit Set"
    "EL35" -> "Veraison"
    else -> stage.description.substringBefore(';')
}

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
    val fmt = LocalRegionFormatter.current
    var viewingAll by remember { mutableStateOf(false) }
    BackHandler(enabled = viewingAll) { viewingAll = false }
    if (viewingAll) {
        GrowthStageHistoryScreen(vm, state, blockName, records, onBack = { viewingAll = false }, modifier = modifier)
        return
    }
    val currentCode = currentEl?.takeIf { it == it.toInt().toDouble() }?.let { "EL${it.toInt()}" }
    val currentStage = GrowthStage.byCode(currentCode)
    val currentRecord = records.filter { growthCode(it) == currentCode }.maxByOrNull { it.observedEpochMs ?: 0L }
    val firstDates = remember(records) {
        records.mapNotNull { record -> record.observedEpochMs?.let { growthCode(record) to it } }
            .groupBy({ it.first }, { it.second }).mapValues { (_, dates) -> dates.min() }
    }
    val seasonalStages = remember(firstDates, currentCode) {
        val codes = growthMilestones.map { "EL$it" }.toSet() + firstDates.keys + listOfNotNull(currentCode)
        GrowthStage.allStages.filter { it.code in codes }
    }
    val shortDate = remember(state.seasonZone) {
        SimpleDateFormat("d MMM", Locale.getDefault()).apply { timeZone = java.util.TimeZone.getTimeZone(state.seasonZone) }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(blockName) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Growth Stage", fontSize = 30.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Text(blockName, fontSize = 14.sp, color = vine.textSecondary)
            }
            Column(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp))
                    .background(vine.cardBackground).padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    growthMilestones.forEach { number ->
                        val stage = GrowthStage.byCode("EL$number")
                        Column(
                            modifier = Modifier.weight(1f),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(5.dp),
                        ) {
                            StageReferenceImage(vm, state, "EL$number", Modifier.size(52.dp))
                            Text(
                                stage?.let(::growthStageName) ?: "Stage", fontSize = 10.sp,
                                fontWeight = FontWeight.SemiBold, color = vine.textPrimary,
                                maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
                            )
                            Text("E-L $number", fontSize = 10.sp, color = vine.textSecondary)
                        }
                    }
                }
                val activeMilestone = growthMilestones.lastOrNull { it <= (currentEl ?: -1.0) }
                Row(
                    modifier = Modifier.fillMaxWidth().semantics {
                        contentDescription = currentEl?.let { "Current stage ${ElRipenessHeatmap.formatEl(it)}" } ?: "No current stage"
                    },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    growthMilestones.forEachIndexed { index, number ->
                        val active = number == activeMilestone
                        Box(
                            Modifier.size(if (active) 20.dp else 14.dp)
                                .border(if (active) 3.dp else 1.dp, stageGreen, CircleShape)
                                .background(
                                    if (active) stageGreen else if ((currentEl ?: -1.0) >= number) stageGreen.copy(alpha = 0.16f) else vine.appBackground,
                                    CircleShape,
                                ),
                        )
                        if (index < growthMilestones.lastIndex) {
                            Box(
                                Modifier.weight(1f).height(2.dp).background(
                                    if ((currentEl ?: -1.0) >= growthMilestones[index + 1]) stageGreen else stageGreen.copy(alpha = 0.2f),
                                ),
                            )
                        }
                    }
                }
            }
            Column(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp))
                    .background(vine.cardBackground).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Current Growth Stage", fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
                    TextButton(onClick = onUpdate) { Text("Update Stage ›", color = stageGreen) }
                }
                if (currentEl != null) {
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        currentStage?.let { StageReferenceImage(vm, state, it.code, Modifier.size(128.dp)) }
                        Column(verticalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.weight(1f)) {
                            Text(currentStage?.let(::growthStageName) ?: "Growth Stage", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                            Text(ElRipenessHeatmap.formatEl(currentEl), fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                            currentStage?.let { Text(it.description, fontSize = 12.sp, color = vine.textSecondary) }
                            currentRecord?.observedEpochMs?.let { Text("Recorded ${fmt.formatDate(it)}", fontSize = 12.sp, color = vine.textSecondary) }
                        }
                    }
                    currentRecord?.notes?.takeIf(String::isNotBlank)?.let { Text(it, fontSize = 12.sp, color = vine.textSecondary) }
                } else {
                    Text("No eligible recent observation for this block and vintage.", color = vine.textSecondary)
                }
                Button(onClick = onUpdate, modifier = Modifier.fillMaxWidth()) { Text("Capture Growth Stage") }
            }
            Column(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp))
                    .background(vine.cardBackground).padding(vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Seasonal Development", fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
                    TextButton(onClick = { viewingAll = true }) { Text("View All ›", color = stageGreen) }
                }
                if (records.isEmpty()) {
                    Text("No observations recorded for this block this vintage.", fontSize = 12.sp, color = vine.textSecondary, modifier = Modifier.padding(horizontal = 16.dp))
                }
                val listState = rememberLazyListState()
                BoxWithConstraints(Modifier.fillMaxWidth()) {
                    val sidePadding = ((maxWidth - 82.dp) / 2).coerceAtLeast(16.dp)
                    val widthPx = with(LocalDensity.current) { maxWidth.roundToPx() }
                    LaunchedEffect(currentCode, seasonalStages, widthPx) {
                        val index = seasonalStages.indexOfFirst { it.code == currentCode }
                        if (index >= 0) {
                            listState.scrollToItem(index)
                            val item = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.index == index }
                            if (item != null) {
                                listState.scrollBy((item.offset + item.size / 2 - widthPx / 2).toFloat())
                            }
                        }
                    }
                    LazyRow(
                        state = listState,
                        contentPadding = PaddingValues(horizontal = sidePadding),
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        items(seasonalStages, key = { it.code }) { stage ->
                            Column(
                                modifier = Modifier.width(82.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(5.dp),
                            ) {
                                Box(
                                    modifier = Modifier.size(82.dp)
                                        .then(if (stage.code == currentCode) Modifier.border(2.dp, stageGreen, RoundedCornerShape(14.dp)) else Modifier)
                                        .padding(3.dp),
                                ) {
                                    StageReferenceImage(vm, state, stage.code, Modifier.fillMaxSize())
                                }
                                Text(stage.code.replace("EL", "E-L "), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                                val date = firstDates[stage.code]?.let { shortDate.format(Date(it)) } ?: "—"
                                Text(date, fontSize = 11.sp, color = vine.textSecondary)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

/** Uses the vineyard's custom photo first, then the bundled E-L reference image. */
@Composable
internal fun StageReferenceImage(vm: AppViewModel, state: AppUiState, code: String, modifier: Modifier = Modifier) {
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
        Box(modifier = modifier.clip(RoundedCornerShape(10.dp)).background(VineColors.LeafGreen.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Spa, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(22.dp))
        }
    }
}
