package com.rork.vinetrack.data

import java.util.Calendar

/** Risk severity tier. Mirrors the iOS `AlertSeverity` used by disease models. */
enum class DiseaseSeverity { LOW, MEDIUM, HIGH }

/** The three supported disease models. */
enum class DiseaseModel(val displayName: String) {
    DOWNY_MILDEW("Downy mildew"),
    POWDERY_MILDEW("Powdery mildew"),
    BOTRYTIS("Botrytis"),
}

/**
 * The result of assessing a single disease model. `severity` of [DiseaseSeverity.LOW]
 * means no actionable risk. `breakdown` carries the "why this risk" key/value pairs.
 */
data class DiseaseRiskAssessment(
    val model: DiseaseModel,
    val severity: DiseaseSeverity,
    val title: String,
    val summary: String,
    val breakdown: List<Pair<String, String>>,
) {
    /** Numeric index used for the 7-day chart and badges (10 / 60 / 90). */
    val score: Int
        get() = when (severity) {
            DiseaseSeverity.LOW -> 10
            DiseaseSeverity.MEDIUM -> 60
            DiseaseSeverity.HIGH -> 90
        }
}

/**
 * Pure disease-pressure models ported 1:1 from the iOS `DiseaseRiskCalculator`.
 *
 * The wetness signal is an estimated proxy (see [WeatherHour.isWetHour]). The
 * models are intentionally simplified versions of well-known viticulture rules
 * so they stay useful with widely available forecast data. Growth stage, spray
 * history and variety susceptibility are NOT applied, matching the iOS MVP.
 */
object DiseaseRiskCalculator {

    fun assess(hours: List<WeatherHour>, now: Long = System.currentTimeMillis()): List<DiseaseRiskAssessment> {
        if (hours.isEmpty()) return emptyList()
        return listOf(
            downyMildew(hours, now),
            powderyMildew(hours, now),
            botrytis(hours, now),
        )
    }

    private const val HOUR_MS = 3_600_000L

    // MARK: - Downy mildew (simplified 10:10:24 rule)
    /** Risk when the past 48h shows >=10mm rain, min temp >=10°C and >=10 wet hours. */
    fun downyMildew(hours: List<WeatherHour>, now: Long = System.currentTimeMillis()): DiseaseRiskAssessment {
        val window = hours.filter { it.epochMs in (now - 48 * HOUR_MS)..now }
        if (window.isEmpty()) {
            return DiseaseRiskAssessment(
                DiseaseModel.DOWNY_MILDEW, DiseaseSeverity.LOW, "Downy mildew",
                "Insufficient hourly data to assess.", emptyList(),
            )
        }
        val rain = window.sumOf { it.precipitationMm }
        val minTemp = window.minOf { it.temperatureC }
        val wetHours = window.count { it.isWetHour }

        var severity = DiseaseSeverity.LOW
        if (rain >= 10 && minTemp >= 10 && wetHours >= 10) {
            severity = DiseaseSeverity.MEDIUM
            if (rain >= 20 && wetHours >= 18) severity = DiseaseSeverity.HIGH
        }

        val summary = String.format(
            java.util.Locale.US,
            "Past 48h: %.1f mm rain, min %.1f°C, %d estimated wet hours.",
            rain, minTemp, wetHours,
        )
        return DiseaseRiskAssessment(
            DiseaseModel.DOWNY_MILDEW, severity, "Downy mildew risk", summary,
            listOf(
                "Rain past 48h" to String.format(java.util.Locale.US, "%.1f mm", rain),
                "Min temperature" to String.format(java.util.Locale.US, "%.1f°C", minTemp),
                "Wet hours" to "$wetHours h",
                "Wetness source" to "Estimated",
            ),
        )
    }

    // MARK: - Powdery mildew (simplified Gubler-Thomas style)
    /** Counts days in the past 72h with >=6 consecutive favourable hours (21–30°C, RH >= 60%). */
    fun powderyMildew(hours: List<WeatherHour>, now: Long = System.currentTimeMillis()): DiseaseRiskAssessment {
        val window = hours.filter { it.epochMs in (now - 72 * HOUR_MS)..now }
        if (window.isEmpty()) {
            return DiseaseRiskAssessment(
                DiseaseModel.POWDERY_MILDEW, DiseaseSeverity.LOW, "Powdery mildew",
                "Insufficient hourly data to assess.", emptyList(),
            )
        }

        val cal = Calendar.getInstance()
        val byDay = window.groupBy { startOfDay(cal, it.epochMs) }
        var favourableDays = 0
        for ((_, dayHours) in byDay) {
            val sorted = dayHours.sortedBy { it.epochMs }
            var run = 0
            var maxRun = 0
            for (h in sorted) {
                val humidOK = (h.humidityPercent ?: 0.0) >= 60
                val tempOK = h.temperatureC in 21.0..30.0
                if (humidOK && tempOK) {
                    run += 1
                    maxRun = maxOf(maxRun, run)
                } else {
                    run = 0
                }
            }
            if (maxRun >= 6) favourableDays += 1
        }

        var severity = DiseaseSeverity.LOW
        if (favourableDays >= 3) severity = DiseaseSeverity.MEDIUM
        if (favourableDays >= 3 && (window.last().temperatureC) >= 25) {
            severity = DiseaseSeverity.HIGH
        }

        val summary = "$favourableDays of last 3 days had 6+ favourable hours (21–30°C, RH ≥ 60%)."
        return DiseaseRiskAssessment(
            DiseaseModel.POWDERY_MILDEW, severity, "Powdery mildew risk", summary,
            listOf(
                "Days with 6+ favourable hours" to "$favourableDays of last 3",
                "Favourable temperature" to "21–30°C",
                "RH threshold" to "≥ 60%",
            ),
        )
    }

    // MARK: - Botrytis (Broome/Bulit style simplified)
    /** Risk from wet hours in the 15–25°C window over the past 36h. */
    fun botrytis(hours: List<WeatherHour>, now: Long = System.currentTimeMillis()): DiseaseRiskAssessment {
        val window = hours.filter { it.epochMs in (now - 36 * HOUR_MS)..now }
        if (window.isEmpty()) {
            return DiseaseRiskAssessment(
                DiseaseModel.BOTRYTIS, DiseaseSeverity.LOW, "Botrytis",
                "Insufficient hourly data to assess.", emptyList(),
            )
        }
        val qualifying = window.filter { it.isWetHour && it.temperatureC in 15.0..25.0 }
        val wetCount = qualifying.count()

        var severity = DiseaseSeverity.LOW
        if (wetCount >= 15) severity = DiseaseSeverity.MEDIUM
        if (wetCount >= 24) severity = DiseaseSeverity.HIGH

        val summary = "$wetCount estimated wet hours in 15–25°C window over past 36h."
        return DiseaseRiskAssessment(
            DiseaseModel.BOTRYTIS, severity, "Botrytis risk", summary,
            listOf(
                "Wet hours past 36h" to "$wetCount h (15–25°C)",
                "Favourable temperature" to "15–25°C",
                "Wetness source" to "Estimated",
            ),
        )
    }

    private fun startOfDay(cal: Calendar, epochMs: Long): Long {
        cal.timeInMillis = epochMs
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }
}

/** A single day's projected scores for the 7-day chart. */
data class DailyDiseaseScore(
    val epochMs: Long,
    val downy: Int,
    val powdery: Int,
    val botrytis: Int,
)

/**
 * Builds a 7-day window (past 2 days + next 4 days) of projected scores by
 * re-running each model with `now` pinned to the end of each day. Matches the
 * iOS `computeDailyScores`.
 */
fun computeDailyDiseaseScores(hours: List<WeatherHour>): List<DailyDiseaseScore> {
    if (hours.isEmpty()) return emptyList()
    val cal = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }
    val today = cal.timeInMillis
    val rows = mutableListOf<DailyDiseaseScore>()
    for (offset in -2..4) {
        val day = today + offset * 86_400_000L
        val endOfDay = day + 86_400_000L
        rows.add(
            DailyDiseaseScore(
                epochMs = day,
                downy = DiseaseRiskCalculator.downyMildew(hours, endOfDay).score,
                powdery = DiseaseRiskCalculator.powderyMildew(hours, endOfDay).score,
                botrytis = DiseaseRiskCalculator.botrytis(hours, endOfDay).score,
            )
        )
    }
    return rows
}
