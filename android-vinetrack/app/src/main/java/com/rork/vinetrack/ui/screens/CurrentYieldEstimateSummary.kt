package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import com.rork.vinetrack.data.VintageResolver
import java.time.LocalDate
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.CurrentYieldEstimate
import com.rork.vinetrack.data.YieldMasterWeight
import com.rork.vinetrack.data.YieldMasterWeightRepository
import com.rork.vinetrack.data.YieldVintageReport
import com.rork.vinetrack.data.model.YieldEstimationSession
import com.rork.vinetrack.data.remainingYieldMultiplierForVintage
import com.rork.vinetrack.ui.AppUiState
import java.util.Locale

@Composable
internal fun rememberYieldMasterWeights(state: AppUiState, refreshToken: Int = 0): Map<String, YieldMasterWeight> {
    val context = LocalContext.current
    val repository = remember { YieldMasterWeightRepository.get(context) }
    val epoch by repository.session.retentionGuard.identityEpoch.collectAsState()
    val locked by repository.session.retentionGuard.state.collectAsState()
    val scope = "${repository.session.userId}/${state.selectedVineyardId}/$epoch/$locked"
    val vineyard = state.selectedVineyardId
    var weights by remember(scope) { mutableStateOf(if (vineyard == null) emptyMap() else repository.cached(vineyard)) }
    val cacheRevision by repository.changes.collectAsState()
    // Cache publications from full Sync/management update visible estimates;
    // observing them must not start another network fetch loop.
    LaunchedEffect(scope, cacheRevision) {
        weights = if (vineyard == null || locked) emptyMap() else repository.cached(vineyard)
    }
    LaunchedEffect(scope, state.paddocks, refreshToken) {
        if (vineyard != null && !locked) weights = repository.refresh(vineyard, state.paddocks)
    }
    return if (locked) emptyMap() else weights
}

@Composable
internal fun currentYieldTrip(state: AppUiState, session: YieldEstimationSession, refreshToken: Int = 0): CurrentYieldEstimate.Trip {
    val weights = rememberYieldMasterWeights(state, refreshToken)
    val vintage = YieldVintageReport.sessionVintage(session, state.seasonStartMonth, state.seasonStartDay)
    return CurrentYieldEstimate.trip(session, state.paddocks, weights) { block ->
        state.damageRecords.remainingYieldMultiplierForVintage(block, state.paddocks, vintage, state.seasonStartMonth, state.seasonStartDay)
    }
}

@Composable
internal fun CurrentTripEstimateSummary(state: AppUiState, session: YieldEstimationSession, detailed: Boolean = true, current: Boolean = false) {
    var refresh by remember { mutableIntStateOf(0) }
    YieldMasterWeightSyncNotice(state)
    CurrentYieldEstimateSummary(currentYieldTrip(state, session, refresh), detailed, current || isCurrentYieldTrip(state, session))
    TextButton(onClick = { refresh++ }) { Text("Refresh shared bunch weights") }
}

@Composable
internal fun YieldMasterWeightSyncNotice(state: AppUiState) {
    val context = LocalContext.current
    val repository = remember { YieldMasterWeightRepository.get(context) }
    val revision by repository.changes.collectAsState()
    val locked by repository.session.retentionGuard.state.collectAsState()
    val warning = remember(revision, state.selectedVineyardId, state.currentUserId, locked) {
        if (locked) null else state.selectedVineyardId?.let(repository::syncError)
    }
    warning?.let { Text(it, fontSize = 12.sp) }
}

internal fun isCurrentYieldTrip(state: AppUiState, session: YieldEstimationSession): Boolean {
    val vintage = VintageResolver.vintageYear(LocalDate.now(), state.seasonStartMonth, state.seasonStartDay)
    return session.isCompleted && session.selectedPaddockIds.any { block ->
        YieldVintageReport.latestCompletedSessionForBlock(state.yieldSessions.filter { it.vineyardId.equals(session.vineyardId, true) },
            block, vintage, state.seasonStartMonth, state.seasonStartDay)?.id == session.id
    }
}

@Composable
internal fun CurrentYieldEstimateSummary(estimate: CurrentYieldEstimate.Trip, detailed: Boolean = true, current: Boolean = false) {
    fun number(value: Double) = String.format(Locale.US, "%.3f", value)
    fun tonnes(value: Double?) = value?.let { "${number(it)} t" } ?: "Bunch weight required"
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        estimate.countMethod?.let { Text(it, fontWeight = FontWeight.SemiBold) }
        if (current) Text("Current Estimate", fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        estimate.blocks.forEach { block ->
            Text(block.name, fontWeight = FontWeight.SemiBold)
            Text(block.varieties.ifBlank { "Variety not configured" }, fontSize = 12.sp)
            Text("${block.samplesRecorded}/${block.samplesTotal} samples · ${block.averageBunches?.let(::number) ?: "—"} bunches/vine · ${block.vines} vines", fontSize = 12.sp)
            Text(block.weightKg?.let { "Current bunch weight ${number(it * 1000)} g" } ?: "Bunch weight not set", fontSize = 12.sp)
            block.weightSources.forEach { Text(it, fontSize = 11.sp) }
            Text(if (block.samplesRecorded == 0) "Not sampled" else if (block.averageBunches == null) "Recorded counts need review" else tonnes(block.displayTonnes), fontWeight = FontWeight.SemiBold)
            block.tonnesPerHa?.let { Text("${number(it)} t/ha", fontSize = 12.sp) }
            if (detailed) {
                Text("Sampled area ${number(block.sampledAreaHa)} ha", fontSize = 12.sp)
                if (block.baseTonnes != null && block.adjustedTonnes != null) Text("Base ${tonnes(block.baseTonnes)} · damage adjusted ${tonnes(block.adjustedTonnes)}", fontSize = 12.sp)
                block.historicalWeightKg?.let { Text("Historical trip weight ${number(it * 1000)} g — not current authority", fontSize = 11.sp) }
            }
        }
        Text("Trip estimate: ${tonnes(estimate.totalTonnes)}", fontWeight = FontWeight.SemiBold)
        Text("Sampled area ${number(estimate.sampledAreaHa)} ha", fontSize = 12.sp)
        estimate.tonnesPerHa?.let { Text("Per ha ${number(it)} t/ha", fontSize = 12.sp) }
    }
}
