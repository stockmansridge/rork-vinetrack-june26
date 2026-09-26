package com.rork.vinetrack.data

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** Vineyard-local four-hour forecast in metric units. Null means unknown, never zero. */
data class SprayForecastPeriod(
    val date: String,
    val startHour: Int,
    val startTimeLocal: String = "%02d:00".format(Locale.US, startHour),
    val endTimeLocal: String = "%02d:00".format(Locale.US, startHour + 4),
    val tempMinC: Double? = null,
    val tempMaxC: Double? = null,
    val windMaxKmh: Double? = null,
    val humidityMinPct: Double? = null,
    val humidityMaxPct: Double? = null,
    val rainMm: Double? = null,
    val sampleCount: Int = 0,
) {
    fun fillingNulls(other: SprayForecastPeriod): SprayForecastPeriod =
        if (date != other.date || startHour != other.startHour) this else copy(
            tempMinC = tempMinC ?: other.tempMinC,
            tempMaxC = tempMaxC ?: other.tempMaxC,
            windMaxKmh = windMaxKmh ?: other.windMaxKmh,
            humidityMinPct = humidityMinPct ?: other.humidityMinPct,
            humidityMaxPct = humidityMaxPct ?: other.humidityMaxPct,
            rainMm = rainMm ?: other.rainMm,
        )
}

data class SprayForecastWindow(val start: Long, val end: Long, val kind: Kind) {
    enum class Kind { OPTIMAL, HIGH_HUMIDITY }

    fun label(timezone: TimeZone, now: Long): String {
        val clock = SimpleDateFormat("h:mm a", Locale.ENGLISH).apply { timeZone = timezone }
        val weekday = SimpleDateFormat("EEE", Locale.ENGLISH).apply { timeZone = timezone }
        val calendar = Calendar.getInstance(timezone)
        fun dayKey(time: Long): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = timezone }.format(Date(time))
        val today = dayKey(now)
        calendar.timeInMillis = now
        calendar.add(Calendar.DAY_OF_YEAR, 1)
        val heading = when (dayKey(start)) {
            today -> "Today"
            dayKey(calendar.timeInMillis) -> "Tomorrow"
            else -> weekday.format(Date(start))
        }
        val range = if (dayKey(start) == dayKey(end - 1)) {
            "${clock.format(Date(start))} – ${clock.format(Date(end))}"
        } else {
            "${weekday.format(Date(start))} ${clock.format(Date(start))} – ${weekday.format(Date(end))} ${clock.format(Date(end))}"
        }
        return "$heading\n$range ${if (kind == Kind.OPTIMAL) "Optimal" else "High humidity"}"
    }
}

/** Provider-independent Portal-default qualification and non-overlapping display bands. */
object SprayForecastWindows {
    fun qualifiesOptimal(p: SprayForecastPeriod): Boolean {
        val low = p.tempMinC ?: return false
        val high = p.tempMaxC ?: return false
        val wind = p.windMaxKmh ?: return false
        val rain = p.rainMm ?: return false
        return low > 10 && high < 35 && wind < 15 && rain <= 0.1
    }

    fun qualifiesHighHumidity(p: SprayForecastPeriod): Boolean =
        qualifiesOptimal(p) && (p.humidityMinPct?.let { it >= 90 } == true)

    fun supplement(primary: List<SprayForecastPeriod>, secondary: List<SprayForecastPeriod>): List<SprayForecastPeriod> {
        val byKey = secondary.associateBy { it.date to it.startHour }
        val existing = primary.map { it.date to it.startHour }.toSet()
        return primary.map { p -> byKey[p.date to p.startHour]?.let(p::fillingNulls) ?: p } +
            secondary.filter { (it.date to it.startHour) !in existing }
    }

    fun windows(periods: List<SprayForecastPeriod>, timezone: TimeZone, now: Long = System.currentTimeMillis()): List<SprayForecastWindow> {
        val calendar = Calendar.getInstance(timezone).apply {
            timeInMillis = now
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val first = calendar.timeInMillis
        calendar.add(Calendar.DAY_OF_YEAR, 5)
        val last = calendar.timeInMillis
        val parser = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = timezone; isLenient = false }
        val slots = periods.mapNotNull { p ->
            if (p.startHour !in 0..23 || p.startHour % 4 != 0 || !qualifiesOptimal(p)) return@mapNotNull null
            val date = parser.parse(p.date) ?: return@mapNotNull null
            if (date.time < first || date.time >= last) return@mapNotNull null
            calendar.time = date
            calendar.set(Calendar.HOUR_OF_DAY, p.startHour)
            val start = calendar.timeInMillis
            calendar.time = date
            if (p.startHour == 20) calendar.add(Calendar.DAY_OF_YEAR, 1)
            else calendar.set(Calendar.HOUR_OF_DAY, p.startHour + 4)
            val end = calendar.timeInMillis
            if (end <= now) null else SprayForecastWindow(start, end,
                if (qualifiesHighHumidity(p)) SprayForecastWindow.Kind.HIGH_HUMIDITY else SprayForecastWindow.Kind.OPTIMAL)
        }.sortedBy { it.start }
        val result = mutableListOf<SprayForecastWindow>()
        for (slot in slots) {
            val previous = result.lastOrNull()
            if (previous != null && previous.end == slot.start && previous.kind == slot.kind) {
                result[result.lastIndex] = previous.copy(end = slot.end)
            } else result.add(slot)
        }
        return result
    }
}
