package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDatePickerState
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.DegreeDayService
import com.rork.vinetrack.data.DavisWeatherLinkRepository
import com.rork.vinetrack.data.OptimalRipenessCacheStore
import com.rork.vinetrack.data.OptimalRipenessWeatherRepository
import com.rork.vinetrack.data.OptimalRipenessSourceSelection
import com.rork.vinetrack.data.OptimalRipenessSourceStore
import com.rork.vinetrack.data.OptimalRipenessSnapshot
import com.rork.vinetrack.data.OptimalRipenessSnapshotRow
import com.rork.vinetrack.data.VineyardWeatherIntegration
import com.rork.vinetrack.data.VineyardWeatherIntegrationRepository
import com.rork.vinetrack.data.WeatherIntegrationProvider
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.GddCalculationMode
import com.rork.vinetrack.data.GddResetMode
import com.rork.vinetrack.data.effectiveCalculationMode
import com.rork.vinetrack.data.effectiveResetMode
import com.rork.vinetrack.data.resetDateMs
import com.rork.vinetrack.data.calculateOptimalRipenessBlock
import com.rork.vinetrack.data.optimalRipenessStartOfDay
import com.rork.vinetrack.data.PaddockRepository
import com.rork.vinetrack.data.GddSettingsStore
import com.rork.vinetrack.data.OperationPrefsStore
import com.rork.vinetrack.data.model.BuiltInGrapeVarietyGDD
import com.rork.vinetrack.data.model.GrapeVarietyRow
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.data.model.canonicalVarietyName
import com.rork.vinetrack.data.model.parseIsoToEpochMs
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.SimpleDateFormat
import java.time.Instant
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

/**
 * Optimal Ripeness hub — mirrors the iOS `OptimalRipenessHubView`. Shows every
 * block's GDD progress toward its allocated variety's optimal harvest target,
 * computed on-device from the free Open-Meteo Archive using the vineyard's
 * coordinates (or a mapped block centroid).
 *
 * Reuses existing Supabase reads: `paddocks` (phenology + variety allocations)
 * and `list_vineyard_grape_varieties` (variety targets / overrides). The season
 * start comes from local Operation Preferences. GDD/BEDD maths match iOS exactly
 * so both platforms agree.
 */

/** A resolved per-block ripeness row. */
internal data class RipenessRow(
    val block: Paddock,
    val varietyName: String?,
    val allocationPercent: Double?,
    val multiVariety: Boolean,
    val resetDateMs: Long?,
    val total: Double,
    val target: Double,
    val daysToTarget: Int?,
    val hasGddValue: Boolean = true,
    val isIncomplete: Boolean = false,
) {
    val progress: Double get() = if (target > 0) min(1.0, max(0.0, total / target)) else 0.0
}

internal data class RipenessResult(
    val sourceConfigured: Boolean,
    val rows: List<RipenessRow>,
    val sourceLabel: String = "Open-Meteo Archive",
    val sourceFingerprint: String = "",
)

internal data class OptimalRipenessScreenState(
    val result: RipenessResult,
    val isUpdatingWeather: Boolean,
)

/** Source decision made only from a conclusive shared-configuration read. */
internal data class OptimalRipenessRefreshPlan(
    val cachedSnapshot: OptimalRipenessSnapshot?,
    val davisIntegration: VineyardWeatherIntegration?,
    val desiredFingerprint: String?,
    val shouldRefresh: Boolean,
    val shouldRemoveCachedSnapshot: Boolean,
)

/**
 * Keeps the last successful source and rows when shared configuration is unavailable.
 * A cache may be invalidated only after a successful read positively resolves a new source.
 */
internal fun planOptimalRipenessRefresh(
    cachedSnapshot: OptimalRipenessSnapshot?,
    integrationRead: Result<VineyardWeatherIntegration?>,
    latitude: Double,
    longitude: Double,
): OptimalRipenessRefreshPlan {
    if (integrationRead.isFailure) {
        return OptimalRipenessRefreshPlan(
            cachedSnapshot = cachedSnapshot,
            davisIntegration = null,
            desiredFingerprint = cachedSnapshot?.sourceFingerprint,
            shouldRefresh = false,
            shouldRemoveCachedSnapshot = false,
        )
    }

    val davis = integrationRead.getOrNull()?.takeIf {
        it.isActive && it.hasApiKey && it.hasApiSecret && !it.stationId.isNullOrBlank()
    }
    val desiredFingerprint = davis?.stationId?.let { "davis:$it" }
        ?: DegreeDayService.openMeteoKey(latitude, longitude)
    val sourceChanged = cachedSnapshot != null && cachedSnapshot.sourceFingerprint != desiredFingerprint
    return OptimalRipenessRefreshPlan(
        cachedSnapshot = cachedSnapshot.takeUnless { sourceChanged },
        davisIntegration = davis,
        desiredFingerprint = desiredFingerprint,
        shouldRefresh = true,
        shouldRemoveCachedSnapshot = sourceChanged,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OptimalRipenessScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenTool: ((ToolRoute) -> Unit)? = null,
) {
    var openVarietyKey by remember { mutableStateOf<String?>(null) }
    var showBudburstSheet by remember { mutableStateOf(false) }
    var showFixVarietiesSheet by remember { mutableStateOf(false) }
    val openVariety = state.grapeVarieties.firstOrNull { it.varietyKey == openVarietyKey }
    if (openVariety != null) {
        VarietyGDDDetailScreen(
            state = state,
            variety = openVariety,
            modifier = modifier,
            onBack = { openVarietyKey = null },
        )
        return
    }

    val vine = LocalVineColors.current
    val context = LocalContext.current
    val gddSettings = remember { GddSettingsStore(context).load() }
    val coordinates = resolveOptimalRipenessCoordinates(state)
    val timeZone = remember(state.seasonZone) { java.util.TimeZone.getTimeZone(state.seasonZone) }
    val seasonStartMs = remember(state.seasonStartMonth, state.seasonStartDay, timeZone) {
        seasonStartDate(state.seasonStartMonth, state.seasonStartDay, timeZone)
    }
    val weather = state.optimalRipenessWeather
    val service = weather.service
    val sourceKey = weather.sourceKey
    val paddocks = remember(state.paddocks, state.selectedVineyardId) {
        selectedOptimalRipenessPaddocks(state)
    }
    val calculated = if (service != null && sourceKey != null && weather.hasCachedData) {
        computeRows(
            service = service,
            sourceKey = sourceKey,
            latitude = coordinates?.first ?: 0.0,
            paddocks = paddocks,
            grapeVarieties = state.grapeVarieties,
            useBEDD = gddSettings.calculationMode.useBEDD,
            seasonStartMs = seasonStartMs,
            globalResetMode = gddSettings.resetMode,
            globalCalculationMode = gddSettings.calculationMode,
            timeZone = timeZone,
        ).copy(sourceLabel = weather.sourceLabel, sourceFingerprint = sourceKey)
    } else {
        buildImmediateRipenessResult(
            paddocks = paddocks,
            grapeVarieties = state.grapeVarieties,
            seasonStartMs = seasonStartMs,
            globalResetMode = gddSettings.resetMode,
            cachedSnapshot = null,
            fallbackSourceLabel = weather.sourceLabel,
            sourceFingerprint = sourceKey.orEmpty(),
        )
    }
    val screenState = OptimalRipenessScreenState(calculated, weather.isUpdating)

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Optimal Ripeness") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        val result = screenState.result
        when {
            paddocks.isEmpty() -> {
                Column(modifier = Modifier.fillMaxSize().padding(padding), verticalArrangement = Arrangement.Center) {
                    EmptyState(
                        icon = Icons.Filled.Spa,
                        title = "No blocks",
                        message = "Add blocks under Vineyard Setup to track ripeness toward each variety's optimal harvest target.",
                    )
                }
            }
            else -> {
                LazyColumn(
                    modifier = Modifier.fillMaxSize().padding(padding),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    if (onOpenTool != null) {
                        item {
                            SetupChecklistCard(
                                state = state,
                                seasonStartMonth = state.seasonStartMonth,
                                seasonStartDay = state.seasonStartDay,
                                onOpenTool = onOpenTool,
                                onOpenBudburst = { showBudburstSheet = true },
                                onOpenFixVarieties = { showFixVarietiesSheet = true },
                            )
                        }
                    }
                    item { GddSourceCard(result.sourceLabel, screenState.isUpdatingWeather) }
                    item { SectionHeader("Blocks · ${result.rows.size}", onLight = true) }
                    items(result.rows) { row ->
                        val varietyKey = row.varietyName?.let { name ->
                            val canonical = canonicalVarietyName(name)
                            state.grapeVarieties.firstOrNull { it.canonicalName == canonical }?.varietyKey
                        }
                        BlockRipenessCard(
                            row = row,
                            isUpdatingWeather = screenState.isUpdatingWeather,
                            weatherError = weather.error,
                            onClick = if (varietyKey != null) ({ openVarietyKey = varietyKey }) else null,
                        )
                    }
                    item {
                        Text(
                            "Status starts from each block's authoritative Budburst date and uses the allocated variety's optimal GDD target. Days to target is projected from the last 14 days of accumulation. Source: ${result.sourceLabel}.",
                            color = vine.textSecondary,
                            fontSize = 12.sp,
                        )
                    }
                }
            }
        }
    }

    if (showBudburstSheet) {
        SetBudburstDatesSheet(
            vm = vm,
            state = state,
            globalResetMode = gddSettings.resetMode,
            onDismiss = { showBudburstSheet = false },
        )
    }

    if (showFixVarietiesSheet) {
        FixBlockVarietiesSheet(
            vm = vm,
            state = state,
            onDismiss = { showFixVarietiesSheet = false },
        )
    }
}

@Composable
private fun GddSourceCard(sourceLabel: String, isUpdatingWeather: Boolean) {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Filled.WbSunny, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(18.dp))
            Text("GDD source", color = vine.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.End) {
                Text(sourceLabel, color = vine.textPrimary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                if (isUpdatingWeather) {
                    Text("Updating season weather…", color = vine.textSecondary, fontSize = 11.sp)
                }
            }
        }
    }
}

@Composable
private fun BlockRipenessCard(
    row: RipenessRow,
    isUpdatingWeather: Boolean,
    weatherError: String?,
    onClick: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val status = when {
        !row.hasGddValue && isUpdatingWeather -> RipenessStatus("Syncing weather history…", vine.textSecondary, Icons.Filled.WbSunny)
        !row.hasGddValue && weatherError != null -> RipenessStatus("Weather history couldn't be updated", VineColors.Orange, Icons.Filled.ErrorOutline)
        !row.hasGddValue -> RipenessStatus("Weather history unavailable", vine.textSecondary, Icons.Filled.ErrorOutline)
        row.isIncomplete -> RipenessStatus("Incomplete weather data", VineColors.Orange, Icons.Filled.ErrorOutline)
        else -> ripenessStatus(row)
    }
    VineyardCard(modifier = if (onClick != null) Modifier.clickable { onClick() } else Modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(row.block.name, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                    val allocation = row.block.varietyAllocations.orEmpty().firstOrNull {
                        canonicalVarietyName(it.displayName.orEmpty()) == canonicalVarietyName(row.varietyName.orEmpty()) &&
                            it.displayPercent == row.allocationPercent
                    }
                    val sub = buildList {
                        val repeatsBlock = row.varietyName?.equals(row.block.name, ignoreCase = true) == true
                        if (!repeatsBlock) add(row.varietyName ?: "No variety")
                        allocation?.clone?.trim()?.takeIf(String::isNotEmpty)?.let { add("Clone $it") }
                        allocation?.rootstock?.trim()?.takeIf(String::isNotEmpty)?.let { add("Rootstock $it") }
                        if (row.multiVariety && row.allocationPercent != null) {
                            add(if (row.allocationPercent > 0 && row.allocationPercent < 1) "<1%" else "${row.allocationPercent.toInt()}%")
                        }
                        row.resetDateMs?.let { add("since ${shortDate(it)}") }
                    }.joinToString(" · ")
                    Text(
                        sub,
                        color = if (row.varietyName == null) VineColors.Orange else vine.textSecondary,
                        fontSize = 12.sp,
                        maxLines = 1,
                    )
                }
                if (row.target > 0) {
                    Column(horizontalAlignment = Alignment.End) {
                        if (row.hasGddValue) {
                            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text("${row.total.toInt()}", color = status.color, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                                Text("/ ${row.target.toInt()}", color = vine.textSecondary, fontSize = 11.sp)
                            }
                            Text(if (row.progress > 0 && row.progress < 0.01) "<1%" else "${(row.progress * 100).toInt()}%", color = status.color, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                        } else {
                            Text("Updating…", color = vine.textSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            Text("Target ${row.target.toInt()}", color = vine.textSecondary, fontSize = 11.sp)
                        }
                    }
                }
            }

            // Progress bar remains present while weather is loading so card geometry is stable.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(CircleShape)
                    .background(vine.cardBorder),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(if (row.hasGddValue) row.progress.toFloat().coerceIn(0.02f, 1f) else 0.02f)
                        .height(6.dp)
                        .clip(CircleShape)
                        .background(Brush.horizontalGradient(listOf(status.color.copy(alpha = 0.7f), status.color))),
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(status.icon, contentDescription = null, tint = status.color, modifier = Modifier.size(14.dp))
                Text(status.label, color = status.color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                val days = row.daysToTarget
                if (days != null && days > 0) {
                    Icon(Icons.Filled.CalendarMonth, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(13.dp))
                    Text("≈$days day${if (days == 1) "" else "s"}", color = vine.textSecondary, fontSize = 11.sp)
                }
            }
        }
    }
}

/**
 * Compact, collapsible setup checklist mirroring the iOS card: flags missing
 * coordinates, block varieties and GDD targets and deep-links to the relevant
 * tool to fix each one.
 */
@Composable
private fun SetupChecklistCard(
    state: AppUiState,
    seasonStartMonth: Int,
    seasonStartDay: Int,
    onOpenTool: (ToolRoute) -> Unit,
    onOpenBudburst: () -> Unit,
    onOpenFixVarieties: () -> Unit,
) {
    val vine = LocalVineColors.current
    var expanded by remember { mutableStateOf(false) }

    val items = remember(
        state.paddocks,
        state.grapeVarieties,
        state.grapeVarietyReferenceLoading,
        state.selectedVineyardId,
        seasonStartMonth,
        seasonStartDay,
    ) {
        buildChecklist(state, seasonStartMonth, seasonStartDay)
    }
    val pending = items.count { !it.ok }

    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth().clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    if (pending == 0) Icons.Filled.CheckCircle else Icons.Filled.ErrorOutline,
                    contentDescription = null,
                    tint = if (pending == 0) VineColors.LeafGreen else VineColors.Orange,
                    modifier = Modifier.size(20.dp),
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text("Setup checklist", color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    Text(
                        if (pending == 0) "All set for ripeness tracking" else "$pending item${if (pending == 1) "" else "s"} need attention",
                        color = vine.textSecondary,
                        fontSize = 12.sp,
                    )
                }
                Icon(
                    Icons.Filled.ExpandMore,
                    contentDescription = null,
                    tint = vine.textSecondary,
                    modifier = Modifier.rotate(if (expanded) 180f else 0f),
                )
            }
            AnimatedVisibility(visible = expanded) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items.forEach { item ->
                        val onClick: (() -> Unit)? = when {
                            item.opensBudburst -> onOpenBudburst
                            item.opensFixVarieties -> onOpenFixVarieties
                            item.route != null -> ({ onOpenTool(item.route) })
                            else -> null
                        }
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable(enabled = onClick != null) { onClick?.invoke() },
                            verticalAlignment = Alignment.Top,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(
                                if (item.ok) Icons.Filled.CheckCircle else Icons.Filled.ErrorOutline,
                                contentDescription = null,
                                tint = if (item.ok) VineColors.LeafGreen else VineColors.Orange,
                                modifier = Modifier.size(16.dp),
                            )
                            Column(modifier = Modifier.weight(1f)) {
                                Text(item.title, color = vine.textPrimary, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                                Text(item.detail, color = vine.textSecondary, fontSize = 12.sp)
                            }
                            if (onClick != null) {
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}

private data class ChecklistItem(
    val title: String,
    val detail: String,
    val ok: Boolean,
    val route: ToolRoute?,
    val opensBudburst: Boolean = false,
    val opensFixVarieties: Boolean = false,
)

private fun buildChecklist(state: AppUiState, seasonStartMonth: Int, seasonStartDay: Int): List<ChecklistItem> {
    val out = mutableListOf<ChecklistItem>()
    val paddocks = selectedOptimalRipenessPaddocks(state)

    val v = state.selectedVineyard
    val hasCoords = (v?.latitude != null && v.longitude != null) ||
        paddocks.any { it.centroid != null }
    out.add(
        ChecklistItem(
            "Weather source",
            if (hasCoords) "Open-Meteo Archive ready" else "Add vineyard coordinates or map a block",
            hasCoords,
            ToolRoute.WeatherData,
        )
    )

    // Flags blocks with no allocation AND blocks whose variety can't be matched
    // to the managed catalog (mirrors iOS `RipenessVarietyResolver` — an
    // unrecognised variety is just as broken as a missing one). Tapping opens
    // the inline Fix Block Varieties sheet rather than the full Blocks editor.
    if (!state.grapeVarietyReferenceLoading) {
        val blocksNeedingVariety = paddocks.count { !blockVarietyRecognised(it, state.grapeVarieties) }
        out.add(
            ChecklistItem(
                "Block varieties",
                if (paddocks.isEmpty()) "Add blocks first"
                else if (blocksNeedingVariety == 0) "All blocks have a recognised variety"
                else "$blocksNeedingVariety block${if (blocksNeedingVariety == 1) "" else "s"} need a variety — tap to fix",
                paddocks.isNotEmpty() && blocksNeedingVariety == 0,
                route = null,
                opensFixVarieties = true,
            )
        )
    }

    // Season start date (always satisfied — informational, deep-links to prefs).
    val monthName = monthSymbol(seasonStartMonth)
    out.add(
        ChecklistItem(
            "Season start date",
            "$seasonStartDay $monthName",
            true,
            ToolRoute.OperationPreferences,
        )
    )

    // GDD targets for varieties currently in use.
    val targetsMissing = paddocks.flatMap { it.varietyAllocations.orEmpty() }
        .mapNotNull { alloc ->
            val target = resolveTargetForAllocation(alloc.varietyKey, alloc.varietyId, alloc.displayName, state)
            if (target <= 0) (alloc.displayName ?: "Unknown") else null
        }.distinct()
    out.add(
        ChecklistItem(
            "Variety GDD targets",
            if (targetsMissing.isEmpty()) "Targets resolved for blocks in use"
            else "Add a target for: ${targetsMissing.take(3).joinToString(", ")}",
            targetsMissing.isEmpty(),
            ToolRoute.Growth,
        )
    )

    // Budburst dates — surfaced when any block has a budburst date in play, so
    // the reset used for GDD accumulation is accurate.
    val blocksWithBudburst = paddocks.count { !it.budburstDate.isNullOrBlank() }
    if (paddocks.isNotEmpty()) {
        out.add(
            ChecklistItem(
                "Budburst dates",
                if (blocksWithBudburst > 0) "$blocksWithBudburst block${if (blocksWithBudburst == 1) "" else "s"} using block budburst date — tap to review"
                else "Budburst required before GDD can be calculated — tap to set dates",
                blocksWithBudburst > 0,
                route = null,
                opensBudburst = true,
            )
        )
    }

    // Block location (Open-Meteo coordinates).
    out.add(
        ChecklistItem(
            "Block location",
            if (hasCoords) "Coordinates available" else "Add vineyard coordinates or map a block",
            hasCoords,
            ToolRoute.WeatherData,
        )
    )

    return out
}

private fun monthSymbol(month: Int): String {
    val cal = Calendar.getInstance()
    cal.set(Calendar.MONTH, (month - 1).coerceIn(0, 11))
    return SimpleDateFormat("MMMM", Locale.getDefault()).format(cal.time)
}

private fun OptimalRipenessSnapshot.toRipenessResult(paddocks: List<Paddock>): RipenessResult {
    val blocks = paddocks.associateBy { it.id }
    return RipenessResult(
        sourceConfigured = true,
        sourceLabel = sourceLabel,
        sourceFingerprint = sourceFingerprint,
        rows = rows.mapNotNull { cached ->
            val block = blocks[cached.blockId] ?: return@mapNotNull null
            RipenessRow(
                block = block,
                varietyName = cached.varietyName,
                allocationPercent = cached.allocationPercent,
                multiVariety = cached.multiVariety,
                resetDateMs = cached.resetDateMs,
                total = cached.total,
                target = cached.target,
                daysToTarget = cached.daysToTarget,
                hasGddValue = true,
                isIncomplete = false,
            )
        },
    )
}

internal fun buildImmediateRipenessResult(
    paddocks: List<Paddock>,
    grapeVarieties: List<GrapeVarietyRow>,
    seasonStartMs: Long,
    globalResetMode: GddResetMode,
    cachedSnapshot: OptimalRipenessSnapshot?,
    fallbackSourceLabel: String,
    sourceFingerprint: String = cachedSnapshot?.sourceFingerprint.orEmpty(),
): RipenessResult {
    val rows = paddocks.flatMap { block ->
        val resetMs = optimalRipenessBudburstMs(block)
        val allocations = block.varietyAllocations.orEmpty().sortedByDescending { it.displayPercent ?: 0.0 }
        val rowInputs = if (allocations.isEmpty()) listOf<PaddockVarietyAllocation?>(null) else allocations
        rowInputs.map { allocation ->
            val varietyName = allocation?.let { resolvedRipenessVarietyName(it, grapeVarieties) }
            val cached = resetMs?.let { authoritativeStart ->
                cachedSnapshot?.rows?.firstOrNull { cachedRow ->
                    cachedRow.blockId.equals(block.id, ignoreCase = true) &&
                        cachedRow.resetDateMs == authoritativeStart &&
                        canonicalVarietyName(cachedRow.varietyName.orEmpty()) == canonicalVarietyName(varietyName.orEmpty())
                }
            }
            RipenessRow(
                block = block,
                varietyName = varietyName,
                allocationPercent = allocation?.displayPercent,
                multiVariety = allocations.size > 1,
                resetDateMs = resetMs,
                total = cached?.total ?: 0.0,
                target = allocation?.let {
                    resolveTargetForAllocationList(it.varietyKey, it.displayName, grapeVarieties, it.varietyId)
                } ?: 0.0,
                daysToTarget = cached?.daysToTarget,
                hasGddValue = cached != null,
                isIncomplete = false,
            )
        }
    }
    return RipenessResult(
        sourceConfigured = true,
        rows = rows,
        sourceLabel = cachedSnapshot?.sourceLabel ?: fallbackSourceLabel,
        sourceFingerprint = sourceFingerprint,
    )
}

private fun RipenessResult.toSnapshot(ownerId: String, vineyardId: String): OptimalRipenessSnapshot =
    OptimalRipenessSnapshot(
        ownerId = ownerId,
        vineyardId = vineyardId,
        sourceFingerprint = sourceFingerprint,
        sourceLabel = sourceLabel,
        cachedAtEpochMs = System.currentTimeMillis(),
        rows = rows.map { row ->
            OptimalRipenessSnapshotRow(
                blockId = row.block.id,
                varietyName = row.varietyName,
                allocationPercent = row.allocationPercent,
                multiVariety = row.multiVariety,
                resetDateMs = row.resetDateMs,
                total = row.total,
                target = row.target,
                daysToTarget = row.daysToTarget,
            )
        },
    )

// MARK: - Computation

internal fun computeRows(
    service: DegreeDayService,
    sourceKey: String,
    latitude: Double,
    paddocks: List<Paddock>,
    grapeVarieties: List<com.rork.vinetrack.data.model.GrapeVarietyRow>,
    useBEDD: Boolean,
    nowMs: Long = System.currentTimeMillis(),
    seasonStartMs: Long = nowMs,
    globalResetMode: GddResetMode = GddResetMode.BUDBURST,
    globalCalculationMode: GddCalculationMode = if (useBEDD) GddCalculationMode.BEDD else GddCalculationMode.GDD,
    timeZone: java.util.TimeZone = java.util.TimeZone.getDefault(),
): RipenessResult {
    val now = nowMs
    val rows = mutableListOf<RipenessRow>()

    for (block in paddocks) {
        val calculation = calculateOptimalRipenessBlock(
            service = service,
            sourceKey = sourceKey,
            latitude = latitude,
            block = block,
            seasonStartMs = seasonStartMs,
            globalResetMode = globalResetMode,
            globalCalculationMode = globalCalculationMode,
            timeZone = timeZone,
            nowMs = now,
        )
        val total = calculation.total
        val perDay = recentDailyRate(calculation.points)
        val resolvedReset = calculation.resetDateMs

        val allocations = block.varietyAllocations.orEmpty().sortedByDescending { it.displayPercent ?: 0.0 }
        if (allocations.isEmpty()) {
            rows.add(
                RipenessRow(
                    block, null, null, false, resolvedReset, total, 0.0, null,
                    hasGddValue = calculation.hasValue,
                    isIncomplete = calculation.isIncomplete,
                )
            )
        } else {
            for (alloc in allocations) {
                val varietyName = resolvedRipenessVarietyName(alloc, grapeVarieties)
                val target = resolveTargetForAllocationList(alloc.varietyKey, varietyName, grapeVarieties, alloc.varietyId)
                val days = if (calculation.isIncomplete) null else daysToTarget(total, target, perDay)
                rows.add(
                    RipenessRow(
                        block = block,
                        varietyName = varietyName,
                        allocationPercent = alloc.displayPercent,
                        multiVariety = allocations.size > 1,
                        resetDateMs = resolvedReset,
                        total = total,
                        target = target,
                        daysToTarget = days,
                        hasGddValue = calculation.hasValue,
                        isIncomplete = calculation.isIncomplete,
                    )
                )
            }
        }
    }
    return RipenessResult(
        sourceConfigured = true,
        rows = rows.sortedByDescending { if (it.target > 0) it.total / it.target else 0.0 },
    )
}

/** Average daily GDD over the last 14 days of the series (0 when too short). */
internal fun recentDailyRate(series: List<com.rork.vinetrack.data.GddPoint>): Double {
    if (series.size < 14) return 0.0
    val recent = series.takeLast(14)
    val gained = recent.last().cumulative - recent.first().cumulative
    return gained / max(1, recent.size - 1)
}

/** Projected days to reach [target] given current [total] and per-day rate. */
internal fun daysToTarget(total: Double, target: Double, perDay: Double): Int? {
    if (target <= 0) return null
    if (total >= target) return 0
    if (perDay <= 0) return null
    return kotlin.math.ceil((target - total) / perDay).toInt()
}

private fun resolveTargetForAllocation(
    varietyKey: String?,
    varietyId: String?,
    displayName: String?,
    state: AppUiState,
): Double = resolveTargetForAllocationList(varietyKey, displayName, state.grapeVarieties, varietyId)

internal fun resolveTargetForAllocationList(
    varietyKey: String?,
    displayName: String?,
    grapeVarieties: List<com.rork.vinetrack.data.model.GrapeVarietyRow>,
    varietyId: String? = null,
): Double {
    val canonical = displayName?.let { canonicalVarietyName(it) }
    val match = grapeVarieties.firstOrNull { row ->
        (varietyId != null && row.id.equals(varietyId, ignoreCase = true)) ||
            (varietyKey != null && row.varietyKey == varietyKey) ||
            (canonical != null && row.canonicalName == canonical)
    }
    return BuiltInGrapeVarietyGDD.resolveTarget(match?.optimalGddOverride, varietyKey ?: match?.varietyKey, displayName ?: match?.displayName)
}

// MARK: - Status / formatting

private data class RipenessStatus(val label: String, val color: Color, val icon: androidx.compose.ui.graphics.vector.ImageVector)

private fun ripenessStatus(row: RipenessRow): RipenessStatus {
    if (row.varietyName == null) return RipenessStatus("Variety not configured for ripeness", VineColors.Orange, Icons.Filled.ErrorOutline)
    if (row.target <= 0) return RipenessStatus("Add GDD target for this variety", VineColors.Orange, Icons.Filled.ErrorOutline)
    if (row.resetDateMs == null) return RipenessStatus("Budburst required", VineColors.Orange, Icons.Filled.CalendarMonth)
    return when {
        row.progress >= 1.05 -> RipenessStatus("Past optimal", VineColors.Destructive, Icons.Filled.ErrorOutline)
        row.progress >= 0.98 -> RipenessStatus("In optimal window", VineColors.LeafGreen, Icons.Filled.CheckCircle)
        row.progress >= 0.85 -> RipenessStatus("Approaching optimal", VineColors.Orange, Icons.Filled.WbSunny)
        row.progress >= 0.4 -> RipenessStatus("Tracking", VineColors.Info, Icons.Filled.Spa)
        else -> RipenessStatus("Early", VineColors.TextSecondaryLight, Icons.Filled.Spa)
    }
}

/** Legacy Budburst accessor retained for migration tests and Budburst-only callers. */
internal fun optimalRipenessBudburstMs(block: Paddock): Long? = parseIsoToEpochMs(block.budburstDate)

/** Earliest valid reset date actually required by tracked blocks. */
internal fun earliestRequiredWeatherDate(
    paddocks: List<Paddock>,
    seasonStartMs: Long,
    globalResetMode: GddResetMode,
): Long? = paddocks.mapNotNull { block ->
    val mode = block.effectiveResetMode(globalResetMode)
    block.resetDateMs(mode, seasonStartMs)
}.minOrNull()

internal fun startOfDayMs(time: Long, timeZone: java.util.TimeZone = java.util.TimeZone.getDefault()): Long =
    optimalRipenessStartOfDay(time, timeZone)

/** Most recent occurrence of (month, day), this year or last, as start-of-day ms. */
internal fun seasonStartDate(
    month: Int,
    day: Int,
    timeZone: java.util.TimeZone = java.util.TimeZone.getDefault(),
    nowMs: Long = System.currentTimeMillis(),
): Long {
    val now = Calendar.getInstance(timeZone)
    now.timeInMillis = nowMs
    val curMonth = now.get(Calendar.MONTH) + 1
    val curDay = now.get(Calendar.DAY_OF_MONTH)
    val year = now.get(Calendar.YEAR)
    val startYear = if (curMonth > month || (curMonth == month && curDay >= day)) year else year - 1
    val cal = Calendar.getInstance(timeZone)
    cal.clear()
    cal.set(startYear, month - 1, day, 0, 0, 0)
    return cal.timeInMillis
}

private fun shortDate(ms: Long): String =
    SimpleDateFormat("d MMM", Locale.getDefault()).format(Date(ms))

// MARK: - Fix Block Varieties

/**
 * True when [block]'s primary variety allocation resolves to a managed catalog
 * variety (by key or canonical name). Mirrors the iOS `RipenessVarietyResolver`
 * — a block with no allocation OR with an allocation whose variety can't be
 * matched is treated as not-ready.
 */
internal fun resolvedRipenessVarietyName(
    allocation: PaddockVarietyAllocation,
    grapeVarieties: List<GrapeVarietyRow>,
): String? = VineyardVarietyPresentation.resolve(allocation, grapeVarieties).name

internal fun blockVarietyRecognised(block: Paddock, grapeVarieties: List<GrapeVarietyRow>): Boolean {
    val primary = block.varietyAllocations.orEmpty().maxByOrNull { it.displayPercent ?: 0.0 } ?: return false
    return VineyardVarietyPresentation.resolve(primary, grapeVarieties).isResolved
}

private fun selectedOptimalRipenessPaddocks(state: AppUiState): List<Paddock> {
    val vineyardId = state.selectedVineyardId ?: return emptyList()
    return state.paddocks.filter { it.vineyardId.equals(vineyardId, ignoreCase = true) }
}

/**
 * Focused correction sheet opened from the setup checklist when one or more
 * blocks have a missing or unrecognised variety. Mirrors the iOS
 * `FixBlockVarietiesSheet`: each block holds one or more variety allocations
 * whose percentages should total 100%. Saves PATCH only the variety column via
 * [AppViewModel.updatePaddockVarietyAllocations], so changes reflect everywhere
 * the Block editor's allocations are read.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FixBlockVarietiesSheet(
    vm: AppViewModel,
    state: AppUiState,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    // De-duplicated managed varieties for the current vineyard, sorted by name.
    val managedVarieties = remember(state.grapeVarieties) {
        val seen = HashSet<String>()
        state.grapeVarieties
            .filter { seen.add(it.canonicalName) }
            .sortedBy { it.displayName.lowercase() }
    }

    val vineyardBlocks = selectedOptimalRipenessPaddocks(state)
    val problemBlocks = vineyardBlocks.filter { !blockVarietyRecognised(it, state.grapeVarieties) }
    val resolvedBlocks = vineyardBlocks.filter { blockVarietyRecognised(it, state.grapeVarieties) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 640.dp)
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Fix block varieties", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(
                "Allocate each block's planted varieties and percentages — totals should add to 100%. Saves immediately to the same data Block Settings uses.",
                color = vine.textSecondary,
                fontSize = 13.sp,
            )

            if (managedVarieties.isEmpty()) {
                EmptyState(
                    icon = Icons.Filled.Spa,
                    title = "No varieties in catalog",
                    message = "Add grape varieties from the Growth & Varieties screen first, then return here to allocate them to blocks.",
                )
                return@Column
            }

            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (problemBlocks.isEmpty()) {
                    item {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Icon(Icons.Filled.VerifiedUser, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
                            Text("All blocks have a recognised variety.", color = vine.textPrimary, fontSize = 14.sp)
                        }
                    }
                } else {
                    item { SectionHeader("Needs attention · ${problemBlocks.size}", onLight = true) }
                    items(problemBlocks, key = { it.id }) { block ->
                        BlockAllocationEditor(vm = vm, block = block, managedVarieties = managedVarieties)
                    }
                }
                if (resolvedBlocks.isNotEmpty()) {
                    item { SectionHeader("Already configured · ${resolvedBlocks.size}", onLight = true) }
                    items(resolvedBlocks, key = { it.id }) { block ->
                        BlockAllocationEditor(vm = vm, block = block, managedVarieties = managedVarieties)
                    }
                }
            }
        }
    }
}

@Composable
private fun BlockAllocationEditor(
    vm: AppViewModel,
    block: Paddock,
    managedVarieties: List<GrapeVarietyRow>,
) {
    val vine = LocalVineColors.current
    // Seed from the latest cached block so optimistic saves keep this in sync.
    val allocations = remember(block.id, block.varietyAllocations) {
        mutableStateListOf<PaddockVarietyAllocation>().apply { addAll(block.varietyAllocations.orEmpty()) }
    }

    fun persist() {
        vm.updatePaddockVarietyAllocations(block.id, allocations.toList()) {}
    }

    val total = allocations.sumOf { it.displayPercent ?: 0.0 }
    val balanced = kotlin.math.abs(total - 100.0) < 0.5
    val usedKeys = allocations.mapNotNull { it.varietyKey }.toSet()
    val available = managedVarieties.filter { it.varietyKey !in usedKeys }

    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(block.name, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), maxLines = 1)
                if (allocations.isNotEmpty()) {
                    Text(
                        "Total ${total.toInt()}%",
                        color = if (balanced) VineColors.LeafGreen else VineColors.Orange,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }

            if (allocations.isEmpty()) {
                Text("No variety allocations yet", color = vine.textSecondary, fontSize = 12.sp)
            }

            allocations.forEachIndexed { index, alloc ->
                AllocationEditorRow(
                    alloc = alloc,
                    managedVarieties = managedVarieties,
                    onPickVariety = { row ->
                        allocations[index] = alloc.copy(varietyKey = row.varietyKey, name = row.displayName, varietyName = row.displayName)
                        persist()
                    },
                    onPercent = { p ->
                        allocations[index] = alloc.copy(percent = p)
                        persist()
                    },
                    onRemove = {
                        allocations.removeAt(index)
                        persist()
                    },
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                if (available.isNotEmpty()) {
                    TextButton(onClick = {
                        val remaining = (100.0 - total).coerceAtLeast(0.0)
                        val suggested = if (allocations.isEmpty()) 100.0 else remaining
                        val row = available.first()
                        // Stable planting identity (sql/184): mint an id for the new
                        // allocation — picking records link to it.
                        allocations.add(PaddockVarietyAllocation(id = java.util.UUID.randomUUID().toString(), varietyKey = row.varietyKey, name = row.displayName, varietyName = row.displayName, percent = suggested))
                        persist()
                    }) {
                        Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Add variety", fontSize = 13.sp)
                    }
                } else {
                    Text("All varieties allocated", color = vine.textSecondary, fontSize = 12.sp)
                }
                Spacer(Modifier.weight(1f))
                if (allocations.isNotEmpty() && !balanced) {
                    Text("Doesn't total 100%", color = VineColors.Orange, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

@Composable
private fun AllocationEditorRow(
    alloc: PaddockVarietyAllocation,
    managedVarieties: List<GrapeVarietyRow>,
    onPickVariety: (GrapeVarietyRow) -> Unit,
    onPercent: (Double?) -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    var menuOpen by remember { mutableStateOf(false) }
    val recognised = VineyardVarietyPresentation.resolve(alloc, managedVarieties).isResolved
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(modifier = Modifier.weight(1f)) {
            OutlinedButton(onClick = { menuOpen = true }, modifier = Modifier.fillMaxWidth()) {
                Text(
                    alloc.displayName ?: "Choose variety",
                    color = if (recognised) vine.textPrimary else VineColors.Orange,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Icon(Icons.Filled.ArrowDropDown, contentDescription = null, modifier = Modifier.size(18.dp))
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                managedVarieties.forEach { row ->
                    DropdownMenuItem(
                        text = { Text(row.displayName) },
                        onClick = { menuOpen = false; onPickVariety(row) },
                    )
                }
            }
        }
        OutlinedTextField(
            value = alloc.displayPercent?.let { if (it % 1.0 == 0.0) it.toInt().toString() else it.toString() } ?: "",
            onValueChange = { onPercent(it.toDoubleOrNull()) },
            label = { Text("%") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.width(84.dp),
        )
        IconButton(onClick = onRemove) {
            Icon(Icons.Filled.Delete, contentDescription = "Remove", tint = VineColors.Destructive, modifier = Modifier.size(20.dp))
        }
    }
}

// MARK: - Set Budburst Dates sheet

/**
 * Focused editor mirroring the iOS `SetBudburstDatesSheet`: lists only the
 * blocks whose effective reset point is Budburst, shows each block's stored
 * budburst date with inline set/clear, and offers a one-tap suggestion sourced
 * from the block's latest EL4 (Budburst) growth observation. Saving patches
 * only the phenology dates via [AppViewModel.updatePaddockPhenologyDates].
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SetBudburstDatesSheet(
    vm: AppViewModel,
    state: AppUiState,
    globalResetMode: GddResetMode,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    // Blocks whose effective reset point is Budburst (per-block override wins).
    val budburstBlocks = remember(state.paddocks, globalResetMode) {
        state.paddocks.filter { block ->
            val effective = block.resetModeOverride?.takeIf { it.isNotBlank() }
                ?.let { GddResetMode.fromKey(it) } ?: globalResetMode
            effective == GddResetMode.BUDBURST
        }.sortedBy { it.name.lowercase() }
    }

    var pickerBlockId by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 560.dp)
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Set budburst dates", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(
                "These blocks reset GDD accumulation at budburst. Set each block's budburst date so ripeness projections start from the right day.",
                color = vine.textSecondary,
                fontSize = 13.sp,
            )

            if (budburstBlocks.isEmpty()) {
                EmptyState(
                    icon = Icons.Filled.Spa,
                    title = "No budburst-reset blocks",
                    message = "No blocks currently reset at budburst. Set a block's reset point to Budburst in its setup to manage its date here.",
                )
            } else {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(budburstBlocks, key = { it.id }) { block ->
                        BudburstBlockRow(
                            block = block,
                            suggestionMs = latestEl4ObservationMs(state, block.id),
                            onPick = { pickerBlockId = block.id },
                            onUseSuggestion = { ms ->
                                vm.updatePaddockPhenologyDates(block.id, block.withBudburst(ms)) {}
                            },
                            onClear = {
                                vm.updatePaddockPhenologyDates(block.id, block.withBudburst(null)) {}
                            },
                        )
                    }
                }
            }
        }
    }

    val pickerBlock = budburstBlocks.firstOrNull { it.id == pickerBlockId }
    if (pickerBlock != null) {
        val initial = parseIsoToEpochMs(pickerBlock.budburstDate) ?: System.currentTimeMillis()
        val dpState = rememberDatePickerState(initialSelectedDateMillis = initial)
        DatePickerDialog(
            onDismissRequest = { pickerBlockId = null },
            confirmButton = {
                TextButton(onClick = {
                    dpState.selectedDateMillis?.let { ms ->
                        vm.updatePaddockPhenologyDates(pickerBlock.id, pickerBlock.withBudburst(ms)) {}
                    }
                    pickerBlockId = null
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { pickerBlockId = null }) { Text("Cancel") } },
        ) { DatePicker(state = dpState) }
    }
}

@Composable
private fun BudburstBlockRow(
    block: Paddock,
    suggestionMs: Long?,
    onPick: () -> Unit,
    onUseSuggestion: (Long) -> Unit,
    onClear: () -> Unit,
) {
    val vine = LocalVineColors.current
    val currentMs = parseIsoToEpochMs(block.budburstDate)
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(block.name, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
                    Text(
                        currentMs?.let { "Budburst ${shortDate(it)}" } ?: "No budburst date set",
                        color = if (currentMs != null) VineColors.LeafGreen else VineColors.Orange,
                        fontSize = 12.sp,
                    )
                }
                if (currentMs != null) {
                    IconButton(onClick = onClear) {
                        Icon(Icons.Filled.Close, contentDescription = "Clear date", tint = vine.textSecondary, modifier = Modifier.size(18.dp))
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onPick, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Filled.CalendarMonth, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (currentMs != null) "Change" else "Set date", fontSize = 13.sp)
                }
                if (suggestionMs != null && suggestionMs != currentMs) {
                    OutlinedButton(onClick = { onUseSuggestion(suggestionMs) }, modifier = Modifier.weight(1f)) {
                        Icon(Icons.Filled.Spa, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("EL4 ${shortDate(suggestionMs)}", fontSize = 13.sp, maxLines = 1)
                    }
                }
            }
        }
    }
}

/** Latest EL4 (Budburst) growth observation date for [paddockId], as epoch ms. */
private fun latestEl4ObservationMs(state: AppUiState, paddockId: String): Long? =
    state.growthRecords
        .filter { it.paddockId == paddockId && it.stageCode == GrowthStage.BUDBURST_CODE && it.deletedAt == null }
        .mapNotNull { it.observedEpochMs }
        .maxOrNull()

/** Build a [PaddockRepository.PhenologyDates] that only changes the budburst date. */
private fun Paddock.withBudburst(ms: Long?): PaddockRepository.PhenologyDates =
    PaddockRepository.PhenologyDates(
        budburstDate = ms?.let { Instant.ofEpochMilli(it).toString() },
        floweringDate = floweringDate,
        veraisonDate = veraisonDate,
        harvestDate = harvestDate,
    )
