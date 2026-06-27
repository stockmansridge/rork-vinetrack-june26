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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Opacity
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.RestartAlt
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.IrrigationDefaults
import com.rork.vinetrack.data.IrrigationForecast
import com.rork.vinetrack.data.IrrigationForecastRepository
import com.rork.vinetrack.data.IrrigationPrefsStore
import com.rork.vinetrack.data.PersistedRainfallRepository
import com.rork.vinetrack.data.RainForecastRepository
import com.rork.vinetrack.data.RecentRainfallSummary
import com.rork.vinetrack.data.SoilProfileRepository
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.BackendSoilProfile
import com.rork.vinetrack.data.model.IrrigationCalculator
import com.rork.vinetrack.data.model.IrrigationRecommendationResult
import com.rork.vinetrack.data.model.IrrigationSettings
import com.rork.vinetrack.data.model.IrrigationUrgency
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SoilProfileInputs
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Irrigation recommendation calculator. Mirrors the iOS calculator-only
 * surface: it combines a free 5-day Open-Meteo ETo + rainfall forecast with the
 * selected block's area / system rate and adjustable agronomy parameters to
 * suggest run-time hours. Nothing is written to the backend — there is no
 * irrigation table in the shared schema, matching iOS.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IrrigationScreen(state: AppUiState, modifier: Modifier = Modifier, onBack: (() -> Unit)? = null) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val forecastRepo = remember { IrrigationForecastRepository() }
    val prefsStore = remember { IrrigationPrefsStore(context) }
    val savedDefaults = remember { prefsStore.load() }
    val soilRepo = remember { SoilProfileRepository(SessionStore(context)) }
    val persistedRainRepo = remember { PersistedRainfallRepository(SessionStore(context)) }
    val rainRepo = remember { RainForecastRepository() }

    val paddocks = remember(state.paddocks, state.selectedVineyardId) {
        val vid = state.selectedVineyardId
        if (vid == null) state.paddocks else state.paddocks.filter { it.vineyardId == vid }
    }

    // Whole Vineyard scope (default), mirroring iOS. When true no specific block
    // is selected and the calculator uses vineyard-wide inputs.
    var useWholeVineyard by remember { mutableStateOf(true) }
    var selectedPaddockId by remember(paddocks) { mutableStateOf(paddocks.firstOrNull()?.id) }
    val selectedPaddock = if (useWholeVineyard) null else paddocks.firstOrNull { it.id == selectedPaddockId }

    // Settings (mirrors iOS defaults). The agronomy parameters are seeded from
    // the on-device saved defaults; the application rate stays per-session and
    // is prefilled from the selected block's system rate.
    var appRateText by remember { mutableStateOf("") }
    var kcText by remember { mutableStateOf(numText(savedDefaults.cropCoefficientKc)) }
    var efficiencyText by remember { mutableStateOf(numText(savedDefaults.irrigationEfficiencyPercent)) }
    var rainEffText by remember { mutableStateOf(numText(savedDefaults.rainfallEffectivenessPercent)) }
    var replacementText by remember { mutableStateOf(numText(savedDefaults.replacementPercent)) }
    var bufferText by remember { mutableStateOf(numText(savedDefaults.soilMoistureBufferMm)) }
    var savedConfirmation by remember { mutableStateOf<String?>(null) }

    var forecast by remember { mutableStateOf<IrrigationForecast?>(null) }
    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    // Recent measured rainfall (last 7 days), preferring the vineyard's persisted
    // station history and falling back to the Open-Meteo archive. Subtracted from
    // the forecast deficit so a recent storm reduces the recommendation.
    val recentRainDays = 7
    var recentRain by remember { mutableStateOf<RecentRainfallSummary?>(null) }
    var isLoadingRecentRain by remember { mutableStateOf(false) }

    // Soil profile state, mirroring the iOS Irrigation Advisor soil panel.
    var paddockSoilProfile by remember { mutableStateOf<BackendSoilProfile?>(null) }
    var vineyardDefaultSoilProfile by remember { mutableStateOf<BackendSoilProfile?>(null) }
    var isLoadingSoilProfile by remember { mutableStateOf(false) }
    var showSoilEditor by remember { mutableStateOf(false) }
    val canEditSoil = state.canEditLauncherButtons

    // Load the per-block soil profile whenever the selected block changes.
    LaunchedEffect(selectedPaddockId, useWholeVineyard) {
        val pid = if (useWholeVineyard) null else selectedPaddockId
        if (pid == null) {
            paddockSoilProfile = null
            return@LaunchedEffect
        }
        isLoadingSoilProfile = true
        try {
            paddockSoilProfile = soilRepo.fetchPaddockSoilProfile(pid)
        } catch (_: Exception) {
            paddockSoilProfile = null
        } finally {
            isLoadingSoilProfile = false
        }
    }

    // Load the vineyard-level fallback soil profile for Whole Vineyard mode.
    LaunchedEffect(state.selectedVineyardId) {
        val vid = state.selectedVineyardId
        vineyardDefaultSoilProfile = if (vid == null) null else {
            try { soilRepo.fetchVineyardDefaultSoilProfile(vid) } catch (_: Exception) { null }
        }
    }

    // Per-day manual overrides (session-only, keyed by the day's epoch ms).
    // A missing key means "use the forecast value", matching iOS. Cleared when
    // a fresh forecast is loaded so stale overrides never leak onto new dates.
    var etoOverrides by remember { mutableStateOf<Map<Long, Double>>(emptyMap()) }
    var rainOverrides by remember { mutableStateOf<Map<Long, Double>>(emptyMap()) }
    var editingDayEpochMs by remember { mutableStateOf<Long?>(null) }

    // Resolve a forecast location: vineyard coords, else the selected block's
    // polygon centroid, else any mapped block's centroid.
    val vineyard = state.selectedVineyard
    val location = remember(vineyard, selectedPaddock, paddocks) {
        val lat = vineyard?.latitude ?: selectedPaddock?.centroid?.latitude
            ?: paddocks.firstNotNullOfOrNull { it.centroid }?.latitude
        val lon = vineyard?.longitude ?: selectedPaddock?.centroid?.longitude
            ?: paddocks.firstNotNullOfOrNull { it.centroid }?.longitude
        if (lat != null && lon != null) Pair(lat, lon) else null
    }

    // Pre-fill the application rate. For a single block use its drip system rate;
    // for Whole Vineyard use an area-weighted average of the blocks' system rates
    // (mirrors the iOS resolver).
    LaunchedEffect(useWholeVineyard, selectedPaddockId) {
        if (useWholeVineyard) {
            val withRate = paddocks.filter { (it.mmPerHour ?: 0.0) > 0 }
            val weight = withRate.sumOf { it.areaHectares }
            val rate = when {
                withRate.isEmpty() -> 0.0
                weight > 0 -> withRate.sumOf { (it.mmPerHour ?: 0.0) * it.areaHectares } / weight
                else -> withRate.mapNotNull { it.mmPerHour }.let { if (it.isEmpty()) 0.0 else it.sum() / it.size }
            }
            if (rate > 0) appRateText = String.format(Locale.US, "%.2f", rate)
        } else {
            val mmHr = selectedPaddock?.mmPerHour
            if (mmHr != null && mmHr > 0) {
                appRateText = String.format(Locale.US, "%.2f", mmHr)
            }
        }
    }

    val settings = IrrigationSettings(
        irrigationApplicationRateMmPerHour = parse(appRateText),
        cropCoefficientKc = parse(kcText, 0.65),
        irrigationEfficiencyPercent = parse(efficiencyText, 90.0),
        rainfallEffectivenessPercent = parse(rainEffText, 80.0),
        replacementPercent = parse(replacementText, 100.0),
        soilMoistureBufferMm = parse(bufferText),
    )

    // Substitute any manual overrides into the forecast days before the
    // calculator runs, so effective-rainfall / soil-buffer logic sees the
    // overridden numbers exactly like iOS.
    val effectiveDays = remember(forecast, etoOverrides, rainOverrides) {
        forecast?.days?.map { d ->
            d.copy(
                forecastEToMm = etoOverrides[d.dateEpochMs] ?: d.forecastEToMm,
                forecastRainMm = rainOverrides[d.dateEpochMs] ?: d.forecastRainMm,
            )
        }
    }

    // Soil-aware inputs from the active profile (block in single-block mode,
    // vineyard fallback in Whole Vineyard mode). Drives the soil-aware v2
    // recommendation when a profile exists.
    val activeSoilProfile = if (useWholeVineyard) vineyardDefaultSoilProfile else paddockSoilProfile
    val soilInputs = remember(activeSoilProfile) {
        val p = activeSoilProfile ?: return@remember SoilProfileInputs.empty
        SoilProfileInputs(
            irrigationSoilClass = p.irrigationSoilClass,
            availableWaterCapacityMmPerM = p.availableWaterCapacityMmPerM,
            effectiveRootDepthM = p.effectiveRootDepthM,
            managementAllowedDepletionPercent = p.managementAllowedDepletionPercent,
            infiltrationRisk = p.infiltrationRisk,
            drainageRisk = p.drainageRisk,
            waterloggingRisk = p.waterloggingRisk,
            modelVersion = p.modelVersion,
        )
    }
    val soilAwareV2Enabled = activeSoilProfile != null

    val result: IrrigationRecommendationResult? = effectiveDays?.let { days ->
        IrrigationCalculator.calculate(
            forecastDays = days,
            settings = settings,
            recentActualRainMm = recentRain?.totalMm ?: 0.0,
            soil = soilInputs,
            soilAwareV2Enabled = soilAwareV2Enabled,
        )
    }

    // Load recent measured rainfall whenever the location resolves.
    LaunchedEffect(location, state.selectedVineyardId) {
        val loc = location
        if (loc == null) {
            recentRain = null
            return@LaunchedEffect
        }
        isLoadingRecentRain = true
        try {
            recentRain = persistedRainRepo.fetchRecentRainfallSummary(
                vineyardId = state.selectedVineyardId,
                latitude = loc.first,
                longitude = loc.second,
                days = recentRainDays,
                rainRepo = rainRepo,
            )
        } catch (_: Exception) {
            recentRain = null
        } finally {
            isLoadingRecentRain = false
        }
    }

    // Setup wizard checklist (mirrors iOS "Finish irrigation setup"). Only the
    // incomplete items are surfaced as a prompt at the top of the screen.
    val wizardItems = listOf(
        "Block or Whole Vineyard" to (useWholeVineyard || selectedPaddockId != null),
        "Weather source / location" to (location != null),
        "Irrigation application rate (mm/hr)" to (settings.irrigationApplicationRateMmPerHour > 0),
        "Crop coefficient (Kc)" to (settings.cropCoefficientKc > 0),
        "Rainfall & irrigation efficiency" to (settings.irrigationEfficiencyPercent > 0 && settings.rainfallEffectivenessPercent > 0),
    )
    val incompleteWizardItems = wizardItems.filterNot { it.second }.map { it.first }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Irrigation Advisor") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
        containerColor = vine.appBackground,
        modifier = modifier,
    ) { padding ->
        if (paddocks.isEmpty()) {
            EmptyState(
                icon = Icons.Filled.Opacity,
                title = "No blocks yet",
                message = "Add blocks with mapped boundaries to calculate irrigation.",
                modifier = Modifier.padding(padding),
            )
            return@Scaffold
        }

        LazyColumn(
            contentPadding = PaddingValues(16.dp).let {
                PaddingValues(start = 16.dp, end = 16.dp, top = padding.calculateTopPadding() + 12.dp, bottom = 32.dp)
            },
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Setup wizard — shown only when items are incomplete.
            if (incompleteWizardItems.isNotEmpty()) {
                item {
                    VineyardCard {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.Opacity, contentDescription = null, tint = VineColors.PrimaryAccent, modifier = Modifier.size(18.dp))
                            Box(Modifier.size(8.dp))
                            Text("Finish irrigation setup", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        }
                        Box(Modifier.height(10.dp))
                        incompleteWizardItems.forEach { item ->
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 3.dp)) {
                                Box(
                                    modifier = Modifier.size(8.dp).clip(CircleShape).background(VineColors.Warning),
                                )
                                Box(Modifier.size(8.dp))
                                Text(item, fontSize = 13.sp, color = vine.textSecondary)
                            }
                        }
                    }
                }
            }

            // Block picker + context
            item {
                VineyardCard {
                    SectionHeader("Block", onLight = true)
                    Box(Modifier.height(8.dp))
                    var expanded by remember { mutableStateOf(false) }
                    ExposedDropdownMenuBox(
                        expanded = expanded,
                        onExpandedChange = { expanded = it },
                    ) {
                        OutlinedTextField(
                            value = if (useWholeVineyard) "Whole Vineyard" else (selectedPaddock?.name ?: "Select…"),
                            onValueChange = {},
                            readOnly = true,
                            label = { Text("Scope") },
                            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
                            modifier = Modifier
                                .fillMaxWidth()
                                .menuAnchor(androidx.compose.material3.MenuAnchorType.PrimaryNotEditable),
                        )
                        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                            DropdownMenuItem(
                                text = { Text("Whole Vineyard") },
                                onClick = {
                                    useWholeVineyard = true
                                    expanded = false
                                },
                            )
                            paddocks.forEach { p ->
                                DropdownMenuItem(
                                    text = { Text(p.name) },
                                    onClick = {
                                        useWholeVineyard = false
                                        selectedPaddockId = p.id
                                        expanded = false
                                    },
                                )
                            }
                        }
                    }
                    selectedPaddock?.let { p ->
                        Box(Modifier.height(10.dp))
                        InfoRow("Area", String.format(Locale.US, "%.2f ha", p.areaHectares))
                        val mmHr = p.mmPerHour
                        if (mmHr != null && mmHr > 0) {
                            InfoRow("System rate", String.format(Locale.US, "%.2f mm/hr", mmHr))
                        } else {
                            Box(Modifier.height(4.dp))
                            Text(
                                "No drip system rate configured for this block — enter an application rate below.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                    if (useWholeVineyard) {
                        Box(Modifier.height(10.dp))
                        val totalArea = paddocks.sumOf { it.areaHectares }
                        InfoRow("Blocks", "${paddocks.size}")
                        InfoRow("Total area", String.format(Locale.US, "%.2f ha", totalArea))
                        Box(Modifier.height(4.dp))
                        Text(
                            "Conservative average across all blocks.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            // Recent measured rainfall
            item {
                RecentRainfallCard(
                    summary = recentRain,
                    isLoading = isLoadingRecentRain,
                    windowDays = recentRainDays,
                )
            }

            // Soil profile
            item {
                SoilProfileSection(
                    useWholeVineyard = useWholeVineyard,
                    selectedPaddock = selectedPaddock,
                    paddockProfile = paddockSoilProfile,
                    vineyardProfile = vineyardDefaultSoilProfile,
                    isLoading = isLoadingSoilProfile,
                    canEdit = canEditSoil && state.selectedVineyardId != null,
                    onEdit = { showSoilEditor = true },
                )
            }

            // Forecast
            item {
                VineyardCard {
                    SectionHeader("5-Day Forecast", onLight = true)
                    Box(Modifier.height(8.dp))
                    when {
                        isLoading -> Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                            Box(Modifier.size(10.dp))
                            Text("Loading 5-day forecast…", fontSize = 14.sp, color = vine.textSecondary)
                        }
                        errorMessage != null -> Text(
                            errorMessage ?: "",
                            fontSize = 13.sp,
                            color = VineColors.Warning,
                        )
                        forecast != null -> {
                            InfoRow("Source", forecast?.source ?: "")
                            InfoRow("Days", "${forecast?.days?.size ?: 0}")
                        }
                        else -> Text(
                            "Load a 5-day forecast to see a recommendation.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                    }
                    Box(Modifier.height(12.dp))
                    OutlinedButton(
                        onClick = {
                            val loc = location ?: return@OutlinedButton
                            scope.launch {
                                isLoading = true
                                errorMessage = null
                                try {
                                    forecast = forecastRepo.fetchForecast(loc.first, loc.second)
                                    etoOverrides = emptyMap()
                                    rainOverrides = emptyMap()
                                } catch (e: Exception) {
                                    errorMessage = e.message ?: "Could not load forecast."
                                    forecast = null
                                } finally {
                                    isLoading = false
                                }
                            }
                        },
                        enabled = !isLoading && location != null,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                        Box(Modifier.size(8.dp))
                        Text(if (forecast == null) "Load Forecast" else "Refresh Forecast")
                    }
                    if (location == null) {
                        Box(Modifier.height(8.dp))
                        Text(
                            "Set your vineyard location, or map a block boundary, to load a forecast.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                    Box(Modifier.height(4.dp))
                    Text(
                        "Evapotranspiration (ETo) and rainfall are fetched from Open-Meteo. You can override each day below if needed.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            // Settings
            item {
                VineyardCard {
                    SectionHeader("Irrigation Settings", onLight = true)
                    Box(Modifier.height(8.dp))
                    val siteRate = (selectedPaddock?.mmPerHour ?: 0.0) > 0
                    SettingField(
                        label = "Application Rate (mm/hr)",
                        value = appRateText,
                        onValueChange = { appRateText = it },
                        help = "How many millimetres of water your irrigation system applies to this block in one hour of running.",
                        siteNote = if (siteRate) "Pre-filled from this block's system rate." else null,
                    )
                    SettingField(
                        label = "Crop Coefficient (Kc)",
                        value = kcText,
                        onValueChange = { kcText = it },
                        help = "How thirsty the vines are compared to a reference grass. 0.65 is a typical mid-season value for wine grapes.",
                    )
                    SettingField(
                        label = "Irrigation Efficiency (%)",
                        value = efficiencyText,
                        onValueChange = { efficiencyText = it },
                        help = "How much of the water you pump actually reaches the vine roots. Drip systems are typically around 90%.",
                    )
                    SettingField(
                        label = "Rainfall Effectiveness (%)",
                        value = rainEffText,
                        onValueChange = { rainEffText = it },
                        help = "How much of the forecast rainfall actually soaks in and is available to the vines. Typically around 80%.",
                    )
                    SettingField(
                        label = "Replacement (%)",
                        value = replacementText,
                        onValueChange = { replacementText = it },
                        help = "How much of the water the vines use that you want to replace. 100% fully replaces it, lower values apply deficit irrigation.",
                    )
                    SettingField(
                        label = "Soil Buffer (mm)",
                        value = bufferText,
                        onValueChange = { bufferText = it },
                        help = "Extra water already stored in the soil from earlier rain or irrigation. Subtracted from the deficit. Leave at 0 if unsure.",
                        isLast = true,
                    )
                    Box(Modifier.height(12.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        OutlinedButton(
                            onClick = {
                                prefsStore.save(
                                    IrrigationDefaults(
                                        cropCoefficientKc = parse(kcText, 0.65),
                                        irrigationEfficiencyPercent = parse(efficiencyText, 90.0),
                                        rainfallEffectivenessPercent = parse(rainEffText, 80.0),
                                        replacementPercent = parse(replacementText, 100.0),
                                        soilMoistureBufferMm = parse(bufferText),
                                    )
                                )
                                savedConfirmation = "Saved as defaults"
                            },
                            modifier = Modifier.weight(1f),
                        ) {
                            Icon(Icons.Filled.Bookmark, contentDescription = null, modifier = Modifier.size(18.dp))
                            Box(Modifier.size(6.dp))
                            Text("Save as defaults")
                        }
                        OutlinedButton(
                            onClick = {
                                val d = IrrigationDefaults.factory
                                kcText = numText(d.cropCoefficientKc)
                                efficiencyText = numText(d.irrigationEfficiencyPercent)
                                rainEffText = numText(d.rainfallEffectivenessPercent)
                                replacementText = numText(d.replacementPercent)
                                bufferText = numText(d.soilMoistureBufferMm)
                                prefsStore.reset()
                                savedConfirmation = "Reset to defaults"
                            },
                            modifier = Modifier.weight(1f),
                        ) {
                            Icon(Icons.Filled.RestartAlt, contentDescription = null, modifier = Modifier.size(18.dp))
                            Box(Modifier.size(6.dp))
                            Text("Reset")
                        }
                    }
                    val confirmation = savedConfirmation
                    if (confirmation != null) {
                        Box(Modifier.height(8.dp))
                        Text(confirmation, fontSize = 12.sp, color = VineColors.LeafGreen, fontWeight = FontWeight.SemiBold)
                    }
                }
            }

            // Result
            if (result != null) {
                result.v2?.let { v2 ->
                    item { SoilAwareRecommendationCard(result, v2) }
                }
                item { RecommendationCard(result, settings.irrigationApplicationRateMmPerHour) }
                item {
                    DailyBreakdownCard(
                        result = result,
                        etoOverrides = etoOverrides,
                        rainOverrides = rainOverrides,
                        onEditDay = { editingDayEpochMs = it },
                    )
                }
            } else if (settings.irrigationApplicationRateMmPerHour <= 0 && forecast != null) {
                item {
                    VineyardCard {
                        Text(
                            "Enter an application rate greater than 0 mm/hr to calculate.",
                            fontSize = 13.sp,
                            color = VineColors.Warning,
                        )
                    }
                }
            }
        }
    }

    val editingMs = editingDayEpochMs
    if (editingMs != null && forecast != null) {
        val rawDay = forecast?.days?.firstOrNull { it.dateEpochMs == editingMs }
        if (rawDay != null) {
            DayOverrideDialog(
                dateEpochMs = editingMs,
                forecastEToMm = rawDay.forecastEToMm,
                forecastRainMm = rawDay.forecastRainMm,
                etoOverride = etoOverrides[editingMs],
                rainOverride = rainOverrides[editingMs],
                onDismiss = { editingDayEpochMs = null },
                onSave = { eto, rain ->
                    etoOverrides = etoOverrides.toMutableMap().also { m ->
                        if (eto == null) m.remove(editingMs) else m[editingMs] = eto
                    }
                    rainOverrides = rainOverrides.toMutableMap().also { m ->
                        if (rain == null) m.remove(editingMs) else m[editingMs] = rain
                    }
                    editingDayEpochMs = null
                },
                onReset = {
                    etoOverrides = etoOverrides.toMutableMap().also { it.remove(editingMs) }
                    rainOverrides = rainOverrides.toMutableMap().also { it.remove(editingMs) }
                    editingDayEpochMs = null
                },
            )
        }
    }

    if (showSoilEditor) {
        val vid = state.selectedVineyardId
        val editorPaddockId = if (useWholeVineyard) null else selectedPaddockId
        if (vid != null) {
            SoilProfileEditorSheet(
                vineyardId = vid,
                paddockId = editorPaddockId,
                paddockName = if (useWholeVineyard) "Whole Vineyard" else (selectedPaddock?.name ?: "Block"),
                vineyardCountry = vineyard?.country,
                canEdit = canEditSoil,
                onSaved = { saved ->
                    if (useWholeVineyard) vineyardDefaultSoilProfile = saved
                    else paddockSoilProfile = saved
                },
                onDismiss = { showSoilEditor = false },
            )
        }
    }
}

@Composable
private fun RecentRainfallCard(
    summary: RecentRainfallSummary?,
    isLoading: Boolean,
    windowDays: Int,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        SectionHeader("Recent Rainfall", onLight = true)
        Box(Modifier.height(10.dp))
        when {
            isLoading && summary == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Box(Modifier.size(10.dp))
                Text("Loading recent rainfall…", fontSize = 13.sp, color = vine.textSecondary)
            }
            summary != null -> {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.WaterDrop, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(18.dp))
                    Box(Modifier.size(6.dp))
                    Text(
                        String.format(Locale.US, "%.1f mm", summary.totalMm),
                        fontSize = 22.sp,
                        fontWeight = FontWeight.Bold,
                        color = vine.textPrimary,
                    )
                    Box(Modifier.size(8.dp))
                    Text("in the last $windowDays days", fontSize = 12.sp, color = vine.textSecondary)
                }
                Box(Modifier.height(6.dp))
                InfoRow("Source", summary.sourceLabel)
                InfoRow("Recorded days", "${summary.measuredDays} of ${summary.windowDays}")
                Box(Modifier.height(4.dp))
                Text(
                    if (summary.usedPersisted) {
                        "Measured rainfall from your station is subtracted from the forecast deficit, so a recent storm reduces the recommendation."
                    } else {
                        "Modelled rainfall from the Open-Meteo archive is subtracted from the forecast deficit. Connect a weather station for station-recorded totals."
                    },
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
            else -> Text(
                "Set your vineyard location, or map a block boundary, to include recent rainfall.",
                fontSize = 13.sp,
                color = vine.textSecondary,
            )
        }
    }
}

@Composable
private fun SoilProfileSection(
    useWholeVineyard: Boolean,
    selectedPaddock: Paddock?,
    paddockProfile: BackendSoilProfile?,
    vineyardProfile: BackendSoilProfile?,
    isLoading: Boolean,
    canEdit: Boolean,
    onEdit: () -> Unit,
) {
    val vine = LocalVineColors.current
    val profile = if (useWholeVineyard) vineyardProfile else paddockProfile
    VineyardCard {
        SectionHeader(if (useWholeVineyard) "Soil Profile (Whole Vineyard)" else "Soil Profile", onLight = true)
        Box(Modifier.height(10.dp))
        when {
            isLoading && profile == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Box(Modifier.size(10.dp))
                Text("Loading soil profile…", fontSize = 13.sp, color = vine.textSecondary)
            }
            profile != null -> SoilProfileSummary(profile)
            else -> {
                Text(
                    if (useWholeVineyard) "No vineyard soil profile yet" else "No soil profile set for this block",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textSecondary,
                )
                Box(Modifier.height(4.dp))
                Text(
                    "Add a soil profile to get soil-aware irrigation guidance.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
        }
        if (canEdit) {
            Box(Modifier.height(12.dp))
            OutlinedButton(onClick = onEdit, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Edit, contentDescription = null, modifier = Modifier.size(18.dp))
                Box(Modifier.size(8.dp))
                Text(
                    when {
                        useWholeVineyard && profile == null -> "Add Whole Vineyard Soil Profile"
                        useWholeVineyard -> "Edit Whole Vineyard Soil Profile"
                        profile == null -> "Add soil profile"
                        else -> "Edit soil profile"
                    },
                )
            }
        }
        Box(Modifier.height(6.dp))
        Text(
            if (profile?.source == "nsw_seed") {
                "Soil information is estimated from NSW SEED mapping and may not reflect site-specific conditions."
            } else {
                "Soil profile values feed the soil buffer and root-zone calculation. Editing requires Owner or Manager access."
            },
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun SoilProfileSummary(soil: BackendSoilProfile) {
    val vine = LocalVineColors.current
    val className = soil.typedSoilClass?.fallbackLabel
        ?: soil.irrigationSoilClass?.replace("_", " ")?.replaceFirstChar { it.uppercase() }
        ?: "Unspecified soil class"
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Layers, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
        Box(Modifier.size(6.dp))
        Text(className, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
        Text(
            soil.source.replace("_", " ").replaceFirstChar { it.uppercase() },
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
    }
    Box(Modifier.height(8.dp))
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        SoilStat("AWC", soil.availableWaterCapacityMmPerM?.let { String.format(Locale.US, "%.0f mm/m", it) } ?: "—", Modifier.weight(1f))
        SoilStat("Root depth", soil.effectiveRootDepthM?.let { String.format(Locale.US, "%.2f m", it) } ?: "—", Modifier.weight(1f))
        SoilStat("Depletion", soil.managementAllowedDepletionPercent?.let { String.format(Locale.US, "%.0f%%", it) } ?: "—", Modifier.weight(1f))
    }
    val rzc = soil.rootZoneCapacityMm
    val raw = soil.readilyAvailableWaterMm
    if (rzc != null && raw != null) {
        Box(Modifier.height(6.dp))
        Text(
            String.format(Locale.US, "Root-zone capacity %.0f mm \u2022 Readily available %.0f mm", rzc, raw),
            fontSize = 11.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun SoilStat(label: String, value: String, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(modifier = modifier) {
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
        Text(value, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
    }
}

@Composable
private fun SoilAwareRecommendationCard(
    result: IrrigationRecommendationResult,
    v2: com.rork.vinetrack.data.model.SoilAwareV2Result,
) {
    val vine = LocalVineColors.current
    val (urgencyColor, urgencyIcon) = when (v2.urgency) {
        IrrigationUrgency.IrrigateNow -> VineColors.VineRed to Icons.Filled.WaterDrop
        IrrigationUrgency.IrrigateSoon -> VineColors.Warning to Icons.Filled.WaterDrop
        IrrigationUrgency.Monitor -> VineColors.Info to Icons.Filled.Opacity
        IrrigationUrgency.DelayRainLikely -> VineColors.LeafGreen to Icons.Filled.Opacity
    }
    VineyardCard {
        SectionHeader("Soil-Aware Recommendation", onLight = true)
        Box(Modifier.height(10.dp))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(androidx.compose.foundation.shape.RoundedCornerShape(12.dp))
                .background(urgencyColor.copy(alpha = 0.12f))
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier.size(36.dp).clip(CircleShape).background(urgencyColor.copy(alpha = 0.2f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(urgencyIcon, contentDescription = null, tint = urgencyColor, modifier = Modifier.size(20.dp))
            }
            Box(Modifier.size(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(v2.urgency.displayLabel, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = urgencyColor)
                val depthLabel = if (v2.splitSuggested) {
                    String.format(Locale.US, "%.0f mm now × %d events", v2.soilAdjustedGrossMm, v2.splitCount)
                } else {
                    String.format(Locale.US, "Apply ~%.0f mm", v2.soilAdjustedGrossMm)
                }
                Text(depthLabel, fontSize = 13.sp, color = vine.textSecondary)
            }
        }
        if (v2.soilAdjusted) {
            Box(Modifier.height(10.dp))
            InfoRow("Base demand", String.format(Locale.US, "%.0f mm", v2.baseGrossIrrigationMm))
            InfoRow("Soil-adjusted", String.format(Locale.US, "%.0f mm", v2.soilAdjustedGrossMm))
        }
        result.readilyAvailableWaterMm?.let { raw ->
            InfoRow("Readily available water", String.format(Locale.US, "%.0f mm", raw))
        }
        v2.adjustmentReason?.let { reason ->
            Box(Modifier.height(8.dp))
            Text(reason, fontSize = 12.sp, color = vine.textSecondary)
        }
        result.soilAdviceText?.let { advice ->
            Box(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Filled.Layers, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(16.dp))
                Box(Modifier.size(6.dp))
                Text(advice, fontSize = 12.sp, color = vine.textSecondary)
            }
        }
        v2.cautionText?.let { caution ->
            Box(Modifier.height(8.dp))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(androidx.compose.foundation.shape.RoundedCornerShape(10.dp))
                    .background(VineColors.Warning.copy(alpha = 0.12f))
                    .padding(10.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(Icons.Filled.Opacity, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(16.dp))
                Box(Modifier.size(6.dp))
                Text(caution, fontSize = 12.sp, color = vine.textPrimary)
            }
        }
    }
}

@Composable
private fun RecommendationCard(result: IrrigationRecommendationResult, rate: Double) {
    val vine = LocalVineColors.current
    VineyardCard {
        SectionHeader("Recommendation", onLight = true)
        Box(Modifier.height(10.dp))
        Text("Recommended irrigation", fontSize = 12.sp, color = vine.textSecondary)
        Text(
            String.format(Locale.US, "%.1f hours", result.recommendedIrrigationHours),
            fontSize = 30.sp,
            fontWeight = FontWeight.Bold,
            color = VineColors.LeafGreen,
        )
        Text(hoursMinutes(result.recommendedIrrigationHours), fontSize = 14.sp, color = vine.textSecondary)
        Text("over the next 5 days", fontSize = 12.sp, color = vine.textSecondary)
        Box(Modifier.height(12.dp))
        HorizontalDivider(color = vine.cardBorder)
        Box(Modifier.height(10.dp))
        InfoRow("Forecast crop use", String.format(Locale.US, "%.1f mm", result.forecastCropUseMm))
        InfoRow("Effective rainfall", String.format(Locale.US, "%.1f mm", result.forecastEffectiveRainMm))
        if (result.recentActualRainMm > 0.0) {
            InfoRow("Recent measured rain", String.format(Locale.US, "-%.1f mm", result.recentActualRainMm))
        }
        InfoRow("Net deficit", String.format(Locale.US, "%.1f mm", result.netDeficitMm))
        InfoRow("Gross to apply", String.format(Locale.US, "%.1f mm", result.grossIrrigationMm))
        InfoRow("Rate", String.format(Locale.US, "%.2f mm/hr", rate))
    }
}

@Composable
private fun DailyBreakdownCard(
    result: IrrigationRecommendationResult,
    etoOverrides: Map<Long, Double>,
    rainOverrides: Map<Long, Double>,
    onEditDay: (Long) -> Unit,
) {
    val vine = LocalVineColors.current
    val dayFmt = remember { SimpleDateFormat("EEE d MMM", Locale.getDefault()) }
    VineyardCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SectionHeader("Daily Breakdown", onLight = true)
            Text("Tap a day to override", fontSize = 11.sp, color = vine.textSecondary)
        }
        Box(Modifier.height(4.dp))
        result.dailyBreakdown.forEachIndexed { index, day ->
            val etoOverridden = etoOverrides.containsKey(day.dateEpochMs)
            val rainOverridden = rainOverrides.containsKey(day.dateEpochMs)
            if (index > 0) {
                Box(Modifier.height(8.dp))
                HorizontalDivider(color = vine.cardBorder)
                Box(Modifier.height(8.dp))
            } else {
                Box(Modifier.height(8.dp))
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onEditDay(day.dateEpochMs) },
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        dayFmt.format(Date(day.dateEpochMs)),
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                    )
                    if (etoOverridden || rainOverridden) {
                        Box(Modifier.size(6.dp))
                        Icon(
                            Icons.Filled.Edit,
                            contentDescription = "Overridden",
                            modifier = Modifier.size(13.dp),
                            tint = VineColors.LeafGreen,
                        )
                        Text(
                            " Manual",
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = VineColors.LeafGreen,
                        )
                    }
                }
                Text(
                    String.format(Locale.US, "%.1f mm deficit", day.dailyDeficitMm),
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (day.dailyDeficitMm > 0) VineColors.VineRed else VineColors.LeafGreen,
                )
            }
            Box(Modifier.height(4.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Metric("ETo", String.format(Locale.US, "%.1f", day.forecastEToMm), highlight = etoOverridden)
                Metric("Rain", String.format(Locale.US, "%.1f", day.forecastRainMm), highlight = rainOverridden)
                Metric("Crop Use", String.format(Locale.US, "%.1f", day.cropUseMm))
                Metric("Eff. Rain", String.format(Locale.US, "%.1f", day.effectiveRainMm))
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DayOverrideDialog(
    dateEpochMs: Long,
    forecastEToMm: Double,
    forecastRainMm: Double,
    etoOverride: Double?,
    rainOverride: Double?,
    onDismiss: () -> Unit,
    onSave: (eto: Double?, rain: Double?) -> Unit,
    onReset: () -> Unit,
) {
    val vine = LocalVineColors.current
    val dayFmt = remember { SimpleDateFormat("EEE d MMM", Locale.getDefault()) }
    var etoText by remember { mutableStateOf(etoOverride?.let { String.format(Locale.US, "%.1f", it) } ?: "") }
    var rainText by remember { mutableStateOf(rainOverride?.let { String.format(Locale.US, "%.1f", it) } ?: "") }
    val hasOverride = etoOverride != null || rainOverride != null

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Override ${dayFmt.format(Date(dateEpochMs))}") },
        text = {
            Column {
                Text(
                    "Leave a field blank to use the forecast value.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
                Box(Modifier.height(12.dp))
                OutlinedTextField(
                    value = etoText,
                    onValueChange = { etoText = it },
                    label = { Text("ETo (mm)") },
                    placeholder = { Text(String.format(Locale.US, "%.1f", forecastEToMm)) },
                    singleLine = true,
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    String.format(Locale.US, "Forecast: %.1f mm", forecastEToMm),
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
                Box(Modifier.height(12.dp))
                OutlinedTextField(
                    value = rainText,
                    onValueChange = { rainText = it },
                    label = { Text("Rain (mm)") },
                    placeholder = { Text(String.format(Locale.US, "%.1f", forecastRainMm)) },
                    singleLine = true,
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    String.format(Locale.US, "Forecast: %.1f mm", forecastRainMm),
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
        },
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = {
                val eto = etoText.replace(",", ".").trim().toDoubleOrNull()
                val rain = rainText.replace(",", ".").trim().toDoubleOrNull()
                onSave(eto, rain)
            }) { Text("Save") }
        },
        dismissButton = {
            if (hasOverride) {
                androidx.compose.material3.TextButton(onClick = onReset) {
                    Text("Reset", color = VineColors.VineRed)
                }
            } else {
                androidx.compose.material3.TextButton(onClick = onDismiss) { Text("Cancel") }
            }
        },
    )
}

@Composable
private fun Metric(label: String, value: String, highlight: Boolean = false) {
    val vine = LocalVineColors.current
    Column {
        Text(label, fontSize = 11.sp, color = vine.textSecondary)
        Text(
            "$value mm",
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (highlight) VineColors.LeafGreen else vine.textPrimary,
        )
    }
}

@Composable
private fun SettingField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    help: String,
    siteNote: String? = null,
    isLast: Boolean = false,
) {
    val vine = LocalVineColors.current
    Column {
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            label = { Text(label) },
            singleLine = true,
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth(),
        )
        Box(Modifier.height(4.dp))
        Text(help, fontSize = 11.sp, color = vine.textSecondary)
        if (siteNote != null) {
            Text(siteNote, fontSize = 11.sp, color = VineColors.LeafGreen)
        }
        if (!isLast) Box(Modifier.height(12.dp))
    }
}

@Composable
private fun InfoRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontSize = 14.sp, color = vine.textPrimary)
        Text(value, fontSize = 14.sp, color = vine.textSecondary)
    }
}

private fun hoursMinutes(hours: Double): String {
    val totalMinutes = (hours * 60.0).toInt()
    val h = totalMinutes / 60
    val m = totalMinutes % 60
    return "$h hr $m min"
}

/** Formats a default for an editable text field, trimming trailing zeros. */
private fun numText(value: Double): String {
    return if (value == value.toLong().toDouble()) {
        value.toLong().toString()
    } else {
        String.format(Locale.US, "%.2f", value).trimEnd('0').trimEnd('.')
    }
}

private fun parse(text: String, default: Double = 0.0): Double {
    val cleaned = text.replace(",", ".").trim()
    if (cleaned.isEmpty()) return default
    return cleaned.toDoubleOrNull() ?: default
}
