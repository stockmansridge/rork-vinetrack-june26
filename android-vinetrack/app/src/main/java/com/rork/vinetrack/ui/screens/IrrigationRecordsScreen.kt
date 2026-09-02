package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.AreaUnit
import com.rork.vinetrack.data.IrrigationAllocationConfig
import com.rork.vinetrack.data.IrrigationAvailableRow
import com.rork.vinetrack.data.IrrigationBlockResult
import com.rork.vinetrack.data.IrrigationCapabilities
import com.rork.vinetrack.data.SeasonScope
import com.rork.vinetrack.data.SeasonSelection
import com.rork.vinetrack.data.IrrigationLocalCalc
import com.rork.vinetrack.data.IrrigationPreviewResult
import com.rork.vinetrack.data.IrrigationRepository
import com.rork.vinetrack.data.IrrigationSessionRow
import com.rork.vinetrack.data.IrrigationSetupStatus
import com.rork.vinetrack.data.IrrigationSystemRow
import com.rork.vinetrack.data.IrrigationValveBlockRow
import com.rork.vinetrack.data.IrrigationValveRow
import com.rork.vinetrack.data.IrrigationValveRowLink
import com.rork.vinetrack.data.IrrigationValveRowsResult
import com.rork.vinetrack.data.IrrigationValveValidation
import androidx.compose.material3.ModalBottomSheet
import com.rork.vinetrack.data.IrrigationBlockReportRow
import com.rork.vinetrack.data.IrrigationCalcSourceReportRow
import com.rork.vinetrack.data.IrrigationPeriodReportRow
import com.rork.vinetrack.data.IrrigationRainfallReportRow
import com.rork.vinetrack.data.IrrigationRecordSourceReportRow
import com.rork.vinetrack.data.IrrigationReportFilter
import com.rork.vinetrack.data.IrrigationReportWarning
import com.rork.vinetrack.data.IrrigationValveReportRow
import com.rork.vinetrack.data.IrrigationVarietyReportRow
import com.rork.vinetrack.data.IrrigationVintageOverview
import com.rork.vinetrack.data.IrrigationVintageSummary
import com.rork.vinetrack.data.IrrigationVintageTrendRow
import com.rork.vinetrack.data.IrrigationWaterSourceReportRow
import com.rork.vinetrack.data.PendingIrrigationSession
import com.rork.vinetrack.ui.components.SeasonSelector
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.VolumeUnit
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

// =============================================================================
// Irrigation Records — Phase 1, System Administrator gated.
// Mirrors the iOS IrrigationRecordsView flow: wizard → landing → record /
// history / setup / reports. All authoritative maths live in the SQL 125 RPCs.
// =============================================================================

private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)

// MARK: Session start/end times (SQL 130). Timestamps are built from the
// LOCAL session date + wall-clock time in the device timezone so the local
// date relationship is preserved; overnight ends roll to the following day.

private fun irrigationTimestamp(sessionDate: String, minutesOfDay: Int, addDays: Int): String? {
    val parsed = runCatching { dayFormat.parse(sessionDate) }.getOrNull() ?: return null
    val cal = Calendar.getInstance()
    cal.time = parsed
    cal.set(Calendar.HOUR_OF_DAY, minutesOfDay / 60)
    cal.set(Calendar.MINUTE, minutesOfDay % 60)
    cal.set(Calendar.SECOND, 0)
    cal.set(Calendar.MILLISECOND, 0)
    if (addDays > 0) cal.add(Calendar.DAY_OF_MONTH, addDays)
    return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).format(cal.time)
}

private fun parseIrrigationTimestamp(iso: String): Date? {
    val patterns = listOf(
        "yyyy-MM-dd'T'HH:mm:ssXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
    )
    for (pattern in patterns) {
        runCatching { SimpleDateFormat(pattern, Locale.US).parse(iso) }.getOrNull()?.let { return it }
    }
    return null
}

private fun minutesOfDay(date: Date): Int {
    val cal = Calendar.getInstance()
    cal.time = date
    return cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
}

private fun formatTimeOfDay(minutesOfDay: Int): String {
    val cal = Calendar.getInstance()
    cal.set(Calendar.HOUR_OF_DAY, minutesOfDay / 60)
    cal.set(Calendar.MINUTE, minutesOfDay % 60)
    // Locale.US, not the device locale: irrigation times must read identically for
    // every user of the vineyard rather than following each phone's settings.
    return SimpleDateFormat("h:mm a", Locale.US).format(cal.time).lowercase(Locale.US)
}

/** "8:30 am–11:45 am" (with " next day" for overnight), or start alone. */
private fun irrigationTimeRange(startedAt: String?, finishedAt: String?): String? {
    val start = startedAt?.let { parseIrrigationTimestamp(it) } ?: return null
    val timeFormat = SimpleDateFormat("h:mm a", Locale.US)
    val startText = timeFormat.format(start).lowercase(Locale.US)
    val finish = finishedAt?.let { parseIrrigationTimestamp(it) } ?: return startText
    val finishText = timeFormat.format(finish).lowercase(Locale.US)
    val calStart = Calendar.getInstance().apply { time = start }
    val calFinish = Calendar.getInstance().apply { time = finish }
    val sameDay = calStart.get(Calendar.YEAR) == calFinish.get(Calendar.YEAR) &&
        calStart.get(Calendar.DAY_OF_YEAR) == calFinish.get(Calendar.DAY_OF_YEAR)
    return if (sameDay) "$startText–$finishText" else "$startText–$finishText next day"
}

// Region-aware irrigation display formatting — the Android twin of the iOS
// `IrrigationFormat` helpers. Stored values stay canonical (litres / mm / L/ha);
// only the DISPLAY converts to metric, US customary or Imperial gallons.
private object IrrigationUnits {
    private fun usesUSGallon(fmt: RegionFormatter): Boolean =
        fmt.settings.countryCode.uppercase() == "US" || fmt.settings.countryCode.uppercase() == "CA"

    /** Auto-scaling volume: litres → kL → ML for metric; gallons for US/Imperial. */
    fun volume(litres: Double, fmt: RegionFormatter): String = when (VolumeUnit.from(fmt.settings.volumeUnit)) {
        VolumeUnit.Litres -> when {
            litres >= 1_000_000 -> String.format(Locale.US, "%.2f ML", litres / 1_000_000)
            litres >= 10_000 -> String.format(Locale.US, "%.1f kL", litres / 1_000)
            else -> fmt.formatVolume(litres, if (litres < 100) 1 else 0)
        }
        VolumeUnit.Gallons -> fmt.formatVolume(litres, 0)
    }

    fun flow(litresPerHour: Double, fmt: RegionFormatter): String =
        "${fmt.formatVolume(litresPerHour, 0)}/h"

    fun perVine(litres: Double, fmt: RegionFormatter): String =
        "${fmt.formatVolume(litres, 2)}/vine"

    fun perHectare(litresPerHectare: Double, fmt: RegionFormatter): String =
        if (VolumeUnit.from(fmt.settings.volumeUnit) == VolumeUnit.Litres &&
            AreaUnit.from(fmt.settings.areaUnit) == AreaUnit.Hectares
        ) {
            String.format(Locale.US, "%.0f L/ha", litresPerHectare)
        } else {
            val galPerAcre = IrrigationLocalCalc.litresPerHectareToGallonsPerAcre(litresPerHectare, usesUSGallon(fmt))
            String.format(Locale.US, "%.0f gal/ac", galPerAcre)
        }

    fun depth(mm: Double, fmt: RegionFormatter): String = when (AreaUnit.from(fmt.settings.areaUnit)) {
        AreaUnit.Hectares -> String.format(Locale.US, "%.2f mm", mm)
        AreaUnit.Acres -> String.format(Locale.US, "%.3f in", mm / IrrigationLocalCalc.MM_PER_INCH)
    }
}

private fun formatMinutes(minutes: Int): String {
    val h = minutes / 60
    val m = minutes % 60
    return when {
        h > 0 && m > 0 -> "$h h $m min"
        h > 0 -> "$h h"
        else -> "$m min"
    }
}

private enum class IrrigationNav { Landing, Wizard, Setup, Record, History, Detail, Reports }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IrrigationRecordsScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val repo = vm.irrigationRepository
    val vineyardId = state.selectedVineyardId
    val scope = rememberCoroutineScope()

    var nav by remember { mutableStateOf(IrrigationNav.Landing) }
    var status by remember { mutableStateOf<IrrigationSetupStatus?>(null) }
    var summary by remember { mutableStateOf<IrrigationVintageSummary?>(null) }
    var recent by remember { mutableStateOf<List<IrrigationSessionRow>>(emptyList()) }
    var pendingCount by remember { mutableIntStateOf(0) }
    var detailSessionId by remember { mutableStateOf<String?>(null) }
    var editSession by remember { mutableStateOf<IrrigationSessionRow?>(null) }
    var duplicateSession by remember { mutableStateOf<IrrigationSessionRow?>(null) }
    var isLoading by remember { mutableStateOf(true) }
    var accessDenied by remember { mutableStateOf(false) }
    var capabilities by remember { mutableStateOf<IrrigationCapabilities?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    // null until the operator picks one — the current vintage is the default.
    var selectedVintage by rememberSaveable { mutableStateOf<Int?>(null) }

    suspend fun reload() {
        val vid = vineyardId ?: return
        isLoading = true
        error = null
        runCatching {
            // Public release (SQL 151): visibility comes from the shared
            // role capabilities. The server enforces every RPC independently.
            val caps = repo.capabilities(vid)
            capabilities = caps
            if (!caps.canViewIrrigationRecords) {
                accessDenied = true
                return@runCatching
            }
            accessDenied = false
            repo.flushPending(vid)
            pendingCount = repo.pendingSessions(vid).size
            val s = repo.setupStatus(vid)
            status = s
            if (s.isOperational) {
                // The vintage summary is a report — operators do not hold the
                // reports capability, so the server would (rightly) refuse it.
                // Scope every figure to the selected vintage. A null selection
                // lets the server apply its own current vintage, which is what
                // the very first load (before `status` arrives) must do.
                summary = if (caps.canViewIrrigationReports) {
                    repo.vintageSummary(vid, vintageYear = selectedVintage)
                } else {
                    null
                }
                recent = repo.listSessions(vid, vintageYear = selectedVintage, limit = 5).sessions
            }
            if (nav == IrrigationNav.Landing && !s.isOperational && caps.canManageIrrigationSetup) {
                nav = IrrigationNav.Wizard
            }
        }.onFailure { e ->
            val message = e.message ?: "Unknown error"
            if (message.contains("irrigation_access_denied") || message.contains("not available")) {
                accessDenied = true
            } else {
                error = "Irrigation Records could not be loaded. $message"
            }
        }
        isLoading = false
    }

    LaunchedEffect(vineyardId) { reload() }
    // Changing the vintage reloads the summary AND the session list, so the
    // cards, totals and records all move together — not just the heading.
    LaunchedEffect(selectedVintage) { reload() }

    val title = when (nav) {
        IrrigationNav.Landing -> "Irrigation Records"
        IrrigationNav.Wizard -> "Irrigation Setup"
        IrrigationNav.Setup -> "Irrigation Setup"
        IrrigationNav.Record -> if (editSession != null) "Edit Irrigation" else "Record Irrigation"
        IrrigationNav.History -> "Irrigation History"
        IrrigationNav.Detail -> "Irrigation Session"
        IrrigationNav.Reports -> "Irrigation Reports"
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    IconButton(onClick = {
                        when (nav) {
                            IrrigationNav.Landing, IrrigationNav.Wizard -> onBack?.invoke()
                            IrrigationNav.Detail -> nav = IrrigationNav.History
                            IrrigationNav.Record -> {
                                editSession = null
                                duplicateSession = null
                                nav = IrrigationNav.Landing
                            }
                            else -> nav = IrrigationNav.Landing
                        }
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                accessDenied -> UnavailableContent()
                isLoading && status == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                else -> when (nav) {
                    IrrigationNav.Landing -> LandingContent(
                        state = state,
                        status = status,
                        summary = summary,
                        recent = recent,
                        pendingCount = pendingCount,
                        error = error,
                        capabilities = capabilities,
                        selectedVintage = selectedVintage,
                        onSelectVintage = { selectedVintage = it },
                        onRecord = { nav = IrrigationNav.Record },
                        onHistory = { nav = IrrigationNav.History },
                        onSetup = { nav = IrrigationNav.Setup },
                        onReports = { nav = IrrigationNav.Reports },
                        onWizard = { nav = IrrigationNav.Wizard },
                        onOpenSession = { detailSessionId = it; nav = IrrigationNav.Detail },
                        onRetryPending = { scope.launch { reload() } },
                    )
                    IrrigationNav.Wizard -> WizardContent(
                        status = status,
                        onOpenSetup = { nav = IrrigationNav.Setup },
                        onContinue = { nav = IrrigationNav.Landing },
                        onRefresh = { scope.launch { reload() } },
                    )
                    IrrigationNav.Setup -> SetupContent(
                        repo = repo,
                        state = state,
                        onChanged = { scope.launch { reload() } },
                    )
                    IrrigationNav.Record -> RecordContent(
                        repo = repo,
                        state = state,
                        editSession = editSession,
                        duplicateFrom = duplicateSession,
                        onDone = {
                            editSession = null
                            duplicateSession = null
                            scope.launch { reload() }
                            nav = IrrigationNav.Landing
                        },
                    )
                    IrrigationNav.History -> HistoryContent(
                        repo = repo,
                        state = state,
                        onOpenSession = { detailSessionId = it; nav = IrrigationNav.Detail },
                    )
                    IrrigationNav.Detail -> DetailContent(
                        repo = repo,
                        sessionId = detailSessionId,
                        fmt = state.regionFormatter,
                        capabilities = capabilities,
                        onChanged = { scope.launch { reload() } },
                        onEdit = { session ->
                            editSession = session
                            nav = IrrigationNav.Record
                        },
                        onDuplicate = { session ->
                            duplicateSession = session
                            nav = IrrigationNav.Record
                        },
                    )
                    IrrigationNav.Reports -> ReportsContent(
                        repo = repo,
                        state = state,
                        onOpenSession = { detailSessionId = it; nav = IrrigationNav.Detail },
                    )
                }
            }
        }
    }
}

@Composable
private fun UnavailableContent() {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Filled.WaterDrop, contentDescription = null, tint = VineColors.Cyan, modifier = Modifier.size(44.dp))
        Spacer(Modifier.height(12.dp))
        Text("Not Available", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(6.dp))
        Text(
            "Irrigation Records is not available for this account.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// -----------------------------------------------------------------------------
// Landing
// -----------------------------------------------------------------------------

@Composable
private fun LandingContent(
    state: AppUiState,
    status: IrrigationSetupStatus?,
    summary: IrrigationVintageSummary?,
    recent: List<IrrigationSessionRow>,
    pendingCount: Int,
    error: String?,
    capabilities: IrrigationCapabilities?,
    selectedVintage: Int?,
    onSelectVintage: (Int?) -> Unit,
    onRecord: () -> Unit,
    onHistory: () -> Unit,
    onSetup: () -> Unit,
    onReports: () -> Unit,
    onWizard: () -> Unit,
    onOpenSession: (String) -> Unit,
    onRetryPending: () -> Unit,
) {
    val vineyardName = state.vineyards.firstOrNull { it.id == state.selectedVineyardId }?.name ?: "Vineyard"
    val fmt = state.regionFormatter

    // Current vintage as resolved by the SERVER for this vineyard (sql/119),
    // never a local calendar year — the two only agree for a 1 January season
    // start.
    val currentVintage = status?.season?.currentVintageYear
    val reportVintage = selectedVintage ?: currentVintage
    val isViewingCurrentVintage = currentVintage == null || reportVintage == currentVintage

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Column {
                Text(vineyardName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                reportVintage?.let {
                    Text("Vintage $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }

        if (currentVintage != null) {
            item {
                // Irrigation is server-paged: the session list and every summary
                // RPC fall back to the SERVER's current vintage when no vintage
                // is passed, so there is no way to ask for all vintages in one
                // call. The All chip is withheld here rather than shown and
                // quietly returning a single vintage's numbers under an
                // "All vintages" heading.
                val availableVintages = remember(recent, currentVintage) {
                    (listOf(currentVintage) + recent.map { it.vintageYear })
                        .filter { it > 0 }
                        .distinct()
                        .sortedDescending()
                }
                SeasonSelector(
                    scope = SeasonScope(
                        vintage = reportVintage,
                        window = null,
                        currentVintage = currentVintage,
                        available = availableVintages,
                        zone = state.seasonZone,
                    ),
                    onSelect = { selection ->
                        // Automatic == let the server apply its own current
                        // vintage, which is what the first load does.
                        onSelectVintage((selection as? SeasonSelection.Vintage)?.year)
                    },
                    allowAll = false,
                )
            }
        }

        if (pendingCount > 0) {
            item {
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                        .background(Color(0xFFFFF3E0)).padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.Sync, contentDescription = null, tint = Color(0xFFEF6C00))
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "$pendingCount irrigation record${if (pendingCount == 1) "" else "s"} waiting to sync",
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.weight(1f),
                    )
                    TextButton(onClick = onRetryPending) { Text("Retry") }
                }
            }
        }

        error?.let {
            item { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        }

        // Setup incomplete and this role cannot fix it — explain instead of
        // silently failing at record time.
        status?.let { s ->
            if (!s.isOperational && capabilities?.canManageIrrigationSetup != true) {
                item {
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                            .background(Color(0xFFFFFDE7)).padding(12.dp),
                    ) {
                        Text(
                            "Irrigation setup has not been completed for this vineyard. Ask an Owner or Manager to finish Irrigation Setup before recording irrigation.",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        }

        status?.let { s ->
            val broken = s.valves.filter { !it.allocationOk }
            if (broken.isNotEmpty()) {
                item {
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                            .background(Color(0xFFFFFDE7)).padding(12.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.Warning, contentDescription = null, tint = Color(0xFFF9A825))
                            Spacer(Modifier.width(8.dp))
                            Text(
                                "Block allocations need attention for: ${broken.joinToString(", ") { it.valveName }}.",
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                        if (capabilities?.canManageIrrigationSetup == true) {
                            TextButton(onClick = onWizard) { Text("Open Setup Wizard") }
                        }
                    }
                }
            }
        }

        if (capabilities?.canRecordIrrigation == true) {
            item {
                Button(
                    onClick = onRecord,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Cyan),
                ) {
                    Icon(Icons.Filled.WaterDrop, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("Record Irrigation", fontWeight = FontWeight.SemiBold)
                }
            }
        }

        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onHistory, modifier = Modifier.weight(1f)) { Text("History") }
                if (capabilities?.canManageIrrigationSetup == true) {
                    OutlinedButton(onClick = onSetup, modifier = Modifier.weight(1f)) { Text("Setup") }
                }
                if (capabilities?.canViewIrrigationReports == true) {
                    OutlinedButton(onClick = onReports, modifier = Modifier.weight(1f)) { Text("Reports") }
                }
            }
        }

        if (capabilities?.canViewIrrigationReports == true) {
            item {
                Text(
                    if (isViewingCurrentVintage) "This Vintage" else "Vintage $reportVintage",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
            }

            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    StatCard("Vintage Water", summary?.let { IrrigationUnits.volume(it.totalVolumeLitres, fmt) } ?: "—", Modifier.weight(1f))
                    StatCard("This Month", summary?.let { IrrigationUnits.volume(it.monthVolumeLitres, fmt) } ?: "—", Modifier.weight(1f))
                }
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    StatCard(
                        "Irrigation Hours",
                        summary?.let { String.format(Locale.US, "%.1f h", it.totalRuntimeMinutes / 60.0) } ?: "—",
                        Modifier.weight(1f),
                    )
                    StatCard("Sessions", summary?.sessionCount?.toString() ?: "—", Modifier.weight(1f))
                }
            }
            if (summary?.waterLitresPerVine != null || summary?.irrigationDepthMm != null) {
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        StatCard(
                            "Avg Water / Vine",
                            summary.waterLitresPerVine?.let { IrrigationUnits.perVine(it, fmt) } ?: "—",
                            Modifier.weight(1f),
                        )
                        StatCard(
                            "Irrigation Depth",
                            summary.irrigationDepthMm?.let { IrrigationUnits.depth(it, fmt) } ?: "—",
                            Modifier.weight(1f),
                        )
                    }
                }
            }
        }

        item { Text("Recent Irrigation", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }

        if (recent.isEmpty()) {
            item {
                Text(
                    if (isViewingCurrentVintage) {
                        "No irrigation recorded yet this vintage."
                    } else {
                        "No irrigation recorded in Vintage $reportVintage."
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            recent.forEach { session ->
                item(key = session.id) {
                    SessionRowCard(session, fmt) { onOpenSession(session.id) }
                }
            }
        }
    }
}

@Composable
private fun StatCard(title: String, value: String, modifier: Modifier = Modifier) {
    Column(
        modifier.clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .padding(12.dp),
    ) {
        Text(title, style = MaterialTheme.typography.labelSmall, color = VineColors.Cyan)
        Spacer(Modifier.height(4.dp))
        Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun SessionRowCard(session: IrrigationSessionRow, fmt: RegionFormatter, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .clickable(onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(session.sessionDate, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                if (session.status != "completed") {
                    Spacer(Modifier.width(6.dp))
                    Text(
                        session.status.replaceFirstChar { it.uppercase() },
                        style = MaterialTheme.typography.labelSmall,
                        color = when (session.status) {
                            "reversed" -> MaterialTheme.colorScheme.error
                            "imported" -> VineColors.Cyan
                            else -> Color(0xFFEF6C00)
                        },
                    )
                }
            }
            Text(
                "${session.valveName ?: "Valve"} · ${session.blockNames.ifEmpty { "No blocks" }}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
            if (session.isImported) {
                Text(
                    session.importInfo?.providerLabel ?: "Controller import",
                    style = MaterialTheme.typography.labelSmall,
                    color = VineColors.Cyan,
                )
            }
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(
                IrrigationUnits.volume(session.totalVolumeLitres, fmt),
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                textDecoration = if (session.status == "reversed") TextDecoration.LineThrough else null,
            )
            Text(
                formatMinutes(session.durationMinutes),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

// -----------------------------------------------------------------------------
// Wizard
// -----------------------------------------------------------------------------

@Composable
private fun WizardContent(
    status: IrrigationSetupStatus?,
    onOpenSetup: () -> Unit,
    onContinue: () -> Unit,
    onRefresh: () -> Unit,
) {
    val s = status ?: return
    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Text(
                "Before recording irrigation, VineTrack needs the growing season, at least one block, an irrigation system, a valve and block connections totalling 100%. Items configured in Vineyard Setup are reused.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        item {
            WizardRow(
                "Growing season & vintage",
                "Season starts ${s.season.seasonStartMonth}/${s.season.seasonStartDay} · Vintage ${s.season.currentVintageYear}",
                complete = true, required = true, onAction = null,
            )
        }
        item {
            WizardRow(
                "At least one active block",
                if (s.required.blocksOk) "${s.required.activeBlockCount} active blocks"
                else "No active blocks yet — valves connect to blocks (open Blocks from the More menu)",
                complete = s.required.blocksOk, required = true, onAction = null,
            )
        }
        item {
            WizardRow(
                "Irrigation system",
                if (s.required.systemsOk) "${s.required.activeSystemCount} active system(s)"
                else "Create your first irrigation system",
                complete = s.required.systemsOk, required = true, onAction = onOpenSetup,
                actionLabel = "Create Irrigation System",
            )
        }
        item {
            WizardRow(
                "Irrigation valve",
                if (s.required.valvesOk) "${s.required.activeValveCount} active valve(s)"
                else "Add at least one valve connected to a system",
                complete = s.required.valvesOk, required = true, onAction = onOpenSetup,
                actionLabel = "Create Irrigation Valve",
            )
        }
        item {
            WizardRow(
                "Valve-to-block connections",
                if (s.required.allocationsOk) "${s.required.fullyAllocatedValveCount} valve(s) fully allocated (100%)"
                else "Connect each valve to its blocks — allocations must total 100%",
                complete = s.required.allocationsOk, required = true, onAction = onOpenSetup,
                actionLabel = "Assign Blocks to Valves",
            )
        }
        item {
            WizardRow(
                "Valve flow rate",
                "A configured flow rate enables automatic water calculations from duration. You may still record by total volume or meter readings. ${s.required.valvesWithConfiguredFlow} of ${s.required.activeValveCount} valves have a flow rate.",
                complete = s.required.valvesWithConfiguredFlow > 0, required = false, onAction = onOpenSetup,
                actionLabel = "Configure Valve Flow",
            )
        }
        item { Text("Recommended for full reporting", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                CoverageRow("Block area — water per hectare & depth", s.recommended.blocksWithArea, s.recommended.totalActiveBlocks)
                CoverageRow("Vine count — water per vine", s.recommended.blocksWithVineCount, s.recommended.totalActiveBlocks)
                CoverageRow("Dripper output — expected delivery", s.recommended.blocksWithDripperOutput, s.recommended.totalActiveBlocks)
                CoverageRow("Dripper spacing — emitters per vine", s.recommended.blocksWithDripperSpacing, s.recommended.totalActiveBlocks)
                CoverageRow("Irrigation efficiency — effective water", s.recommended.blocksWithEfficiency, s.recommended.totalActiveBlocks)
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onRefresh, modifier = Modifier.weight(1f)) { Text("Re-check") }
                Button(
                    onClick = onContinue,
                    enabled = s.isOperational,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Cyan),
                ) { Text("Continue") }
            }
        }
    }
}

@Composable
private fun WizardRow(
    title: String,
    detail: String,
    complete: Boolean,
    required: Boolean,
    onAction: (() -> Unit)?,
    actionLabel: String = "Open Setup",
) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                if (complete) Icons.Filled.CheckCircle else if (required) Icons.Filled.Warning else Icons.Filled.Info,
                contentDescription = null,
                tint = if (complete) Color(0xFF2E7D32) else if (required) Color(0xFFEF6C00) else Color(0xFF1565C0),
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text(
                if (complete) "Complete" else if (required) "Required" else "Recommended",
                style = MaterialTheme.typography.labelSmall,
                color = if (complete) Color(0xFF2E7D32) else if (required) Color(0xFFEF6C00) else Color(0xFF1565C0),
            )
        }
        Spacer(Modifier.height(4.dp))
        Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (!complete && onAction != null) {
            TextButton(onClick = onAction) { Text(actionLabel) }
        }
    }
}

@Composable
private fun CoverageRow(title: String, done: Int, total: Int) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
        Text(
            "$done/$total",
            style = MaterialTheme.typography.labelMedium,
            color = if (total > 0 && done >= total) Color(0xFF2E7D32) else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// -----------------------------------------------------------------------------
// Setup (systems / valves / block connections / status)
// -----------------------------------------------------------------------------

@Composable
private fun SetupContent(
    repo: IrrigationRepository,
    state: AppUiState,
    onChanged: () -> Unit,
) {
    val vineyardId = state.selectedVineyardId ?: return
    val scope = rememberCoroutineScope()
    val fmt = state.regionFormatter

    var tab by remember { mutableIntStateOf(0) }
    var systems by remember { mutableStateOf<List<IrrigationSystemRow>>(emptyList()) }
    var valves by remember { mutableStateOf<List<IrrigationValveRow>>(emptyList()) }
    var status by remember { mutableStateOf<IrrigationSetupStatus?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var showSystemForm by remember { mutableStateOf(false) }
    var editingSystem by remember { mutableStateOf<IrrigationSystemRow?>(null) }
    var showValveForm by remember { mutableStateOf(false) }
    var editingValve by remember { mutableStateOf<IrrigationValveRow?>(null) }
    var blocksValve by remember { mutableStateOf<IrrigationValveRow?>(null) }
    var reloadKey by remember { mutableIntStateOf(0) }

    LaunchedEffect(vineyardId, reloadKey) {
        runCatching {
            systems = repo.listSystems(vineyardId, includeInactive = true)
            valves = repo.listValves(vineyardId, includeInactive = true)
            status = repo.setupStatus(vineyardId)
        }.onFailure { error = it.message }
    }

    fun refresh() {
        reloadKey += 1
        onChanged()
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            listOf("Systems", "Valves", "Blocks", "Status").forEachIndexed { index, label ->
                FilterChip(selected = tab == index, onClick = { tab = index }, label = { Text(label) })
            }
        }

        error?.let {
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp))
        }

        when (tab) {
            0 -> LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                systems.forEach { system ->
                    item(key = system.id) {
                        SetupRowCard(
                            title = system.name,
                            subtitle = system.waterSource ?: "",
                            trailing = if (system.isActive) "" else "Inactive",
                        ) { editingSystem = system }
                    }
                }
                item {
                    OutlinedButton(onClick = { showSystemForm = true }, modifier = Modifier.fillMaxWidth()) {
                        Icon(Icons.Filled.Add, contentDescription = null)
                        Spacer(Modifier.width(6.dp))
                        Text("Add Irrigation System")
                    }
                }
            }
            1 -> LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                valves.forEach { valve ->
                    item(key = valve.id) {
                        // SQL 131: the trailing value shows the RESOLVED operational
                        // flow (explicit valve flow or emitter-derived automatic flow).
                        val vs = status?.valves?.firstOrNull { it.valveId == valve.id }
                        val resolvedFlow = vs?.resolvedFlowLph ?: valve.configuredFlowLph
                        val autoDerived = vs?.automaticFlowReady == true && valve.configuredFlowLph == null
                        SetupRowCard(
                            title = valve.name,
                            subtitle = "${valve.systemName ?: "System"} · " +
                                (vs?.configurationSummary ?: "Not configured") +
                                (vs?.resolvedFlowEmitterCount?.takeIf { autoDerived }
                                    ?.let { " · Derived from $it connected emitters" } ?: ""),
                            trailing = resolvedFlow?.let {
                                IrrigationUnits.flow(it, fmt) + (if (autoDerived) " (auto)" else "")
                            } ?: if (valve.isActive) "No flow" else "Inactive",
                        ) { editingValve = valve }
                    }
                }
                item {
                    OutlinedButton(
                        onClick = { showValveForm = true },
                        enabled = systems.any { it.isActive },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = null)
                        Spacer(Modifier.width(6.dp))
                        Text("Add Irrigation Valve")
                    }
                }
            }
            2 -> {
                val blocksTarget = blocksValve
                if (blocksTarget != null) {
                    ValveBlocksEditor(
                        repo = repo,
                        vineyardId = vineyardId,
                        valve = blocksTarget,
                        paddocks = state.paddocks.map { it.id to it.name },
                        onDone = {
                            blocksValve = null
                            refresh()
                        },
                    )
                } else {
                    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        item {
                            Text(
                                "Each valve shows its saved connection method and readiness. Select a valve to configure its connections.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        valves.filter { it.isActive }.forEach { valve ->
                            item(key = valve.id) {
                                val vs = status?.valves?.firstOrNull { it.valveId == valve.id }
                                val ready = vs?.allocationOk == true
                                SetupRowCard(
                                    title = valve.name,
                                    subtitle = vs?.configurationSummary ?: "Not configured",
                                    trailing = when {
                                        ready -> "Ready to record"
                                        vs == null || vs.blockCount == 0 -> "Configure connections"
                                        else -> "Setup required"
                                    },
                                    trailingColor = if (ready) Color(0xFF2E7D32) else Color(0xFFEF6C00),
                                ) { blocksValve = valve }
                            }
                        }
                    }
                }
            }
            else -> LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                status?.let { s ->
                    item { CoverageRow("Active blocks", s.required.activeBlockCount, s.required.activeBlockCount) }
                    item { CoverageRow("Active systems", s.required.activeSystemCount, s.required.activeSystemCount) }
                    item { CoverageRow("Valves fully allocated", s.required.fullyAllocatedValveCount, s.required.activeValveCount) }
                    item { CoverageRow("Valves with configured flow", s.required.valvesWithConfiguredFlow, s.required.activeValveCount) }
                    item { CoverageRow("Valves with automatic flow", s.required.valvesWithAutomaticFlow ?: s.required.valvesWithConfiguredFlow, s.required.activeValveCount) }
                    item { HorizontalDivider() }
                    item { Text("Data coverage", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }
                    item { CoverageRow("Block area", s.recommended.blocksWithArea, s.recommended.totalActiveBlocks) }
                    item { CoverageRow("Vine count", s.recommended.blocksWithVineCount, s.recommended.totalActiveBlocks) }
                    item { CoverageRow("Dripper output", s.recommended.blocksWithDripperOutput, s.recommended.totalActiveBlocks) }
                    item { CoverageRow("Dripper spacing", s.recommended.blocksWithDripperSpacing, s.recommended.totalActiveBlocks) }
                    item { CoverageRow("Irrigation efficiency", s.recommended.blocksWithEfficiency, s.recommended.totalActiveBlocks) }
                }
            }
        }
    }

    if (showSystemForm || editingSystem != null) {
        SystemFormDialog(
            system = editingSystem,
            onDismiss = { showSystemForm = false; editingSystem = null },
            onSave = { name, waterSource, notes, isActive ->
                scope.launch {
                    runCatching {
                        val existing = editingSystem
                        if (existing != null) {
                            repo.updateSystem(existing.id, name, waterSource, notes, isActive)
                        } else {
                            repo.createSystem(vineyardId, name, waterSource, notes)
                        }
                    }.onFailure { error = it.message }
                    showSystemForm = false
                    editingSystem = null
                    refresh()
                }
            },
        )
    }

    if (showValveForm || editingValve != null) {
        ValveFormDialog(
            valve = editingValve,
            systems = systems.filter { it.isActive },
            onDismiss = { showValveForm = false; editingValve = null },
            onSave = { systemId, name, number, configured, measured, notes, isActive ->
                scope.launch {
                    runCatching {
                        val existing = editingValve
                        if (existing != null) {
                            repo.updateValve(existing.id, name, number, configured, measured, notes, isActive)
                        } else {
                            repo.createValve(vineyardId, systemId, name, number, configured, measured, notes)
                        }
                    }.onFailure { error = it.message }
                    showValveForm = false
                    editingValve = null
                    refresh()
                }
            },
        )
    }
}

@Composable
private fun SetupRowCard(
    title: String,
    subtitle: String,
    trailing: String,
    trailingColor: Color = VineColors.Cyan,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .clickable(onClick = onClick)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
            if (subtitle.isNotEmpty()) {
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (trailing.isNotEmpty()) {
            Text(trailing, style = MaterialTheme.typography.labelMedium, color = trailingColor)
        }
    }
}

@Composable
private fun SystemFormDialog(
    system: IrrigationSystemRow?,
    onDismiss: () -> Unit,
    onSave: (name: String, waterSource: String?, notes: String?, isActive: Boolean?) -> Unit,
) {
    var name by remember { mutableStateOf(system?.name ?: "") }
    var waterSource by remember { mutableStateOf(system?.waterSource ?: "") }
    var notes by remember { mutableStateOf(system?.notes ?: "") }
    var isActive by remember { mutableStateOf(system?.isActive ?: true) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (system == null) "New Irrigation System" else "Edit System") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name") }, singleLine = true)
                OutlinedTextField(value = waterSource, onValueChange = { waterSource = it }, label = { Text("Water source") }, singleLine = true)
                OutlinedTextField(value = notes, onValueChange = { notes = it }, label = { Text("Notes") })
                if (system != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Active", modifier = Modifier.weight(1f))
                        Switch(checked = isActive, onCheckedChange = { isActive = it })
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onSave(name.trim(), waterSource.trim().ifEmpty { null }, notes.trim().ifEmpty { null }, if (system != null) isActive else null) },
                enabled = name.trim().isNotEmpty(),
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun ValveFormDialog(
    valve: IrrigationValveRow?,
    systems: List<IrrigationSystemRow>,
    onDismiss: () -> Unit,
    onSave: (systemId: String, name: String, number: String?, configured: Double?, measured: Double?, notes: String?, isActive: Boolean?) -> Unit,
) {
    var systemId by remember { mutableStateOf(valve?.irrigationSystemId ?: systems.firstOrNull()?.id ?: "") }
    var name by remember { mutableStateOf(valve?.name ?: "") }
    var number by remember { mutableStateOf(valve?.valveNumber ?: "") }
    var configured by remember { mutableStateOf(valve?.configuredFlowLph?.toString() ?: "") }
    var measured by remember { mutableStateOf(valve?.measuredFlowLph?.toString() ?: "") }
    var notes by remember { mutableStateOf(valve?.notes ?: "") }
    var isActive by remember { mutableStateOf(valve?.isActive ?: true) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (valve == null) "New Valve" else "Edit Valve") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (valve == null) {
                    Text("Irrigation system", style = MaterialTheme.typography.labelMedium)
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        systems.forEach { system ->
                            FilterChip(
                                selected = systemId == system.id,
                                onClick = { systemId = system.id },
                                label = { Text(system.name) },
                            )
                        }
                    }
                }
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Valve name") }, singleLine = true)
                OutlinedTextField(value = number, onValueChange = { number = it }, label = { Text("Valve number (optional)") }, singleLine = true)
                OutlinedTextField(value = configured, onValueChange = { configured = it }, label = { Text("Configured flow (L/h)") }, singleLine = true)
                OutlinedTextField(value = measured, onValueChange = { measured = it }, label = { Text("Measured flow (L/h, optional)") }, singleLine = true)
                Text(
                    "The configured flow is used for duration-based calculations. Measured flow is informational until saved as configured.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                OutlinedTextField(value = notes, onValueChange = { notes = it }, label = { Text("Notes") })
                if (valve != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Active", modifier = Modifier.weight(1f))
                        Switch(checked = isActive, onCheckedChange = { isActive = it })
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    onSave(
                        systemId, name.trim(), number.trim().ifEmpty { null },
                        configured.replace(",", ".").toDoubleOrNull(),
                        measured.replace(",", ".").toDoubleOrNull(),
                        notes.trim().ifEmpty { null },
                        if (valve != null) isActive else null,
                    )
                },
                enabled = name.trim().isNotEmpty() && systemId.isNotEmpty(),
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun ValveBlocksEditor(
    repo: IrrigationRepository,
    vineyardId: String,
    valve: IrrigationValveRow,
    paddocks: List<Pair<String, String>>,
    onDone: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    data class RowState(val key: String, var blockId: String?, var pct: String)

    var mode by remember { mutableStateOf("manual") }
    var rows by remember { mutableStateOf<List<RowState>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var isSaving by remember { mutableStateOf(false) }

    // Rows-method state (SQL 126). Percentages shown after saving come from
    // the BACKEND response — the local weighting is provisional only.
    var availableRows by remember { mutableStateOf<List<IrrigationAvailableRow>>(emptyList()) }
    var selectedRowIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var expandedBlocks by remember { mutableStateOf<Set<String>>(emptySet()) }
    var rowSearch by remember { mutableStateOf("") }
    var serverResult by remember { mutableStateOf<IrrigationValveRowsResult?>(null) }

    // Saved state — kept strictly separate from the local draft so the UI can
    // always distinguish "Current saved configuration" from "Unsaved preview".
    var savedLinks by remember { mutableStateOf<List<IrrigationValveRowLink>>(emptyList()) }
    var savedBlocks by remember { mutableStateOf<List<IrrigationValveBlockRow>>(emptyList()) }
    var showClearConfirm by remember { mutableStateOf(false) }

    LaunchedEffect(valve.id) {
        runCatching {
            val existing = repo.listValveBlocks(vineyardId, valve.id)
            rows = existing.map {
                RowState(UUID.randomUUID().toString(), it.blockId, it.allocationPercentage?.toString() ?: "")
            }
            availableRows = repo.listAvailableRows(vineyardId)
            val links = repo.listValveRows(vineyardId, valve.id)
            savedBlocks = existing
            savedLinks = links
            selectedRowIds = links.mapNotNull { it.rowId }.toSet()
            if (existing.any { it.allocationMethod == "rows" }) {
                mode = "rows"
                expandedBlocks = links.map { it.blockId }.toSet()
            }
        }.onFailure { error = it.message }
    }

    val total = rows.sumOf { it.pct.replace(",", ".").toDoubleOrNull() ?: 0.0 }
    val totalOk = rows.isNotEmpty() && abs(total - 100.0) <= 0.05
    val selectedRows = availableRows.filter { selectedRowIds.contains(it.rowId) }
    val savedRowIds = savedLinks.mapNotNull { it.rowId }.toSet()
    val hasUnsavedRowChanges = selectedRowIds != savedRowIds

    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Text(
                if (mode == "manual") {
                    "Connect ${valve.name} to the blocks it waters. Active allocations must total 100%."
                } else {
                    "Select the exact vineyard rows ${valve.name} supplies. VineTrack derives the blocks and water split from your selection."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(selected = mode == "manual", onClick = { mode = "manual" }, label = { Text("Manual %") })
                FilterChip(selected = mode == "rows", onClick = { mode = "rows" }, label = { Text("Rows") })
            }
        }

        if (mode == "rows") {
            if (availableRows.isEmpty()) {
                item {
                    Text(
                        "No vineyard rows are configured. Map rows for your blocks in Vineyard Blocks before using row-based allocation.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                if (availableRows.size > 30) {
                    item {
                        OutlinedTextField(
                            value = rowSearch,
                            onValueChange = { rowSearch = it },
                            label = { Text("Search rows (e.g. 12)") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }

                val grouped = availableRows.groupBy { it.blockId }
                grouped.forEach { (blockId, blockRows) ->
                    val blockName = blockRows.first().blockName
                    val selectedCount = blockRows.count { selectedRowIds.contains(it.rowId) }
                    val expanded = expandedBlocks.contains(blockId) || rowSearch.isNotEmpty()
                    item(key = "block_$blockId") {
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
                                .clickable {
                                    expandedBlocks = if (expanded) expandedBlocks - blockId else expandedBlocks + blockId
                                }
                                .padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(blockName, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            Text(
                                "$selectedCount of ${blockRows.size} rows",
                                style = MaterialTheme.typography.labelMedium,
                                color = if (selectedCount > 0) VineColors.Cyan else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    if (expanded) {
                        item(key = "block_actions_$blockId") {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                TextButton(onClick = {
                                    selectedRowIds = selectedRowIds + blockRows.map { it.rowId }
                                    serverResult = null
                                }) { Text("Select All") }
                                TextButton(onClick = {
                                    selectedRowIds = selectedRowIds - blockRows.map { it.rowId }.toSet()
                                    serverResult = null
                                }) { Text("Clear") }
                            }
                        }
                        blockRows.filter {
                            rowSearch.isEmpty() || it.displayLabel.contains(rowSearch, ignoreCase = true)
                        }.forEach { row ->
                            item(key = "row_${row.rowId}") {
                                val isSelected = selectedRowIds.contains(row.rowId)
                                val otherValves = row.connectedValveNames.filter { it != valve.name }
                                Row(
                                    Modifier.fillMaxWidth()
                                        .clickable {
                                            selectedRowIds = if (isSelected) selectedRowIds - row.rowId else selectedRowIds + row.rowId
                                            serverResult = null
                                        }
                                        .padding(horizontal = 8.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Checkbox(
                                        checked = isSelected,
                                        onCheckedChange = {
                                            selectedRowIds = if (isSelected) selectedRowIds - row.rowId else selectedRowIds + row.rowId
                                            serverResult = null
                                        },
                                    )
                                    Column(Modifier.weight(1f)) {
                                        Text(row.displayLabel, style = MaterialTheme.typography.bodyMedium)
                                        // "215.01 m · ≈103 vines · ≈430 emitters" — shared
                                        // SQL 127 estimates, never calculated on-device.
                                        val detail = listOf(
                                            row.rowLengthMetres?.let { String.format(Locale.US, "%.2f m", it) } ?: "Length unavailable",
                                            row.vineCount?.let { "${if (row.vineCountIsEstimated == true) "≈" else ""}$it vines" } ?: "Vines unavailable",
                                            row.emitterCount?.let { "${if (row.emitterCountIsEstimated == true) "≈" else ""}$it emitters" } ?: "Emitters unavailable",
                                        ).joinToString(" · ")
                                        Text(
                                            detail,
                                            style = MaterialTheme.typography.labelSmall,
                                            color = if (row.rowLengthMetres == null) Color(0xFFEF6C00)
                                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                        if (otherValves.isNotEmpty()) {
                                            Text(
                                                "Also: ${otherValves.joinToString(", ")}",
                                                style = MaterialTheme.typography.labelSmall,
                                                color = Color(0xFFEF6C00),
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                item {
                    val dirty = hasUnsavedRowChanges
                    val totalsByBlock = availableRows.groupBy { it.blockId }
                    // Saved configurations derive rows from list_irrigation_valve_rows;
                    // unsaved edits derive them from the local selection. Exact selection
                    // is NEVER inferred from row_start/row_end.
                    data class SummaryBlock(
                        val blockId: String,
                        val blockName: String,
                        val selectedNumbers: List<Int>,
                        val totalRows: Int,
                        val share: Double?,
                        // SQL 127 estimated totals — shown only when every selected
                        // row in the block carries a value (never partial sums).
                        val vines: Int?,
                        val emitters: Int?,
                        val anyEstimated: Boolean,
                    )
                    val summaryBlocks: List<SummaryBlock> = if (dirty || savedLinks.isEmpty()) {
                        val shares = IrrigationLocalCalc.rowWeighting(selectedRows).blocks
                            .associate { it.blockId to it.percentage }
                        selectedRows.groupBy { it.blockId }.map { (blockId, rowsInBlock) ->
                            SummaryBlock(
                                blockId = blockId,
                                blockName = rowsInBlock.first().blockName,
                                selectedNumbers = rowsInBlock.map { it.rowNumber },
                                totalRows = totalsByBlock[blockId]?.size ?: 0,
                                share = shares[blockId],
                                vines = if (rowsInBlock.all { it.vineCount != null })
                                    rowsInBlock.sumOf { it.vineCount ?: 0 } else null,
                                emitters = if (rowsInBlock.all { it.emitterCount != null })
                                    rowsInBlock.sumOf { it.emitterCount ?: 0 } else null,
                                anyEstimated = rowsInBlock.any {
                                    it.vineCountIsEstimated == true || it.emitterCountIsEstimated == true
                                },
                            )
                        }.sortedBy { it.blockName }
                    } else {
                        val shares = savedBlocks
                            .filter { it.allocationMethod == "rows" && it.allocationPercentage != null }
                            .associate { it.blockId to (it.allocationPercentage ?: 0.0) }
                        savedLinks.groupBy { it.blockId }.map { (blockId, linksInBlock) ->
                            SummaryBlock(
                                blockId = blockId,
                                blockName = linksInBlock.first().blockName
                                    ?: totalsByBlock[blockId]?.firstOrNull()?.blockName ?: "Block",
                                selectedNumbers = linksInBlock.map { it.rowNumber },
                                totalRows = totalsByBlock[blockId]?.size ?: 0,
                                share = shares[blockId],
                                vines = if (linksInBlock.all { it.vineCount != null })
                                    linksInBlock.sumOf { it.vineCount ?: 0 } else null,
                                emitters = if (linksInBlock.all { it.emitterCount != null })
                                    linksInBlock.sumOf { it.emitterCount ?: 0 } else null,
                                anyEstimated = linksInBlock.any {
                                    it.vineCountIsEstimated == true || it.emitterCountIsEstimated == true
                                },
                            )
                        }.sortedBy { it.blockName }
                    }
                    val displayBasis: String? = if (dirty) {
                        if (selectedRows.isEmpty()) null else IrrigationLocalCalc.rowBasis(selectedRows)
                    } else {
                        serverResult?.weightingBasis
                            ?: savedLinks.firstOrNull()?.weightingBasis
                            ?: if (selectedRows.isEmpty()) null else IrrigationLocalCalc.rowBasis(selectedRows)
                    }
                    val usingSaved = !dirty && savedLinks.isNotEmpty()
                    // Backend-derived totals only — SQL 127 supplies shared
                    // estimates; partial sums are never presented as totals.
                    val vineTotal: Int? = if (usingSaved) {
                        if (savedLinks.all { it.vineCount != null })
                            savedLinks.sumOf { it.vineCount ?: 0 } else null
                    } else {
                        if (selectedRows.isNotEmpty() && selectedRows.all { (it.vineCount ?: 0) > 0 })
                            selectedRows.sumOf { it.vineCount ?: 0 } else null
                    }
                    val emitterTotal: Int? = if (usingSaved) {
                        if (savedLinks.all { it.emitterCount != null })
                            savedLinks.sumOf { it.emitterCount ?: 0 } else null
                    } else {
                        if (selectedRows.isNotEmpty() && selectedRows.all { (it.emitterCount ?: 0) > 0 })
                            selectedRows.sumOf { it.emitterCount ?: 0 } else null
                    }
                    // Drives the ≈ prefix and the shared "estimates" explanation.
                    val valuesEstimated = if (usingSaved) {
                        savedLinks.any { it.vineCountIsEstimated == true || it.emitterCountIsEstimated == true }
                    } else {
                        selectedRows.any { it.vineCountIsEstimated == true || it.emitterCountIsEstimated == true }
                    }
                    val missingLength = if (usingSaved) {
                        savedLinks.count { it.rowLengthMetres == null }
                    } else {
                        selectedRows.count { it.rowLengthMetres == null }
                    }

                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                            .background(VineColors.Cyan.copy(alpha = 0.08f)).padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            if (dirty) "Unsaved preview" else "Current saved configuration",
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        if (savedRowIds.isNotEmpty()) {
                            DetailLine("Saved", "${savedRowIds.size} row${if (savedRowIds.size == 1) "" else "s"}")
                        }
                        if (dirty) {
                            DetailLine("Draft", "${selectedRows.size} row${if (selectedRows.size == 1) "" else "s"} selected")
                        }
                        if (dirty && selectedRows.isEmpty() && savedRowIds.isNotEmpty()) {
                            Text(
                                "All rows have been removed from the draft. The saved configuration remains active until you save.",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color(0xFFEF6C00),
                            )
                        }
                        displayBasis?.let { DetailLine("Allocation basis", IrrigationLocalCalc.basisLabel(it)) }

                        summaryBlocks.forEach { block ->
                            Spacer(Modifier.height(2.dp))
                            Text(block.blockName, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold)
                            DetailLine("Rows", "${block.selectedNumbers.size} / ${block.totalRows} rows")
                            if (block.selectedNumbers.isNotEmpty()) {
                                Text(
                                    "Rows ${IrrigationLocalCalc.rangeSummary(block.selectedNumbers)}",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            DetailLine(
                                "Estimated vines",
                                block.vines?.let { "${if (block.anyEstimated) "≈" else ""}$it" } ?: "Not available",
                            )
                            DetailLine(
                                "Estimated emitters",
                                block.emitters?.let { "${if (block.anyEstimated) "≈" else ""}$it" } ?: "Not available",
                            )
                            if (block.totalRows > 0) {
                                DetailLine(
                                    "Block coverage",
                                    String.format(Locale.US, "%.1f%%", block.selectedNumbers.size.toDouble() / block.totalRows * 100.0),
                                )
                            }
                            DetailLine(
                                if (dirty) "Share of valve water (preview)" else "Share of valve water",
                                block.share?.let { String.format(Locale.US, "%.1f%%", it) } ?: "—",
                            )
                        }

                        if (summaryBlocks.isNotEmpty()) {
                            DetailLine(
                                if (valuesEstimated) "Estimated vines (selected rows)" else "Vines (selected rows)",
                                vineTotal?.let { "${if (valuesEstimated) "≈" else ""}$it" } ?: "Not available",
                            )
                            DetailLine(
                                if (valuesEstimated) "Estimated emitters (selected rows)" else "Emitters (selected rows)",
                                emitterTotal?.let { "${if (valuesEstimated) "≈" else ""}$it" } ?: "Not available",
                            )
                            if ((vineTotal != null || emitterTotal != null) && valuesEstimated) {
                                Text(
                                    "Vine and emitter counts are estimates based on mapped row length and Vineyard Setup information.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            if (vineTotal == null || emitterTotal == null) {
                                Text(
                                    if (displayBasis == "row_length")
                                        "Row length is currently used to calculate the block water split. Per-row vine and emitter counts are not available."
                                    else
                                        "Per-row vine and emitter counts have not been configured.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            if (missingLength > 0) {
                                Text(
                                    "$missingLength selected row${if (missingLength == 1) " does" else "s do"} not have complete mapped start and end points, so their length is unavailable.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = Color(0xFFEF6C00),
                                )
                            }
                            if (displayBasis == "equal_rows") {
                                Text(
                                    "Allocation is estimated by selected row count because complete row lengths are unavailable.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = Color(0xFFEF6C00),
                                )
                            }
                        }
                        serverResult?.warnings?.forEach { warning ->
                            Text(warning, style = MaterialTheme.typography.bodySmall, color = Color(0xFFEF6C00))
                        }
                    }
                }
            }
        } else {
        rows.forEachIndexed { index, row ->
            item(key = row.key) {
                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
                        .padding(10.dp),
                ) {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        paddocks.forEach { (id, name) ->
                            FilterChip(
                                selected = row.blockId == id,
                                onClick = {
                                    rows = rows.toMutableList().also { it[index] = row.copy(blockId = id) }
                                },
                                label = { Text(name) },
                            )
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = row.pct,
                            onValueChange = { value ->
                                rows = rows.toMutableList().also { it[index] = row.copy(pct = value) }
                            },
                            label = { Text("Allocation %") },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = { rows = rows.filterNot { it.key == row.key } }) { Text("Remove") }
                    }
                }
            }
        }
        item {
            OutlinedButton(onClick = {
                val remaining = (100.0 - total).coerceAtLeast(0.0)
                rows = rows + RowState(UUID.randomUUID().toString(), null, if (remaining > 0) String.format(Locale.US, "%.2f", remaining) else "")
            }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Add, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Add Block")
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Allocated", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Text(
                    String.format(Locale.US, "%.2f%%", total),
                    fontWeight = FontWeight.Bold,
                    color = if (totalOk) Color(0xFF2E7D32) else if (total > 100) MaterialTheme.colorScheme.error else Color(0xFFEF6C00),
                )
            }
        }
        }
        if (mode == "rows" && selectedRowIds.isEmpty() && availableRows.isNotEmpty()) {
            item {
                Text(
                    "Select at least one row before saving.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        error?.let { item { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) } }
        item {
            Button(
                onClick = {
                    scope.launch {
                        isSaving = true
                        error = null
                        if (mode == "rows") {
                            if (selectedRowIds.isEmpty()) {
                                error = "Select at least one row before saving."
                            } else {
                                runCatching {
                                    repo.setValveRows(vineyardId, valve.id, selectedRowIds.toList())
                                }.onSuccess { result ->
                                    serverResult = result
                                    savedBlocks = result.blocks
                                    savedLinks = runCatching { repo.listValveRows(vineyardId, valve.id) }.getOrDefault(savedLinks)
                                    if (result.warnings.isEmpty()) onDone()
                                }.onFailure { error = it.message }
                            }
                        } else {
                            runCatching {
                                repo.setValveBlocks(
                                    vineyardId, valve.id,
                                    rows.mapNotNull { row ->
                                        val blockId = row.blockId ?: return@mapNotNull null
                                        val pct = row.pct.replace(",", ".").toDoubleOrNull() ?: return@mapNotNull null
                                        blockId to pct
                                    },
                                )
                            }.onSuccess { onDone() }
                                .onFailure { error = it.message }
                        }
                        isSaving = false
                    }
                },
                enabled = !isSaving && if (mode == "rows") {
                    selectedRowIds.isNotEmpty()
                } else {
                    (totalOk || rows.isEmpty()) && rows.none { it.blockId == null }
                },
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Cyan),
            ) { Text(if (isSaving) "Saving…" else if (mode == "rows") "Save Row Connections" else "Save Block Connections") }
        }
        if (mode == "rows" && savedRowIds.isNotEmpty()) {
            item {
                OutlinedButton(
                    onClick = { showClearConfirm = true },
                    enabled = !isSaving,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Clear saved connections", color = MaterialTheme.colorScheme.error) }
            }
        }
    }

    if (showClearConfirm) {
        AlertDialog(
            onDismissRequest = { showClearConfirm = false },
            title = { Text("Clear saved connections?") },
            text = { Text("This valve will no longer have any connected rows and cannot record irrigation until it is configured again.") },
            confirmButton = {
                TextButton(onClick = {
                    showClearConfirm = false
                    scope.launch {
                        isSaving = true
                        error = null
                        // The shared RPC treats an EMPTY selection as an explicit
                        // disconnect — an empty draft is never silently saved.
                        runCatching { repo.setValveRows(vineyardId, valve.id, emptyList()) }
                            .onSuccess {
                                savedLinks = emptyList()
                                savedBlocks = emptyList()
                                selectedRowIds = emptySet()
                                serverResult = null
                                onDone()
                            }
                            .onFailure { error = it.message }
                        isSaving = false
                    }
                }) { Text("Clear", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { showClearConfirm = false }) { Text("Cancel") } },
        )
    }
}

// -----------------------------------------------------------------------------
// Record / edit form + preview
// -----------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RecordContent(
    repo: IrrigationRepository,
    state: AppUiState,
    editSession: IrrigationSessionRow?,
    duplicateFrom: IrrigationSessionRow?,
    onDone: () -> Unit,
) {
    val vineyardId = state.selectedVineyardId ?: return
    val scope = rememberCoroutineScope()
    val fmt = state.regionFormatter
    val source = editSession ?: duplicateFrom

    var systems by remember { mutableStateOf<List<IrrigationSystemRow>>(emptyList()) }
    var valves by remember { mutableStateOf<List<IrrigationValveRow>>(emptyList()) }
    var systemId by remember { mutableStateOf(source?.irrigationSystemId) }
    var valveId by remember { mutableStateOf(source?.valveId) }
    var validation by remember { mutableStateOf<IrrigationValveValidation?>(null) }
    var sessionDate by remember {
        mutableStateOf(if (editSession != null) editSession.sessionDate else dayFormat.format(Date()))
    }
    var showDatePicker by remember { mutableStateOf(false) }
    var durationHours by remember { mutableStateOf(source?.let { (it.durationMinutes / 60).toString() } ?: "") }
    var durationMins by remember { mutableStateOf(source?.let { (it.durationMinutes % 60).toString() } ?: "") }
    // Optional start/end times (SQL 130); prefilled only when editing.
    var startMinutes by remember {
        mutableStateOf(editSession?.startedAt?.let { parseIrrigationTimestamp(it) }?.let { minutesOfDay(it) })
    }
    var endMinutes by remember {
        mutableStateOf(editSession?.finishedAt?.let { parseIrrigationTimestamp(it) }?.let { minutesOfDay(it) })
    }
    var method by remember { mutableStateOf(source?.calculationMethod ?: "configured_flow") }
    var sessionFlow by remember {
        mutableStateOf(if (source?.calculationMethod == "session_flow") source.flowLph?.toString() ?: "" else "")
    }
    var meterStart by remember { mutableStateOf(source?.meterStartLitres?.toString() ?: "") }
    var meterFinish by remember { mutableStateOf(source?.meterFinishLitres?.toString() ?: "") }
    var totalVolume by remember {
        mutableStateOf(if (source?.calculationMethod == "total_volume") source.totalVolumeLitres.toString() else "")
    }
    var notes by remember { mutableStateOf(editSession?.notes ?: "") }
    var useCurrentConfig by remember { mutableStateOf(false) }
    // SQL 131 — advanced measurement options stay hidden while the default
    // configured-flow workflow is available.
    var showAdvancedMethods by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<IrrigationPreviewResult?>(null) }
    var localPreview by remember { mutableStateOf<IrrigationLocalCalc.Result?>(null) }
    var offlinePreview by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var isSaving by remember { mutableStateOf(false) }
    var savedMessage by remember { mutableStateOf<String?>(null) }

    // When both times are set their difference is authoritative (read-only
    // duration); equal times are invalid and block saving.
    val derivedDuration = startMinutes?.let { s -> endMinutes?.let { e -> IrrigationLocalCalc.minutesBetweenTimes(s, e) } }
    val bothTimesSet = startMinutes != null && endMinutes != null
    val durationMinutes = derivedDuration
        ?: if (bothTimesSet) 0 else (durationHours.toIntOrNull() ?: 0) * 60 + (durationMins.toIntOrNull() ?: 0)

    fun preserveDerivedDuration() {
        derivedDuration?.let {
            durationHours = (it / 60).toString()
            durationMins = (it % 60).toString()
        }
    }

    LaunchedEffect(vineyardId) {
        runCatching {
            systems = repo.listSystems(vineyardId)
            valves = repo.listValves(vineyardId)
            if (systemId == null && systems.size == 1) systemId = systems.first().id
        }
    }

    LaunchedEffect(valveId) {
        preview = null
        localPreview = null
        val vid = valveId ?: return@LaunchedEffect
        validation = runCatching { repo.validateValve(vineyardId, vid) }
            .getOrElse { repo.cachedValidation(vineyardId, vid) }
    }

    val availableValves = valves.filter { it.isActive && (systemId == null || it.irrigationSystemId == systemId) }
    val canPreview = valveId != null && durationMinutes > 0 && when (method) {
        "configured_flow" -> validation?.automaticFlowAvailable == true
        "session_flow" -> (sessionFlow.replace(",", ".").toDoubleOrNull() ?: 0.0) > 0
        "total_volume" -> (totalVolume.replace(",", ".").toDoubleOrNull() ?: 0.0) > 0
        "meter_readings" -> {
            val s = meterStart.replace(",", ".").toDoubleOrNull() ?: 0.0
            val f = meterFinish.replace(",", ".").toDoubleOrNull() ?: 0.0
            f > s && f > 0
        }
        else -> false
    }

    fun runPreview() {
        scope.launch {
            val vid = valveId ?: return@launch
            offlinePreview = false
            error = null
            runCatching {
                repo.preview(
                    vineyardId, vid, sessionDate, durationMinutes, method,
                    flowLph = if (method == "session_flow") sessionFlow.replace(",", ".").toDoubleOrNull() else null,
                    meterStart = meterStart.replace(",", ".").toDoubleOrNull(),
                    meterFinish = meterFinish.replace(",", ".").toDoubleOrNull(),
                    totalVolume = totalVolume.replace(",", ".").toDoubleOrNull(),
                )
            }.onSuccess {
                preview = it
                localPreview = null
            }.onFailure {
                // Offline fallback: local mirror of the SQL calculation core.
                val v = validation
                if (v != null) {
                    runCatching {
                        val flow = when (method) {
                            "configured_flow" -> v.flowForCalculation
                            "session_flow" -> sessionFlow.replace(",", ".").toDoubleOrNull()
                            else -> null
                        }
                        val total = IrrigationLocalCalc.totalVolume(
                            method, flow, durationMinutes,
                            meterStart.replace(",", ".").toDoubleOrNull(),
                            meterFinish.replace(",", ".").toDoubleOrNull(),
                            totalVolume.replace(",", ".").toDoubleOrNull(),
                        )
                        IrrigationLocalCalc.allocate(total, v.allocations)
                    }.onSuccess { result ->
                        localPreview = result
                        preview = null
                        offlinePreview = true
                    }.onFailure { calc -> error = calc.message }
                } else {
                    error = it.message
                }
            }
        }
    }

    fun save() {
        scope.launch {
            isSaving = true
            error = null
            val flowValue = if (method == "session_flow") sessionFlow.replace(",", ".").toDoubleOrNull() else null
            val meterStartValue = if (method == "meter_readings") meterStart.replace(",", ".").toDoubleOrNull() else null
            val meterFinishValue = if (method == "meter_readings") meterFinish.replace(",", ".").toDoubleOrNull() else null
            val totalValue = if (method == "total_volume") totalVolume.replace(",", ".").toDoubleOrNull() else null

            val sMin = startMinutes
            val eMin = endMinutes
            val startedAtIso = sMin?.let { irrigationTimestamp(sessionDate, it, 0) }
            val finishedAtIso = when {
                sMin == null -> null
                eMin != null -> irrigationTimestamp(sessionDate, eMin, if (eMin <= sMin) 1 else 0)
                durationMinutes > 0 -> {
                    val end = IrrigationLocalCalc.endOfSession(sMin, durationMinutes)
                    irrigationTimestamp(sessionDate, end.minutesOfDay, end.daysLater)
                }
                else -> null
            }

            if (editSession != null) {
                runCatching {
                    repo.updateSession(
                        editSession.id, sessionDate, durationMinutes, method,
                        flowValue, meterStartValue, meterFinishValue, totalValue,
                        startedAt = startedAtIso, finishedAt = finishedAtIso,
                        // Clearing is explicit: the session had stored times
                        // and the user removed the start time.
                        clearTimes = editSession.startedAt != null && sMin == null,
                        notes = notes.ifEmpty { null }, useCurrentConfiguration = useCurrentConfig,
                    )
                }.onSuccess {
                    savedMessage = "The irrigation record was updated and all block allocations were recalculated."
                }.onFailure { error = it.message }
                isSaving = false
                return@launch
            }

            val vid = valveId ?: return@launch
            val sysId = systemId ?: valves.firstOrNull { it.id == vid }?.irrigationSystemId ?: return@launch
            val pending = PendingIrrigationSession(
                id = UUID.randomUUID().toString(),
                vineyardId = vineyardId,
                irrigationSystemId = sysId,
                valveId = vid,
                valveName = validation?.valveName ?: "Valve",
                sessionDate = sessionDate,
                durationMinutes = durationMinutes,
                calculationMethod = method,
                flowLph = flowValue,
                meterStartLitres = meterStartValue,
                meterFinishLitres = meterFinishValue,
                totalVolumeLitres = totalValue,
                startedAt = startedAtIso,
                finishedAt = finishedAtIso,
                notes = notes.ifEmpty { null },
                localTotalVolumeLitres = localPreview?.totalVolumeLitres ?: preview?.totalVolumeLitres,
            )
            runCatching { repo.recordSession(pending) }
                .onSuccess { saved ->
                    savedMessage = if (saved.duplicate == true) {
                        "This irrigation record was already saved."
                    } else {
                        "Irrigation recorded: ${IrrigationUnits.volume(saved.totalVolumeLitres, fmt)} across ${saved.blocks.size} block(s)."
                    }
                }
                .onFailure { e ->
                    val text = (e.message ?: "").lowercase()
                    val offline = "network" in text || "timeout" in text || "connect" in text ||
                        "unreachable" in text || "hostname" in text
                    if (offline) {
                        repo.enqueuePending(pending)
                        savedMessage = "You're offline. The irrigation record was saved on this device and will sync automatically."
                    } else {
                        error = e.message
                    }
                }
            isSaving = false
        }
    }

    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (editSession == null) {
            item {
                Text("Irrigation system", style = MaterialTheme.typography.labelMedium)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    systems.filter { it.isActive }.forEach { system ->
                        FilterChip(selected = systemId == system.id, onClick = {
                            systemId = system.id
                            if (valveId != null && valves.firstOrNull { it.id == valveId }?.irrigationSystemId != system.id) valveId = null
                        }, label = { Text(system.name) })
                    }
                }
            }
            item {
                Text("Valve", style = MaterialTheme.typography.labelMedium)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    availableValves.forEach { valve ->
                        FilterChip(selected = valveId == valve.id, onClick = { valveId = valve.id }, label = { Text(valve.name) })
                    }
                }
            }
            validation?.takeIf { !it.canRecord }?.let { v ->
                item {
                    v.issues.forEach {
                        Text(it, color = Color(0xFFEF6C00), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        } else {
            item {
                Text(
                    "${editSession.valveName ?: "Valve"} · ${editSession.systemName ?: "System"}",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }

        item {
            OutlinedTextField(
                value = sessionDate,
                onValueChange = {},
                readOnly = true,
                label = { Text("Date") },
                modifier = Modifier.fillMaxWidth().clickable { showDatePicker = true },
                trailingIcon = { TextButton(onClick = { showDatePicker = true }) { Text("Change") } },
            )
        }
        item {
            val context = androidx.compose.ui.platform.LocalContext.current
            fun pickTime(initial: Int?, onPicked: (Int) -> Unit) {
                val init = initial ?: (8 * 60)
                android.app.TimePickerDialog(
                    context,
                    { _, hour, minute -> onPicked(hour * 60 + minute) },
                    init / 60, init % 60, false,
                ).show()
            }
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Times (optional)", style = MaterialTheme.typography.labelMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = startMinutes?.let { formatTimeOfDay(it) } ?: "",
                        onValueChange = {}, readOnly = true, singleLine = true,
                        label = { Text("Start time") },
                        modifier = Modifier.weight(1f),
                        trailingIcon = {
                            TextButton(onClick = { pickTime(startMinutes) { startMinutes = it } }) { Text("Set") }
                        },
                    )
                    OutlinedTextField(
                        value = endMinutes?.let { formatTimeOfDay(it) } ?: "",
                        onValueChange = {}, readOnly = true, singleLine = true,
                        label = { Text("End time") },
                        enabled = startMinutes != null,
                        modifier = Modifier.weight(1f),
                        trailingIcon = {
                            TextButton(
                                enabled = startMinutes != null,
                                onClick = { pickTime(endMinutes) { endMinutes = it } },
                            ) { Text("Set") }
                        },
                    )
                }
                if (startMinutes != null) {
                    Row {
                        TextButton(onClick = {
                            preserveDerivedDuration()
                            startMinutes = null
                            endMinutes = null
                        }) { Text("Clear times") }
                        if (endMinutes != null) {
                            TextButton(onClick = {
                                preserveDerivedDuration()
                                endMinutes = null
                            }) { Text("Clear end") }
                        }
                    }
                }
            }
        }
        item {
            if (bothTimesSet) {
                if (derivedDuration == null) {
                    Text(
                        "End time must be different from start time.",
                        color = Color(0xFFEF6C00),
                        style = MaterialTheme.typography.bodySmall,
                    )
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            "Duration: ${formatMinutes(derivedDuration)}",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        if (endMinutes!! <= startMinutes!!) {
                            Text(
                                "Ends the following day",
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(value = durationHours, onValueChange = { durationHours = it }, label = { Text("Hours") }, singleLine = true, modifier = Modifier.weight(1f))
                        OutlinedTextField(value = durationMins, onValueChange = { durationMins = it }, label = { Text("Minutes") }, singleLine = true, modifier = Modifier.weight(1f))
                    }
                    val sMin = startMinutes
                    if (sMin != null && durationMinutes > 0) {
                        val end = IrrigationLocalCalc.endOfSession(sMin, durationMinutes)
                        Text(
                            "Calculated end: ${formatTimeOfDay(end.minutesOfDay)}${if (end.daysLater > 0) " next day" else ""}",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        }
        // SQL 131 default workflow: when a configured flow resolves
        // automatically, no measurement method needs selecting — the picker
        // stays behind an advanced action.
        val defaultFlowWorkflow = validation?.automaticFlowAvailable == true &&
            method == "configured_flow" && !showAdvancedMethods
        item {
            Text("Water calculation", style = MaterialTheme.typography.labelMedium)
            if (!defaultFlowWorkflow) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(
                        "configured_flow" to "Configured Flow",
                        "session_flow" to "Session Flow",
                        "total_volume" to "Total Volume",
                        "meter_readings" to "Meter Readings",
                    ).forEach { (key, label) ->
                        FilterChip(selected = method == key, onClick = { method = key }, label = { Text(label) })
                    }
                }
            }
        }
        when (method) {
            "configured_flow" -> item {
                val v = validation
                val flow = v?.flowForCalculation
                if (v != null && v.automaticFlowAvailable && flow != null) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            "Calculated flow: ${IrrigationUnits.flow(flow, fmt)}",
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        v.resolvedFlowSourceLabel?.let { label ->
                            Text(
                                label + (if (v.resolvedFlowIsEstimated == true) " (estimated)" else ""),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        if (defaultFlowWorkflow) {
                            TextButton(onClick = { showAdvancedMethods = true }) {
                                Text("Change measurement method")
                            }
                        }
                    }
                } else {
                    Text(
                        v?.resolvedFlowWarning
                            ?: "No configured flow source exists for this valve. Enter a session flow, total volume or meter readings instead.",
                        color = Color(0xFFEF6C00),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            "session_flow" -> item {
                OutlinedTextField(value = sessionFlow, onValueChange = { sessionFlow = it }, label = { Text("Flow rate (L/h)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
            "total_volume" -> item {
                OutlinedTextField(value = totalVolume, onValueChange = { totalVolume = it }, label = { Text("Total water (litres)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
            "meter_readings" -> item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(value = meterStart, onValueChange = { meterStart = it }, label = { Text("Meter start (L)") }, singleLine = true, modifier = Modifier.weight(1f))
                    OutlinedTextField(value = meterFinish, onValueChange = { meterFinish = it }, label = { Text("Meter finish (L)") }, singleLine = true, modifier = Modifier.weight(1f))
                }
            }
        }
        item {
            OutlinedTextField(value = notes, onValueChange = { notes = it }, label = { Text("Notes (optional)") }, modifier = Modifier.fillMaxWidth())
        }
        if (editSession != null) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Apply current valve configuration", style = MaterialTheme.typography.bodyMedium)
                        Text(
                            if (useCurrentConfig) "Recalculates with today's valve and block setup."
                            else "The configuration saved with this record is kept.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Switch(checked = useCurrentConfig, onCheckedChange = { useCurrentConfig = it })
                }
            }
        }

        item {
            OutlinedButton(onClick = { runPreview() }, enabled = canPreview, modifier = Modifier.fillMaxWidth()) {
                Text("Calculate Preview")
            }
        }
        if (offlinePreview) {
            item {
                Text(
                    "Offline preview — the server will confirm the final values when the record syncs.",
                    color = Color(0xFFEF6C00),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        preview?.let { p ->
            item { PreviewSummary(p.totalVolumeLitres, p.effectiveVolumeLitres, p.flowLphUsed, fmt) }
            p.flowExplanation?.let { explanation ->
                item {
                    Text(
                        explanation + (if (p.flowIsEstimated == true) " (estimated)" else ""),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            p.blocks.forEach { block ->
                item { PreviewBlockRow(block, fmt) }
            }
            p.warnings.forEach { warning ->
                item { Text(warning, color = Color(0xFFEF6C00), style = MaterialTheme.typography.bodySmall) }
            }
        }
        localPreview?.let { p ->
            item { PreviewSummary(p.totalVolumeLitres, p.effectiveVolumeLitres, null, fmt) }
            p.blocks.forEach { block ->
                item {
                    PreviewBlockRow(
                        IrrigationBlockResult(
                            blockId = block.blockId, blockName = block.blockName,
                            allocationPercentage = block.allocationPercentage,
                            allocatedVolumeLitres = block.allocatedVolumeLitres,
                            effectiveVolumeLitres = block.effectiveVolumeLitres,
                            waterLitresPerVine = block.waterLitresPerVine,
                            waterLitresPerHectare = block.waterLitresPerHectare,
                            irrigationDepthMm = block.irrigationDepthMm,
                        ),
                        fmt,
                    )
                }
            }
            p.warnings.forEach { warning ->
                item { Text(warning, color = Color(0xFFEF6C00), style = MaterialTheme.typography.bodySmall) }
            }
        }

        error?.let { item { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) } }

        item {
            Button(
                onClick = { save() },
                enabled = canPreview && !isSaving,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Cyan),
            ) { Text(if (isSaving) "Saving…" else if (editSession != null) "Save Changes" else "Save Irrigation Record") }
        }
    }

    if (showDatePicker) {
        val pickerState = rememberDatePickerState(
            initialSelectedDateMillis = runCatching { dayFormat.parse(sessionDate)?.time }.getOrNull()
                ?: System.currentTimeMillis(),
        )
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    pickerState.selectedDateMillis?.let { millis ->
                        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = millis }
                        val local = Calendar.getInstance().apply {
                            set(cal.get(Calendar.YEAR), cal.get(Calendar.MONTH), cal.get(Calendar.DAY_OF_MONTH))
                        }
                        sessionDate = dayFormat.format(local.time)
                    }
                    showDatePicker = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { showDatePicker = false }) { Text("Cancel") } },
        ) { DatePicker(state = pickerState) }
    }

    savedMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { savedMessage = null; onDone() },
            title = { Text("Saved") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { savedMessage = null; onDone() }) { Text("OK") } },
        )
    }
}

@Composable
private fun PreviewSummary(total: Double, effective: Double?, flowUsed: Double?, fmt: RegionFormatter) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(VineColors.Cyan.copy(alpha = 0.08f)).padding(12.dp),
    ) {
        Text("Total water: ${IrrigationUnits.volume(total, fmt)}", fontWeight = FontWeight.SemiBold)
        effective?.let { Text("Effective water: ${IrrigationUnits.volume(it, fmt)}", style = MaterialTheme.typography.bodySmall) }
        flowUsed?.let { Text("Flow used: ${IrrigationUnits.flow(it, fmt)}", style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun PreviewBlockRow(block: IrrigationBlockResult, fmt: RegionFormatter) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 4.dp)) {
        Row {
            Text(block.blockName ?: "Block", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text(String.format(Locale.US, "%.1f%%", block.allocationPercentage), style = MaterialTheme.typography.bodySmall)
        }
        val parts = buildList {
            add(IrrigationUnits.volume(block.allocatedVolumeLitres, fmt))
            block.waterLitresPerVine?.let { add(IrrigationUnits.perVine(it, fmt)) }
            block.waterLitresPerHectare?.let { add(IrrigationUnits.perHectare(it, fmt)) }
            block.irrigationDepthMm?.let { add(IrrigationUnits.depth(it, fmt)) }
        }
        Text(parts.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// -----------------------------------------------------------------------------
// History + detail
// -----------------------------------------------------------------------------

@Composable
private fun HistoryContent(
    repo: IrrigationRepository,
    state: AppUiState,
    onOpenSession: (String) -> Unit,
) {
    val vineyardId = state.selectedVineyardId ?: return
    val fmt = state.regionFormatter
    var sessions by remember { mutableStateOf<List<IrrigationSessionRow>>(emptyList()) }
    var totalCount by remember { mutableIntStateOf(0) }
    var includeReversed by remember { mutableStateOf(false) }
    // SQL 142 source filter: null = all, 'manual' = any manual, 'imported' = controller imports.
    var sourceFilter by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(vineyardId, includeReversed, sourceFilter) {
        runCatching {
            val result = repo.listSessions(
                vineyardId,
                sourceType = sourceFilter,
                includeReversed = includeReversed,
                limit = 100,
            )
            sessions = result.sessions
            totalCount = result.totalCount
        }.onFailure { error = it.message }
    }

    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("$totalCount session(s)", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                Text("Include reversed", style = MaterialTheme.typography.bodySmall)
                Spacer(Modifier.width(6.dp))
                Switch(checked = includeReversed, onCheckedChange = { includeReversed = it })
            }
        }
        item {
            Row(
                Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                listOf<Pair<String?, String>>(
                    null to "All sources",
                    "manual" to "Manual",
                    "imported" to "Imported",
                ).forEach { (value, label) ->
                    FilterChip(
                        selected = sourceFilter == value,
                        onClick = { sourceFilter = value },
                        label = { Text(label) },
                    )
                }
            }
        }
        error?.let { item { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) } }
        if (sessions.isEmpty()) {
            item {
                Text("No irrigation sessions yet.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        sessions.forEach { session ->
            item(key = session.id) { SessionRowCard(session, fmt) { onOpenSession(session.id) } }
        }
    }
}

@Composable
private fun DetailContent(
    repo: IrrigationRepository,
    sessionId: String?,
    fmt: RegionFormatter,
    capabilities: IrrigationCapabilities?,
    onChanged: () -> Unit,
    onEdit: (IrrigationSessionRow) -> Unit,
    onDuplicate: (IrrigationSessionRow) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var session by remember { mutableStateOf<IrrigationSessionRow?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var showReverseConfirm by remember { mutableStateOf(false) }

    LaunchedEffect(sessionId) {
        val id = sessionId ?: return@LaunchedEffect
        runCatching { session = repo.getSession(id) }.onFailure { error = it.message }
    }

    val s = session
    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        error?.let { item { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) } }
        if (s == null) {
            item { CircularProgressIndicator() }
        } else {
            item {
                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)).padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    DetailLine("Date", s.sessionDate)
                    DetailLine("Vintage", s.vintageYear.toString())
                    DetailLine("System", s.systemName ?: "—")
                    DetailLine("Valve", s.valveName ?: "—")
                    DetailLine("Duration", formatMinutes(s.durationMinutes))
                    irrigationTimeRange(s.startedAt, s.finishedAt)?.let { DetailLine("Times", it) }
                    DetailLine("Method", s.calculationMethod.replace('_', ' '))
                    s.flowLph?.let { DetailLine("Flow", IrrigationUnits.flow(it, fmt)) }
                    DetailLine("Status", s.status.replaceFirstChar { it.uppercase() })
                    DetailLine("Source", s.sourceLabel)
                    DetailLine("Total water", IrrigationUnits.volume(s.totalVolumeLitres, fmt))
                    s.effectiveVolumeLitres?.let { DetailLine("Effective water", IrrigationUnits.volume(it, fmt)) }
                }
            }
            s.importInfo?.let { info ->
                item { Text("Controller Import", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }
                item {
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)).padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        DetailLine("Provider", info.providerLabel)
                        info.unitName?.let { DetailLine("Controller", it) }
                        info.externalValveName?.let { DetailLine("Controller valve", it) }
                        info.program?.let { DetailLine("Program", it) }
                        info.originalWaterValue?.let {
                            DetailLine("Reported water", "$it ${info.originalWaterUnit ?: "m\u00B3"}")
                        }
                        info.originalFlowValue?.let {
                            DetailLine("Reported flow", "$it ${info.originalFlowUnit ?: "m\u00B3/h"}")
                        }
                        info.reportedRuntimeSeconds?.let {
                            DetailLine("Reported runtime", formatMinutes(((it / 60.0) + 0.5).toInt()))
                        }
                        info.sourceComment?.takeIf { it.isNotEmpty() }?.let { DetailLine("Controller status", it) }
                        info.classification?.let {
                            DetailLine("Classification", it.replace('_', ' ').replaceFirstChar { c -> c.uppercase() })
                        }
                        info.batchId?.let { DetailLine("Import batch", it.take(8)) }
                        info.sourceRowNumber?.let { DetailLine("Source row", "#$it") }
                        if (info.overrideThreshold == true || info.overrideTest == true) {
                            Text(
                                if (info.overrideTest == true) "Test-program override applied" else "Volume-threshold override applied",
                                style = MaterialTheme.typography.labelSmall,
                                color = Color(0xFFEF6C00),
                            )
                            info.overrideReason?.takeIf { it.isNotEmpty() }?.let {
                                Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                        info.validationWarnings.orEmpty().forEach { warning ->
                            Text(warning, style = MaterialTheme.typography.labelSmall, color = Color(0xFFEF6C00))
                        }
                    }
                }
            }
            item { Text("Blocks", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }
            s.blocks.forEach { block ->
                item(key = block.id) {
                    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                        Row {
                            Text(block.blockName ?: "Block", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                            Text(String.format(Locale.US, "%.1f%%", block.allocationPercentage), style = MaterialTheme.typography.bodySmall)
                        }
                        val parts = buildList {
                            add(IrrigationUnits.volume(block.allocatedVolumeLitres, fmt))
                            block.waterLitresPerVine?.let { add(IrrigationUnits.perVine(it, fmt)) }
                            block.waterLitresPerHectare?.let { add(IrrigationUnits.perHectare(it, fmt)) }
                            block.irrigationDepthMm?.let { add(IrrigationUnits.depth(it, fmt)) }
                        }
                        Text(parts.joinToString(" · "), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            s.notes?.takeIf { it.isNotEmpty() }?.let { noteText ->
                item { Text("Notes", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }
                item { Text(noteText, style = MaterialTheme.typography.bodySmall) }
            }
            // Public release (SQL 151): actions follow the shared role
            // capabilities. The server enforces each one independently.
            if (s.status != "reversed" && !s.isImported) {
                if (capabilities?.canEditIrrigation == true || capabilities?.canRecordIrrigation == true) {
                    item {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (capabilities.canEditIrrigation) {
                                OutlinedButton(onClick = { onEdit(s) }, modifier = Modifier.weight(1f)) { Text("Edit") }
                            }
                            if (capabilities.canRecordIrrigation) {
                                OutlinedButton(onClick = { onDuplicate(s) }, modifier = Modifier.weight(1f)) { Text("Duplicate") }
                            }
                        }
                    }
                }
                if (capabilities?.canReverseIrrigation == true) {
                    item {
                        Button(
                            onClick = { showReverseConfirm = true },
                            modifier = Modifier.fillMaxWidth(),
                            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                        ) { Text("Reverse Record") }
                    }
                }
            }
            if (s.status != "reversed" && s.isImported) {
                item {
                    Text(
                        "Imported sessions are managed through the Portal import workflow. Reversing the whole import batch removes every session it created.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }

    if (showReverseConfirm && s != null) {
        AlertDialog(
            onDismissRequest = { showReverseConfirm = false },
            title = { Text("Reverse this irrigation record?") },
            text = { Text("The record is excluded from totals but kept in history for audit.") },
            confirmButton = {
                TextButton(onClick = {
                    showReverseConfirm = false
                    scope.launch {
                        runCatching { session = repo.reverseSession(s.id) }
                            .onSuccess { onChanged() }
                            .onFailure { error = it.message }
                    }
                }) { Text("Reverse", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { showReverseConfirm = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun DetailLine(label: String, value: String) {
    Row {
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(110.dp))
        Text(value, style = MaterialTheme.typography.bodySmall)
    }
}

// -----------------------------------------------------------------------------
// Reports
// -----------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReportsContent(
    repo: IrrigationRepository,
    state: AppUiState,
    onOpenSession: (String) -> Unit = {},
) {
    val vineyardId = state.selectedVineyardId ?: return
    val fmt = state.regionFormatter
    val scope = rememberCoroutineScope()

    val tabs = listOf(
        "Overview", "Daily", "Weekly", "Monthly", "Blocks", "Valves",
        "Varieties", "Water", "Rainfall", "Sources", "Trends",
    )
    var tab by remember { mutableIntStateOf(0) }
    var sourceGroup by remember { mutableStateOf<String?>(null) }
    var vintageYear by remember { mutableStateOf<Int?>(null) }
    var rainGroup by remember { mutableStateOf("month") }

    var overview by remember { mutableStateOf<IrrigationVintageOverview?>(null) }
    var periodRows by remember { mutableStateOf<List<IrrigationPeriodReportRow>>(emptyList()) }
    var blockReport by remember { mutableStateOf<List<IrrigationBlockReportRow>>(emptyList()) }
    var valveReport by remember { mutableStateOf<List<IrrigationValveReportRow>>(emptyList()) }
    var varietyReport by remember { mutableStateOf<List<IrrigationVarietyReportRow>>(emptyList()) }
    var waterReport by remember { mutableStateOf<List<IrrigationWaterSourceReportRow>>(emptyList()) }
    var rainReport by remember { mutableStateOf<List<IrrigationRainfallReportRow>>(emptyList()) }
    var recordSources by remember { mutableStateOf<List<IrrigationRecordSourceReportRow>>(emptyList()) }
    var calcSources by remember { mutableStateOf<List<IrrigationCalcSourceReportRow>>(emptyList()) }
    var trendRows by remember { mutableStateOf<List<IrrigationVintageTrendRow>>(emptyList()) }
    var warnings by remember { mutableStateOf<List<IrrigationReportWarning>>(emptyList()) }
    var resolvedVintage by remember { mutableStateOf<Int?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var drillTitle by remember { mutableStateOf<String?>(null) }
    var drillSessions by remember { mutableStateOf<List<IrrigationSessionRow>>(emptyList()) }

    fun baseFilter() = IrrigationReportFilter(vintageYear = vintageYear, sourceGroup = sourceGroup)

    fun openDrill(title: String, filter: IrrigationReportFilter) {
        scope.launch {
            runCatching { repo.listReportSessions(vineyardId, filter) }
                .onSuccess { drillSessions = it.sessions; drillTitle = title }
                .onFailure { error = it.message }
        }
    }

    LaunchedEffect(vineyardId, tab, sourceGroup, vintageYear, rainGroup) {
        loading = true
        error = null
        val filter = baseFilter()
        runCatching {
            when (tab) {
                0 -> {
                    val o = repo.reportOverview(vineyardId, filter)
                    overview = o; warnings = o.warnings; resolvedVintage = o.vintageYear
                }
                1 -> {
                    val e = repo.reportDaily(vineyardId, filter)
                    periodRows = e.rows.reversed(); warnings = e.warnings; resolvedVintage = e.vintageYear
                }
                2 -> {
                    val e = repo.reportWeekly(vineyardId, filter)
                    periodRows = e.rows.reversed(); warnings = e.warnings; resolvedVintage = e.vintageYear
                }
                3 -> {
                    val e = repo.reportMonthly(vineyardId, filter)
                    periodRows = e.rows; warnings = e.warnings; resolvedVintage = e.vintageYear
                }
                4 -> {
                    val e = repo.reportBlocks(vineyardId, filter)
                    blockReport = e.rows; warnings = e.warnings; resolvedVintage = e.vintageYear
                }
                5 -> {
                    val e = repo.reportValves(vineyardId, filter)
                    valveReport = e.rows; warnings = e.warnings; resolvedVintage = e.vintageYear
                }
                6 -> {
                    val e = repo.reportVarieties(vineyardId, filter)
                    varietyReport = e.rows; warnings = e.warnings; resolvedVintage = e.vintageYear
                }
                7 -> {
                    val e = repo.reportWaterSources(vineyardId, filter)
                    waterReport = e.rows; warnings = e.warnings; resolvedVintage = e.vintageYear
                }
                8 -> {
                    val e = repo.reportRainfall(vineyardId, filter, rainGroup)
                    rainReport = e.rows; warnings = e.warnings; resolvedVintage = e.vintageYear
                }
                9 -> {
                    val rec = repo.reportRecordSources(vineyardId, filter)
                    recordSources = rec.rows; warnings = rec.warnings; resolvedVintage = rec.vintageYear
                    calcSources = repo.reportCalcSources(vineyardId, filter).rows
                }
                else -> {
                    val e = repo.reportTrends(vineyardId, filter, vintageCount = 5)
                    trendRows = e.rows; warnings = emptyList(); resolvedVintage = e.vintageYear
                }
            }
        }.onFailure {
            val message = it.message ?: "Unknown error"
            error = if (message.contains("irrigation_access_denied")) {
                "Irrigation reports are limited to System Administrators during validation."
            } else message
        }
        loading = false
    }

    val currentYear = java.time.LocalDate.now().year
    val vintageOptions: List<Int?> = listOf(null, currentYear + 1, currentYear, currentYear - 1, currentYear - 2)

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            tabs.forEachIndexed { index, label ->
                FilterChip(selected = tab == index, onClick = { tab = index }, label = { Text(label) })
            }
        }
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilterChip(selected = sourceGroup == null, onClick = { sourceGroup = null }, label = { Text("All") })
            FilterChip(selected = sourceGroup == "manual", onClick = { sourceGroup = "manual" }, label = { Text("Manual") })
            FilterChip(selected = sourceGroup == "controller_import", onClick = { sourceGroup = "controller_import" }, label = { Text("Imported") })
            vintageOptions.forEach { year ->
                FilterChip(
                    selected = vintageYear == year,
                    onClick = { vintageYear = year },
                    label = { Text(year?.let { "V$it" } ?: "Current") },
                )
            }
            if (tab == 8) {
                listOf("day", "week", "month", "vintage").forEach { g ->
                    FilterChip(selected = rainGroup == g, onClick = { rainGroup = g }, label = { Text(g.replaceFirstChar { it.uppercase() }) })
                }
            }
        }
        resolvedVintage?.let {
            Text(
                "Vintage $it", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp)) }
        if (loading) {
            Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        }

        LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            when (tab) {
                0 -> overview?.let { o ->
                    item {
                        Column(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)).padding(12.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text("Vintage ${o.vintageYear}", fontWeight = FontWeight.SemiBold)
                            DetailLine("Total water", IrrigationUnits.volume(o.totalIrrigationLitres, fmt))
                            DetailLine("Effective water", o.effectiveIrrigationLitres?.let { IrrigationUnits.volume(it, fmt) } ?: "—")
                            DetailLine("Manual", IrrigationUnits.volume(o.manualLitres ?: 0.0, fmt))
                            DetailLine("Imported", IrrigationUnits.volume(o.importedLitres ?: 0.0, fmt))
                            DetailLine("Reported", IrrigationUnits.volume(o.directlyReportedLitres ?: 0.0, fmt))
                            DetailLine("Measured", IrrigationUnits.volume(o.directlyMeasuredLitres ?: 0.0, fmt))
                            DetailLine("Calculated", IrrigationUnits.volume(o.calculatedLitres ?: 0.0, fmt))
                            DetailLine("Estimated", IrrigationUnits.volume(o.estimatedLitres ?: 0.0, fmt))
                            DetailLine("Sessions", o.sessionCount.toString())
                            DetailLine("Total runtime", formatMinutes(o.totalRuntimeMinutes))
                            o.averageSessionMinutes?.let { DetailLine("Average session", formatMinutes(it.roundToInt())) }
                        }
                    }
                    item {
                        Column(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)).padding(12.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text("Coverage & normalised", fontWeight = FontWeight.SemiBold)
                            DetailLine("Valves / blocks", "${o.valvesUsed ?: 0} / ${o.blocksIrrigated ?: 0}")
                            DetailLine("Serviced area", o.servicedAreaHectares?.let { fmt.formatArea(it) } ?: "—")
                            DetailLine("Serviced vines", o.servicedVines?.toString() ?: "—")
                            DetailLine("Per hectare", o.litresPerHectare?.let { IrrigationUnits.perHectare(it, fmt) } ?: "—")
                            DetailLine("Per vine", o.litresPerVine?.let { IrrigationUnits.perVine(it, fmt) } ?: "—")
                            DetailLine("Depth", o.irrigationDepthMm?.let { IrrigationUnits.depth(it, fmt) } ?: "—")
                            DetailLine("Effective depth", o.effectiveIrrigationDepthMm?.let { IrrigationUnits.depth(it, fmt) } ?: "—")
                            DetailLine("Rainfall", o.rainfallMm?.let { IrrigationUnits.depth(it, fmt) } ?: "—")
                        }
                    }
                    item {
                        Column(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)).padding(12.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text("Previous vintage ${o.previousVintageYear ?: ""}", fontWeight = FontWeight.SemiBold)
                            DetailLine("Previous total", o.previousTotalLitres?.let { IrrigationUnits.volume(it, fmt) } ?: "—")
                            DetailLine("Change", o.volumeDifferenceLitres?.let { d ->
                                val pct = o.volumeDifferencePercent?.let { String.format(java.util.Locale.US, " (%+.1f%%)", it) } ?: ""
                                (if (d >= 0) "+" else "") + IrrigationUnits.volume(d, fmt) + pct
                            } ?: "—")
                            DetailLine("Last irrigation", o.lastIrrigationDate ?: "—")
                            o.dataQuality?.let { DetailLine("Report quality", it.replace('_', ' ')) }
                        }
                    }
                }
                1, 2, 3 -> periodRows.forEach { row ->
                    item(key = row.periodKey) {
                        val title = row.monthLabel ?: row.periodKey
                        val parts = buildList {
                            add("${row.sessionCount} session(s)")
                            add(formatMinutes(row.runtimeMinutes))
                            row.irrigationDepthMm?.let { add(IrrigationUnits.depth(it, fmt)) }
                            row.rainfallMm?.let { add("rain ${IrrigationUnits.depth(it, fmt)}") }
                            if ((row.importedLitres ?: 0.0) > 0) add("imported ${IrrigationUnits.volume(row.importedLitres ?: 0.0, fmt)}")
                            if (tab == 3 && (row.previousVintageTotalLitres ?: 0.0) > 0) {
                                add("prev ${IrrigationUnits.volume(row.previousVintageTotalLitres ?: 0.0, fmt)}")
                            }
                        }
                        Box(Modifier.clickable {
                            openDrill(title, baseFilter().copy(dateFrom = row.periodStart, dateTo = row.periodEnd))
                        }) {
                            ReportCard(title, IrrigationUnits.volume(row.totalLitres, fmt), parts.joinToString(" · "))
                        }
                    }
                }
                4 -> blockReport.forEach { row ->
                    item(key = row.blockId) {
                        val parts = buildList {
                            add("${row.sessionCount} session(s)")
                            row.varietyName?.let { add(it) }
                            row.litresPerVine?.let { add(IrrigationUnits.perVine(it, fmt)) }
                            row.irrigationDepthMm?.let { add(IrrigationUnits.depth(it, fmt)) }
                            row.combinedWaterInputMm?.let { add("combined ${IrrigationUnits.depth(it, fmt)}") }
                            if ((row.previousVintageLitres ?: 0.0) > 0) add("prev ${IrrigationUnits.volume(row.previousVintageLitres ?: 0.0, fmt)}")
                        }
                        Box(Modifier.clickable {
                            openDrill(row.blockName ?: "Block", baseFilter().copy(blockId = row.blockId))
                        }) {
                            ReportCard(row.blockName ?: "Block", IrrigationUnits.volume(row.totalLitres, fmt), parts.joinToString(" · "))
                        }
                    }
                }
                5 -> valveReport.forEach { row ->
                    item(key = row.valveId) {
                        val parts = buildList {
                            add("${row.sessionCount} session(s)")
                            add(formatMinutes(row.runtimeMinutes))
                            row.averageFlowLitresPerHour?.let { add("${IrrigationUnits.volume(it, fmt)}/h avg") }
                            row.percentOfVineyardTotal?.let { add(String.format(java.util.Locale.US, "%.1f%%", it)) }
                            row.lastUse?.let { add("last $it") }
                        }
                        Box(Modifier.clickable {
                            openDrill(row.valveName, baseFilter().copy(valveId = row.valveId))
                        }) {
                            ReportCard(row.valveName, IrrigationUnits.volume(row.totalLitres, fmt), parts.joinToString(" · "))
                        }
                    }
                }
                6 -> varietyReport.forEach { row ->
                    item(key = row.varietyName) {
                        val parts = buildList {
                            row.blockCount?.let { add("$it block(s)") }
                            add("${row.sessionCount} session(s)")
                            row.litresPerVine?.let { add(IrrigationUnits.perVine(it, fmt)) }
                            row.irrigationDepthMm?.let { add(IrrigationUnits.depth(it, fmt)) }
                            if ((row.previousVintageLitres ?: 0.0) > 0) add("prev ${IrrigationUnits.volume(row.previousVintageLitres ?: 0.0, fmt)}")
                        }
                        ReportCard(row.varietyName, IrrigationUnits.volume(row.totalLitres, fmt), parts.joinToString(" · "))
                    }
                }
                7 -> waterReport.forEach { row ->
                    item(key = row.waterSource) {
                        val parts = buildList {
                            add("${row.systemCount ?: 0} system(s) · ${row.valveCount ?: 0} valve(s)")
                            add("${row.sessionCount} session(s)")
                            row.percentOfVineyardTotal?.let { add(String.format(java.util.Locale.US, "%.1f%%", it)) }
                        }
                        ReportCard(row.waterSource, IrrigationUnits.volume(row.totalLitres, fmt), parts.joinToString(" · "))
                    }
                }
                8 -> rainReport.forEach { row ->
                    item(key = row.periodKey) {
                        val parts = buildList {
                            add("rain ${row.rainfallMm?.let { IrrigationUnits.depth(it, fmt) } ?: "—"}")
                            add("irrigation ${row.grossIrrigationDepthMm?.let { IrrigationUnits.depth(it, fmt) } ?: "—"}")
                            row.irrigationPercentOfCombined?.let { add(String.format(java.util.Locale.US, "%.0f%% irrigation", it)) }
                            if (row.rainfallDataComplete == false) add("rainfall incomplete")
                        }
                        ReportCard(
                            row.periodKey,
                            row.combinedWaterInputMm?.let { IrrigationUnits.depth(it, fmt) } ?: "—",
                            parts.joinToString(" · "),
                        )
                    }
                }
                9 -> {
                    recordSources.forEach { row ->
                        item(key = "rec-${row.sourceType}") {
                            val parts = buildList {
                                add("${row.sessionCount} session(s)")
                                row.percentOfTotalLitres?.let { add(String.format(java.util.Locale.US, "%.1f%%", it)) }
                            }
                            Box(Modifier.clickable {
                                openDrill(row.sourceLabel ?: row.sourceType, baseFilter().copy(sourceType = row.sourceType))
                            }) {
                                ReportCard(row.sourceLabel ?: row.sourceType, IrrigationUnits.volume(row.totalLitres, fmt), parts.joinToString(" · "))
                            }
                        }
                    }
                    calcSources.forEach { row ->
                        item(key = "calc-${row.calculationMethod}-${row.measurementGroup}") {
                            val parts = buildList {
                                row.measurementLabel?.let { add(it) }
                                add("${row.sessionCount} session(s)")
                                row.percentOfTotalLitres?.let { add(String.format(java.util.Locale.US, "%.1f%%", it)) }
                            }
                            ReportCard(row.calculationLabel ?: row.calculationMethod, IrrigationUnits.volume(row.totalLitres, fmt), parts.joinToString(" · "))
                        }
                    }
                }
                else -> trendRows.forEach { row ->
                    item(key = row.vintageYear) {
                        val parts = buildList {
                            add("${row.sessionCount} session(s)")
                            row.irrigationDepthMm?.let { add(IrrigationUnits.depth(it, fmt)) }
                            row.rainfallMm?.let { add("rain ${IrrigationUnits.depth(it, fmt)}") }
                            row.dataQuality?.let { add(it.replace('_', ' ')) }
                        }
                        ReportCard("Vintage ${row.vintageYear}", IrrigationUnits.volume(row.totalLitres, fmt), parts.joinToString(" · "))
                    }
                }
            }
            if (warnings.isNotEmpty()) {
                item(key = "warnings-header") {
                    Text("Data quality", fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
                }
                warnings.forEachIndexed { index, warning ->
                    item(key = "warning-$index") {
                        Text(
                            warning.message,
                            style = MaterialTheme.typography.bodySmall,
                            color = if (warning.severity == "info") MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error,
                        )
                    }
                }
            }
        }
    }

    if (drillTitle != null) {
        ModalBottomSheet(onDismissRequest = { drillTitle = null }) {
            Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(drillTitle ?: "", fontWeight = FontWeight.SemiBold)
                if (drillSessions.isEmpty()) {
                    Text("No sessions behind this row.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                drillSessions.take(50).forEach { session ->
                    Box(Modifier.clickable {
                        drillTitle = null
                        onOpenSession(session.id)
                    }) {
                        ReportCard(
                            session.sessionDate,
                            IrrigationUnits.volume(session.totalVolumeLitres, fmt),
                            "${session.valveName ?: ""} · ${formatMinutes(session.durationMinutes)} · ${session.sourceType}",
                        )
                    }
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun ReportCard(title: String, value: String, subtitle: String) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(value, fontWeight = FontWeight.SemiBold, color = VineColors.Cyan)
    }
}
