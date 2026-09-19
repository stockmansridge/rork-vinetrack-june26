package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import java.util.Calendar
import java.util.TimeZone

/** Canonical block result consumed by every Android Optimal Ripeness surface. */
data class OptimalRipenessBlockCalculation(
    val resetDateMs: Long?,
    val points: List<GddPoint>,
    val total: Double,
    val hasValue: Boolean,
    val isIncomplete: Boolean,
)

/**
 * Applies the vineyard defaults, valid block overrides, authoritative milestone,
 * and vineyard-calendar boundaries in one calculation contract.
 */
fun calculateOptimalRipenessBlock(
    service: DegreeDayService,
    sourceKey: String,
    latitude: Double,
    block: Paddock,
    seasonStartMs: Long,
    globalResetMode: GddResetMode,
    globalCalculationMode: GddCalculationMode,
    timeZone: TimeZone,
    nowMs: Long = System.currentTimeMillis(),
): OptimalRipenessBlockCalculation {
    val resetMode = block.effectiveResetMode(globalResetMode)
    val calculationMode = block.effectiveCalculationMode(globalCalculationMode)
    val resetMs = block.resetDateMs(resetMode, seasonStartMs)
    val oneYearAgo = Calendar.getInstance(timeZone).run {
        timeInMillis = nowMs
        add(Calendar.YEAR, -1)
        timeInMillis
    }
    if (resetMs == null || resetMs !in oneYearAgo..nowMs) {
        return OptimalRipenessBlockCalculation(
            resetMs?.takeIf { it in oneYearAgo..nowMs }, emptyList(), 0.0, false, false,
        )
    }
    val fromMs = optimalRipenessStartOfDay(resetMs, timeZone)
    val toMs = optimalRipenessStartOfDay(nowMs, timeZone)
    if (!service.hasUsableData(sourceKey, fromMs, toMs)) {
        return OptimalRipenessBlockCalculation(resetMs, emptyList(), 0.0, false, false)
    }
    val points = service.dailyGddSeries(
        sourceKey = sourceKey,
        fromMs = fromMs,
        toMs = toMs,
        latitude = latitude,
        useBEDD = calculationMode.useBEDD,
    )
    val isIncomplete = !service.hasCompleteData(sourceKey, fromMs, toMs) || points.any { it.interpolated }
    return OptimalRipenessBlockCalculation(
        resetMs, points, points.lastOrNull()?.cumulative ?: 0.0, true, isIncomplete,
    )
}

/** Vineyard-local start-of-day boundary used by weather planning and calculation. */
fun optimalRipenessStartOfDay(timeMs: Long, timeZone: TimeZone): Long {
    val calendar = Calendar.getInstance(timeZone)
    calendar.timeInMillis = timeMs
    calendar.set(Calendar.HOUR_OF_DAY, 0)
    calendar.set(Calendar.MINUTE, 0)
    calendar.set(Calendar.SECOND, 0)
    calendar.set(Calendar.MILLISECOND, 0)
    return calendar.timeInMillis
}
