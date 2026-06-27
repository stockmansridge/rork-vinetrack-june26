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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.RainDay
import com.rork.vinetrack.data.RainForecastBundle
import com.rork.vinetrack.data.RainForecastRepository
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
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
    val repo = remember { RainForecastRepository() }

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
    var isLoading by remember { mutableStateOf(false) }
    var hasLoaded by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    fun refresh() {
        val loc = location ?: run {
            hasLoaded = true
            bundle = null
            return
        }
        scope.launch {
            isLoading = true
            errorMessage = null
            try {
                bundle = repo.fetch(loc.first, loc.second, pastDays = 30, forecastDays = 7)
            } catch (e: Exception) {
                errorMessage = e.message ?: "Could not load rain forecast."
            } finally {
                isLoading = false
                hasLoaded = true
            }
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
        val days = bundle?.forecast ?: emptyList()
        val rain24h = days.firstOrNull()?.rainMm ?: 0.0
        val rain48h = days.take(2).sumOf { it.rainMm }
        val rain7d = days.take(7).sumOf { it.rainMm }
        val todayMm = bundle?.todayMm
        val hasLocation = location != null

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
                StatusBanner(
                    todayMm = todayMm,
                    rain24h = rain24h,
                    rain48h = rain48h,
                    rain7d = rain7d,
                    hasLocation = hasLocation,
                    hasLoaded = hasLoaded,
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
                    hasLoaded = hasLoaded && hasLocation,
                )
            }

            item {
                DailyForecastSection(
                    days = days,
                    source = bundle?.source,
                    hasLocation = hasLocation,
                    isLoading = isLoading,
                    hasLoaded = hasLoaded,
                    warningThresholdKmh = windWarningThresholdKmh,
                    cautionThresholdKmh = windCautionThresholdKmh,
                    onOpenWeatherSettings = onOpenWeatherSettings,
                )
            }

            item {
                RainfallHistorySection(
                    history = bundle?.history ?: emptyList(),
                    source = bundle?.source,
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
    rain24h: Double,
    rain48h: Double,
    rain7d: Double,
    hasLocation: Boolean,
    hasLoaded: Boolean,
) {
    val tint = when {
        (todayMm ?: 0.0) > 0 || rain24h >= 5 -> VineColors.Info
        rain24h >= 1 || rain48h >= 1 -> VineColors.Cyan
        rain7d >= 1 -> VineColors.LeafGreen
        else -> VineColors.Orange
    }
    val icon = when {
        (todayMm ?: 0.0) > 0 -> Icons.Filled.WaterDrop
        rain24h >= 1 -> Icons.Filled.Grain
        rain7d >= 1 -> Icons.Filled.Cloud
        else -> Icons.Filled.WbSunny
    }
    val title = when {
        todayMm != null && todayMm > 0 -> "Rain recorded today: %.1f mm".format(todayMm)
        rain24h >= 1 -> "Rain expected in next 24h"
        rain48h >= 1 -> "Rain possible in next 48h"
        rain7d >= 1 -> "Rain possible this week"
        else -> "No rain forecast"
    }
    val subtitle = when {
        !hasLocation -> "Set vineyard location to enable forecast."
        !hasLoaded -> "Loading forecast…"
        else -> "Today %.1f mm · 24h %.1f mm · 7d %.1f mm".format(todayMm ?: 0.0, rain24h, rain7d)
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
    rain24h: Double,
    rain48h: Double,
    rain7d: Double,
    hasLoaded: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            SummaryTile("Today so far", formatMm(todayMm), Icons.Filled.WaterDrop, VineColors.Info, Modifier.weight(1f))
            SummaryTile("Next 24h", if (hasLoaded) "%.1f mm".format(rain24h) else "—", Icons.Filled.Grain, VineColors.Cyan, Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
            SummaryTile("Next 48h", if (hasLoaded) "%.1f mm".format(rain48h) else "—", Icons.Filled.Cloud, VineColors.Indigo, Modifier.weight(1f))
            SummaryTile("Next 7 days", if (hasLoaded) "%.1f mm".format(rain7d) else "—", Icons.Filled.CalendarMonth, VineColors.Primary, Modifier.weight(1f))
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
    source: String?,
    hasLocation: Boolean,
    isLoading: Boolean,
    hasLoaded: Boolean,
    warningThresholdKmh: Double,
    cautionThresholdKmh: Double,
    onOpenWeatherSettings: (() -> Unit)?,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Text("Daily forecast", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
            val sourceLabel = forecastSourceLabel(source)
            if (sourceLabel != null) {
                Text("Forecast source: $sourceLabel", fontSize = 11.sp, color = vine.textSecondary, maxLines = 1)
            }
        }
        when {
            !hasLocation -> UnavailableCard("Rain forecast is currently unavailable.", onOpenWeatherSettings)
            isLoading && days.isEmpty() -> LoadingCard("Loading forecast…")
            days.isEmpty() && hasLoaded -> UnavailableCard("Rain forecast is currently unavailable.", onOpenWeatherSettings)
            else -> Column(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(vine.cardBackground),
            ) {
                days.forEachIndexed { index, day ->
                    ForecastRow(day, warningThresholdKmh, cautionThresholdKmh)
                    if (index < days.lastIndex) {
                        HorizontalDivider(color = vine.cardBorder, modifier = Modifier.padding(start = 12.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun ForecastRow(day: RainDay, warningThresholdKmh: Double, cautionThresholdKmh: Double) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(modifier = Modifier.width(104.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(dayLabel(day.dateEpochMs), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(dateLabel(day.dateEpochMs), fontSize = 11.sp, color = vine.textSecondary)
        }
        Icon(rainIcon(day.rainMm), contentDescription = null, tint = rainTint(day.rainMm), modifier = Modifier.size(20.dp))
        Box(modifier = Modifier.weight(1f))
        val wind = day.windKmhMax
        if (wind != null) {
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Icon(Icons.Filled.Air, contentDescription = null, tint = windTint(wind, warningThresholdKmh, cautionThresholdKmh), modifier = Modifier.size(13.dp))
                    Text("${wind.roundToInt()} km/h", fontSize = 13.sp, color = windTint(wind, warningThresholdKmh, cautionThresholdKmh))
                }
                Text("Forecast wind", fontSize = 10.sp, color = vine.textSecondary)
            }
        }
        Text(
            "%.1f mm".format(day.rainMm),
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (day.rainMm >= 1) vine.textPrimary else vine.textSecondary,
            modifier = Modifier.width(64.dp),
        )
    }
}

// MARK: - Rainfall history section

@Composable
private fun RainfallHistorySection(
    history: List<RainDay>,
    source: String?,
    isLoading: Boolean,
    hasLoaded: Boolean,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
            Text("Recent rainfall", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
            Text("Last 30 days", fontSize = 11.sp, color = vine.textSecondary)
        }
        val rainDays = remember(history) { history.filter { it.rainMm > 0 }.sortedByDescending { it.dateEpochMs } }
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
                        Text(fullDateLabel(day.dateEpochMs), fontSize = 14.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                        Text(prettySource(source), fontSize = 12.sp, color = vine.textSecondary, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center, maxLines = 1)
                        Text("%.1f mm".format(day.rainMm), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.End)
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
                    Text("%.1f mm total".format(total), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
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
    val tint = if (warning.isHigh) VineColors.Destructive else VineColors.Orange
    val title = if (warning.isHigh) "High wind warning" else "Spray caution: high wind forecast"
    val speed = "${warning.maxKmh.roundToInt()} km/h"
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
                "Limit: ${warningThresholdKmh.roundToInt()} km/h · Caution: ${cautionThresholdKmh.roundToInt()} km/h",
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

private fun formatMm(mm: Double?): String {
    if (mm == null) return "—"
    if (mm <= 0) return "0 mm"
    return "%.1f mm".format(mm)
}

private fun dayLabel(epochMs: Long): String {
    val cal = Calendar.getInstance()
    val today = startOfDay(cal.timeInMillis)
    val target = startOfDay(epochMs)
    val dayMs = 24L * 60 * 60 * 1000
    return when (target) {
        today -> "Today"
        today + dayMs -> "Tomorrow"
        else -> SimpleDateFormat("EEEE", Locale.getDefault()).format(Date(epochMs))
    }
}

private fun dateLabel(epochMs: Long): String =
    SimpleDateFormat("d MMM", Locale.getDefault()).format(Date(epochMs))

private fun fullDateLabel(epochMs: Long): String =
    SimpleDateFormat("dd/MM/yyyy", Locale.getDefault()).format(Date(epochMs))

private fun startOfDay(epochMs: Long): Long {
    val cal = Calendar.getInstance()
    cal.timeInMillis = epochMs
    cal.set(Calendar.HOUR_OF_DAY, 0)
    cal.set(Calendar.MINUTE, 0)
    cal.set(Calendar.SECOND, 0)
    cal.set(Calendar.MILLISECOND, 0)
    return cal.timeInMillis
}

private fun rainIcon(mm: Double): ImageVector = when {
    mm >= 10 -> Icons.Filled.Grain
    mm >= 1 -> Icons.Filled.WaterDrop
    mm > 0 -> Icons.Filled.Cloud
    else -> Icons.Filled.WbSunny
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
