package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Grain
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.PersistedRainfallRepository
import com.rork.vinetrack.data.insights.ScoutWeatherRepository
import com.rork.vinetrack.data.insights.ScoutWeatherSnapshot
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.RainDay
import com.rork.vinetrack.data.RainForecastBundle
import com.rork.vinetrack.data.RainForecastRepository
import com.rork.vinetrack.data.VineyardWeatherIntegrationRepository
import com.rork.vinetrack.data.WeatherIntegrationProvider
import com.rork.vinetrack.data.WillyWeatherRepository
import com.rork.vinetrack.data.toRainDay
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.regionFormatter
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt

/**
 * Rain & Forecast page, mirroring the iOS `RainAndForecastView`. Combines a
 * 7-day rainfall forecast at the top with recent rainfall history below, plus a
 * status banner and a wind-caution banner. Reachable only from the Home →
 * Today's Rain card, like iOS. Data comes from the free Open-Meteo API
 * (daily precipitation + max wind); nothing is persisted.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RainAndForecastScreen(
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenWeatherSettings: (() -> Unit)? = null,
) {
    var showCalendar by remember { mutableStateOf(false) }
    AnimatedContent(
        targetState = showCalendar,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "rain-calendar-nav",
        modifier = modifier,
    ) { calendar ->
        if (calendar) {
            RainfallCalendarScreen(state, onBack = { showCalendar = false })
        } else {
            RainAndForecastContent(
                state = state,
                onBack = onBack,
                onOpenCalendar = { showCalendar = true },
                onOpenWeatherSettings = onOpenWeatherSettings,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RainAndForecastContent(
    state: AppUiState,
    onBack: (() -> Unit)?,
    onOpenCalendar: () -> Unit,
    onOpenWeatherSettings: (() -> Unit)?,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val repo = remember { RainForecastRepository() }
    val sessionStore = remember { SessionStore(context) }
    val persistedRepo = remember { PersistedRainfallRepository(sessionStore) }
    val wwRepo = remember { WillyWeatherRepository(sessionStore) }
    val integrationRepo = remember { VineyardWeatherIntegrationRepository(sessionStore) }
    val currentRepo = remember { ScoutWeatherRepository(sessionStore) }

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

    val windWarningThresholdKmh = state.alertPreferences?.windAlertThresholdKmh ?: 25.0
    val windCautionThresholdKmh = 15.0

    var bundle by remember { mutableStateOf<RainForecastBundle?>(null) }
    var persistedHistory by remember { mutableStateOf<List<HistoryDay>?>(null) }
    var persistedTodayMm by remember { mutableStateOf<Double?>(null) }
    var currentConditions by remember { mutableStateOf<ScoutWeatherSnapshot?>(null) }
    // WillyWeather forecast override — non-null when the shared server-side
    // provider preference resolved to WillyWeather and the proxy returned
    // forecast days. Mirrors iOS `IrrigationForecastService`.
    var wwForecast by remember { mutableStateOf<List<RainDay>?>(null) }
    var wwSource by remember { mutableStateOf<String?>(null) }
    var wwTimezone by remember { mutableStateOf<String?>(null) }
    var rolling24hMm by remember { mutableStateOf<Double?>(null) }
    var rolling48hMm by remember { mutableStateOf<Double?>(null) }
    var rollingSource by remember { mutableStateOf<String?>(null) }
    // Non-blocking reason the forecast fell back to Open-Meteo, if any.
    var fallbackNote by remember { mutableStateOf<String?>(null) }
    var isLoading by remember { mutableStateOf(false) }
    var hasLoaded by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    fun refresh() {
        val loc = location ?: run {
            hasLoaded = true
            bundle = null
            persistedHistory = null
            persistedTodayMm = null
            currentConditions = null
            return
        }
        scope.launch {
            isLoading = true
            errorMessage = null
            wwForecast = null
            wwSource = null
            wwTimezone = null
            rolling24hMm = null
            rolling48hMm = null
            rollingSource = null
            fallbackNote = null
            currentConditions = null
            state.selectedVineyardId?.let { vineyardId ->
                currentConditions = runCatching { currentRepo.current(vineyardId, java.time.Instant.now().toString()) }.getOrNull()
            }

            // 1. Try WillyWeather first when the shared server-side provider
            //    preference selects it (willyweather, or auto with a configured
            //    location) — same priority as iOS. Open-Meteo below remains the
            //    transparent fallback and still supplies rainfall history.
            val vid = state.selectedVineyardId
            if (vid != null) {
                val provider = runCatching { wwRepo.getProviderPreference(vid) }.getOrDefault("auto")
                if (provider != "open_meteo") {
                    val hasWillyLocation = runCatching {
                        integrationRepo.fetch(vid, WeatherIntegrationProvider.WILLY_WEATHER)
                            ?.stationId?.isNotEmpty() == true
                    }.getOrDefault(false)
                    val shouldTryWilly = provider == "willyweather" || (provider == "auto" && hasWillyLocation)
                    if (shouldTryWilly) {
                        try {
                            val result = wwRepo.fetchForecast(vid, days = 7)
                            val mapped = result.days.mapNotNull { it.toRainDay(result.timezone) }
                            if (mapped.isNotEmpty()) {
                                wwForecast = mapped
                                wwSource = result.source
                                wwTimezone = result.timezone
                                rolling24hMm = result.rollingRain?.next24hMm
                                rolling48hMm = result.rollingRain?.next48hMm
                                rollingSource = result.rollingRain?.source
                            } else {
                                fallbackNote = "WillyWeather returned no forecast days — using Open-Meteo."
                            }
                        } catch (_: Exception) {
                            fallbackNote = "Using Open-Meteo forecast because WillyWeather is unavailable."
                        }
                    } else if (provider == "willyweather") {
                        fallbackNote = "WillyWeather is selected but not yet configured for this vineyard — using Open-Meteo."
                    }
                }
            }

            // 2. Open-Meteo — forecast fallback plus recent rainfall history.
            try {
                bundle = repo.fetch(loc.first, loc.second, pastDays = 30, forecastDays = 7)
            } catch (e: Exception) {
                if (wwForecast == null) {
                    errorMessage = e.message ?: "Could not load rain forecast."
                }
            }
            // Persisted station-sourced rainfall (`rainfall_daily`) — the same
            // shared records iOS and the portal show, with per-day source
            // labels (Manual/Davis/Wunderground/Open-Meteo). Falls back to the
            // raw Open-Meteo history when unavailable.
            var rows: List<HistoryDay>? = null
            var todayPersisted: Double? = null
            if (vid != null) {
                try {
                    val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
                        timeZone = TimeZone.getTimeZone(wwTimezone ?: bundle?.timezone ?: "UTC")
                    }
                    val cal = Calendar.getInstance(fmt.timeZone)
                    val todayKey = fmt.format(cal.time)
                    cal.add(Calendar.DAY_OF_YEAR, -29)
                    val fromKey = fmt.format(cal.time)
                    val persisted = persistedRepo.fetchDailyRainfall(vid, fromKey, todayKey)
                    if (persisted.isNotEmpty()) {
                        rows = persisted.map { HistoryDay(it.date, it.rainfallMm ?: 0.0, it.source) }
                        todayPersisted = persisted.firstOrNull { it.date == todayKey }?.rainfallMm
                    }
                } catch (_: Exception) {
                    rows = null
                }
            }
            persistedHistory = rows
            persistedTodayMm = todayPersisted
            isLoading = false
            hasLoaded = true
        }
    }

    LaunchedEffect(state.selectedVineyardId) { refresh() }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Rain & Forecast") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                actions = {
                    IconButton(onClick = { refresh() }, enabled = !isLoading) {
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
        // WillyWeather forecast wins when available; Open-Meteo is the fallback.
        val days = wwForecast ?: bundle?.forecast ?: emptyList()
        val forecastSource = if (wwForecast != null) wwSource else bundle?.source
        val rain24h = rolling24hMm
        val rain48h = rolling48hMm
        val rain7d = days.take(7).sumOf { it.rainMm }
        // Today so far is observed/persisted rain, never forecast today.
        val todayMm = persistedTodayMm ?: currentConditions?.takeIf { !it.isUnavailable }?.recentRainfallMm
        val zone = TimeZone.getTimeZone(wwTimezone ?: bundle?.timezone ?: "UTC")
        val hasLocation = location != null
        val fallbackKeyFmt = remember(zone.id) {
            SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = zone }
        }
        val historyDays: List<HistoryDay> = persistedHistory
            ?: (bundle?.history ?: emptyList()).map {
                HistoryDay(fallbackKeyFmt.format(Date(it.dateEpochMs)), it.rainMm, "open_meteo")
            }

        LazyColumn(
            modifier = Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp,
                top = padding.calculateTopPadding() + 8.dp,
                bottom = padding.calculateBottomPadding() + 24.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item { CurrentConditionsCard(currentConditions, todayMm) }
            item {
                StatusBanner(
                    todayMm = todayMm,
                    rain24h = rolling24hMm,
                    rain48h = rolling48hMm,
                    rain7d = rain7d,
                    isRange = forecastSource.equals("WillyWeather", ignoreCase = true),
                    hasLocation = hasLocation,
                    hasLoaded = hasLoaded,
                    hasForecast = days.isNotEmpty(),
                )
            }

            // Wind caution / warning banner (highest forecast wind in next 48h).
            val windWarning = resolveWindWarning(days, windWarningThresholdKmh, windCautionThresholdKmh)
            if (windWarning != null) {
                item {
                    WindWarningBanner(
                        warning = windWarning,
                        warningThresholdKmh = windWarningThresholdKmh,
                        cautionThresholdKmh = windCautionThresholdKmh,
                    )
                }
            }

            item {
                ForecastSummaryGrid(
                    todayMm = todayMm,
                    rain24h = rain24h,
                    rain48h = rain48h,
                    rain7d = rain7d,
                    isRange = forecastSource.equals("WillyWeather", ignoreCase = true),
                    hasLoaded = hasLoaded && hasLocation && days.isNotEmpty(),
                    rollingSource = rollingSource,
                )
            }

            item {
                DailyForecastSection(
                    days = days,
                    timezone = zone,
                    source = forecastSource,
                    fallbackNote = fallbackNote,
                    hasLocation = hasLocation,
                    isLoading = isLoading,
                    hasLoaded = hasLoaded,
                    warningThresholdKmh = windWarningThresholdKmh,
                    cautionThresholdKmh = windCautionThresholdKmh,
                    onOpenWeatherSettings = onOpenWeatherSettings,
                )
            }

            item { ConditionsCheckCard(currentConditions, windCautionThresholdKmh) }

            item {
                RainfallHistorySection(
                    history = historyDays,
                    isLoading = isLoading,
                    hasLoaded = hasLoaded,
                )
            }

            item { CalendarLinkCard(onClick = onOpenCalendar) }

            if (errorMessage != null) {
                item {
                    Text(
                        errorMessage ?: "",
                        color = VineColors.Destructive,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun CurrentConditionsCard(snapshot: ScoutWeatherSnapshot?, todayMm: Double?) {
    val vine = LocalVineColors.current
    val fmt = regionFormatter
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(vine.cardBackground).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Current Conditions", fontWeight = FontWeight.SemiBold, fontSize = 17.sp, color = vine.textPrimary)
            Text(if (snapshot?.isStale == false && !snapshot.isUnavailable) "Observed" else "Latest available", fontSize = 11.sp, color = vine.textSecondary)
        }
        if (snapshot != null && !snapshot.isUnavailable) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                CurrentMetric("Temperature", snapshot.temperatureCelsius?.let { "${it.roundToInt()}°C" } ?: "—", Modifier.weight(1f))
                CurrentMetric("Wind", snapshot.windSpeedKph?.let { fmt.formatSpeed(it, 0) } ?: "—", Modifier.weight(1f))
                CurrentMetric("Rain today", formatMm(fmt, todayMm), Modifier.weight(1f))
            }
            Text(listOfNotNull(snapshot.source, snapshot.observedAtIso).joinToString(" · "), fontSize = 11.sp, color = vine.textSecondary)
        } else {
            Text("No current station observation available. Forecast and rainfall history remain below.", fontSize = 12.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun CurrentMetric(label: String, value: String, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier) {
        Text(label, fontSize = 10.sp, color = vine.textSecondary)
        Text(value, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, maxLines = 1)
    }
}

@Composable
private fun ConditionsCheckCard(snapshot: ScoutWeatherSnapshot?, windCautionKmh: Double) {
    val vine = LocalVineColors.current
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(vine.cardBackground).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("Conditions Check", fontWeight = FontWeight.SemiBold, fontSize = 17.sp, color = vine.textPrimary)
        val wind = snapshot?.takeIf { !it.isUnavailable && !it.isStale }?.windSpeedKph
        Text(
            wind?.let { "Wind ${regionFormatter.formatSpeed(it, 0)} · ${if (it < windCautionKmh) "below caution level" else "check on-site before spraying"}" }
                ?: "Live wind check unavailable.",
            fontSize = 13.sp, color = if (wind != null && wind >= windCautionKmh) VineColors.Orange else vine.textSecondary,
        )
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CurrentMetric("Temperature", snapshot?.temperatureCelsius?.let { "${it.roundToInt()}°C" } ?: "—", Modifier.weight(1f))
            CurrentMetric("Rain today", snapshot?.recentRainfallMm?.let { regionFormatter.formatRainfall(it) } ?: "—", Modifier.weight(1f))
            CurrentMetric("Humidity", snapshot?.humidityPercent?.let { "${it.roundToInt()}%" } ?: "—", Modifier.weight(1f))
        }
        Text("Spray suitability cannot be qualified without the Portal thresholds and detailed forecast periods. Daily totals are not optimal-window evidence.", fontSize = 11.sp, color = vine.textSecondary)
    }
}

// MARK: - Calendar link

@Composable
private fun CalendarLinkCard(onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .clickable(onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.CalendarMonth, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(22.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Rainfall Calendar", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text("Full daily rainfall by month and year", fontSize = 12.sp, color = vine.textSecondary)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
    }
}

// MARK: - Status banner

@Composable
private fun StatusBanner(
    todayMm: Double?,
    rain24h: Double?,
    rain48h: Double?,
    rain7d: Double,
    isRange: Boolean,
    hasLocation: Boolean,
    hasLoaded: Boolean,
    hasForecast: Boolean,
) {
    val fmt = regionFormatter
    val tint = when {
        (todayMm ?: 0.0) > 0 || (rain24h ?: 0.0) >= 5 -> VineColors.Info
        (rain24h ?: 0.0) >= 1 || (rain48h ?: 0.0) >= 1 -> VineColors.Cyan
        rain7d >= 1 -> VineColors.LeafGreen
        else -> VineColors.Orange
    }
    val icon = when {
        (todayMm ?: 0.0) > 0 -> Icons.Filled.WaterDrop
        (rain24h ?: 0.0) >= 1 -> Icons.Filled.Grain
        rain7d >= 1 -> Icons.Filled.Cloud
        else -> Icons.Filled.WbSunny
    }
    val title = when {
        todayMm != null && todayMm > 0 -> "Rain recorded today: ${fmt.formatRainfall(todayMm)}"
        (rain24h ?: 0.0) >= 1 -> "Rain expected in next 24h"
        (rain48h ?: 0.0) >= 1 -> "Rain possible in next 48h"
        rain7d >= 1 -> "Rain possible this week"
        else -> if (hasLoaded && !hasForecast) "Forecast unavailable" else "No rain forecast"
    }
    val subtitle = when {
        !hasLocation -> "Set vineyard location to enable forecast."
        !hasLoaded -> "Loading forecast…"
        !hasForecast -> "Forecast data is not available. Check Weather Settings or try again."
        else -> "Today ${formatMm(fmt, todayMm)} · 24h ${formatMm(fmt, rain24h)} · 7d ${if (isRange) "up to " else ""}${fmt.formatRainfall(rain7d)}"
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(tint.copy(alpha = 0.12f))
            .border(1.dp, tint.copy(alpha = 0.25f), RoundedCornerShape(12.dp))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(28.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = LocalVineColors.current.textPrimary)
            Text(subtitle, fontSize = 12.sp, color = LocalVineColors.current.textSecondary)
        }
    }
}

// MARK: - Forecast summary grid

@Composable
private fun ForecastSummaryGrid(
    todayMm: Double?,
    rain24h: Double?,
    rain48h: Double?,
    rain7d: Double,
    isRange: Boolean,
    hasLoaded: Boolean,
    rollingSource: String?,
) {
    val fmt = regionFormatter
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            SummaryTile("Today so far", formatMm(fmt, todayMm), Icons.Filled.WaterDrop, VineColors.Info, Modifier.weight(1f))
            SummaryTile("Next 24h", if (hasLoaded && rain24h != null) fmt.formatRainfall(rain24h) else "—", Icons.Filled.Grain, VineColors.Cyan, Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            SummaryTile("Next 48h", if (hasLoaded && rain48h != null) fmt.formatRainfall(rain48h) else "—", Icons.Filled.Cloud, VineColors.Indigo, Modifier.weight(1f))
            SummaryTile("Next 7 days", if (hasLoaded) (if (isRange) "Up to " else "") + fmt.formatRainfall(rain7d) else "—", Icons.Filled.CalendarMonth, VineColors.Primary, Modifier.weight(1f))
        }
        if (rollingSource != null && rollingSource != "WillyWeather") {
            Text("Rolling rain detail: $rollingSource", fontSize = 11.sp, color = LocalVineColors.current.textSecondary)
        }
    }
}

@Composable
private fun SummaryTile(title: String, value: String, icon: ImageVector, tint: Color, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(15.dp))
            Text(title, fontSize = 12.sp, color = vine.textSecondary)
        }
        Text(value, fontSize = 19.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
    }
}

// MARK: - Daily forecast section

@Composable
private fun DailyForecastSection(
    days: List<RainDay>,
    timezone: TimeZone,
    source: String?,
    fallbackNote: String?,
    hasLocation: Boolean,
    isLoading: Boolean,
    hasLoaded: Boolean,
    warningThresholdKmh: Double,
    cautionThresholdKmh: Double,
    onOpenWeatherSettings: (() -> Unit)?,
) {
    val vine = LocalVineColors.current
    var selectedDay by remember(days) { mutableStateOf(0) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Text("Spray Window Forecast", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
            val sourceLabel = forecastSourceLabel(source)
            if (sourceLabel != null) {
                Text("Forecast source: $sourceLabel", fontSize = 11.sp, color = vine.textSecondary, maxLines = 1)
            }
        }
        if (days.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                days.forEachIndexed { index, day ->
                    Column(
                        Modifier.clip(RoundedCornerShape(12.dp))
                            .background(if (selectedDay == index) VineColors.Primary else vine.cardBackground)
                            .clickable { selectedDay = index }
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                    ) {
                        Text(dayLabel(day.dateEpochMs, timezone), fontSize = 12.sp, color = if (selectedDay == index) Color.White else vine.textPrimary)
                        Text(dateLabel(day.dateEpochMs, timezone), fontSize = 11.sp, color = if (selectedDay == index) Color.White else vine.textSecondary)
                    }
                }
            }
            Text("Daily outlook · detailed period qualification is not available in this view", fontSize = 11.sp, color = vine.textSecondary)
        }
        if (fallbackNote != null && days.isNotEmpty()) {
            Text(
                fallbackNote,
                fontSize = 11.sp,
                color = VineColors.Orange,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
        when {
            !hasLocation -> UnavailableCard("Rain forecast is currently unavailable.", onOpenWeatherSettings)
            isLoading && days.isEmpty() -> LoadingCard("Loading forecast…")
            days.isEmpty() && hasLoaded -> UnavailableCard("Rain forecast is currently unavailable.", onOpenWeatherSettings)
            else -> Column(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(vine.cardBackground),
            ) {
                days.getOrNull(selectedDay)?.let { ForecastRow(it, timezone, source) }
            }
        }
    }
}

@Composable
private fun ForecastRow(day: RainDay, timezone: TimeZone, source: String?) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(modifier = Modifier.width(104.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(dayLabel(day.dateEpochMs, timezone), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(dateLabel(day.dateEpochMs, timezone), fontSize = 11.sp, color = vine.textSecondary)
        }
        if (conditionLabel(day) == "Partly cloudy") {
            Box(modifier = Modifier.size(24.dp)) {
                Icon(Icons.Filled.WbSunny, contentDescription = conditionLabel(day), tint = VineColors.Orange, modifier = Modifier.size(17.dp))
                Icon(Icons.Filled.Cloud, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.align(Alignment.BottomEnd).size(17.dp))
            }
        } else {
            Icon(conditionIcon(day), contentDescription = conditionLabel(day), tint = vine.textSecondary, modifier = Modifier.size(20.dp))
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(conditionLabel(day), fontSize = 12.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
            if (day.tempMinC != null && day.tempMaxC != null) {
                Text("${day.tempMinC.roundToInt()}–${day.tempMaxC.roundToInt()}°C", fontSize = 11.sp, color = vine.textSecondary)
            }
            val rain = when {
                day.rainMaxMm != null && day.rainMinMm != null -> "${regionFormatter.formatRainfall(day.rainMinMm)}–${regionFormatter.formatRainfall(day.rainMaxMm)}"
                day.rainMaxMm != null -> "Up to ${regionFormatter.formatRainfall(day.rainMaxMm)}"
                source.equals("WillyWeather", ignoreCase = true) -> "Up to ${regionFormatter.formatRainfall(day.rainMm)}"
                else -> regionFormatter.formatRainfall(day.rainMm)
            }
            day.windKmhMax?.let {
                Text("Wind ${regionFormatter.formatSpeed(it, 0)}", fontSize = 10.sp, color = vine.textSecondary)
            }
            val chance = day.rainProbabilityPct?.let { " · ${it.roundToInt()}% chance" }.orEmpty()
            Text("$rain$chance", fontSize = 10.sp, color = vine.textSecondary)
        }
    }
}

private fun conditionLabel(day: RainDay): String {
    day.condition?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
    val key = (day.conditionKey ?: day.conditionCode ?: "").lowercase()
    return when {
        "thunder" in key || "storm" in key -> "Thunderstorms"
        "rain" in key || "shower" in key || "drizzle" in key -> "Rain"
        "partly" in key || "mostly sunny" in key -> "Partly cloudy"
        "cloud" in key || "overcast" in key -> "Cloudy"
        "clear" in key || "sunny" in key -> "Clear"
        else -> "Condition unavailable"
    }
}

// MARK: - Rainfall history section

/**
 * One display row of recent rainfall history with its per-day source, sourced
 * from the shared `rainfall_daily` records (or Open-Meteo as fallback).
 * [dateKey] is a "yyyy-MM-dd" calendar-day string.
 */
private data class HistoryDay(val dateKey: String, val rainMm: Double, val source: String?)

@Composable
private fun RainfallHistorySection(
    history: List<HistoryDay>,
    isLoading: Boolean,
    hasLoaded: Boolean,
) {
    val vine = LocalVineColors.current
    val fmt = regionFormatter
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
            Text("Recent rainfall", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
            Text("Last 30 days", fontSize = 11.sp, color = vine.textSecondary)
        }
        val rainDays = remember(history) { history.filter { it.rainMm > 0 }.sortedByDescending { it.dateKey } }
        when {
            isLoading && history.isEmpty() -> LoadingCard("Loading rainfall…")
            rainDays.isEmpty() -> Box(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(vine.cardBackground).padding(12.dp),
            ) {
                Text(
                    if (hasLoaded) "No rain recorded in the last 30 days." else "—",
                    fontSize = 13.sp, color = vine.textSecondary,
                )
            }
            else -> Column(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(vine.cardBackground),
            ) {
                Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
                    Text("Date", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary, modifier = Modifier.weight(1f))
                    Text("Source", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    Text("Rain", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.End)
                }
                HorizontalDivider(color = vine.cardBorder)
                rainDays.forEachIndexed { index, day ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(displayDateKey(day.dateKey), fontSize = 14.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                        Text(prettySource(day.source), fontSize = 12.sp, color = vine.textSecondary, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center, maxLines = 1)
                        Text(fmt.formatRainfall(day.rainMm), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.End)
                    }
                    if (index < rainDays.lastIndex) {
                        HorizontalDivider(color = vine.cardBorder, modifier = Modifier.padding(start = 12.dp))
                    }
                }
                HorizontalDivider(color = vine.cardBorder)
                val total = rainDays.sumOf { it.rainMm }
                Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp)) {
                    Text(
                        "${rainDays.size} rain day${if (rainDays.size == 1) "" else "s"}",
                        fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f),
                    )
                    Text("${fmt.formatRainfall(total)} total", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                }
            }
        }
    }
}

// MARK: - Wind warning

private data class WindWarning(val isHigh: Boolean, val maxKmh: Double, val timeframe: String)

private fun resolveWindWarning(days: List<RainDay>, warningKmh: Double, cautionKmh: Double): WindWarning? {
    if (days.isEmpty()) return null
    val today = days.firstOrNull()?.windKmhMax
    val next48 = days.take(2).mapNotNull { it.windKmhMax }.maxOrNull()
    if (today != null && today >= cautionKmh) {
        return WindWarning(isHigh = today >= warningKmh, maxKmh = today, timeframe = "Today")
    }
    if (next48 != null && next48 >= cautionKmh) {
        return WindWarning(isHigh = next48 >= warningKmh, maxKmh = next48, timeframe = "Next 48h")
    }
    return null
}

@Composable
private fun WindWarningBanner(warning: WindWarning, warningThresholdKmh: Double, cautionThresholdKmh: Double) {
    val vine = LocalVineColors.current
    val fmt = regionFormatter
    val tint = if (warning.isHigh) VineColors.Destructive else VineColors.Orange
    val title = if (warning.isHigh) "High wind warning" else "Spray caution: high wind forecast"
    val speed = fmt.formatSpeed(warning.maxKmh, 0)
    val subtitle = if (warning.isHigh) {
        "Wind forecast up to $speed ${warning.timeframe.lowercase()}. Wind is above the recommended spray limit — consider delaying spray operations."
    } else {
        "Wind forecast up to $speed ${warning.timeframe.lowercase()}. Conditions may be unsuitable for spraying — check on-site before applying."
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(tint.copy(alpha = 0.12f))
            .border(1.dp, tint.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
            .padding(12.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.Air, contentDescription = null, tint = tint, modifier = Modifier.size(28.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
            Text(
                "Limit: ${fmt.formatSpeed(warningThresholdKmh, 0)} · Caution: ${fmt.formatSpeed(cautionThresholdKmh, 0)}",
                fontSize = 10.sp, color = vine.textSecondary,
            )
        }
    }
}

// MARK: - Shared cards

@Composable
private fun UnavailableCard(message: String, onOpenWeatherSettings: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(vine.cardBackground).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Filled.Cloud, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
            Text(message, fontSize = 13.sp, color = vine.textSecondary)
        }
        if (onOpenWeatherSettings != null) {
            Row(
                modifier = Modifier.clickable(onClick = onOpenWeatherSettings),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text("Open Weather Settings", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Info)
                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(16.dp))
            }
        }
    }
}

@Composable
private fun LoadingCard(message: String) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(vine.cardBackground).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
        Text(message, fontSize = 13.sp, color = vine.textSecondary)
    }
}

// MARK: - Formatting helpers

/**
 * Display label for the active forecast source shown on the Daily forecast
 * header. Returns null while the source is still loading so the header stays
 * clean. Mirrors iOS `forecastSourceLabel`.
 */
private fun forecastSourceLabel(source: String?): String? {
    val raw = source?.trim().orEmpty()
    if (raw.isEmpty()) return null
    return when (raw.lowercase()) {
        "willyweather", "willy_weather", "willy-weather" -> "WillyWeather"
        "open_meteo", "open-meteo", "openmeteo" -> "Open-Meteo"
        "davis_weatherlink", "davis", "weatherlink" -> "Davis"
        "weather_underground", "wunderground" -> "Wunderground"
        else -> raw
    }
}

/** Pretty per-row provenance label, mirroring iOS `prettySource`. */
private fun prettySource(source: String?): String = when (source) {
    "manual" -> "Manual"
    "davis_weatherlink" -> "Davis"
    "open_meteo" -> "Open-Meteo"
    "weather_underground" -> "Wunderground"
    null, "" -> "—"
    else -> source.replaceFirstChar { it.uppercase() }
}

/** Region-aware "today so far" value: "—" when unknown, "0 mm"/"0 in" when dry. */
private fun formatMm(fmt: RegionFormatter, mm: Double?): String {
    if (mm == null) return "—"
    if (mm <= 0) return "0 ${fmt.rainfallUnitAbbreviation}"
    return fmt.formatRainfall(mm)
}

private fun dayLabel(epochMs: Long, timezone: TimeZone): String {
    val cal = Calendar.getInstance(timezone)
    val today = startOfDay(cal.timeInMillis, timezone)
    val target = startOfDay(epochMs, timezone)
    cal.timeInMillis = today
    cal.add(Calendar.DAY_OF_YEAR, 1)
    return when (target) {
        today -> "Today"
        cal.timeInMillis -> "Tomorrow"
        else -> SimpleDateFormat("EEEE", Locale.getDefault()).apply { timeZone = timezone }.format(Date(epochMs))
    }
}

private fun dateLabel(epochMs: Long, timezone: TimeZone): String =
    SimpleDateFormat("d MMM", Locale.getDefault()).apply { timeZone = timezone }.format(Date(epochMs))

/** Formats a "yyyy-MM-dd" calendar-day key as "dd/MM/yyyy" for display. */
private fun displayDateKey(dateKey: String): String = try {
    val parsed = SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(dateKey)
    if (parsed != null) SimpleDateFormat("dd/MM/yyyy", Locale.getDefault()).format(parsed) else dateKey
} catch (_: Exception) {
    dateKey
}

private fun startOfDay(epochMs: Long, timezone: TimeZone): Long {
    val cal = Calendar.getInstance(timezone)
    cal.timeInMillis = epochMs
    cal.set(Calendar.HOUR_OF_DAY, 0)
    cal.set(Calendar.MINUTE, 0)
    cal.set(Calendar.SECOND, 0)
    cal.set(Calendar.MILLISECOND, 0)
    return cal.timeInMillis
}

private fun conditionIcon(day: RainDay): ImageVector {
    val key = (day.conditionKey ?: day.conditionCode ?: day.condition ?: "").lowercase()
    return when {
        "storm" in key || "thunder" in key -> Icons.Filled.Grain
        "rain" in key || "shower" in key || "drizzle" in key -> Icons.Filled.WaterDrop
        "clear" in key || "sunny" in key -> Icons.Filled.WbSunny
        else -> Icons.Filled.Cloud
    }
}

private fun rainTint(mm: Double): Color = when {
    mm >= 10 -> VineColors.Info
    mm >= 1 -> VineColors.Cyan
    mm > 0 -> VineColors.LeafGreen
    else -> VineColors.Orange
}

private fun windTint(kmh: Double, warningKmh: Double, cautionKmh: Double): Color = when {
    kmh >= warningKmh -> VineColors.Destructive
    kmh >= cautionKmh -> VineColors.Orange
    else -> VineColors.TextSecondaryLight
}
