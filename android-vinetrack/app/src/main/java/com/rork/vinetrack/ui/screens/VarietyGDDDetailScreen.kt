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
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.DegreeDayService
import com.rork.vinetrack.data.GddPoint
import com.rork.vinetrack.data.GddResetMode
import com.rork.vinetrack.data.GddSettingsStore
import com.rork.vinetrack.data.OperationPrefsStore
import com.rork.vinetrack.data.model.BuiltInGrapeVarietyGDD
import com.rork.vinetrack.data.model.GrapeVarietyRow
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.canonicalVarietyName
import com.rork.vinetrack.data.model.parseIsoToEpochMs
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * Per-variety GDD detail — mirrors the iOS `VarietyGDDDetailView`. Shows the
 * variety's season-to-date heat accumulation across every block that plants it,
 * a cumulative GDD chart with the optimal target line and projected crossover, a
 * daily-contribution chart, a per-block breakdown and phenology milestones.
 *
 * Reuses the same on-device [DegreeDayService] (Open-Meteo Archive) and BEDD
 * maths as the Optimal Ripeness hub so both surfaces agree exactly.
 */

private data class BlockGddSeries(
    val block: Paddock,
    val points: List<GddPoint>,
    val resetMs: Long,
    val total: Double,
)

private data class VarietyGddResult(
    val sourceConfigured: Boolean,
    val series: List<BlockGddSeries>,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VarietyGDDDetailScreen(
    state: AppUiState,
    variety: GrapeVarietyRow,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val service = remember { DegreeDayService() }
    val opPrefs = remember { OperationPrefsStore(context).load() }
    val gddSettings = remember { GddSettingsStore(context).load() }

    val target = remember(variety) {
        BuiltInGrapeVarietyGDD.resolveTarget(variety.optimalGddOverride, variety.varietyKey, variety.displayName)
    }

    // Blocks that plant this variety (variety-key first, canonical-name fallback).
    val allocatedBlocks = remember(variety, state.paddocks) {
        val canonical = variety.canonicalName
        state.paddocks.filter { paddock ->
            paddock.varietyAllocations.orEmpty().any { a ->
                (a.varietyKey != null && a.varietyKey == variety.varietyKey) ||
                    (a.displayName != null && canonicalVarietyName(a.displayName!!) == canonical)
            }
        }
    }

    val coords: Pair<Double, Double>? = remember(state.selectedVineyardId, state.vineyards, state.paddocks) {
        val v = state.selectedVineyard
        val vLat = v?.latitude
        val vLon = v?.longitude
        if (vLat != null && vLon != null) vLat to vLon
        else state.paddocks.firstNotNullOfOrNull { it.centroid }?.let { it.latitude to it.longitude }
    }

    val seasonStartMs = remember(opPrefs) {
        seasonStartDateMs(opPrefs.seasonStartMonth, opPrefs.seasonStartDay)
    }

    val resultState = produceState<VarietyGddResult?>(
        initialValue = null,
        coords, allocatedBlocks, seasonStartMs,
    ) {
        val c = coords
        if (c == null) {
            value = VarietyGddResult(sourceConfigured = false, series = emptyList())
            return@produceState
        }
        value = null
        service.fetchSeasonOpenMeteo(c.first, c.second, seasonStartMs)
        value = VarietyGddResult(
            sourceConfigured = true,
            series = computeVarietySeries(
                service = service,
                sourceKey = DegreeDayService.openMeteoKey(c.first, c.second),
                latitude = c.first,
                blocks = allocatedBlocks,
                seasonStartMs = seasonStartMs,
                useBEDD = gddSettings.calculationMode.useBEDD,
                resetMode = gddSettings.resetMode,
            ),
        )
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(variety.displayName) },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        val result = resultState.value
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(4.dp))
            val series = result?.series.orEmpty()
            val averageTotal = if (series.isEmpty()) 0.0 else series.sumOf { it.total } / series.size

            VarietyHeaderCard(
                averageTotal = averageTotal,
                target = target,
                series = series,
                loading = result == null,
                sourceConfigured = result?.sourceConfigured == true,
            )

            when {
                result == null -> {
                    Box(modifier = Modifier.fillMaxWidth().height(180.dp), contentAlignment = Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            CircularProgressIndicator(color = VineColors.LeafGreen)
                            Text("Fetching season weather…", color = vine.textSecondary, fontSize = 13.sp)
                        }
                    }
                }
                series.isEmpty() -> {
                    VineyardCard {
                        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(Icons.Filled.WbSunny, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(28.dp))
                            Text("No degree-day data yet", color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                            Text(
                                "Set block budburst dates and a weather station to see the season graph.",
                                color = vine.textSecondary, fontSize = 13.sp,
                            )
                        }
                    }
                }
                else -> {
                    val union = remember(series) { unionPoints(series) }
                    CumulativeChartCard(points = union, target = target)
                    DailyChartCard(points = union)
                    SectionHeader("Blocks", onLight = true)
                    series.forEach { bs -> BlockBreakdownRow(bs, target) }
                    PhenologyMilestonesCard(blocks = allocatedBlocks)
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun VarietyHeaderCard(
    averageTotal: Double,
    target: Double,
    series: List<BlockGddSeries>,
    loading: Boolean,
    sourceConfigured: Boolean,
) {
    val vine = LocalVineColors.current
    val progress = if (target > 0) min(1.0, max(0.0, averageTotal / target)) else 0.0
    val color = progressColorFor(progress)
    val days = projectedDaysToTarget(averageTotal, target, series)

    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (sourceConfigured) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Filled.WbSunny, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(14.dp))
                    Text("GDD source: Open-Meteo archive", color = vine.textSecondary, fontSize = 11.sp, modifier = Modifier.weight(1f))
                    if (loading) CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 1.5.dp, color = VineColors.LeafGreen)
                }
            }
            Row(verticalAlignment = Alignment.Bottom) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Season to date", color = vine.textSecondary, fontSize = 12.sp)
                    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("${averageTotal.toInt()}", color = color, fontSize = 32.sp, fontWeight = FontWeight.Bold)
                        Text("°C·days", color = vine.textSecondary, fontSize = 13.sp, modifier = Modifier.padding(bottom = 4.dp))
                    }
                }
                if (target > 0) {
                    Column(horizontalAlignment = Alignment.End) {
                        Text("Target", color = vine.textSecondary, fontSize = 12.sp)
                        Text("${target.toInt()}", color = vine.textPrimary, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }

            Box(modifier = Modifier.fillMaxWidth().height(10.dp).clip(CircleShape).background(vine.cardBorder)) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(progress.toFloat().coerceIn(0.02f, 1f))
                        .height(10.dp)
                        .clip(CircleShape)
                        .background(Brush.horizontalGradient(listOf(color.copy(alpha = 0.7f), color))),
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("${(progress * 100).toInt()}% of optimal", color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                if (target > 0) {
                    if (averageTotal >= target) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(14.dp))
                            Text("Ready", color = VineColors.LeafGreen, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    } else if (days != null && days > 0) {
                        Text("≈ $days day${if (days == 1) "" else "s"} to target", color = vine.textSecondary, fontSize = 12.sp)
                    }
                }
            }

            val crossover = targetCrossover(unionPoints(series), target, days)
            if (crossover != null) {
                val tint = if (crossover.reached) VineColors.LeafGreen else VineColors.Orange
                Row(
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.1f)).padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        if (crossover.reached) Icons.Filled.Flag else Icons.Filled.CalendarMonth,
                        contentDescription = null, tint = tint, modifier = Modifier.size(20.dp),
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(if (crossover.reached) "Target reached on" else "Projected crossover", color = vine.textSecondary, fontSize = 11.sp)
                        Text(longDate(crossover.dateMs), color = tint, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    }
                    if (target > 0) {
                        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                            Text("at target", color = vine.textSecondary, fontSize = 11.sp)
                            Text("${target.toInt()} GDD", color = vine.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CumulativeChartCard(points: List<GddPoint>, target: Double) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Cumulative GDD", color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            if (points.size < 2) {
                Text("Not enough data to plot.", color = vine.textSecondary, fontSize = 13.sp)
            } else {
                val maxY = max(target, points.last().cumulative).coerceAtLeast(1.0)
                val color = progressColorFor(if (target > 0) points.last().cumulative / target else 0.0)
                val gridColor = vine.cardBorder
                val targetColor = vine.textSecondary
                Canvas(modifier = Modifier.fillMaxWidth().height(200.dp)) {
                    val w = size.width
                    val h = size.height
                    fun x(i: Int): Float = if (points.size <= 1) 0f else w * i / (points.size - 1)
                    fun y(v: Double): Float = (h - (v / maxY * h)).toFloat()

                    // Area + line.
                    val linePath = Path()
                    val areaPath = Path()
                    points.forEachIndexed { i, p ->
                        val px = x(i); val py = y(p.cumulative)
                        if (i == 0) { linePath.moveTo(px, py); areaPath.moveTo(px, h); areaPath.lineTo(px, py) }
                        else { linePath.lineTo(px, py); areaPath.lineTo(px, py) }
                    }
                    areaPath.lineTo(x(points.size - 1), h)
                    areaPath.close()
                    drawPath(areaPath, brush = Brush.verticalGradient(listOf(color.copy(alpha = 0.22f), color.copy(alpha = 0.02f))))
                    drawPath(linePath, color = color, style = Stroke(width = 3f))

                    // Target rule line.
                    if (target > 0 && target <= maxY) {
                        val ty = y(target)
                        drawLine(
                            color = targetColor,
                            start = Offset(0f, ty),
                            end = Offset(w, ty),
                            strokeWidth = 1.5f,
                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 10f)),
                        )
                    }
                }
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(shortDate(points.first().epochDayMs), color = vine.textSecondary, fontSize = 11.sp)
                    if (target > 0) Text("Target ${target.toInt()}", color = vine.textSecondary, fontSize = 11.sp)
                    Text(shortDate(points.last().epochDayMs), color = vine.textSecondary, fontSize = 11.sp)
                }
            }
        }
    }
}

@Composable
private fun DailyChartCard(points: List<GddPoint>) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Daily contribution", color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Text("°C·days / day", color = vine.textSecondary, fontSize = 11.sp)
            }
            if (points.isEmpty()) {
                Text("No daily data.", color = vine.textSecondary, fontSize = 13.sp)
            } else {
                val maxDaily = points.maxOf { it.daily }.coerceAtLeast(0.1)
                val reported = progressColorFor(0.5)
                val estimated = vine.textSecondary.copy(alpha = 0.5f)
                Canvas(modifier = Modifier.fillMaxWidth().height(120.dp)) {
                    val w = size.width
                    val h = size.height
                    val n = points.size
                    val slot = w / n
                    val barW = (slot * 0.7f).coerceAtLeast(1f)
                    points.forEachIndexed { i, p ->
                        val bh = (p.daily / maxDaily * h).toFloat()
                        val left = i * slot + (slot - barW) / 2f
                        drawRect(
                            color = if (p.interpolated) estimated else reported.copy(alpha = 0.8f),
                            topLeft = Offset(left, h - bh),
                            size = androidx.compose.ui.geometry.Size(barW, bh),
                        )
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    LegendDot(reported.copy(alpha = 0.8f), "Reported")
                    LegendDot(estimated, "Estimated")
                }
            }
        }
    }
}

@Composable
private fun LegendDot(color: Color, label: String) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(color))
        Text(label, color = vine.textSecondary, fontSize = 11.sp)
    }
}

@Composable
private fun BlockBreakdownRow(series: BlockGddSeries, target: Double) {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(series.block.name, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text("Since ${shortDate(series.resetMs)}", color = vine.textSecondary, fontSize = 11.sp)
            }
            val p = if (target > 0) series.total / target else 0.0
            Text("${series.total.toInt()} GDD", color = progressColorFor(p), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun PhenologyMilestonesCard(blocks: List<Paddock>) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Phenology milestones", color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            if (blocks.isEmpty()) {
                Text("No blocks assigned.", color = vine.textSecondary, fontSize = 13.sp)
            } else {
                blocks.forEach { block ->
                    Column(
                        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(vine.appBackground).padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(block.name, color = vine.textPrimary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Milestone("Budburst", block.budburstDate, Modifier.weight(1f))
                            Milestone("Flowering", block.floweringDate, Modifier.weight(1f))
                            Milestone("Veraison", block.veraisonDate, Modifier.weight(1f))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Milestone(label: String, iso: String?, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    val date = parseIsoToEpochMs(iso)?.let { shortDate(it) }
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, color = vine.textSecondary, fontSize = 11.sp)
        Text(date ?: "—", color = if (date == null) vine.textSecondary else vine.textPrimary, fontSize = 12.sp)
    }
}

// MARK: - Computation

private fun computeVarietySeries(
    service: DegreeDayService,
    sourceKey: String,
    latitude: Double,
    blocks: List<Paddock>,
    seasonStartMs: Long,
    useBEDD: Boolean,
    resetMode: GddResetMode,
): List<BlockGddSeries> {
    val now = System.currentTimeMillis()
    val oneYearAgo = run { val cal = Calendar.getInstance(); cal.timeInMillis = now; cal.add(Calendar.YEAR, -1); cal.timeInMillis }
    val out = mutableListOf<BlockGddSeries>()
    for (block in blocks) {
        val stageMs = when (resetMode) {
            GddResetMode.SEASON_START -> null
            GddResetMode.BUDBURST -> parseIsoToEpochMs(block.budburstDate)
            GddResetMode.FLOWERING -> parseIsoToEpochMs(block.floweringDate)
            GddResetMode.VERAISON -> parseIsoToEpochMs(block.veraisonDate)
        }
        val resetMs = stageMs ?: seasonStartMs
        if (resetMs !in oneYearAgo..now) continue
        val series = service.dailyGddSeries(
            sourceKey = sourceKey,
            fromMs = startOfDayMsLocal(resetMs),
            toMs = startOfDayMsLocal(now),
            latitude = latitude,
            useBEDD = useBEDD,
        )
        if (series.isEmpty()) continue
        out.add(BlockGddSeries(block, series, resetMs, series.last().cumulative))
    }
    return out
}

/** Daily-aligned average cumulative across all block series (mirrors iOS unionPoints). */
private fun unionPoints(series: List<BlockGddSeries>): List<GddPoint> {
    if (series.isEmpty()) return emptyList()
    val longest = series.maxByOrNull { it.points.size }?.points ?: return emptyList()
    val sums = HashMap<Long, Pair<Double, Int>>()
    for (s in series) {
        for (p in s.points) {
            val cur = sums[p.epochDayMs] ?: (0.0 to 0)
            sums[p.epochDayMs] = (cur.first + p.cumulative) to (cur.second + 1)
        }
    }
    return longest.mapNotNull { p ->
        val agg = sums[p.epochDayMs] ?: return@mapNotNull null
        GddPoint(p.epochDayMs, p.daily, agg.first / agg.second, p.interpolated)
    }
}

private fun projectedDaysToTarget(averageTotal: Double, target: Double, series: List<BlockGddSeries>): Int? {
    if (target <= 0) return 0
    if (averageTotal >= target) return 0
    val points = series.firstOrNull()?.points ?: return null
    if (points.size < 14) return null
    val recent = points.takeLast(14)
    val gained = recent.last().cumulative - recent.first().cumulative
    val perDay = gained / max(1, recent.size - 1)
    if (perDay <= 0) return null
    return ceil((target - averageTotal) / perDay).toInt()
}

private data class Crossover(val dateMs: Long, val reached: Boolean)

private fun targetCrossover(points: List<GddPoint>, target: Double, projectedDays: Int?): Crossover? {
    if (target <= 0 || points.size < 2) return null
    for (i in 1 until points.size) {
        val prev = points[i - 1]
        val curr = points[i]
        if (prev.cumulative < target && curr.cumulative >= target) {
            val span = curr.cumulative - prev.cumulative
            val frac = if (span > 0) (target - prev.cumulative) / span else 0.0
            val interval = curr.epochDayMs - prev.epochDayMs
            return Crossover((prev.epochDayMs + interval * frac).toLong(), reached = true)
        }
    }
    val last = points.last()
    if (last.cumulative >= target) return Crossover(last.epochDayMs, reached = true)
    if (projectedDays != null && projectedDays > 0) {
        return Crossover(last.epochDayMs + projectedDays * 24L * 60 * 60 * 1000, reached = false)
    }
    return null
}

private fun progressColorFor(progress: Double): Color = when {
    progress >= 0.98 -> VineColors.LeafGreen
    progress >= 0.9 -> VineColors.Orange
    progress >= 0.4 -> VineColors.Info
    else -> VineColors.Destructive
}

private fun startOfDayMsLocal(time: Long): Long {
    val cal = Calendar.getInstance()
    cal.timeInMillis = time
    cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0); cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
    return cal.timeInMillis
}

private fun seasonStartDateMs(month: Int, day: Int): Long {
    val now = Calendar.getInstance()
    val curMonth = now.get(Calendar.MONTH) + 1
    val curDay = now.get(Calendar.DAY_OF_MONTH)
    val year = now.get(Calendar.YEAR)
    val startYear = if (curMonth > month || (curMonth == month && curDay >= day)) year else year - 1
    val cal = Calendar.getInstance()
    cal.clear()
    cal.set(startYear, month - 1, day, 0, 0, 0)
    return cal.timeInMillis
}

private fun shortDate(ms: Long): String = SimpleDateFormat("d MMM", Locale.getDefault()).format(Date(ms))
private fun longDate(ms: Long): String = SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(ms))
