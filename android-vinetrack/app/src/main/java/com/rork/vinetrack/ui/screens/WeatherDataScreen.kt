package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Coronavirus
import androidx.compose.material.icons.filled.Opacity
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.VpnKey
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.DavisSensorSummary
import com.rork.vinetrack.data.DavisStation
import com.rork.vinetrack.data.DavisWeatherLinkRepository
import com.rork.vinetrack.data.OpenMeteoGapFillResult
import com.rork.vinetrack.data.RainfallHistoryBackfillRepository
import com.rork.vinetrack.data.VineyardWeatherIntegration
import com.rork.vinetrack.data.VineyardWeatherIntegrationRepository
import com.rork.vinetrack.data.WeatherIntegrationProvider
import com.rork.vinetrack.data.WillyWeatherLocation
import com.rork.vinetrack.data.WillyWeatherRepository
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

/** Forecast provider preference stored on `vineyards.forecast_provider`. */
private enum class ForecastProvider(
    val key: String,
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
    val tint: Color,
) {
    Auto("auto", "Automatic", "Use WillyWeather when configured, otherwise fall back to Open-Meteo.", Icons.Filled.AutoAwesome, VineColors.Indigo),
    OpenMeteo("open_meteo", "Open-Meteo Forecast", "Free global forecast service. Used for future rainfall, ET, temperature, wind and irrigation forecast calculations.", Icons.Filled.Public, VineColors.Info),
    WillyWeather("willyweather", "WillyWeather", "Australian-focused forecast service backed by the Bureau of Meteorology. Requires a WillyWeather API key.", Icons.Filled.WbSunny, VineColors.Orange),
    ;

    companion object {
        fun from(key: String?): ForecastProvider = entries.firstOrNull { it.key == key } ?: Auto
    }
}

/**
 * Weather Data & Forecasting setup. Mirrors the iOS `WeatherDataSettingsView`:
 * a per-vineyard forecast source picker (Open-Meteo / WillyWeather / Auto), the
 * shared WillyWeather location selection, and the local observation station
 * (Weather Underground PWS) — all stored on the shared vineyard so every member
 * uses the same source. Editing is owner/manager only; staff and operators see
 * a read-only view (the server RPCs/edge function also enforce this).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WeatherDataScreen(
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenTool: ((ToolRoute) -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val wwRepo = remember { WillyWeatherRepository(SessionStore(context)) }
    val integrationRepo = remember { VineyardWeatherIntegrationRepository(SessionStore(context)) }
    val davisRepo = remember { DavisWeatherLinkRepository(SessionStore(context)) }
    val backfillRepo = remember { RainfallHistoryBackfillRepository(SessionStore(context)) }
    val vineyardId = state.selectedVineyardId
    val vineyard = state.vineyards.firstOrNull { it.id == vineyardId }
    val canEdit = state.currentRole == "owner" || state.currentRole == "manager"

    var showWizard by remember { mutableStateOf(false) }
    if (showWizard) {
        BackHandler { showWizard = false }
        WeatherSetupWizardScreen(
            state = state,
            modifier = modifier,
            onBack = { showWizard = false },
            onOpenTool = onOpenTool,
        )
        return
    }

    var forecastProvider by remember { mutableStateOf(ForecastProvider.Auto) }
    var wwIntegration by remember { mutableStateOf<VineyardWeatherIntegration?>(null) }
    var wuIntegration by remember { mutableStateOf<VineyardWeatherIntegration?>(null) }
    var davisIntegration by remember { mutableStateOf<VineyardWeatherIntegration?>(null) }
    var loading by remember { mutableStateOf(true) }
    var statusMessage by remember { mutableStateOf<String?>(null) }

    suspend fun reload() {
        if (vineyardId == null) return
        runCatching { wwRepo.getProviderPreference(vineyardId) }.getOrNull()?.let {
            forecastProvider = ForecastProvider.from(it)
        }
        wwIntegration = runCatching {
            integrationRepo.fetch(vineyardId, WeatherIntegrationProvider.WILLY_WEATHER)
        }.getOrNull()
        wuIntegration = runCatching {
            integrationRepo.fetch(vineyardId, WeatherIntegrationProvider.WUNDERGROUND)
        }.getOrNull()
        davisIntegration = runCatching {
            integrationRepo.fetch(vineyardId, WeatherIntegrationProvider.DAVIS)
        }.getOrNull()
    }

    LaunchedEffect(vineyardId) {
        loading = true
        reload()
        loading = false
    }

    fun selectForecastProvider(p: ForecastProvider) {
        if (!canEdit || vineyardId == null || p == forecastProvider) return
        val previous = forecastProvider
        forecastProvider = p
        scope.launch {
            try {
                wwRepo.setProviderPreference(vineyardId, p.key)
            } catch (e: Exception) {
                forecastProvider = previous
                statusMessage = e.message ?: "Couldn't update forecast source."
            }
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Weather Data & Forecasting") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            if (loading) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
                    horizontalArrangement = Arrangement.Center,
                ) { CircularProgressIndicator(color = VineColors.Primary) }
            }

            statusMessage?.let { msg ->
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(msg, fontSize = 13.sp, color = VineColors.Destructive, modifier = Modifier.weight(1f))
                        TextButton(onClick = { statusMessage = null }) { Text("Dismiss") }
                    }
                }
            }

            // Guided setup wizard entry (owner/manager only)
            if (canEdit) {
                VineyardCard {
                    Row(
                        modifier = Modifier.fillMaxWidth().clickable { showWizard = true },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        WxIconTile(Icons.Filled.AutoAwesome, VineColors.Indigo)
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Weather Setup Wizard", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            Text(
                                "Guided setup: connect your sources and backfill rainfall history step by step.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
                    }
                }
            }

            // Forecast source picker
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Forecast Source", onLight = true)
                VineyardCard {
                    ForecastProvider.entries.forEachIndexed { index, p ->
                        if (index > 0) RowDividerWx(vine.cardBorder)
                        ForecastProviderRow(
                            provider = p,
                            selected = forecastProvider == p,
                            enabled = canEdit,
                            onClick = { selectForecastProvider(p) },
                        )
                    }
                }
                Text(
                    if (canEdit) "Forecast rainfall, ET, temperature, wind and irrigation forecast. Auto uses WillyWeather when configured for this vineyard, otherwise Open-Meteo."
                    else "Only owners and managers can change the forecast source.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }

            // WillyWeather location (shown for Auto + WillyWeather)
            if (forecastProvider != ForecastProvider.OpenMeteo) {
                WillyWeatherLocationSection(
                    integration = wwIntegration,
                    canEdit = canEdit,
                    vineyardLat = vineyard?.latitude,
                    vineyardLon = vineyard?.longitude,
                    onSearch = { query -> wwRepo.searchLocations(vineyardId ?: "", query, vineyard?.latitude, vineyard?.longitude) },
                    onSelect = { loc ->
                        scope.launch {
                            try {
                                if (vineyardId != null) {
                                    wwRepo.setLocation(vineyardId, loc)
                                    reload()
                                }
                            } catch (e: Exception) {
                                statusMessage = e.message ?: "Couldn't save location."
                            }
                        }
                    },
                    onClear = {
                        scope.launch {
                            try {
                                if (vineyardId != null) {
                                    wwRepo.deleteLocation(vineyardId)
                                    reload()
                                }
                            } catch (e: Exception) {
                                statusMessage = e.message ?: "Couldn't clear location."
                            }
                        }
                    },
                )
            }

            // Local observation source (Weather Underground PWS + Davis status)
            LocalObservationSection(
                wuIntegration = wuIntegration,
                davisIntegration = davisIntegration,
                canEdit = canEdit,
                onSaveStation = { stationId, stationName ->
                    scope.launch {
                        try {
                            if (vineyardId != null) {
                                integrationRepo.saveStation(
                                    vineyardId = vineyardId,
                                    provider = WeatherIntegrationProvider.WUNDERGROUND,
                                    stationId = stationId,
                                    stationName = stationName,
                                    hasRain = true,
                                )
                                reload()
                            }
                        } catch (e: Exception) {
                            statusMessage = e.message ?: "Couldn't save station."
                        }
                    }
                },
                onClearStation = {
                    scope.launch {
                        try {
                            if (vineyardId != null) {
                                integrationRepo.delete(vineyardId, WeatherIntegrationProvider.WUNDERGROUND)
                                reload()
                            }
                        } catch (e: Exception) {
                            statusMessage = e.message ?: "Couldn't clear station."
                        }
                    }
                },
            )

            // Weather-driven tools
            if (onOpenTool != null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Weather-Driven Tools", onLight = true)
                    VineyardCard {
                        WeatherToolRow(
                            Icons.Filled.Coronavirus,
                            VineColors.LeafGreen,
                            "Disease Risk",
                            "Downy, Powdery & Botrytis from hourly weather",
                            onClick = { onOpenTool(ToolRoute.DiseaseRisk) },
                        )
                        RowDividerWx(vine.cardBorder)
                        WeatherToolRow(
                            Icons.Filled.Opacity,
                            VineColors.Cyan,
                            "Irrigation",
                            "Water planning with rainfall outlook",
                            onClick = { onOpenTool(ToolRoute.Irrigation) },
                        )
                    }
                }
            }

            // Davis WeatherLink — full credential setup, test, station picker
            DavisWeatherLinkSection(
                integration = davisIntegration,
                canEdit = canEdit,
                vineyardId = vineyardId,
                repo = davisRepo,
                onChanged = { scope.launch { reload() } },
                onError = { statusMessage = it },
            )

            // Build rainfall history — Davis → WU → Open-Meteo gap fill
            if (canEdit) {
                BuildRainfallHistorySection(
                    vineyardId = vineyardId,
                    repo = backfillRepo,
                    davisStationId = davisIntegration
                        ?.takeIf { it.isActive }
                        ?.stationId
                        ?.takeIf { it.isNotBlank() },
                    wuStationId = wuIntegration
                        ?.takeIf { it.isActive }
                        ?.stationId
                        ?.takeIf { it.isNotBlank() },
                )
            }
        }
    }
}

/** A line of the running backfill log, with success/neutral styling. */
private data class BackfillLogLine(val text: String, val isError: Boolean = false)

/**
 * "Build rainfall history" — runs the best available sources in priority order
 * (Davis 60-day chunks → Weather Underground 30-day chunks → Open-Meteo gap
 * fill) to assemble up to 365 days of `rainfall_daily` rows. Manual records are
 * never overwritten, and Open-Meteo only fills days still missing afterwards.
 * Mirrors the iOS `buildRainfallHistorySection` flow. Owner/manager only.
 */
@Composable
private fun BuildRainfallHistorySection(
    vineyardId: String?,
    repo: RainfallHistoryBackfillRepository,
    davisStationId: String?,
    wuStationId: String?,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()

    var running by remember { mutableStateOf(false) }
    var phase by remember { mutableStateOf<String?>(null) }
    var fraction by remember { mutableStateOf(0f) }
    var log by remember { mutableStateOf<List<BackfillLogLine>>(emptyList()) }
    var finished by remember { mutableStateOf(false) }
    var hadError by remember { mutableStateOf(false) }

    fun run() {
        val vid = vineyardId ?: return
        running = true
        finished = false
        hadError = false
        phase = "Starting\u2026"
        fraction = 0f
        log = emptyList()
        scope.launch {
            try {
                // 1. Davis (if a station is configured).
                if (davisStationId != null) {
                    phase = "Davis WeatherLink\u2026"
                    val r = repo.backfillDavisChunked(
                        vineyardId = vid,
                        stationId = davisStationId,
                        onProgress = { p ->
                            fraction = (p.daysProcessed.toFloat() / p.daysRequested.toFloat()).coerceIn(0f, 1f)
                        },
                    )
                    log = log + BackfillLogLine(
                        "Davis: ${r.rowsUpserted} days filled" +
                            (if (r.rateLimited) " (rate-limited, resume later)" else "") +
                            (if (r.errorsCount > 0) " \u00b7 ${r.errorsCount} errors" else ""),
                        isError = r.errorsCount > 0,
                    )
                    if (r.errorsCount > 0) hadError = true
                } else {
                    log = log + BackfillLogLine("Davis: no station configured \u2014 skipped")
                }

                // 2. Weather Underground (if a PWS is configured).
                if (wuStationId != null) {
                    phase = "Weather Underground\u2026"
                    fraction = 0f
                    val r = repo.backfillWundergroundChunked(
                        vineyardId = vid,
                        stationId = wuStationId,
                        onProgress = { p ->
                            fraction = (p.daysProcessed.toFloat() / p.daysRequested.toFloat()).coerceIn(0f, 1f)
                        },
                    )
                    log = log + BackfillLogLine(
                        "Weather Underground: ${r.rowsUpserted} days filled" +
                            (if (r.rateLimited) " (rate-limited, resume later)" else "") +
                            (if (r.errorsCount > 0) " \u00b7 ${r.errorsCount} errors" else ""),
                        isError = r.errorsCount > 0,
                    )
                    if (r.errorsCount > 0) hadError = true
                } else {
                    log = log + BackfillLogLine("Weather Underground: no station configured \u2014 skipped")
                }

                // 3. Open-Meteo gap fill (lowest priority, fills remaining days).
                phase = "Open-Meteo gap fill\u2026"
                fraction = 1f
                val om: OpenMeteoGapFillResult = repo.backfillOpenMeteoGaps(vid)
                log = log + BackfillLogLine(
                    "Open-Meteo: ${om.rowsUpserted} gaps filled \u00b7 ${om.daysSkippedBetterSource} kept from better source" +
                        (if (om.errorsCount > 0) " \u00b7 ${om.errorsCount} errors" else ""),
                    isError = om.errorsCount > 0,
                )
                if (om.errorsCount > 0) hadError = true

                phase = "Done"
                finished = true
            } catch (e: Exception) {
                hadError = true
                finished = true
                log = log + BackfillLogLine(e.message ?: "Rainfall history build failed.", isError = true)
            } finally {
                running = false
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Build Rainfall History", onLight = true)
        VineyardCard {
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                WxIconTile(Icons.Filled.CalendarMonth, VineColors.Indigo)
                Column(modifier = Modifier.weight(1f)) {
                    Text("Build up to 365 days", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                    Text(
                        "Fills rainfall history from the best available sources: Davis first, then Weather Underground, then Open-Meteo for remaining gaps. Manual records are never overwritten.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            if (running || log.isNotEmpty()) {
                RowDividerWx(vine.cardBorder)
                Column(modifier = Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (running) {
                        phase?.let { Text(it, fontSize = 12.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary) }
                        LinearProgressIndicator(
                            progress = { fraction },
                            modifier = Modifier.fillMaxWidth(),
                            color = VineColors.Primary,
                        )
                    }
                    log.forEach { line ->
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(
                                if (line.isError) Icons.Filled.Close else Icons.Filled.Check,
                                contentDescription = null,
                                tint = if (line.isError) VineColors.Destructive else VineColors.Success,
                                modifier = Modifier.size(14.dp),
                            )
                            Text(line.text, fontSize = 12.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
                        }
                    }
                    if (finished) {
                        Text(
                            if (hadError) "Finished with some errors. Safe to re-run \u2014 already-filled days are skipped."
                            else "Rainfall history is up to date.",
                            fontSize = 12.sp,
                            color = if (hadError) VineColors.Warning else VineColors.Success,
                        )
                    }
                }
            }

            RowDividerWx(vine.cardBorder)
            Button(
                onClick = { run() },
                enabled = !running && vineyardId != null,
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
            ) {
                if (running) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                } else {
                    Text(if (finished) "Re-run rainfall history build" else "Build 365-day rainfall history")
                }
            }
        }
        Text(
            "Davis runs in 60-day chunks, Weather Underground in 30-day chunks, then Open-Meteo fills any days still missing. If a station source is rate-limited it stops gracefully \u2014 just re-run to continue.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun ForecastProviderRow(
    provider: ForecastProvider,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (enabled) it.clickable { onClick() } else it }
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        WxIconTile(provider.icon, provider.tint)
        Column(modifier = Modifier.weight(1f)) {
            Text(provider.title, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(provider.subtitle, fontSize = 12.sp, color = vine.textSecondary)
        }
        if (selected) {
            Icon(Icons.Filled.Check, contentDescription = "Selected", tint = VineColors.Success)
        }
    }
}

@Composable
private fun WillyWeatherLocationSection(
    integration: VineyardWeatherIntegration?,
    canEdit: Boolean,
    vineyardLat: Double?,
    vineyardLon: Double?,
    onSearch: suspend (String) -> List<WillyWeatherLocation>,
    onSelect: (WillyWeatherLocation) -> Unit,
    onClear: () -> Unit,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<WillyWeatherLocation>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var searchError by remember { mutableStateOf<String?>(null) }

    fun runSearch(q: String) {
        if (q.isBlank() && (vineyardLat == null || vineyardLon == null)) return
        searching = true
        searchError = null
        scope.launch {
            try {
                results = onSearch(q)
                if (results.isEmpty()) searchError = "No matching forecast locations found."
            } catch (e: Exception) {
                searchError = e.message ?: "Search failed."
            } finally {
                searching = false
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("WillyWeather", onLight = true)
        VineyardCard {
            val current = integration?.takeIf { it.isActive && !it.stationId.isNullOrBlank() }
            if (current != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    WxIconTile(Icons.Filled.WbSunny, VineColors.Orange)
                    Column(modifier = Modifier.weight(1f)) {
                        Text(current.stationName ?: "Selected location", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        Text("WillyWeather forecast source for this vineyard", fontSize = 12.sp, color = vine.textSecondary)
                    }
                    if (canEdit) {
                        IconButton(onClick = onClear) {
                            Icon(Icons.Filled.Close, contentDescription = "Clear location", tint = vine.textSecondary)
                        }
                    }
                }
            } else {
                Text(
                    "No WillyWeather location selected yet.",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                )
            }
        }

        if (canEdit) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                label = { Text("Search by suburb or postcode") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                trailingIcon = {
                    TextButton(onClick = { runSearch(query) }, enabled = !searching) {
                        Text(if (searching) "…" else "Find")
                    }
                },
            )
            if (vineyardLat != null && vineyardLon != null) {
                TextButton(onClick = { runSearch("") }, enabled = !searching) {
                    Text("Find nearest WillyWeather location")
                }
            }
            searchError?.let { Text(it, fontSize = 12.sp, color = VineColors.Destructive) }
            if (results.isNotEmpty()) {
                VineyardCard {
                    results.forEachIndexed { index, loc ->
                        if (index > 0) RowDividerWx(vine.cardBorder)
                        Row(
                            modifier = Modifier.fillMaxWidth().clickable {
                                onSelect(loc)
                                results = emptyList()
                                query = ""
                            }.padding(vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(loc.name, fontWeight = FontWeight.Medium, color = vine.textPrimary)
                                val sub = listOfNotNull(
                                    loc.region ?: loc.state,
                                    loc.distanceKm?.let { "${it} km" },
                                ).joinToString(" · ")
                                if (sub.isNotBlank()) Text(sub, fontSize = 12.sp, color = vine.textSecondary)
                            }
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LocalObservationSection(
    wuIntegration: VineyardWeatherIntegration?,
    davisIntegration: VineyardWeatherIntegration?,
    canEdit: Boolean,
    onSaveStation: (String, String?) -> Unit,
    onClearStation: () -> Unit,
) {
    val vine = LocalVineColors.current
    val current = wuIntegration?.takeIf { it.isActive && !it.stationId.isNullOrBlank() }
    var editing by remember(current?.stationId) { mutableStateOf(false) }
    var stationId by remember(current?.stationId) { mutableStateOf(current?.stationId ?: "") }
    var stationName by remember(current?.stationName) { mutableStateOf(current?.stationName ?: "") }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Local Observation Source", onLight = true)
        VineyardCard {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                WxIconTile(Icons.Filled.Air, VineColors.Cyan)
                Column(modifier = Modifier.weight(1f)) {
                    Text("Weather Underground PWS", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                    Text(
                        if (current != null) "Station ${current.stationId}" + (current.stationName?.let { " · $it" } ?: "")
                        else "Use a nearby personal weather station for recent rainfall.",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            if (canEdit) {
                RowDividerWx(vine.cardBorder)
                if (editing || current == null) {
                    Column(modifier = Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedTextField(
                            value = stationId,
                            onValueChange = { stationId = it },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            label = { Text("Station ID (e.g. IBAROS1)") },
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters),
                        )
                        OutlinedTextField(
                            value = stationName,
                            onValueChange = { stationName = it },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            label = { Text("Label (optional)") },
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(
                                onClick = {
                                    if (stationId.isNotBlank()) {
                                        onSaveStation(stationId.trim().uppercase(), stationName.trim().ifBlank { null })
                                        editing = false
                                    }
                                },
                            ) { Text("Save station") }
                            if (current != null) {
                                TextButton(onClick = { editing = false }) { Text("Cancel") }
                            }
                        }
                    }
                } else {
                    Row(modifier = Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = { editing = true }) { Text("Change") }
                        TextButton(onClick = onClearStation) {
                            Text("Remove", color = VineColors.Destructive)
                        }
                    }
                }
            }
        }
        Text(
            "Recent rainfall and current conditions prefer a local station when configured, falling back to the Open-Meteo archive otherwise.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun WeatherToolRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        WxIconTile(icon, tint)
        Column(modifier = Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
    }
}

@Composable
private fun WxIconTile(icon: ImageVector, tint: Color) {
    Box(
        modifier = Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(tint.copy(alpha = 0.15f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun RowDividerWx(color: Color) {
    Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(color))
}

/**
 * Davis WeatherLink credential setup. Owner/manager can enter the v2 API
 * key/secret, test the connection (which lists stations), pick a station
 * (detecting its sensors) and remove the integration. Operators see a
 * read-only status. Mirrors the iOS Davis section of `WeatherDataSettingsView`.
 */
@Composable
private fun DavisWeatherLinkSection(
    integration: VineyardWeatherIntegration?,
    canEdit: Boolean,
    vineyardId: String?,
    repo: DavisWeatherLinkRepository,
    onChanged: () -> Unit,
    onError: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()

    val hasCredentials = integration?.hasApiKey == true && integration.hasApiSecret
    val stationActive = integration?.isActive == true && !integration.stationId.isNullOrBlank()

    var editing by remember(hasCredentials) { mutableStateOf(false) }
    var apiKey by remember { mutableStateOf("") }
    var apiSecret by remember { mutableStateOf("") }
    var showSecret by remember { mutableStateOf(false) }
    var testing by remember { mutableStateOf(false) }
    var testMessage by remember { mutableStateOf<String?>(null) }
    var testOk by remember { mutableStateOf(false) }
    var stations by remember { mutableStateOf<List<DavisStation>>(emptyList()) }
    var savingStation by remember { mutableStateOf<String?>(null) }

    fun pickStation(station: DavisStation) {
        if (vineyardId == null) return
        savingStation = station.stationId
        scope.launch {
            try {
                val sensors = runCatching { repo.detectSensors(vineyardId, station.stationId) }
                    .getOrDefault(DavisSensorSummary())
                repo.saveStation(vineyardId, station, sensors)
                stations = emptyList()
                editing = false
                apiKey = ""; apiSecret = ""
                testMessage = null
                onChanged()
            } catch (e: Exception) {
                onError(e.message ?: "Couldn't save station.")
            } finally {
                savingStation = null
            }
        }
    }

    fun testAndConnect() {
        if (vineyardId == null || apiKey.isBlank() || apiSecret.isBlank()) return
        testing = true
        testMessage = null
        testOk = false
        scope.launch {
            try {
                val found = repo.testConnection(vineyardId, apiKey, apiSecret)
                repo.saveCredentials(vineyardId, apiKey, apiSecret)
                stations = found
                testOk = true
                testMessage = if (found.size == 1)
                    "Connected. Saving station\u2026"
                else
                    "Connected \u2014 ${found.size} stations found. Choose one below."
                if (found.size == 1) {
                    pickStation(found.first())
                } else {
                    onChanged()
                }
            } catch (e: Exception) {
                testOk = false
                testMessage = e.message ?: "Could not connect. Check your API Key and Secret."
            } finally {
                testing = false
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionHeader("Davis WeatherLink", onLight = true)
        VineyardCard {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                WxIconTile(Icons.Filled.Sensors, VineColors.Warning)
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        if (stationActive) "Connected \u00b7 ${integration?.stationName ?: integration?.stationId}"
                        else if (hasCredentials) "Connected \u2014 station required"
                        else "Not connected",
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    Text(
                        when {
                            stationActive && integration?.hasLeafWetness == true ->
                                "Measured leaf wetness available for disease risk."
                            stationActive -> "Davis station powers rainfall, current conditions and irrigation here."
                            hasCredentials -> "Credentials saved. Choose a station to finish setup."
                            canEdit -> "Connect your WeatherLink v2 API key to share a Davis station with every member."
                            else -> "Davis WeatherLink is managed by your vineyard owner or manager."
                        },
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
                if (stationActive) {
                    Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Success)
                }
            }

            // Detected sensors when configured.
            if (stationActive && integration != null && integration.detectedSensors.isNotEmpty()) {
                RowDividerWx(vine.cardBorder)
                Column(modifier = Modifier.padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Detected sensors", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                    integration.detectedSensors.forEach { sensor ->
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Success, modifier = Modifier.size(14.dp))
                            Text(sensor, fontSize = 12.sp, color = vine.textPrimary)
                        }
                    }
                }
            }

            if (canEdit) {
                RowDividerWx(vine.cardBorder)
                Column(modifier = Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (editing || !hasCredentials) {
                        OutlinedTextField(
                            value = apiKey,
                            onValueChange = { apiKey = it },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            label = { Text("API Key") },
                            leadingIcon = { Icon(Icons.Filled.VpnKey, contentDescription = null) },
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None),
                        )
                        OutlinedTextField(
                            value = apiSecret,
                            onValueChange = { apiSecret = it },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true,
                            label = { Text("API Secret") },
                            visualTransformation = if (showSecret) VisualTransformation.None else PasswordVisualTransformation(),
                            trailingIcon = {
                                IconButton(onClick = { showSecret = !showSecret }) {
                                    Icon(
                                        if (showSecret) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                                        contentDescription = if (showSecret) "Hide secret" else "Show secret",
                                    )
                                }
                            },
                            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None),
                        )
                        Text(
                            "Generate a v2 API Key and Secret from Account Settings on weatherlink.com. Stored securely on the vineyard and used by every member through a secure proxy.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                        Button(
                            onClick = { testAndConnect() },
                            enabled = !testing && apiKey.isNotBlank() && apiSecret.isNotBlank(),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            if (testing) {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                            } else {
                                Text("Test & Connect")
                            }
                        }
                        if (hasCredentials) {
                            TextButton(onClick = { editing = false; apiKey = ""; apiSecret = ""; testMessage = null }) {
                                Text("Cancel")
                            }
                        }
                    } else {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(onClick = { editing = true }) { Text("Replace credentials") }
                            TextButton(onClick = {
                                if (vineyardId != null) scope.launch {
                                    try { repo.remove(vineyardId); onChanged() }
                                    catch (e: Exception) { onError(e.message ?: "Couldn't remove.") }
                                }
                            }) { Text("Remove", color = VineColors.Destructive) }
                        }
                    }

                    testMessage?.let { msg ->
                        Text(msg, fontSize = 12.sp, color = if (testOk) VineColors.Success else VineColors.Destructive)
                    }

                    // Station picker after a successful test (or when a station
                    // is still required for saved credentials).
                    if (stations.isNotEmpty()) {
                        Text("Choose station", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                        stations.forEach { station ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(enabled = savingStation == null) { pickStation(station) }
                                    .padding(vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(station.name, fontWeight = FontWeight.Medium, color = vine.textPrimary)
                                    Text("Station ${station.stationId}", fontSize = 12.sp, color = vine.textSecondary)
                                }
                                if (savingStation == station.stationId) {
                                    CircularProgressIndicator(modifier = Modifier.size(16.dp), color = VineColors.Primary, strokeWidth = 2.dp)
                                } else if (integration?.stationId == station.stationId) {
                                    Icon(Icons.Filled.Check, contentDescription = "Selected", tint = VineColors.Success)
                                } else {
                                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
                                }
                            }
                        }
                    } else if (hasCredentials && !stationActive && !editing) {
                        TextButton(onClick = {
                            if (vineyardId != null) scope.launch {
                                try { stations = repo.fetchStations(vineyardId) }
                                catch (e: Exception) { onError(e.message ?: "Couldn't load stations.") }
                            }
                        }) { Text("Choose station") }
                    } else if (stationActive && !editing) {
                        TextButton(onClick = {
                            if (vineyardId != null) scope.launch {
                                try { stations = repo.fetchStations(vineyardId) }
                                catch (e: Exception) { onError(e.message ?: "Couldn't load stations.") }
                            }
                        }) { Text("Change station") }
                    }
                }
            }
        }
    }
}
