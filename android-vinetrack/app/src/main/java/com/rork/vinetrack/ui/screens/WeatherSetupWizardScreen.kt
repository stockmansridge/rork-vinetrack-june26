package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CloudQueue
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Opacity
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.NearbyWuStation
import com.rork.vinetrack.data.RainfallHistoryBackfillRepository
import com.rork.vinetrack.data.VineyardWeatherIntegration
import com.rork.vinetrack.data.VineyardWeatherIntegrationRepository
import com.rork.vinetrack.data.WeatherIntegrationProvider
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.components.WuNearbyStationsFinder
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

/**
 * Weather Setup Wizard — Android counterpart of the iOS `WeatherSetupWizardView`.
 * A guided, owner/manager-only flow that walks a new vineyard through connecting
 * its weather sources and backfilling rainfall history so the Rain Calendar,
 * GDD, Disease Risk and Irrigation advice all have useful data from day one.
 *
 * Six steps: intro → Davis WeatherLink → Weather Underground → Open-Meteo →
 * summary → finish. Each provider step surfaces connection status and runs a
 * rainfall backfill via [RainfallHistoryBackfillRepository] with row counts.
 * Davis credentials still live in Weather Data & Forecasting — the wizard
 * surfaces status and nudges the user there if Davis isn't connected yet.
 */
private enum class WxStep(val title: String) {
    Intro("Welcome"),
    Davis("Davis WeatherLink"),
    Wunderground("Weather Underground"),
    OpenMeteo("Open-Meteo"),
    Summary("Summary"),
    Finish("Done"),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WeatherSetupWizardScreen(
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onOpenTool: ((ToolRoute) -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val integrationRepo = remember { VineyardWeatherIntegrationRepository(SessionStore(context)) }
    val backfillRepo = remember { RainfallHistoryBackfillRepository(SessionStore(context)) }

    val vineyardId = state.selectedVineyardId
    val canEdit = state.currentRole == "owner" || state.currentRole == "manager"

    // Search location for nearby WU stations, matching the iOS priority:
    // vineyard latitude/longitude → block/paddock centroid.
    val vineyard = state.vineyards.firstOrNull { it.id == vineyardId }
    val searchCoordinates = remember(vineyard, state.paddocks, vineyardId) {
        val paddockCentroid = state.paddocks
            .filter { vineyardId == null || it.vineyardId == vineyardId }
            .firstNotNullOfOrNull { it.centroid }
        val lat = vineyard?.latitude ?: paddockCentroid?.latitude
        val lon = vineyard?.longitude ?: paddockCentroid?.longitude
        if (lat != null && lon != null && (lat != 0.0 || lon != 0.0)) Pair(lat, lon) else null
    }

    var step by remember { mutableIntStateOf(WxStep.Intro.ordinal) }

    var davisIntegration by remember { mutableStateOf<VineyardWeatherIntegration?>(null) }
    var wuIntegration by remember { mutableStateOf<VineyardWeatherIntegration?>(null) }

    // Backfill tallies shown on the summary step.
    var davisRows by remember { mutableIntStateOf(0) }
    var wuRows by remember { mutableIntStateOf(0) }
    var openMeteoRows by remember { mutableIntStateOf(0) }
    var davisSkipped by remember { mutableStateOf(false) }
    var wuSkipped by remember { mutableStateOf(false) }
    var openMeteoSkipped by remember { mutableStateOf(false) }

    suspend fun reload() {
        if (vineyardId == null) return
        davisIntegration = runCatching {
            integrationRepo.fetch(vineyardId, WeatherIntegrationProvider.DAVIS)
        }.getOrNull()
        wuIntegration = runCatching {
            integrationRepo.fetch(vineyardId, WeatherIntegrationProvider.WUNDERGROUND)
        }.getOrNull()
    }

    LaunchedEffect(vineyardId) { reload() }

    val davisStationId = davisIntegration
        ?.takeIf { it.isActive }?.stationId?.takeIf { it.isNotBlank() }
    val wuStationId = wuIntegration
        ?.takeIf { it.isActive }?.stationId?.takeIf { it.isNotBlank() }
    val davisConfigured = davisStationId != null
    val wuConfigured = wuStationId != null

    fun advance() {
        if (step == WxStep.Davis.ordinal && !davisConfigured) davisSkipped = true
        if (step == WxStep.Wunderground.ordinal && !wuConfigured) wuSkipped = true
        if (step == WxStep.OpenMeteo.ordinal && openMeteoRows == 0) openMeteoSkipped = true
        step = (step + 1).coerceAtMost(WxStep.Finish.ordinal)
    }
    fun goBack() { step = (step - 1).coerceAtLeast(0) }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Weather Setup Wizard") },
                navigationIcon = { BackNavIcon(onBack) },
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
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            WxProgressHeader(step)

            AnimatedContent(
                targetState = step,
                transitionSpec = { fadeIn() togetherWith fadeOut() },
                label = "weather-wizard-step",
            ) { current ->
                when (WxStep.entries[current]) {
                    WxStep.Intro -> IntroStep(canEdit)
                    WxStep.Davis -> DavisStep(
                        canEdit = canEdit,
                        configured = davisConfigured,
                        stationLabel = davisIntegration?.stationName ?: davisStationId,
                        vineyardId = vineyardId,
                        stationId = davisStationId,
                        backfillRepo = backfillRepo,
                        onBackfilled = { davisRows = it },
                        onOpenSettings = { onOpenTool?.invoke(ToolRoute.WeatherData) ?: onBack() },
                        onSkip = { davisSkipped = true; advance() },
                    )
                    WxStep.Wunderground -> WundergroundStep(
                        canEdit = canEdit,
                        configured = wuConfigured,
                        integration = wuIntegration,
                        vineyardId = vineyardId,
                        backfillRepo = backfillRepo,
                        coordinates = searchCoordinates,
                        onFindNearby = { lat, lon -> integrationRepo.nearbyStations(lat, lon) },
                        onSelectNearby = { station ->
                            if (vineyardId != null) {
                                integrationRepo.saveStation(
                                    vineyardId = vineyardId,
                                    provider = WeatherIntegrationProvider.WUNDERGROUND,
                                    stationId = station.stationId,
                                    stationName = station.name?.trim()?.takeIf { it.isNotEmpty() },
                                    hasRain = true,
                                )
                                reload()
                            }
                        },
                        onSaveStation = { id, name ->
                            scope.launch {
                                if (vineyardId != null) {
                                    runCatching {
                                        integrationRepo.saveStation(
                                            vineyardId = vineyardId,
                                            provider = WeatherIntegrationProvider.WUNDERGROUND,
                                            stationId = id,
                                            stationName = name,
                                            hasRain = true,
                                        )
                                    }
                                    reload()
                                }
                            }
                        },
                        onBackfilled = { wuRows = it },
                    )
                    WxStep.OpenMeteo -> OpenMeteoStep(
                        canEdit = canEdit,
                        vineyardId = vineyardId,
                        backfillRepo = backfillRepo,
                        onBackfilled = { openMeteoRows = it },
                    )
                    WxStep.Summary -> SummaryStep(
                        davisConfigured = davisConfigured,
                        davisSkipped = davisSkipped,
                        wuConfigured = wuConfigured,
                        wuSkipped = wuSkipped,
                        davisRows = davisRows,
                        wuRows = wuRows,
                        openMeteoRows = openMeteoRows,
                        openMeteoSkipped = openMeteoSkipped,
                        canEdit = canEdit,
                        vineyardId = vineyardId,
                        backfillRepo = backfillRepo,
                        davisStationId = davisStationId,
                        wuStationId = wuStationId,
                    )
                    WxStep.Finish -> FinishStep(
                        onOpenIrrigation = { onOpenTool?.invoke(ToolRoute.Irrigation) ?: onBack() },
                        onOpenWeatherSettings = { onOpenTool?.invoke(ToolRoute.WeatherData) ?: onBack() },
                        onDone = onBack,
                    )
                }
            }

            Spacer(Modifier.height(4.dp))

            if (WxStep.entries[step] != WxStep.Finish) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (step != WxStep.Intro.ordinal) {
                        OutlinedButton(onClick = { goBack() }, modifier = Modifier.weight(1f)) {
                            Text("Back")
                        }
                    }
                    Button(onClick = { advance() }, modifier = Modifier.weight(1f)) {
                        Text(
                            when (WxStep.entries[step]) {
                                WxStep.Intro -> "Get started"
                                WxStep.Davis -> if (davisConfigured) "Continue" else "Skip Davis"
                                WxStep.Wunderground -> if (wuConfigured) "Continue" else "Skip"
                                WxStep.OpenMeteo -> if (openMeteoRows > 0) "Continue" else "Skip"
                                WxStep.Summary -> "Finish"
                                WxStep.Finish -> "Done"
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun WxProgressHeader(step: Int) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
            WxStep.entries.forEach { s ->
                val color = when {
                    s.ordinal < step -> VineColors.Success
                    s.ordinal == step -> VineColors.Primary
                    else -> vine.cardBorder
                }
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(4.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(color),
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Step ${step + 1} of ${WxStep.entries.size}",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textSecondary,
                modifier = Modifier.weight(1f),
            )
            Text(
                WxStep.entries[step].title,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
            )
        }
    }
}

@Composable
private fun IntroStep(canEdit: Boolean) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Box(
            modifier = Modifier.size(64.dp).clip(RoundedCornerShape(16.dp))
                .background(VineColors.Info.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.CloudQueue, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(34.dp))
        }
        Text("Set up vineyard weather", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
        Text(
            "VineTrack can use your vineyard weather station to improve rainfall history, irrigation advice, alerts and spray planning.",
            fontSize = 14.sp,
            color = vine.textSecondary,
            lineHeight = 20.sp,
        )
        WxBullet(Icons.Filled.Sensors, VineColors.Warning, "Davis WeatherLink (optional)",
            "If you own a WeatherLink-enabled station, connect it for the most accurate vineyard rainfall. Skip this step if you don't have one.")
        WxBullet(Icons.Filled.Air, VineColors.Cyan, "Weather Underground",
            "Pick a nearby personal weather station as a backup rainfall source.")
        WxBullet(Icons.Filled.CalendarMonth, VineColors.Success, "Rainfall history",
            "Backfill recent rainfall after setup so the Rain Calendar has useful history.")
        if (!canEdit) {
            WxInfoCard(VineColors.Orange, Icons.Filled.Info, "Read-only access",
                "Only owners and managers can configure weather services. Ask your owner or manager to run this wizard.")
        }
        WxPriorityCard()
    }
}

@Composable
private fun DavisStep(
    canEdit: Boolean,
    configured: Boolean,
    stationLabel: String?,
    vineyardId: String?,
    stationId: String?,
    backfillRepo: RainfallHistoryBackfillRepository,
    onBackfilled: (Int) -> Unit,
    onOpenSettings: () -> Unit,
    onSkip: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        WxSectionHeader(Icons.Filled.Sensors, VineColors.Warning, "Davis WeatherLink")
        if (configured) {
            WxInfoCard(VineColors.Success, Icons.Filled.Check, "Davis is connected",
                stationLabel?.let { "Station: $it" } ?: "Vineyard-shared Davis credentials are saved.")
            if (canEdit && vineyardId != null && stationId != null) {
                WxBackfillButton(
                    label = "Backfill Davis rainfall (14 days)",
                    tint = VineColors.Info,
                    run = { backfillRepo.backfillDavisChunked(vineyardId, stationId, totalDays = 14, chunkDays = 14).rowsUpserted },
                    onDone = onBackfilled,
                )
                Text(
                    "Backfill is safe to re-run. Manual rainfall corrections are never overwritten.",
                    fontSize = 12.sp, color = vine.textSecondary,
                )
            }
        } else {
            WxInfoCard(VineColors.Orange, Icons.Filled.Info, "Davis is not connected yet",
                "Davis credentials live in the Davis section of Weather Data & Forecasting. Add your WeatherLink API key, secret and pick a station, then return here to backfill rainfall.")
            Text(
                "Davis is optional. If you don't own a Davis WeatherLink station, skip this step and use Weather Underground instead.",
                fontSize = 12.sp, color = vine.textSecondary,
            )
            if (canEdit) {
                Button(onClick = onOpenSettings, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Settings, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Open Weather Settings")
                }
                OutlinedButton(onClick = onSkip, modifier = Modifier.fillMaxWidth()) {
                    Text("I don't have a Davis — skip")
                }
            }
        }
    }
}

@Composable
private fun WundergroundStep(
    canEdit: Boolean,
    configured: Boolean,
    integration: VineyardWeatherIntegration?,
    vineyardId: String?,
    backfillRepo: RainfallHistoryBackfillRepository,
    coordinates: Pair<Double, Double>?,
    onFindNearby: suspend (Double, Double) -> List<NearbyWuStation>,
    onSelectNearby: suspend (NearbyWuStation) -> Unit,
    onSaveStation: (String, String?) -> Unit,
    onBackfilled: (Int) -> Unit,
) {
    val vine = LocalVineColors.current
    var stationId by remember(integration?.stationId) { mutableStateOf(integration?.stationId ?: "") }
    var stationName by remember(integration?.stationName) { mutableStateOf(integration?.stationName ?: "") }

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        WxSectionHeader(Icons.Filled.Air, VineColors.Cyan, "Weather Underground")
        Text(
            "Pick a personal weather station near your vineyard. Weather Underground only fills days where Manual and Davis rainfall are missing.",
            fontSize = 13.sp, color = vine.textSecondary,
        )
        if (configured) {
            WxInfoCard(VineColors.Success, Icons.Filled.Check, "Weather Underground station saved",
                listOfNotNull(integration?.stationName?.takeIf { it.isNotBlank() }, integration?.stationId)
                    .joinToString(" · "))
        }
        if (canEdit) {
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    WuNearbyStationsFinder(
                        coordinates = coordinates,
                        enabled = canEdit,
                        onSearch = onFindNearby,
                        onSelect = onSelectNearby,
                    )
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
                    Button(
                        onClick = {
                            if (stationId.isNotBlank()) {
                                onSaveStation(stationId.trim().uppercase(), stationName.trim().ifBlank { null })
                            }
                        },
                        enabled = stationId.isNotBlank(),
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("Save station") }
                }
            }
            if (configured && vineyardId != null) {
                WxBackfillButton(
                    label = "Backfill Weather Underground rainfall (14 days)",
                    tint = VineColors.Cyan,
                    run = {
                        backfillRepo.backfillWundergroundChunked(
                            vineyardId, integration?.stationId, totalDays = 14, chunkDays = 14,
                        ).rowsUpserted
                    },
                    onDone = onBackfilled,
                )
            }
            Text(
                "Weather Underground rows never overwrite Manual or Davis rainfall. Today is skipped because the daily summary is incomplete.",
                fontSize = 12.sp, color = vine.textSecondary,
            )
        }
    }
}

@Composable
private fun OpenMeteoStep(
    canEdit: Boolean,
    vineyardId: String?,
    backfillRepo: RainfallHistoryBackfillRepository,
    onBackfilled: (Int) -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        WxSectionHeader(Icons.Filled.Public, VineColors.Info, "Open-Meteo fallback")
        Text(
            "Use Open-Meteo archive data only for days where no Manual, Davis or Weather Underground rainfall record exists.",
            fontSize = 13.sp, color = vine.textSecondary,
        )
        WxInfoCard(VineColors.Info, Icons.Filled.Info, "Optional step",
            "You can skip this and run it later from Weather Data & Forecasting. Open-Meteo never overwrites Manual, Davis or Weather Underground rows.")
        if (canEdit && vineyardId != null) {
            WxBackfillButton(
                label = "Fill remaining gaps with Open-Meteo (365 days)",
                tint = VineColors.Indigo,
                run = { backfillRepo.backfillOpenMeteoGaps(vineyardId, days = 365).rowsUpserted },
                onDone = onBackfilled,
            )
            Text(
                "Today and yesterday are skipped because the archive is incomplete.",
                fontSize = 12.sp, color = vine.textSecondary,
            )
        }
    }
}

@Composable
private fun SummaryStep(
    davisConfigured: Boolean,
    davisSkipped: Boolean,
    wuConfigured: Boolean,
    wuSkipped: Boolean,
    davisRows: Int,
    wuRows: Int,
    openMeteoRows: Int,
    openMeteoSkipped: Boolean,
    canEdit: Boolean,
    vineyardId: String?,
    backfillRepo: RainfallHistoryBackfillRepository,
    davisStationId: String?,
    wuStationId: String?,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        WxSectionHeader(Icons.Filled.CalendarMonth, VineColors.Indigo, "Setup summary")
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                WxSummaryRow(Icons.Filled.Sensors, "Davis configured",
                    if (davisConfigured) "Yes" else if (davisSkipped) "Skipped" else "No", davisConfigured)
                WxSummaryRow(Icons.Filled.Air, "WU station configured",
                    if (wuConfigured) "Yes" else if (wuSkipped) "Skipped" else "No", wuConfigured)
                WxSummaryRow(Icons.Filled.CalendarMonth, "Davis rows backfilled", "$davisRows", davisRows > 0)
                WxSummaryRow(Icons.Filled.CalendarMonth, "WU rows backfilled", "$wuRows", wuRows > 0)
                WxSummaryRow(Icons.Filled.Public, "Open-Meteo rows backfilled",
                    if (openMeteoSkipped && openMeteoRows == 0) "Skipped" else "$openMeteoRows", openMeteoRows > 0)
            }
        }
        WxPriorityCard()
        if (canEdit && vineyardId != null) {
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Build full 365-day rainfall history", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                    Text(
                        "Optional. Runs Davis → Weather Underground → Open-Meteo to fill the past year. Open-Meteo only fills days still missing after higher-priority sources.",
                        fontSize = 12.sp, color = vine.textSecondary,
                    )
                    WxFullHistoryButton(
                        vineyardId = vineyardId,
                        backfillRepo = backfillRepo,
                        davisStationId = davisStationId,
                        wuStationId = wuStationId,
                    )
                }
            }
        }
    }
}

@Composable
private fun FinishStep(
    onOpenIrrigation: () -> Unit,
    onOpenWeatherSettings: () -> Unit,
    onDone: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                modifier = Modifier.size(72.dp).clip(RoundedCornerShape(20.dp))
                    .background(VineColors.Success.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.VerifiedUser, contentDescription = null, tint = VineColors.Success, modifier = Modifier.size(40.dp))
            }
            Text("Weather setup complete", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(
                "You can revisit the wizard any time from Weather Data & Forecasting.",
                fontSize = 13.sp, color = vine.textSecondary,
            )
        }
        WxFinishLink(Icons.Filled.Opacity, VineColors.Cyan, "Open Irrigation Advisor",
            "See updated irrigation recommendations.", onOpenIrrigation)
        WxFinishLink(Icons.Filled.Settings, VineColors.Indigo, "Open Weather Settings",
            "Fine-tune providers, station selection and history.", onOpenWeatherSettings)
        Button(onClick = onDone, modifier = Modifier.fillMaxWidth()) {
            Text("Done", fontWeight = FontWeight.SemiBold)
        }
    }
}

// MARK: - Reusable pieces

@Composable
private fun WxBackfillButton(
    label: String,
    tint: Color,
    run: suspend () -> Int,
    onDone: (Int) -> Unit,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    var running by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var ok by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Button(
            onClick = {
                running = true
                status = null
                scope.launch {
                    try {
                        val rows = run()
                        onDone(rows)
                        ok = true
                        status = "Done — $rows day${if (rows == 1) "" else "s"} filled."
                    } catch (e: Exception) {
                        ok = false
                        status = e.message ?: "Backfill failed."
                    } finally {
                        running = false
                    }
                }
            },
            enabled = !running,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (running) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
            } else {
                Text(label)
            }
        }
        if (running) LinearProgressIndicator(modifier = Modifier.fillMaxWidth(), color = VineColors.Primary)
        status?.let {
            Text(it, fontSize = 12.sp, color = if (ok) VineColors.Success else VineColors.Destructive)
        }
    }
}

@Composable
private fun WxFullHistoryButton(
    vineyardId: String,
    backfillRepo: RainfallHistoryBackfillRepository,
    davisStationId: String?,
    wuStationId: String?,
) {
    val scope = rememberCoroutineScope()
    var running by remember { mutableStateOf(false) }
    var phase by remember { mutableStateOf<String?>(null) }
    var status by remember { mutableStateOf<String?>(null) }
    var ok by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Button(
            onClick = {
                running = true
                status = null
                scope.launch {
                    try {
                        var total = 0
                        if (davisStationId != null) {
                            phase = "Davis WeatherLink…"
                            total += backfillRepo.backfillDavisChunked(vineyardId, davisStationId).rowsUpserted
                        }
                        if (wuStationId != null) {
                            phase = "Weather Underground…"
                            total += backfillRepo.backfillWundergroundChunked(vineyardId, wuStationId).rowsUpserted
                        }
                        phase = "Open-Meteo gap fill…"
                        total += backfillRepo.backfillOpenMeteoGaps(vineyardId).rowsUpserted
                        ok = true
                        status = "Rainfall history is up to date — $total day${if (total == 1) "" else "s"} filled."
                    } catch (e: Exception) {
                        ok = false
                        status = e.message ?: "Rainfall history build failed."
                    } finally {
                        running = false
                        phase = null
                    }
                }
            },
            enabled = !running,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (running) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
            } else {
                Text("Build 365-day rainfall history")
            }
        }
        if (running) {
            phase?.let { Text(it, fontSize = 12.sp, color = LocalVineColors.current.textSecondary) }
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth(), color = VineColors.Primary)
        }
        status?.let {
            Text(it, fontSize = 12.sp, color = if (ok) VineColors.Success else VineColors.Destructive)
        }
    }
}

@Composable
private fun WxPriorityCard() {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("Rainfall source priority", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
        Text("Manual → Davis → Weather Underground → Open-Meteo", fontSize = 13.sp, color = vine.textPrimary)
        Text(
            "Higher-priority rows are never overwritten by lower-priority sources.",
            fontSize = 12.sp, color = vine.textSecondary,
        )
    }
}

@Composable
private fun WxBullet(icon: ImageVector, tint: Color, title: String, detail: String) {
    val vine = LocalVineColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
        WxIconTileLocal(icon, tint)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(detail, fontSize = 12.sp, color = vine.textSecondary, lineHeight = 17.sp)
        }
    }
}

@Composable
private fun WxSectionHeader(icon: ImageVector, tint: Color, title: String) {
    val vine = LocalVineColors.current
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        WxIconTileLocal(icon, tint)
        Text(title, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
    }
}

@Composable
private fun WxInfoCard(tint: Color, icon: ImageVector, title: String, body: String) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(tint.copy(alpha = 0.1f))
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(body, fontSize = 12.sp, color = vine.textSecondary, lineHeight = 17.sp)
        }
    }
}

@Composable
private fun WxSummaryRow(icon: ImageVector, label: String, value: String, ok: Boolean) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Icon(icon, contentDescription = null, tint = if (ok) VineColors.Success else vine.textSecondary, modifier = Modifier.size(18.dp))
        Text(label, fontSize = 13.sp, color = vine.textPrimary, modifier = Modifier.weight(1f))
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = if (ok) VineColors.Success else vine.textSecondary)
    }
}

@Composable
private fun WxFinishLink(icon: ImageVector, tint: Color, title: String, detail: String, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .clickable { onClick() }
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        WxIconTileLocal(icon, tint)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(detail, fontSize = 12.sp, color = vine.textSecondary)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
    }
}

@Composable
private fun WxIconTileLocal(icon: ImageVector, tint: Color) {
    Box(
        modifier = Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.15f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
    }
}
