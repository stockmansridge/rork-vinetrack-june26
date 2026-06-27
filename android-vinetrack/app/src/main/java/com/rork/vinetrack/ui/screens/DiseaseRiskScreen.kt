package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CloudQueue
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
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
import com.rork.vinetrack.data.DailyDiseaseScore
import com.rork.vinetrack.data.DiseaseModel
import com.rork.vinetrack.data.DiseaseRiskAssessment
import com.rork.vinetrack.data.DiseaseRiskCalculator
import com.rork.vinetrack.data.DiseaseSeverity
import com.rork.vinetrack.data.WeatherHourlyRepository
import com.rork.vinetrack.data.VineyardWeatherIntegration
import com.rork.vinetrack.data.VineyardWeatherIntegrationRepository
import com.rork.vinetrack.data.WeatherIntegrationProvider
import com.rork.vinetrack.data.WillyWeatherRepository
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.computeDailyDiseaseScores
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Disease Risk Advisor — a read-only tool surfacing Downy, Powdery and Botrytis
 * pressure from free Open-Meteo hourly weather and an estimated leaf-wetness
 * proxy. Mirrors the iOS `DiseaseRiskAdvisorView` MVP: risk is computed entirely
 * on-device and nothing is persisted. Growth stage, spray history and variety
 * susceptibility are not applied.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiseaseRiskScreen(
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenTool: ((ToolRoute) -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val weatherRepo = remember { WeatherHourlyRepository() }
    val integrationRepo = remember { VineyardWeatherIntegrationRepository(SessionStore(context)) }
    val willyRepo = remember { WillyWeatherRepository(SessionStore(context)) }

    val paddocks = remember(state.paddocks, state.selectedVineyardId) {
        val vid = state.selectedVineyardId
        if (vid == null) state.paddocks else state.paddocks.filter { it.vineyardId == vid }
    }

    // Resolve a forecast location: vineyard coords, else any mapped block centroid.
    val vineyard = state.selectedVineyard
    val location = remember(vineyard, paddocks) {
        val lat = vineyard?.latitude ?: paddocks.firstNotNullOfOrNull { it.centroid }?.latitude
        val lon = vineyard?.longitude ?: paddocks.firstNotNullOfOrNull { it.centroid }?.longitude
        if (lat != null && lon != null) Pair(lat, lon) else null
    }

    var assessments by remember { mutableStateOf<List<DiseaseRiskAssessment>>(emptyList()) }
    var dailyScores by remember { mutableStateOf<List<DailyDiseaseScore>>(emptyList()) }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var lastUpdated by remember { mutableStateOf<Long?>(null) }
    var hasLoadedOnce by remember { mutableStateOf(false) }
    var showInfo by remember { mutableStateOf(false) }
    var sourceStatus by remember { mutableStateOf(WeatherSourceStatus.automatic) }
    var stationLocation by remember { mutableStateOf<Pair<Double, Double>?>(null) }

    fun refresh() {
        val loc = stationLocation ?: location
        if (loc == null) {
            hasLoadedOnce = true
            assessments = emptyList()
            dailyScores = emptyList()
            return
        }
        scope.launch {
            isLoading = true
            errorMessage = null
            try {
                val forecast = weatherRepo.fetch(loc.first, loc.second, pastDays = 3, forecastDays = 5)
                assessments = DiseaseRiskCalculator.assess(forecast.hours)
                dailyScores = computeDailyDiseaseScores(forecast.hours)
                lastUpdated = System.currentTimeMillis()
            } catch (e: Exception) {
                errorMessage = e.message ?: "Could not load weather data."
                assessments = emptyList()
                dailyScores = emptyList()
            } finally {
                isLoading = false
                hasLoadedOnce = true
            }
        }
    }

    LaunchedEffect(location) {
        if (!hasLoadedOnce) refresh()
    }

    // Resolve the vineyard's configured weather source so the advisor reflects
    // the real forecast provider and any connected local station (mirrors the
    // iOS WeatherProviderResolver). Falls back to automatic Open-Meteo.
    LaunchedEffect(state.selectedVineyardId) {
        val vid = state.selectedVineyardId ?: return@LaunchedEffect
        val preferOpenMeteo = runCatching { willyRepo.getProviderPreference(vid) }
            .getOrNull()?.equals("openmeteo", ignoreCase = true) ?: false
        val ww = runCatching { integrationRepo.fetch(vid, WeatherIntegrationProvider.WILLY_WEATHER) }.getOrNull()
        val wu = runCatching { integrationRepo.fetch(vid, WeatherIntegrationProvider.WUNDERGROUND) }.getOrNull()
        val davis = runCatching { integrationRepo.fetch(vid, WeatherIntegrationProvider.DAVIS) }.getOrNull()
        sourceStatus = resolveWeatherSource(preferOpenMeteo, ww, wu, davis)
        val sLat = davis?.stationLatitude ?: ww?.stationLatitude
        val sLon = davis?.stationLongitude ?: ww?.stationLongitude
        stationLocation = if (sLat != null && sLon != null) Pair(sLat, sLon) else null
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Disease Risk Advisor") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                actions = {
                    IconButton(onClick = { showInfo = true }) {
                        Icon(Icons.Filled.Info, contentDescription = "About disease risk")
                    }
                    IconButton(onClick = { refresh() }, enabled = !isLoading) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        containerColor = vine.appBackground,
        modifier = modifier,
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp,
                top = padding.calculateTopPadding() + 12.dp, bottom = 32.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            item { HeaderCard(lastUpdated, sourceStatus) }

            when {
                isLoading && assessments.isEmpty() -> item { LoadingCard() }
                errorMessage != null && assessments.isEmpty() -> item {
                    ErrorCard(errorMessage ?: "", onRetry = { refresh() })
                }
                location == null && hasLoadedOnce -> item { NoLocationCard() }
                assessments.isEmpty() && hasLoadedOnce -> item { EmptyRiskCard() }
                else -> {
                    item { DataQualityCard(lastUpdated, sourceStatus) }
                    item { SectionHeader("Current Risk", onLight = true) }
                    items(assessments) { a -> SummaryCard(a) }
                    if (dailyScores.isNotEmpty()) {
                        item { SectionHeader("7-Day Risk", onLight = true) }
                        item { SevenDayChart(dailyScores) }
                    }
                    item { SectionHeader("Details", onLight = true) }
                    items(assessments) { a -> DetailCard(a, lastUpdated) }
                    item { DisclaimerCard() }
                    if (onOpenTool != null) {
                        item {
                            PreferenceLink(
                                icon = Icons.Filled.NotificationsActive,
                                label = "Manage disease alert settings",
                                onClick = { onOpenTool(ToolRoute.Alerts) },
                            )
                        }
                        item {
                            PreferenceLink(
                                icon = Icons.Filled.CloudQueue,
                                label = "Weather Data & Forecasting",
                                onClick = { onOpenTool(ToolRoute.WeatherData) },
                            )
                        }
                    }
                }
            }
        }
    }

    if (showInfo) {
        AboutDialog(onDismiss = { showInfo = false })
    }
}

// MARK: - Weather source resolution

/** Configured-source quality, mirroring the iOS `WeatherSourceStatus.quality`. */
private enum class SourceQuality(val label: String) {
    LocalStationMeasuredWetness("Local station + leaf wetness"),
    LocalStation("Local station"),
    ForecastOnly("Forecast only"),
}

/** Resolved view of the vineyard's weather source, used to label the advisor. */
private data class WeatherSourceStatus(
    val forecastLabel: String,
    val stationLabel: String?,
    val hasLeafWetness: Boolean,
    val quality: SourceQuality,
) {
    companion object {
        val automatic = WeatherSourceStatus(
            forecastLabel = "Open-Meteo hourly (automatic)",
            stationLabel = null,
            hasLeafWetness = false,
            quality = SourceQuality.ForecastOnly,
        )
    }
}

/**
 * Resolve the configured forecast provider and any connected local station
 * (Davis WeatherLink / Weather Underground) into display labels + a quality
 * tier. An integration counts as active only when it is enabled and has a
 * saved station. Mirrors the iOS `WeatherProviderResolver` resolution order.
 */
private fun resolveWeatherSource(
    forecastPreferOpenMeteo: Boolean,
    willy: VineyardWeatherIntegration?,
    wunderground: VineyardWeatherIntegration?,
    davis: VineyardWeatherIntegration?,
): WeatherSourceStatus {
    fun active(i: VineyardWeatherIntegration?): Boolean =
        i != null && i.isActive && !i.stationId.isNullOrBlank()
    val wwActive = !forecastPreferOpenMeteo && active(willy)
    val davisActive = active(davis)
    val wuActive = active(wunderground)
    val forecastLabel = if (wwActive) {
        "WillyWeather — ${willy?.stationName ?: "configured location"}"
    } else {
        "Open-Meteo hourly (automatic)"
    }
    val stationLabel = when {
        davisActive -> "Davis WeatherLink — ${davis?.stationName ?: "station ${davis?.stationId}"}"
        wuActive -> "Weather Underground — ${wunderground?.stationName ?: wunderground?.stationId}"
        else -> null
    }
    val hasLeafWetness = davisActive && davis?.hasLeafWetness == true
    val quality = when {
        hasLeafWetness -> SourceQuality.LocalStationMeasuredWetness
        davisActive || wuActive -> SourceQuality.LocalStation
        else -> SourceQuality.ForecastOnly
    }
    return WeatherSourceStatus(forecastLabel, stationLabel, hasLeafWetness, quality)
}

// MARK: - Risk level mapping

private data class RiskLevel(val label: String, val color: Color)

private fun riskLevel(severity: DiseaseSeverity): RiskLevel = when (severity) {
    DiseaseSeverity.LOW -> RiskLevel("Low", VineColors.LeafGreen)
    DiseaseSeverity.MEDIUM -> RiskLevel("Medium", VineColors.Warning)
    DiseaseSeverity.HIGH -> RiskLevel("High", VineColors.Destructive)
}

private fun iconFor(model: DiseaseModel): ImageVector = when (model) {
    DiseaseModel.DOWNY_MILDEW -> Icons.Filled.Spa
    DiseaseModel.POWDERY_MILDEW -> Icons.Filled.WaterDrop
    DiseaseModel.BOTRYTIS -> Icons.Filled.BugReport
}

private fun driverText(model: DiseaseModel): String = when (model) {
    DiseaseModel.DOWNY_MILDEW ->
        "Drivers: rainfall over the past 48h, minimum temperature, and wet hours."
    DiseaseModel.POWDERY_MILDEW ->
        "Drivers: extended periods of 21–30°C with humidity ≥ 60% over the past 3 days."
    DiseaseModel.BOTRYTIS ->
        "Drivers: wet hours in the 15–25°C window over the past 36h."
}

private fun nextStepText(label: String): String = when (label) {
    "High" -> "Prioritise vineyard inspection and check whether protection is current. Conditions may favour disease development."
    "Medium" -> "Inspect susceptible blocks and review protection status."
    else -> "Continue monitoring."
}

/** Short provenance badge shown beside the score, mirroring iOS `sourceBadge`. */
private fun sourceBadgeText(model: DiseaseModel): String = when (model) {
    DiseaseModel.POWDERY_MILDEW -> "Temp + RH model"
    DiseaseModel.DOWNY_MILDEW, DiseaseModel.BOTRYTIS -> "Estimated wetness"
}

@Composable
private fun SourceBadge(model: DiseaseModel) {
    val vine = LocalVineColors.current
    Box(
        modifier = Modifier.clip(CircleShape).background(vine.textSecondary.copy(alpha = 0.12f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(sourceBadgeText(model), fontSize = 10.sp, color = vine.textSecondary)
    }
}

// MARK: - Cards

@Composable
private fun HeaderCard(lastUpdated: Long?, source: WeatherSourceStatus) {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier.size(36.dp).clip(RoundedCornerShape(10.dp))
                    .background(VineColors.LeafGreen.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Spa, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(20.dp))
            }
            Box(Modifier.size(10.dp))
            Text("Disease Risk Advisor", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        }
        Box(Modifier.height(8.dp))
        Text(
            "Forecast risk for Downy, Powdery and Botrytis based on weather conditions and estimated leaf wetness.",
            fontSize = 12.sp, color = vine.textSecondary,
        )
        Box(Modifier.height(8.dp))
        SourceRow("Forecast", source.forecastLabel)
        if (source.stationLabel != null) SourceRow("Local station", source.stationLabel)
        SourceRow(
            "Wetness",
            if (source.hasLeafWetness) "Davis leaf-wetness sensor connected"
            else "Estimated from rain / RH / dew point",
        )
        SourceRow("Growth stage", "Not applied")
        if (lastUpdated != null) {
            Box(Modifier.height(6.dp))
            Text(
                "Updated ${timeFmt.format(Date(lastUpdated))}",
                fontSize = 11.sp, color = vine.textSecondary,
            )
        }
    }
}

@Composable
private fun SourceRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(label, fontSize = 12.sp, color = vine.textSecondary, modifier = Modifier.width(96.dp))
        Text(value, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
    }
}

@Composable
private fun SummaryCard(assessment: DiseaseRiskAssessment) {
    val vine = LocalVineColors.current
    val level = riskLevel(assessment.severity)
    VineyardCard {
        Row(verticalAlignment = Alignment.Top) {
            Box(
                modifier = Modifier.size(40.dp).clip(CircleShape)
                    .background(level.color.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(iconFor(assessment.model), contentDescription = null, tint = level.color, modifier = Modifier.size(20.dp))
            }
            Box(Modifier.size(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(assessment.model.displayName, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
                    RiskPill(level)
                }
                Box(Modifier.height(4.dp))
                Text(assessment.summary, fontSize = 12.sp, color = vine.textSecondary)
                Box(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Score ${assessment.score}", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                    SourceBadge(assessment.model)
                }
            }
        }
    }
}

@Composable
private fun DataQualityCard(lastUpdated: Long?, source: WeatherSourceStatus) {
    val vine = LocalVineColors.current
    val isLocal = source.quality != SourceQuality.ForecastOnly
    val badgeColor = if (source.quality == SourceQuality.LocalStationMeasuredWetness) VineColors.LeafGreen else vine.textSecondary
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                if (isLocal) Icons.Filled.Sensors else Icons.Filled.CloudQueue,
                contentDescription = null,
                tint = if (isLocal) badgeColor else VineColors.Info,
                modifier = Modifier.size(16.dp),
            )
            Box(Modifier.size(8.dp))
            Text(source.stationLabel ?: "Automatic Forecast", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
            Box(
                modifier = Modifier.clip(CircleShape).background(badgeColor.copy(alpha = 0.15f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            ) {
                Text(source.quality.label, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = badgeColor)
            }
        }
        Box(Modifier.height(6.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Last updated: ${if (lastUpdated != null) timeFmt.format(Date(lastUpdated)) else "—"}",
                fontSize = 11.sp, color = vine.textSecondary, modifier = Modifier.weight(1f),
            )
            Text("Growth stage adjustment: Not applied", fontSize = 11.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun RiskPill(level: RiskLevel) {
    Box(
        modifier = Modifier.clip(CircleShape).background(level.color.copy(alpha = 0.15f))
            .padding(horizontal = 10.dp, vertical = 3.dp),
    ) {
        Text(level.label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = level.color)
    }
}

@Composable
private fun DetailCard(assessment: DiseaseRiskAssessment, lastUpdated: Long?) {
    val vine = LocalVineColors.current
    val level = riskLevel(assessment.severity)
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(iconFor(assessment.model), contentDescription = null, tint = level.color, modifier = Modifier.size(18.dp))
            Box(Modifier.size(8.dp))
            Text(assessment.model.displayName, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
            Text(level.label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = level.color)
        }
        Box(Modifier.height(8.dp))
        Text(driverText(assessment.model), fontSize = 12.sp, color = vine.textSecondary)
        Box(Modifier.height(6.dp))
        Text("Current assessment: ${level.label}. ${assessment.summary}", fontSize = 12.sp, color = vine.textPrimary)

        if (assessment.breakdown.isNotEmpty()) {
            Box(Modifier.height(10.dp))
            Column(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp))
                    .background(vine.textSecondary.copy(alpha = 0.06f)).padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text("Why this risk?", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                assessment.breakdown.forEach { (label, value) ->
                    Row(modifier = Modifier.fillMaxWidth()) {
                        Text(label, fontSize = 11.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
                        Text(value, fontSize = 11.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
                    }
                }
                Row(modifier = Modifier.fillMaxWidth()) {
                    Text("Resulting level", fontSize = 11.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
                    Text(level.label, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = level.color)
                }
            }
        }

        Box(Modifier.height(10.dp))
        Column(
            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp))
                .background(level.color.copy(alpha = 0.08f)).padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text("What to do next", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
            Text(nextStepText(level.label), fontSize = 12.sp, color = vine.textPrimary)
        }
        if (assessment.model != DiseaseModel.POWDERY_MILDEW) {
            Box(Modifier.height(8.dp))
            Text(
                "Based on estimated wetness (rain / RH / dew point proxy).",
                fontSize = 11.sp, color = vine.textSecondary,
            )
        }
        Box(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (lastUpdated != null) {
                Text(timeFmt.format(Date(lastUpdated)), fontSize = 11.sp, color = vine.textSecondary)
            }
            Box(Modifier.weight(1f))
            SourceBadge(assessment.model)
        }
    }
}

@Composable
private fun SevenDayChart(scores: List<DailyDiseaseScore>) {
    val vine = LocalVineColors.current
    val dayFmt = remember { SimpleDateFormat("EEE", Locale.getDefault()) }
    VineyardCard {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            scores.forEach { row ->
                Column(
                    modifier = Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Bottom,
                ) {
                    Row(
                        modifier = Modifier.height(96.dp),
                        verticalAlignment = Alignment.Bottom,
                        horizontalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Bar(row.downy, VineColors.Info)
                        Bar(row.powdery, VineColors.Orange)
                        Bar(row.botrytis, VineColors.Purple)
                    }
                    Box(Modifier.height(4.dp))
                    Text(dayFmt.format(Date(row.epochMs)), fontSize = 10.sp, color = vine.textSecondary)
                }
            }
        }
        Box(Modifier.height(12.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            LegendDot(VineColors.Info, "Downy")
            LegendDot(VineColors.Orange, "Powdery")
            LegendDot(VineColors.Purple, "Botrytis")
            Box(Modifier.weight(1f))
            Text("Low / Med / High", fontSize = 10.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun Bar(score: Int, color: Color) {
    // Map score (0–100) onto a 96dp tall column, min 4dp for visibility.
    val heightDp = (4 + (score / 100f) * 92f).dp
    Box(
        modifier = Modifier.width(7.dp).height(heightDp).clip(RoundedCornerShape(2.dp)).background(color),
    )
}

@Composable
private fun LegendDot(color: Color, label: String) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Box(Modifier.size(4.dp))
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
    }
}

@Composable
private fun PreferenceLink(icon: ImageVector, label: String, onClick: () -> Unit) {
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(18.dp))
            Box(Modifier.size(10.dp))
            Text(label, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Info, modifier = Modifier.weight(1f))
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun DisclaimerCard() {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.Top) {
            Icon(Icons.Filled.Info, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(18.dp))
            Box(Modifier.size(10.dp))
            Text(
                "Advisory estimate only — not a diagnosis or spray recommendation. Inspect the vineyard and follow your local agronomic advice, spray program and product labels.",
                fontSize = 12.sp, color = vine.textSecondary,
            )
        }
    }
}

@Composable
private fun LoadingCard() {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            Box(Modifier.size(10.dp))
            Text("Loading hourly forecast…", fontSize = 14.sp, color = vine.textSecondary)
        }
    }
}

@Composable
private fun ErrorCard(message: String, onRetry: () -> Unit) {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.WarningAmber, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(20.dp))
            Box(Modifier.size(8.dp))
            Text("Unable to load weather data", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        }
        Box(Modifier.height(6.dp))
        Text(message, fontSize = 12.sp, color = vine.textSecondary)
        Box(Modifier.height(6.dp))
        Text(
            "Pull to refresh, or check your weather data source in Settings → Weather Data & Forecasting.",
            fontSize = 11.sp, color = vine.textSecondary,
        )
        Box(Modifier.height(12.dp))
        OutlinedButton(onClick = onRetry) {
            Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
            Box(Modifier.size(6.dp))
            Text("Try again")
        }
    }
}

@Composable
private fun NoLocationCard() {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("No vineyard location", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        Box(Modifier.height(6.dp))
        Text(
            "Set your vineyard location, or map a block boundary, so we can fetch hourly weather and assess disease risk.",
            fontSize = 12.sp, color = vine.textSecondary,
        )
    }
}

@Composable
private fun EmptyRiskCard() {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("No assessable risk yet", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        Box(Modifier.height(6.dp))
        Text("Pull refresh to load hourly weather and assess risk.", fontSize = 12.sp, color = vine.textSecondary)
    }
}

@Composable
private fun AboutDialog(onDismiss: () -> Unit) {
    val vine = LocalVineColors.current
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = onDismiss) { Text("Done") }
        },
        title = { Text("About disease risk") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "This is a forecast risk tool, not a diagnosis. Always inspect the vineyard and follow local agronomic advice and product labels.",
                    fontSize = 13.sp, color = vine.textSecondary,
                )
                AboutBlock("Downy mildew", "Risk uses rainfall, temperature and wetness over the past 48 hours.")
                AboutBlock("Powdery mildew", "Risk uses favourable temperature (21–30°C) and humidity (≥ 60%) periods over the past 3 days. Leaf wetness is not used.")
                AboutBlock("Botrytis", "Risk uses wet hours within the 15–25°C window over the past 36 hours.")
                AboutBlock("Wetness source", "Wetness may be measured from a Davis WeatherLink leaf wetness sensor when available, or estimated from rainfall, humidity and dew-point spread.")
                AboutBlock("Important", "This tool does not recommend chemicals or claim that infection has occurred. Always inspect the vineyard and follow local agronomic advice and product labels.")
            }
        },
    )
}

@Composable
private fun AboutBlock(title: String, body: String) {
    val vine = LocalVineColors.current
    Column {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
        Text(body, fontSize = 12.sp, color = vine.textSecondary)
    }
}

private val timeFmt = SimpleDateFormat("h:mm a", Locale.getDefault())
