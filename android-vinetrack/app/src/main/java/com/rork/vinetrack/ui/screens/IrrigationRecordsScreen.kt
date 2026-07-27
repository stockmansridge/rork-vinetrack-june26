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
import com.rork.vinetrack.data.IrrigationLocalCalc
import com.rork.vinetrack.data.IrrigationPreviewResult
import com.rork.vinetrack.data.IrrigationRepository
import com.rork.vinetrack.data.IrrigationSessionRow
import com.rork.vinetrack.data.IrrigationSetupStatus
import com.rork.vinetrack.data.IrrigationSystemRow
import com.rork.vinetrack.data.IrrigationValveRow
import com.rork.vinetrack.data.IrrigationValveRowsResult
import com.rork.vinetrack.data.IrrigationValveValidation
import com.rork.vinetrack.data.IrrigationVintageSummary
import com.rork.vinetrack.data.PendingIrrigationSession
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
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun reload() {
        val vid = vineyardId ?: return
        isLoading = true
        error = null
        runCatching {
            repo.flushPending(vid)
            pendingCount = repo.pendingSessions(vid).size
            val s = repo.setupStatus(vid)
            status = s
            if (s.isOperational) {
                summary = repo.vintageSummary(vid)
                recent = repo.listSessions(vid, limit = 5).sessions
            }
            if (nav == IrrigationNav.Landing && !s.isOperational) nav = IrrigationNav.Wizard
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
                !state.isSystemAdmin || accessDenied -> UnavailableContent()
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
                    IrrigationNav.Reports -> ReportsContent(repo = repo, state = state)
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

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Column {
                Text(vineyardName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                status?.season?.currentVintageYear?.let {
                    Text("Vintage $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
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
                        TextButton(onClick = onWizard) { Text("Open Setup Wizard") }
                    }
                }
            }
        }

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

        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onHistory, modifier = Modifier.weight(1f)) { Text("History") }
                OutlinedButton(onClick = onSetup, modifier = Modifier.weight(1f)) { Text("Setup") }
                OutlinedButton(onClick = onReports, modifier = Modifier.weight(1f)) { Text("Reports") }
            }
        }

        item { Text("This Vintage", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }

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

        item { Text("Recent Irrigation", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }

        if (recent.isEmpty()) {
            item {
                Text(
                    "No irrigation recorded yet this vintage.",
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
                        color = if (session.status == "reversed") MaterialTheme.colorScheme.error else Color(0xFFEF6C00),
                    )
                }
            }
            Text(
                "${session.valveName ?: "Valve"} · ${session.blockNames.ifEmpty { "No blocks" }}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
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
                        SetupRowCard(
                            title = valve.name,
                            subtitle = "${valve.systemName ?: "System"} · ${valve.activeBlockCount ?: 0} block(s)",
                            trailing = valve.configuredFlowLph?.let { IrrigationUnits.flow(it, fmt) }
                                ?: if (valve.isActive) "No flow" else "Inactive",
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
                        valves.filter { it.isActive }.forEach { valve ->
                            item(key = valve.id) {
                                val vs = status?.valves?.firstOrNull { it.valveId == valve.id }
                                SetupRowCard(
                                    title = valve.name,
                                    subtitle = "Tap to assign blocks",
                                    trailing = when {
                                        vs == null -> ""
                                        vs.allocationOk -> "100%"
                                        vs.blockCount == 0 -> "Not connected"
                                        else -> String.format(Locale.US, "%.1f%%", vs.allocationTotal)
                                    },
                                    trailingColor = if (vs?.allocationOk == true) Color(0xFF2E7D32) else Color(0xFFEF6C00),
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

    LaunchedEffect(valve.id) {
        runCatching {
            val existing = repo.listValveBlocks(vineyardId, valve.id)
            rows = existing.map {
                RowState(UUID.randomUUID().toString(), it.blockId, it.allocationPercentage?.toString() ?: "")
            }
            availableRows = repo.listAvailableRows(vineyardId)
            val links = repo.listValveRows(vineyardId, valve.id)
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
                                        if (otherValves.isNotEmpty()) {
                                            Text(
                                                "Also: ${otherValves.joinToString(", ")}",
                                                style = MaterialTheme.typography.labelSmall,
                                                color = Color(0xFFEF6C00),
                                            )
                                        }
                                    }
                                    row.rowLengthMetres?.let {
                                        Text(
                                            String.format(Locale.US, "%.0f m", it),
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                item {
                    val provisional = IrrigationLocalCalc.rowWeighting(selectedRows)
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                            .background(VineColors.Cyan.copy(alpha = 0.08f)).padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(
                            if (serverResult == null) "Summary (provisional — saved values come from the server)" else "Summary",
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        DetailLine("Selected rows", selectedRows.size.toString())
                        val result = serverResult
                        if (result != null) {
                            DetailLine("Blocks supplied", result.blocks.size.toString())
                            DetailLine("Allocation basis", IrrigationLocalCalc.basisLabel(result.weightingBasis))
                            result.blocks.forEach { block ->
                                DetailLine(
                                    block.blockName ?: "Block",
                                    String.format(Locale.US, "%.1f%%", block.allocationPercentage ?: 0.0),
                                )
                            }
                        } else if (selectedRows.isNotEmpty()) {
                            DetailLine("Blocks supplied", provisional.blocks.size.toString())
                            DetailLine("Allocation basis", IrrigationLocalCalc.basisLabel(provisional.basis))
                            provisional.blocks.forEach { share ->
                                DetailLine(share.blockName, String.format(Locale.US, "%.1f%%", share.percentage))
                            }
                            if (provisional.basis == "equal_rows") {
                                Text(
                                    "Water allocation is being estimated from the number of selected rows because emitter, vine-count and row-length information is incomplete.",
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
        error?.let { item { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) } }
        item {
            Button(
                onClick = {
                    scope.launch {
                        isSaving = true
                        error = null
                        if (mode == "rows") {
                            runCatching {
                                repo.setValveRows(vineyardId, valve.id, selectedRowIds.toList())
                            }.onSuccess { result ->
                                serverResult = result
                                if (result.warnings.isEmpty()) onDone()
                            }.onFailure { error = it.message }
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
    var preview by remember { mutableStateOf<IrrigationPreviewResult?>(null) }
    var localPreview by remember { mutableStateOf<IrrigationLocalCalc.Result?>(null) }
    var offlinePreview by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var isSaving by remember { mutableStateOf(false) }
    var savedMessage by remember { mutableStateOf<String?>(null) }

    val durationMinutes = (durationHours.toIntOrNull() ?: 0) * 60 + (durationMins.toIntOrNull() ?: 0)

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
        "configured_flow" -> validation?.hasConfiguredFlow == true
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
                            "configured_flow" -> v.configuredFlowLph
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

            if (editSession != null) {
                runCatching {
                    repo.updateSession(
                        editSession.id, sessionDate, durationMinutes, method,
                        flowValue, meterStartValue, meterFinishValue, totalValue,
                        notes.ifEmpty { null }, useCurrentConfig,
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
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(value = durationHours, onValueChange = { durationHours = it }, label = { Text("Hours") }, singleLine = true, modifier = Modifier.weight(1f))
                OutlinedTextField(value = durationMins, onValueChange = { durationMins = it }, label = { Text("Minutes") }, singleLine = true, modifier = Modifier.weight(1f))
            }
        }
        item {
            Text("Water calculation", style = MaterialTheme.typography.labelMedium)
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
        when (method) {
            "configured_flow" -> item {
                val flow = validation?.configuredFlowLph
                if (flow != null) {
                    Text(
                        "Configured flow: ${IrrigationUnits.flow(flow, fmt)}",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                } else {
                    Text(
                        "This valve has no configured flow rate. Enter a session flow, total volume or meter readings instead.",
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
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(vineyardId, includeReversed) {
        runCatching {
            val result = repo.listSessions(vineyardId, includeReversed = includeReversed, limit = 100)
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
                    DetailLine("Method", s.calculationMethod.replace('_', ' '))
                    s.flowLph?.let { DetailLine("Flow", IrrigationUnits.flow(it, fmt)) }
                    DetailLine("Status", s.status.replaceFirstChar { it.uppercase() })
                    DetailLine(
                        "Source",
                        when (s.sourceType) {
                            "manual_ios" -> "iPhone"
                            "manual_android" -> "Android"
                            "manual_portal" -> "Portal"
                            else -> s.sourceType
                        },
                    )
                    DetailLine("Total water", IrrigationUnits.volume(s.totalVolumeLitres, fmt))
                    s.effectiveVolumeLitres?.let { DetailLine("Effective water", IrrigationUnits.volume(it, fmt)) }
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
            if (s.status != "reversed") {
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { onEdit(s) }, modifier = Modifier.weight(1f)) { Text("Edit") }
                        OutlinedButton(onClick = { onDuplicate(s) }, modifier = Modifier.weight(1f)) { Text("Duplicate") }
                    }
                }
                item {
                    Button(
                        onClick = { showReverseConfirm = true },
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                    ) { Text("Reverse Record") }
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

@Composable
private fun ReportsContent(repo: IrrigationRepository, state: AppUiState) {
    val vineyardId = state.selectedVineyardId ?: return
    val fmt = state.regionFormatter
    var tab by remember { mutableIntStateOf(0) }
    var vintage by remember { mutableStateOf<IrrigationVintageSummary?>(null) }
    var valveRows by remember { mutableStateOf<List<com.rork.vinetrack.data.IrrigationValveSummaryRow>>(emptyList()) }
    var blockRows by remember { mutableStateOf<List<com.rork.vinetrack.data.IrrigationBlockSummaryRow>>(emptyList()) }
    var varietyRows by remember { mutableStateOf<List<com.rork.vinetrack.data.IrrigationVarietySummaryRow>>(emptyList()) }
    var dailyRows by remember { mutableStateOf<List<com.rork.vinetrack.data.IrrigationDailySummaryRow>>(emptyList()) }
    var monthlyRows by remember { mutableStateOf<List<com.rork.vinetrack.data.IrrigationMonthlySummaryRow>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(vineyardId) {
        runCatching {
            vintage = repo.vintageSummary(vineyardId)
            valveRows = repo.valveSummary(vineyardId)
            blockRows = repo.blockSummary(vineyardId)
            varietyRows = repo.varietySummary(vineyardId)
            dailyRows = repo.dailySummary(vineyardId)
            monthlyRows = repo.monthlySummary(vineyardId)
        }.onFailure { error = it.message }
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            listOf("Vintage", "Valves", "Blocks", "Varieties", "Daily", "Monthly").forEachIndexed { index, label ->
                FilterChip(selected = tab == index, onClick = { tab = index }, label = { Text(label) })
            }
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp)) }

        LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            when (tab) {
                0 -> vintage?.let { v ->
                    item {
                        Column(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f)).padding(12.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text("Vintage ${v.vintageYear}", fontWeight = FontWeight.SemiBold)
                            DetailLine("Total water", IrrigationUnits.volume(v.totalVolumeLitres, fmt))
                            v.effectiveVolumeLitres?.let { DetailLine("Effective water", IrrigationUnits.volume(it, fmt)) }
                            DetailLine("Total runtime", formatMinutes(v.totalRuntimeMinutes))
                            DetailLine("Sessions", v.sessionCount.toString())
                            v.averageSessionMinutes?.let { DetailLine("Average session", formatMinutes(it.roundToInt())) }
                            v.waterLitresPerVine?.let { DetailLine("Water per vine", IrrigationUnits.perVine(it, fmt)) }
                            v.irrigationDepthMm?.let { DetailLine("Irrigation depth", IrrigationUnits.depth(it, fmt)) }
                        }
                    }
                }
                1 -> valveRows.forEach { row ->
                    item(key = row.valveId) {
                        ReportCard(
                            row.valveName, IrrigationUnits.volume(row.totalVolumeLitres, fmt),
                            "${row.sessionCount} sessions · ${formatMinutes(row.totalRuntimeMinutes)} · last ${row.lastIrrigationDate ?: "—"}",
                        )
                    }
                }
                2 -> blockRows.forEach { row ->
                    item(key = row.blockId) {
                        val parts = buildList {
                            row.waterLitresPerVine?.let { add(IrrigationUnits.perVine(it, fmt)) }
                            row.waterLitresPerHectare?.let { add(IrrigationUnits.perHectare(it, fmt)) }
                            row.irrigationDepthMm?.let { add(IrrigationUnits.depth(it, fmt)) }
                            add("last ${row.lastIrrigationDate ?: "—"}")
                        }
                        ReportCard(row.blockName ?: "Block", IrrigationUnits.volume(row.totalVolumeLitres, fmt), parts.joinToString(" · "))
                    }
                }
                3 -> varietyRows.forEach { row ->
                    item(key = row.varietyName) {
                        val parts = buildList {
                            row.totalServicedVines?.let { add("$it vines") }
                            row.averageWaterLitresPerVine?.let { add(IrrigationUnits.perVine(it, fmt)) }
                            row.averageWaterLitresPerHectare?.let { add(IrrigationUnits.perHectare(it, fmt)) }
                            row.irrigationDepthMm?.let { add(IrrigationUnits.depth(it, fmt)) }
                        }
                        ReportCard(row.varietyName, IrrigationUnits.volume(row.totalVolumeLitres, fmt), parts.joinToString(" · "))
                    }
                }
                4 -> dailyRows.forEach { row ->
                    item(key = row.date) {
                        ReportCard(row.date, IrrigationUnits.volume(row.totalVolumeLitres, fmt), "${row.sessionCount} session(s) · ${formatMinutes(row.runtimeMinutes)}")
                    }
                }
                else -> monthlyRows.forEach { row ->
                    item(key = row.month) {
                        val depth = row.irrigationDepthMm?.let { " · ${IrrigationUnits.depth(it, fmt)}" } ?: ""
                        ReportCard(row.month, IrrigationUnits.volume(row.totalVolumeLitres, fmt), "${row.sessionCount} session(s)$depth")
                    }
                }
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
