package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.LocationOff
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.PersistedRainfallDay
import com.rork.vinetrack.data.PersistedRainfallRepository
import com.rork.vinetrack.data.RainForecastRepository
import com.rork.vinetrack.data.YearlyRainfall
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.text.DateFormatSymbols
import java.util.Calendar
import java.util.Locale
import kotlin.math.min

/**
 * Rainfall Calendar page, mirroring the iOS `RainfallCalendarView`. Shows a
 * compact table of daily rainfall (mm) for a selected year — 31 day-rows by 12
 * month-columns — plus a per-month and annual summary. Data comes from the free
 * Open-Meteo archive + recent forecast (no API key, nothing persisted).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RainfallCalendarScreen(
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val repo = remember { RainForecastRepository() }
    val persistedRepo = remember { PersistedRainfallRepository(SessionStore(context)) }

    val paddocks = remember(state.paddocks, state.selectedVineyardId) {
        val vid = state.selectedVineyardId
        if (vid == null) state.paddocks else state.paddocks.filter { it.vineyardId == vid }
    }
    val vineyard = state.selectedVineyard
    val location = remember(vineyard, paddocks) {
        val lat = vineyard?.latitude ?: paddocks.firstNotNullOfOrNull { it.centroid }?.latitude
        val lon = vineyard?.longitude ?: paddocks.firstNotNullOfOrNull { it.centroid }?.longitude
        if (lat != null && lon != null) Pair(lat, lon) else null
    }

    val vineyardId = state.selectedVineyardId

    val currentYear = remember { Calendar.getInstance().get(Calendar.YEAR) }
    var year by remember { mutableIntStateOf(currentYear) }
    var data by remember { mutableStateOf<YearlyRainfall?>(null) }
    var persisted by remember { mutableStateOf<Map<String, PersistedRainfallDay>>(emptyMap()) }
    var isLoading by remember { mutableStateOf(false) }
    var hasLoaded by remember { mutableStateOf(false) }

    fun reload() {
        val loc = location ?: run {
            hasLoaded = true
            data = null
            persisted = emptyMap()
            return
        }
        scope.launch {
            isLoading = true
            // Persisted station-sourced rainfall (preferred over modelled).
            persisted = if (vineyardId != null) {
                try {
                    val today = todayKey()
                    val to = if (year >= currentYear) today else "$year-12-31"
                    persistedRepo.fetchDailyRainfall(vineyardId, "$year-01-01", to)
                        .filter { it.rainfallMm != null }
                        .associateBy { it.date }
                } catch (_: Exception) {
                    emptyMap()
                }
            } else {
                emptyMap()
            }
            try {
                data = repo.fetchYear(loc.first, loc.second, year)
            } catch (_: Exception) {
                data = null
            } finally {
                isLoading = false
                hasLoaded = true
            }
        }
    }

    LaunchedEffect(year, state.selectedVineyardId) { reload() }

    // Merge persisted station data over the modelled Open-Meteo values. A day
    // with a persisted reading always wins; gaps fall back to the model.
    val mergedDaily = remember(data, persisted) {
        val merged = HashMap(data?.dailyMm ?: emptyMap())
        persisted.forEach { (key, day) -> day.rainfallMm?.let { merged[key] = it } }
        merged
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Rainfall Calendar") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                actions = {
                    IconButton(onClick = { reload() }, enabled = !isLoading) {
                        if (isLoading) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = vine.appBackground,
                    titleContentColor = vine.textPrimary,
                ),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp,
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 24.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item {
                YearControls(
                    year = year,
                    canGoForward = year < currentYear,
                    onPrev = { year -= 1 },
                    onNext = { if (year < currentYear) year += 1 },
                )
            }

            if (location == null) {
                item { LocationMissingCard() }
            } else {
                item {
                    SourceCard(
                        data = data,
                        persisted = persisted,
                        mergedDaily = mergedDaily,
                        isLoading = isLoading,
                        hasLoaded = hasLoaded,
                    )
                }
                item {
                    CalendarTable(year = year, daily = mergedDaily)
                }
                item {
                    SummarySection(year = year, daily = mergedDaily)
                }
                item { Legend() }
            }
        }
    }
}

@Composable
private fun YearControls(year: Int, canGoForward: Boolean, onPrev: () -> Unit, onNext: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        FilledIconButton(onClick = onPrev) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowLeft, contentDescription = "Previous year")
        }
        Column(modifier = Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("$year", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text("Year", fontSize = 11.sp, color = vine.textSecondary)
        }
        FilledIconButton(onClick = onNext, enabled = canGoForward) {
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = "Next year")
        }
    }
}

@Composable
private fun SourceCard(
    data: YearlyRainfall?,
    persisted: Map<String, PersistedRainfallDay>,
    mergedDaily: Map<String, Double>,
    isLoading: Boolean,
    hasLoaded: Boolean,
) {
    val vine = LocalVineColors.current
    val stationDays = persisted.size
    val stationLabel = remember(persisted) { primaryStationSourceLabel(persisted.values) }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        SourceRow(
            "Source",
            if (stationDays > 0) "$stationLabel + Open-Meteo fallback"
            else "Open-Meteo archive + recent forecast",
        )
        if (hasLoaded) {
            val measured = mergedDaily.values.count { it > 0 }
            SourceRow("Days with data", "${mergedDaily.size}")
            SourceRow("Rain days", "$measured")
            if (stationDays > 0) {
                SourceRow("Station days", "$stationDays")
            }
        }
        Text(
            when {
                isLoading -> "Loading rainfall…"
                !hasLoaded -> "—"
                mergedDaily.isEmpty() -> "No rainfall data available for this year."
                stationDays > 0 -> "Station-recorded days are shown where available; remaining days are modelled Open-Meteo estimates."
                else -> "Daily values are modelled rainfall estimates, not station readings."
            },
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
    }
}

/**
 * Picks a human label for the dominant persisted rainfall source. Manual and
 * station readings (Davis / Weather Underground) are preferred over modelled
 * archive rows when choosing the headline label.
 */
private fun primaryStationSourceLabel(days: Collection<PersistedRainfallDay>): String {
    val sources = days.mapNotNull { it.source }
    return when {
        sources.any { it == "davis_weatherlink" } -> "Davis WeatherLink"
        sources.any { it == "wunderground" } -> "Weather Underground"
        sources.any { it == "manual" } -> "Manual entries"
        else -> "Persisted history"
    }
}

@Composable
private fun SourceRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, fontSize = 12.sp, color = vine.textSecondary, modifier = Modifier.width(120.dp))
        Text(value, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
    }
}

private val DayColumnWidth = 30.dp
private val MonthColumnWidth = 46.dp
private val CellHeight = 20.dp

@Composable
private fun CalendarTable(year: Int, daily: Map<String, Double>) {
    val vine = LocalVineColors.current
    val scroll = rememberScrollState()
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .horizontalScroll(scroll)
            .padding(8.dp),
    ) {
        Column {
            // Header row.
            Row {
                Box(modifier = Modifier.width(DayColumnWidth).height(CellHeight))
                for (m in 1..12) {
                    Text(
                        monthAbbrev(m),
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textSecondary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.width(MonthColumnWidth).height(CellHeight),
                    )
                }
            }
            HorizontalDivider(color = vine.cardBorder)
            for (day in 1..31) {
                Row(
                    modifier = Modifier.background(
                        if (day % 2 == 0) Color.Transparent else vine.textPrimary.copy(alpha = 0.025f)
                    ),
                ) {
                    Text(
                        "$day",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textSecondary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.width(DayColumnWidth).height(CellHeight),
                    )
                    for (m in 1..12) {
                        RainCell(year = year, month = m, day = day, daily = daily)
                    }
                }
            }
        }
    }
}

@Composable
private fun RainCell(year: Int, month: Int, day: Int, daily: Map<String, Double>) {
    val vine = LocalVineColors.current
    val valid = isValidDate(year, month, day)
    val key = if (valid) dateKey(year, month, day) else null
    val mm = key?.let { daily[it] }
    val isFutureEmpty = mm == null && valid && key != null && key > todayKey()

    val bg = when {
        mm != null && mm > 0 -> VineColors.Info.copy(alpha = min(0.55, mm / 30.0).toFloat())
        else -> Color.Transparent
    }
    Box(
        modifier = Modifier
            .width(MonthColumnWidth)
            .height(CellHeight)
            .background(bg),
        contentAlignment = Alignment.Center,
    ) {
        when {
            !valid -> {}
            mm != null -> Text(
                formatMmCell(mm),
                fontSize = 10.sp,
                fontWeight = FontWeight.Medium,
                color = vine.textPrimary.copy(alpha = if (mm >= 10) 1f else 0.85f),
            )
            isFutureEmpty -> {}
            else -> Text("----", fontSize = 10.sp, color = vine.textSecondary.copy(alpha = 0.5f))
        }
    }
}

@Composable
private fun SummarySection(year: Int, daily: Map<String, Double>) {
    val vine = LocalVineColors.current
    val months = remember(year, daily) { (1..12).map { monthSummary(year, it, daily) } }
    val annualTotal = months.sumOf { it.totalMm }
    val annualRainDays = months.sumOf { it.rainDays }
    val wettestMonth = months.maxByOrNull { it.totalMm }?.takeIf { it.totalMm > 0 }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Summary", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

        val scroll = rememberScrollState()
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(vine.cardBackground)
                .horizontalScroll(scroll)
                .padding(8.dp),
        ) {
            Column {
                Row {
                    Box(modifier = Modifier.width(DayColumnWidth + 64.dp).height(CellHeight))
                    months.forEach { mSum ->
                        Text(
                            monthAbbrev(mSum.month),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textSecondary,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.width(MonthColumnWidth).height(CellHeight),
                        )
                    }
                }
                SummaryRow("TOTALS", months) { mmString(it.totalMm) }
                SummaryRow("Rain days", months) { "${it.rainDays}" }
                SummaryRow("Wettest day", months) {
                    val d = it.wettestDay
                    val mm = it.wettestDayMm
                    if (d == null || mm == null) "—" else "$d (${mmString(mm)})"
                }
                SummaryRow("Average", months) { mmString(it.averageMm) }
            }
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(vine.cardBackground)
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            StatRow("Year total to date", "${mmString(annualTotal)} mm")
            StatRow("Rain days (year)", "$annualRainDays")
            if (wettestMonth != null) {
                StatRow("Wettest month", "${monthAbbrev(wettestMonth.month)} (${mmString(wettestMonth.totalMm)} mm)")
            }
            val driestMonth = months.filter { it.measuredDays > 0 }.minByOrNull { it.totalMm }
            if (driestMonth != null) {
                StatRow("Driest month", "${monthAbbrev(driestMonth.month)} (${mmString(driestMonth.totalMm)} mm)")
            }
            val wettestDayMonth = months.filter { it.wettestDayMm != null }.maxByOrNull { it.wettestDayMm ?: 0.0 }
            if (wettestDayMonth?.wettestDay != null && wettestDayMonth.wettestDayMm != null) {
                StatRow(
                    "Wettest day",
                    "${wettestDayMonth.wettestDay} ${monthAbbrev(wettestDayMonth.month)} (${mmString(wettestDayMonth.wettestDayMm)} mm)",
                )
            }
            StatRow("Av. Year total", "—")
        }
    }
}

@Composable
private fun SummaryRow(label: String, months: List<MonthSummary>, value: (MonthSummary) -> String) {
    val vine = LocalVineColors.current
    Row {
        Text(
            label,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            color = vine.textSecondary,
            modifier = Modifier.width(DayColumnWidth + 64.dp).height(CellHeight),
        )
        months.forEach { mSum ->
            Text(
                value(mSum),
                fontSize = 10.sp,
                fontWeight = FontWeight.Medium,
                color = vine.textPrimary,
                textAlign = TextAlign.Center,
                modifier = Modifier.width(MonthColumnWidth).height(CellHeight),
            )
        }
    }
}

@Composable
private fun StatRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 13.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
    }
}

@Composable
private fun Legend() {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Box(modifier = Modifier.size(10.dp).clip(RoundedCornerShape(2.dp)).background(VineColors.Info.copy(alpha = 0.5f)))
            Text("Rain (mm)", fontSize = 11.sp, color = vine.textSecondary)
        }
        Text("Blank / ---- = no data", fontSize = 11.sp, color = vine.textSecondary)
        Box(modifier = Modifier.weight(1f))
        Text("mm", fontSize = 11.sp, color = vine.textSecondary)
    }
}

@Composable
private fun LocationMissingCard() {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Filled.LocationOff, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(20.dp))
            Text("No vineyard location set", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Orange)
        }
        Text(
            "Set your vineyard location in Weather Data & Forecasting setup to load rainfall history.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
    }
}

// MARK: - Math / formatting helpers

private data class MonthSummary(
    val month: Int,
    val totalMm: Double,
    val rainDays: Int,
    val averageMm: Double,
    val measuredDays: Int,
    val wettestDay: Int?,
    val wettestDayMm: Double?,
)

private fun monthSummary(year: Int, month: Int, daily: Map<String, Double>): MonthSummary {
    var total = 0.0
    var rainDays = 0
    var measuredDays = 0
    var wettestDay: Int? = null
    var wettestDayMm: Double? = null
    for (day in 1..31) {
        if (!isValidDate(year, month, day)) continue
        val mm = daily[dateKey(year, month, day)] ?: continue
        measuredDays++
        total += mm
        if (mm > 0) rainDays++
        if (mm > (wettestDayMm ?: -1.0)) {
            wettestDayMm = mm
            wettestDay = day
        }
    }
    val avg = if (measuredDays > 0) total / measuredDays else 0.0
    val wettest = if ((wettestDayMm ?: 0.0) > 0) wettestDay else null
    return MonthSummary(month, total, rainDays, avg, measuredDays, wettest, wettest?.let { wettestDayMm })
}

private fun isValidDate(year: Int, month: Int, day: Int): Boolean {
    val cal = Calendar.getInstance()
    cal.isLenient = false
    cal.clear()
    return try {
        cal.set(year, month - 1, day)
        cal.time
        true
    } catch (_: Exception) {
        false
    }
}

private fun dateKey(year: Int, month: Int, day: Int): String =
    "%04d-%02d-%02d".format(year, month, day)

private fun todayKey(): String {
    val cal = Calendar.getInstance()
    return dateKey(cal.get(Calendar.YEAR), cal.get(Calendar.MONTH) + 1, cal.get(Calendar.DAY_OF_MONTH))
}

private fun monthAbbrev(month: Int): String =
    DateFormatSymbols(Locale.getDefault()).shortMonths[month - 1]

private fun formatMmCell(mm: Double): String {
    val clamped = mm.coerceIn(0.0, 99.9)
    return "%04.1f".format(clamped)
}

private fun mmString(mm: Double): String = "%.1f".format(mm)
