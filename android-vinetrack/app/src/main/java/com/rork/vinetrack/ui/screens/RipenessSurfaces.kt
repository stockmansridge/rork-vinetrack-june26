package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.DegreeDayService
import com.rork.vinetrack.data.GddPoint
import com.rork.vinetrack.data.GddResetMode
import com.rork.vinetrack.data.GddSettingsStore
import com.rork.vinetrack.data.OperationPrefsStore
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.canonicalVarietyName
import com.rork.vinetrack.data.model.parseIsoToEpochMs
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.util.Calendar
import kotlin.math.max
import kotlin.math.min

/**
 * Lightweight ripeness surfaces shown outside the dedicated Optimal Ripeness hub,
 * mirroring the iOS `RipenessSurfacesViews`:
 *
 *  - [RipenessWatchTile] — Home dashboard tile highlighting the variety closest to
 *    its optimal GDD across allocated blocks, deep-linking into the hub.
 *  - [BlockRipenessChip] — compact per-block chip surfaced in the block detail view
 *    so growers see that block's progress toward its variety's target inline.
 *
 * Both reuse the same Open-Meteo GDD maths as [OptimalRipenessScreen] (shared
 * `internal` helpers) — no new schema, no new fetch path.
 */

private fun ripenessSurfaceColor(progress: Double): Color = when {
    progress >= 0.98 -> VineColors.LeafGreen
    progress >= 0.9 -> VineColors.Orange
    else -> VineColors.Info
}

/** Resolve the GDD source coordinates: vineyard coords, else first mapped block centroid. */
private fun resolveRipenessCoords(state: AppUiState): Pair<Double, Double>? {
    val v = state.selectedVineyard
    val vLat = v?.latitude
    val vLon = v?.longitude
    return if (vLat != null && vLon != null) {
        vLat to vLon
    } else {
        state.paddocks.firstNotNullOfOrNull { it.centroid }?.let { it.latitude to it.longitude }
    }
}

/** Cumulative GDD total and series for a single block, or null when out of range. */
private fun blockGddTotal(
    service: DegreeDayService,
    sourceKey: String,
    latitude: Double,
    block: Paddock,
    seasonStartMs: Long,
    useBEDD: Boolean,
    resetMode: GddResetMode,
): Pair<Double, List<GddPoint>>? {
    val now = System.currentTimeMillis()
    val oneYearAgo = run {
        val cal = Calendar.getInstance(); cal.timeInMillis = now; cal.add(Calendar.YEAR, -1); cal.timeInMillis
    }
    val stageMs = when (resetMode) {
        GddResetMode.SEASON_START -> null
        GddResetMode.BUDBURST -> parseIsoToEpochMs(block.budburstDate)
        GddResetMode.FLOWERING -> parseIsoToEpochMs(block.floweringDate)
        GddResetMode.VERAISON -> parseIsoToEpochMs(block.veraisonDate)
    }
    val resetMs = stageMs ?: seasonStartMs
    if (resetMs !in oneYearAgo..now) return null
    val series = service.dailyGddSeries(
        sourceKey = sourceKey,
        fromMs = startOfDayMs(resetMs),
        toMs = startOfDayMs(now),
        latitude = latitude,
        useBEDD = useBEDD,
    )
    val total = series.lastOrNull()?.cumulative ?: 0.0
    return total to series
}

// MARK: - Home dashboard tile

/** Resolved status for the Home tile's top (closest-to-optimal) variety. */
private data class RipenessTileStatus(
    val varietyName: String,
    val progress: Double,
    val daysToTarget: Int?,
    val blockCount: Int,
)

private sealed interface RipenessTileResult {
    data object NoSource : RipenessTileResult
    data object NoData : RipenessTileResult
    data class Ready(val status: RipenessTileStatus) : RipenessTileResult
}

/**
 * Home "Ripeness Watch" tile — surfaces the variety closest to its optimal GDD
 * across allocated blocks. Tapping opens the full Optimal Ripeness hub.
 */
@Composable
fun RipenessWatchTile(state: AppUiState, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val service = remember { DegreeDayService() }
    val opPrefs = remember { OperationPrefsStore(context).load() }
    val gddSettings = remember { GddSettingsStore(context).load() }
    val coords = remember(state.selectedVineyardId, state.vineyards, state.paddocks) {
        resolveRipenessCoords(state)
    }
    val seasonStartMs = remember(opPrefs) { seasonStartDate(opPrefs.seasonStartMonth, opPrefs.seasonStartDay) }

    val resultState = produceState<RipenessTileResult?>(
        initialValue = null,
        coords,
        state.paddocks,
        state.grapeVarieties,
        seasonStartMs,
    ) {
        val c = coords
        if (c == null) {
            value = RipenessTileResult.NoSource
            return@produceState
        }
        value = null
        service.fetchSeasonOpenMeteo(c.first, c.second, seasonStartMs)
        value = computeTopVariety(
            service = service,
            sourceKey = DegreeDayService.openMeteoKey(c.first, c.second),
            latitude = c.first,
            state = state,
            seasonStartMs = seasonStartMs,
            useBEDD = gddSettings.calculationMode.useBEDD,
            resetMode = gddSettings.resetMode,
        )
    }

    // Hide entirely until we know there is something worth showing, so the Home
    // feed isn't cluttered for vineyards that haven't set up ripeness tracking.
    val result = resultState.value
    if (result == null || result is RipenessTileResult.NoData) return

    VineyardCard(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .clip(RoundedCornerShape(14.dp))
            .clickable { onClick() },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(48.dp).clip(RoundedCornerShape(12.dp)).background(VineColors.Orange.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Thermostat, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(24.dp))
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                when (result) {
                    is RipenessTileResult.Ready -> ReadyTileBody(result.status)
                    is RipenessTileResult.NoSource -> {
                        Text("Ripeness Watch", color = vine.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        Text("Weather source required", color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                        Text(
                            "Add vineyard coordinates or map a block to track GDD and harvest timing.",
                            color = vine.textSecondary, fontSize = 12.sp, maxLines = 2,
                        )
                    }
                    else -> {}
                }
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

@Composable
private fun ReadyTileBody(status: RipenessTileStatus) {
    val vine = LocalVineColors.current
    val color = ripenessSurfaceColor(status.progress)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Ripeness Watch", color = vine.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
        if (status.progress >= 1.0) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(14.dp))
            Text("Ready", color = VineColors.LeafGreen, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
    }
    Text(
        "${status.varietyName} — ${(status.progress * 100).toInt()}% of optimal",
        color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
    )
    Box(
        modifier = Modifier.fillMaxWidth().height(5.dp).clip(CircleShape).background(vine.cardBorder),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(status.progress.toFloat().coerceIn(0.02f, 1f))
                .height(5.dp)
                .clip(CircleShape)
                .background(Brush.horizontalGradient(listOf(color.copy(alpha = 0.7f), color))),
        )
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        val days = status.daysToTarget
        when {
            days != null && days > 0 -> {
                Icon(Icons.Filled.CalendarMonth, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(13.dp))
                Text("Est. ripeness: $days day${if (days == 1) "" else "s"}", color = vine.textSecondary, fontSize = 11.sp)
            }
            status.progress >= 1.0 -> Text("Target reached — review harvest plan", color = VineColors.LeafGreen, fontSize = 11.sp)
            else -> Text("Not enough recent data to project", color = vine.textSecondary, fontSize = 11.sp)
        }
    }
}

private fun computeTopVariety(
    service: DegreeDayService,
    sourceKey: String,
    latitude: Double,
    state: AppUiState,
    seasonStartMs: Long,
    useBEDD: Boolean,
    resetMode: GddResetMode,
): RipenessTileResult {
    data class Acc(val name: String, val target: Double, val totals: MutableList<Pair<Double, List<GddPoint>>>)
    val groups = LinkedHashMap<String, Acc>()
    // Cache per-block totals so blocks with multiple varieties only fetch once.
    val blockCache = HashMap<String, Pair<Double, List<GddPoint>>?>()

    for (block in state.paddocks) {
        val allocations = block.varietyAllocations.orEmpty()
        if (allocations.isEmpty()) continue
        val bt = blockCache.getOrPut(block.id) {
            blockGddTotal(service, sourceKey, latitude, block, seasonStartMs, useBEDD, resetMode)
        } ?: continue
        for (alloc in allocations) {
            val target = resolveTargetForAllocationList(alloc.varietyKey, alloc.displayName, state.grapeVarieties)
            if (target <= 0) continue
            val name = alloc.displayName ?: alloc.varietyKey ?: continue
            val key = alloc.varietyKey ?: canonicalVarietyName(name)
            groups.getOrPut(key) { Acc(name, target, mutableListOf()) }.totals.add(bt)
        }
    }

    val candidates = groups.values.mapNotNull { acc ->
        if (acc.totals.isEmpty()) return@mapNotNull null
        val avg = acc.totals.map { it.first }.average()
        val progress = min(1.0, max(0.0, avg / acc.target))
        val longest = acc.totals.maxByOrNull { it.second.size }?.second ?: emptyList()
        val days = daysToTarget(avg, acc.target, recentDailyRate(longest))
        RipenessTileStatus(acc.name, progress, days, acc.totals.size)
    }
    val top = candidates.maxByOrNull { it.progress } ?: return RipenessTileResult.NoData
    return RipenessTileResult.Ready(top)
}

// MARK: - Block detail chip

/**
 * Compact ripeness chip for a single block's primary (highest-allocation) variety,
 * shown inline in the block detail view. Mirrors iOS `BlockRipenessChip`.
 */
@Composable
fun BlockRipenessChip(state: AppUiState, block: Paddock, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val service = remember { DegreeDayService() }
    val opPrefs = remember { OperationPrefsStore(context).load() }
    val gddSettings = remember { GddSettingsStore(context).load() }
    val coords = remember(state.selectedVineyardId, state.vineyards, state.paddocks) {
        resolveRipenessCoords(state)
    }
    val seasonStartMs = remember(opPrefs) { seasonStartDate(opPrefs.seasonStartMonth, opPrefs.seasonStartDay) }

    val primary = remember(block.varietyAllocations) {
        block.varietyAllocations.orEmpty().maxByOrNull { it.displayPercent ?: 0.0 }
    }

    val target = remember(primary, state.grapeVarieties) {
        primary?.let { resolveTargetForAllocationList(it.varietyKey, it.displayName, state.grapeVarieties) } ?: 0.0
    }

    val resultState = produceState<RipenessChipState?>(
        initialValue = null,
        coords, block.id, target, seasonStartMs,
    ) {
        if (primary == null || target <= 0) {
            value = RipenessChipState.Caveat(if (primary == null) "Allocate a variety to track ripeness" else "Add a GDD target for this variety")
            return@produceState
        }
        val c = coords
        if (c == null) {
            value = RipenessChipState.Caveat("Add vineyard coordinates to project ripeness")
            return@produceState
        }
        value = null
        service.fetchSeasonOpenMeteo(c.first, c.second, seasonStartMs)
        val bt = blockGddTotal(
            service, DegreeDayService.openMeteoKey(c.first, c.second), c.first,
            block, seasonStartMs, gddSettings.calculationMode.useBEDD, gddSettings.resetMode,
        )
        value = if (bt == null) {
            RipenessChipState.Caveat("Insufficient season data to project ripeness")
        } else {
            val progress = min(1.0, max(0.0, bt.first / target))
            RipenessChipState.Ready(
                varietyName = primary.displayName ?: primary.varietyKey ?: "Variety",
                total = bt.first,
                target = target,
                progress = progress,
                daysToTarget = daysToTarget(bt.first, target, recentDailyRate(bt.second)),
            )
        }
    }

    val result = resultState.value ?: return
    val clickMod = if (onClick != null) Modifier.clickable { onClick() } else Modifier
    VineyardCard(modifier = modifier.then(clickMod)) {
        when (result) {
            is RipenessChipState.Caveat -> Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Filled.Info, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
                Text("Ripeness: ${result.message}", color = vine.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
                if (onClick != null) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
            }
            is RipenessChipState.Ready -> {
                val color = ripenessSurfaceColor(result.progress)
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Filled.Thermostat, contentDescription = null, tint = color, modifier = Modifier.size(15.dp))
                        Text("Ripeness", color = vine.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        if (result.progress >= 1.0) {
                            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(14.dp))
                            Text("Ready", color = VineColors.LeafGreen, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                        } else {
                            Text("${(result.progress * 100).toInt()}% of optimal", color = color, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                        }
                        if (onClick != null) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(14.dp))
                    }
                    Box(
                        modifier = Modifier.fillMaxWidth().height(5.dp).clip(CircleShape).background(vine.cardBorder),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(result.progress.toFloat().coerceIn(0.02f, 1f))
                                .height(5.dp)
                                .clip(CircleShape)
                                .background(Brush.horizontalGradient(listOf(color.copy(alpha = 0.7f), color))),
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("${result.total.toInt()} / ${result.target.toInt()} GDD", color = vine.textSecondary, fontSize = 11.sp, modifier = Modifier.weight(1f))
                        val days = result.daysToTarget
                        if (days != null && days > 0) {
                            Icon(Icons.Filled.CalendarMonth, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(13.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("≈$days day${if (days == 1) "" else "s"}", color = vine.textSecondary, fontSize = 11.sp)
                        }
                    }
                }
            }
        }
    }
}

private sealed interface RipenessChipState {
    data class Caveat(val message: String) : RipenessChipState
    data class Ready(
        val varietyName: String,
        val total: Double,
        val target: Double,
        val progress: Double,
        val daysToTarget: Int?,
    ) : RipenessChipState
}
