package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import android.text.format.DateUtils
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentCut
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.ReportProblem
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.PendingSyncItem
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlin.coroutines.resume
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Read-only field-reliability surface. Reports live connection status and the
 * pending-sync count from the local outbox ([PendingWriteRepository]).
 *
 * Stage 4A-iv enables offline queueing for new pin creation only: queued pins
 * appear here while waiting and replay automatically on reconnect. Every other
 * field action remains online-only. This screen is display-only — it reads
 * state and never triggers a write, replay, or retry itself.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SyncStatusScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val online = state.isOnline
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    // Per-function breakdown (iOS Settings → Sync parity). Outbox items are
    // grouped by entity type so each function shows its own waiting /
    // needs-attention counts; last-synced times come from the domain read-cache.
    val itemsByType = remember(state.pendingSyncItems) { state.pendingSyncItems.groupBy { it.entityType } }
    var syncTick by remember { mutableIntStateOf(0) }
    val syncTimes = remember(state.pendingSyncItems, state.selectedVineyardId, syncTick) { vm.domainSyncTimes() }
    /** Function ids with a per-function sync currently in flight (spinner + guard). */
    var syncingIds by remember { mutableStateOf(setOf<String>()) }

    /**
     * Runs the targeted sync for one function row. Pruning / fertiliser /
     * maintenance complete-await their refresh; the remaining areas trigger the
     * matching targeted or full refresh and briefly hold the spinner so the
     * reactive state has time to land. Failed outbox rows are granted a retry
     * through the same ordered replay pipeline as "Retry all".
     */
    fun runFunctionSync(spec: SyncFunctionSpec) {
        if (spec.id in syncingIds || !online) return
        scope.launch {
            syncingIds = syncingIds + spec.id
            try {
                if (state.canRetrySync) vm.retryPendingSync()
                when (spec.id) {
                    "pruning" -> state.selectedVineyardId?.let { vm.refreshPruning(it) }
                    "fertiliser" -> state.selectedVineyardId?.let { vm.refreshFertiliser(it) }
                    "workTasks" -> { vm.refreshWorkTasks(); delay(1200) }
                    "fuel" -> { vm.refreshFuelData(); delay(1200) }
                    "maintenance" -> suspendCancellableCoroutine { cont ->
                        vm.refreshMaintenanceLogs { if (cont.isActive) cont.resume(Unit) }
                    }
                    else -> { vm.refresh(); delay(1500) }
                }
            } finally {
                syncingIds = syncingIds - spec.id
                syncTick++
            }
            snackbarHostState.showSnackbar("${spec.title} refreshed.")
        }
    }
    // Tier-A Stage F-3 — details sheet for a single pending item. Read-only:
    // selecting an item only opens a sheet; nothing about the outbox row
    // changes. Cleared when the sheet closes.
    var detailItem by remember { mutableStateOf<PendingSyncItem?>(null) }
    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text("Sync Status") },
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
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            SectionHeader("Connection", onLight = true)
            VineyardCard {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    val tint = if (online) VineColors.Success else VineColors.Warning
                    Box(
                        modifier = Modifier.size(44.dp).clip(CircleShape).background(tint.copy(alpha = 0.15f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            if (online) Icons.Filled.CloudDone else Icons.Filled.CloudOff,
                            contentDescription = null,
                            tint = tint,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            if (online) "Online" else "Offline",
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                            fontSize = 16.sp,
                        )
                        Text(
                            if (online) "Connected — changes save to the server."
                            else "No connection — changes may not save right now.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            SectionHeader("Pending Sync", onLight = true)
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    val count = state.pendingSyncCount
                    Text(
                        "$count items waiting to sync",
                        fontWeight = FontWeight.SemiBold,
                        color = vine.textPrimary,
                        fontSize = 16.sp,
                    )
                    if (count == 0) {
                        Text(
                            "No pending items.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                    }
                    Text(
                        "New observation, repair and growth pins are saved on this device while offline and sync automatically when you reconnect. Other field actions still need a connection for now.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                    // Tier-A Stage F-2 — explicit, safe "Retry all". Only shown
                    // when retryable items exist and a connection is available;
                    // it re-runs the normal ordered sync, never a direct write.
                    if (state.canRetrySync && online) {
                        Button(
                            onClick = vm::retryPendingSync,
                            enabled = !state.isRetryingSync,
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Success),
                            modifier = Modifier.padding(top = 4.dp),
                        ) {
                            Icon(
                                Icons.Filled.Refresh,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp),
                            )
                            Text(
                                if (state.isRetryingSync) "Retrying…" else "Retry all",
                                modifier = Modifier.padding(start = 8.dp),
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 14.sp,
                            )
                        }
                        Text(
                            "Retries use the normal sync order so trip changes stay safe.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                    val photos = state.pendingPhotoCount
                    if (photos > 0) {
                        Text(
                            if (photos == 1) "1 photo waiting to upload" else "$photos photos waiting to upload",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                        if (state.pendingPhotoBlockedCount > 0) {
                            Text(
                                if (state.pendingPhotoBlockedCount == 1) "1 photo needs attention"
                                else "${state.pendingPhotoBlockedCount} photos need attention",
                                fontSize = 13.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                }
            }

            // Per-function breakdown — mirrors the iOS Settings → Sync page
            // groupings so both platforms report sync state the same way.
            SectionHeader("Field Data", onLight = true)
            SyncFunctionsCard(
                specs = fieldDataSyncFunctions,
                itemsByType = itemsByType,
                syncTimes = syncTimes,
                syncingIds = syncingIds,
                online = online,
                onSync = ::runFunctionSync,
            )

            SectionHeader("Operations", onLight = true)
            SyncFunctionsCard(
                specs = operationsSyncFunctions,
                itemsByType = itemsByType,
                syncTimes = syncTimes,
                syncingIds = syncingIds,
                online = online,
                onSync = ::runFunctionSync,
            )

            SectionHeader("Operational Tools", onLight = true)
            SyncFunctionsCard(
                specs = operationalToolsSyncFunctions,
                itemsByType = itemsByType,
                syncTimes = syncTimes,
                syncingIds = syncingIds,
                online = online,
                onSync = ::runFunctionSync,
            )
            Text(
                "Each area syncs automatically — use a sync button to pull the latest shared data now. Items waiting to sync are listed under Pending Sync.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )

            SectionHeader("Saved Field Data", onLight = true)
            if (state.isUsingCachedFieldData) {
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            "Showing saved field data",
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                            fontSize = 16.sp,
                        )
                        state.cachedFieldDataLastSyncedAt?.let { ts ->
                            Text(
                                "Last saved " + relativeTime(ts),
                                fontSize = 13.sp,
                                color = vine.textSecondary,
                            )
                        }
                        Text(
                            "Saved data may be out of date until connection returns.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    val cache = state.cacheStatus
                    if (cache.hasVineyards) {
                        Text(
                            "Field data saved on this device",
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                            fontSize = 16.sp,
                        )
                        cache.vineyardsSyncedAt?.let { ts ->
                            Text(
                                "Vineyard list last saved " + relativeTime(ts),
                                fontSize = 13.sp,
                                color = vine.textSecondary,
                            )
                        }
                        if (cache.selectedSyncedAt != null) {
                            Text(
                                "${cache.paddockCount} blocks · ${cache.pinCount} pins saved for this vineyard",
                                fontSize = 13.sp,
                                color = vine.textSecondary,
                            )
                        }
                    } else {
                        Text(
                            "No saved field data yet",
                            fontWeight = FontWeight.SemiBold,
                            color = vine.textPrimary,
                            fontSize = 16.sp,
                        )
                        Text(
                            "Field data is saved automatically as it loads while you're online.",
                            fontSize = 13.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            if (state.pendingSyncItems.isNotEmpty()) {
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        state.pendingSyncItems.forEach { item ->
                            // Tier-A Stage F-3 — tapping a row opens a read-only
                            // details sheet. The tap never mutates the outbox row.
                            Column(
                                verticalArrangement = Arrangement.spacedBy(2.dp),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { detailItem = item },
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                ) {
                                    Text(
                                        item.title,
                                        fontWeight = FontWeight.Medium,
                                        color = vine.textPrimary,
                                        fontSize = 15.sp,
                                        modifier = Modifier.weight(1f),
                                    )
                                    Text(
                                        item.displayStatusLabel,
                                        fontSize = 13.sp,
                                        color = vine.textSecondary,
                                    )
                                    Icon(
                                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                        contentDescription = "View details",
                                        tint = vine.textSecondary.copy(alpha = 0.6f),
                                        modifier = Modifier.size(18.dp).padding(start = 2.dp),
                                    )
                                }
                                item.friendlyDetail?.takeIf { it.isNotBlank() }?.let { detail ->
                                    Text(detail, fontSize = 12.sp, color = vine.textSecondary)
                                }
                                item.attemptLabel?.let { attempt ->
                                    Text(
                                        attempt,
                                        fontSize = 12.sp,
                                        color = vine.textSecondary,
                                    )
                                }
                                item.rawDetail?.takeIf { it.isNotBlank() }?.let { raw ->
                                    Text(
                                        raw,
                                        fontSize = 11.sp,
                                        color = vine.textSecondary.copy(alpha = 0.7f),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Tier-A Stage F-3 — read-only details sheet with copyable diagnostics.
    // The only actions are Copy diagnostics and dismiss; no retry, dismiss,
    // or overwrite, and nothing here mutates the pending row.
    val sheetItem = detailItem
    if (sheetItem != null) {
        val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { detailItem = null },
            sheetState = sheetState,
            containerColor = vine.appBackground,
        ) {
            SyncItemDetails(
                item = sheetItem,
                // Tier-A Stage F-2b — per-item retry. Only offered for
                // retry-eligible (FAILED) rows while online and no retry is in
                // flight; it routes through the same ordered replay pipeline as
                // "Retry all", never a single coordinator in isolation.
                canRetry = sheetItem.canRetry && online && !state.isRetryingSync,
                onRetry = {
                    val started = vm.retryPendingSyncItem(sheetItem.id)
                    detailItem = null
                    scope.launch {
                        snackbarHostState.showSnackbar(
                            if (started) "Retry started." else "This item can no longer be retried.",
                        )
                    }
                },
                onCopy = {
                    clipboard.setText(AnnotatedString(sheetItem.diagnosticText))
                    scope.launch { snackbarHostState.showSnackbar("Sync diagnostics copied.") }
                },
            )
        }
    }
}

/**
 * Read-only details for a single pending sync item (Tier-A Stage F-3). Shows
 * the friendly status, attempt info, identifiers, timestamps and de-emphasised
 * raw diagnostic, plus a single "Copy diagnostics" action. No retry / dismiss /
 * overwrite actions, and the opaque payload JSON is never displayed.
 */
@Composable
private fun SyncItemDetails(
    item: PendingSyncItem,
    canRetry: Boolean,
    onRetry: () -> Unit,
    onCopy: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp)
            .padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            item.title,
            fontWeight = FontWeight.SemiBold,
            color = vine.textPrimary,
            fontSize = 20.sp,
        )
        Text(
            item.displayStatusLabel,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = vine.textPrimary,
        )
        item.friendlyDetail?.takeIf { it.isNotBlank() }?.let { detail ->
            Text(detail, fontSize = 14.sp, color = vine.textSecondary)
        }
        item.attemptLabel?.let { attempt ->
            Text(attempt, fontSize = 13.sp, color = vine.textSecondary)
        }

        DetailRow("Type", syncEntityLabel(item.entityType))
        DetailRow("Operation", item.opType.ifBlank { "—" })
        DetailRow("Related id", item.clientId.ifBlank { "—" })
        DetailRow("Status", item.status.ifBlank { "—" })
        if (item.createdAt > 0L) DetailRow("Created", relativeTime(item.createdAt))
        if (item.updatedAt > 0L) DetailRow("Updated", relativeTime(item.updatedAt))

        item.rawDetail?.takeIf { it.isNotBlank() }?.let { raw ->
            Text(
                "Diagnostic detail",
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = vine.textSecondary,
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(vine.textSecondary.copy(alpha = 0.08f))
                    .padding(12.dp),
            ) {
                Text(
                    raw,
                    fontSize = 12.sp,
                    fontFamily = FontFamily.Monospace,
                    color = vine.textSecondary,
                )
            }
        }

        if (canRetry) {
            Button(
                onClick = onRetry,
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Success),
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
            ) {
                Icon(
                    Icons.Filled.Refresh,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    "Retry this item",
                    modifier = Modifier.padding(start = 8.dp),
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                )
            }
            Text(
                "Retries use the normal sync order so trip changes stay safe.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
        }

        OutlinedButton(
            onClick = onCopy,
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        ) {
            Icon(
                Icons.Filled.ContentCopy,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
            )
            Text(
                "Copy diagnostics",
                modifier = Modifier.padding(start = 8.dp),
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
            )
        }
        Text(
            "Copies non-sensitive sync details for support. No personal data, passwords or keys are included.",
            fontSize = 12.sp,
            color = vine.textSecondary,
        )
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, fontSize = 13.sp, color = vine.textSecondary)
        Text(
            value,
            fontSize = 13.sp,
            color = vine.textPrimary,
            fontWeight = FontWeight.Medium,
        )
    }
}

/** Plain-language label for an outbox entity type used in the details sheet. */
private fun syncEntityLabel(entityType: String): String = when (entityType) {
    "trip_start" -> "Trip start"
    "trip_metadata" -> "Trip details"
    "trip_gps" -> "Trip GPS"
    "trip_row" -> "Trip rows"
    "trip_tank" -> "Trip tanks"
    "trip_end" -> "Trip end"
    "pin" -> "Pin"
    "pin_edit" -> "Pin edit"
    "fuel_log" -> "Fuel log"
    "spray_record" -> "Spray record"
    "work_task" -> "Work task"
    "work_task_labour" -> "Work task labour"
    "work_task_machine" -> "Work task machine"
    "maintenance_log" -> "Maintenance"
    "yield_record" -> "Yield"
    "growth_record" -> "Growth"
    "damage_record" -> "Damage"
    "button_config" -> "Buttons"
    "yield_session" -> "Yield estimation"
    "" -> "—"
    else -> entityType
}

/** Human-friendly relative time (e.g. "5 minutes ago") for a cache timestamp. */
private fun relativeTime(epochMillis: Long): String =
    DateUtils.getRelativeTimeSpanString(
        epochMillis,
        System.currentTimeMillis(),
        DateUtils.MINUTE_IN_MILLIS,
    ).toString()

// ---------------------------------------------------------------------------
// Per-function sync breakdown (iOS Settings → Sync parity)
// ---------------------------------------------------------------------------

/**
 * One row in the per-function sync breakdown. [entityTypes] are the outbox
 * discriminators owned by this function (used to derive waiting /
 * needs-attention counts); [syncTimeKey] indexes [AppViewModel.domainSyncTimes]
 * for the "last synced" line (null when that area has no read-cache timestamp).
 */
private data class SyncFunctionSpec(
    val id: String,
    val title: String,
    val icon: ImageVector,
    val entityTypes: Set<String>,
    val syncTimeKey: String? = null,
)

/** Field data — mirrors the first section of the iOS Sync page. */
private val fieldDataSyncFunctions = listOf(
    SyncFunctionSpec("pins", "Pins", Icons.Filled.PushPin, setOf("pin", "pin_edit"), "pins"),
    SyncFunctionSpec("paddocks", "Blocks", Icons.Filled.GridView, emptySet(), "paddocks"),
    SyncFunctionSpec(
        "trips", "Trips", Icons.Filled.Map,
        setOf("trip", "trip_start", "trip_metadata", "trip_seeding", "trip_gps", "trip_row", "trip_tank", "trip_end", "tank_session"),
        "trips",
    ),
    SyncFunctionSpec("spray", "Spray Records", Icons.Filled.WaterDrop, setOf("spray_record"), "spray"),
    SyncFunctionSpec("buttonConfig", "Button Config", Icons.Filled.Apps, setOf("button_config")),
)

/** Operations — mirrors the iOS Operations section. */
private val operationsSyncFunctions = listOf(
    SyncFunctionSpec(
        "workTasks", "Work Tasks", Icons.Filled.Checklist,
        setOf("work_task", "work_task_labour", "work_task_machine", "work_task_paddock"),
        "workTasks",
    ),
    SyncFunctionSpec("maintenance", "Maintenance Logs", Icons.Filled.Build, setOf("maintenance_log"), "maintenance"),
    SyncFunctionSpec("fuel", "Fuel Logs", Icons.Filled.LocalGasStation, setOf("fuel_log"), "fuel"),
    SyncFunctionSpec("yield", "Yield Estimation", Icons.Filled.BarChart, setOf("yield_record", "yield_session"), "yield"),
    SyncFunctionSpec("damage", "Damage Records", Icons.Filled.ReportProblem, setOf("damage_record"), "damage"),
    SyncFunctionSpec("growth", "Growth Stage Records", Icons.Filled.Eco, setOf("growth_record"), "growth"),
)

/** Operational tools — mirrors the iOS Operational Tools section. */
private val operationalToolsSyncFunctions = listOf(
    SyncFunctionSpec("pruning", "Pruning Tracker", Icons.Filled.ContentCut, setOf("pruning_season", "pruning_entry")),
    SyncFunctionSpec("fertiliser", "Fertiliser Records", Icons.Filled.Grass, setOf("fertiliser_record")),
)

/**
 * Card listing one group of sync functions. Each row derives its own state
 * from the shared outbox snapshot — rendering never mutates anything.
 */
@Composable
private fun SyncFunctionsCard(
    specs: List<SyncFunctionSpec>,
    itemsByType: Map<String, List<PendingSyncItem>>,
    syncTimes: Map<String, Long?>,
    syncingIds: Set<String>,
    online: Boolean,
    onSync: (SyncFunctionSpec) -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column {
            specs.forEachIndexed { index, spec ->
                if (index > 0) {
                    HorizontalDivider(color = vine.textSecondary.copy(alpha = 0.12f))
                }
                SyncFunctionRow(
                    spec = spec,
                    items = spec.entityTypes.flatMap { itemsByType[it].orEmpty() },
                    lastSyncedAt = spec.syncTimeKey?.let { syncTimes[it] },
                    isSyncing = spec.id in syncingIds,
                    online = online,
                    onSync = { onSync(spec) },
                )
            }
        }
    }
}

/**
 * A single function row: icon, name, live status line (needs attention /
 * waiting / up to date with last-synced time) and a per-function sync button
 * matching the iOS "Sync …" rows.
 */
@Composable
private fun SyncFunctionRow(
    spec: SyncFunctionSpec,
    items: List<PendingSyncItem>,
    lastSyncedAt: Long?,
    isSyncing: Boolean,
    online: Boolean,
    onSync: () -> Unit,
) {
    val vine = LocalVineColors.current
    val attention = items.count { it.status == "blocked" }
    val waiting = items.size - attention
    val statusText: String
    val statusColor: Color
    when {
        isSyncing -> {
            statusText = "Syncing…"
            statusColor = VineColors.Primary
        }
        attention > 0 -> {
            statusText = buildString {
                append(if (attention == 1) "1 item needs attention" else "$attention items need attention")
                if (waiting > 0) append(" · $waiting waiting")
            }
            statusColor = VineColors.Destructive
        }
        waiting > 0 -> {
            statusText = if (waiting == 1) "1 item waiting to sync" else "$waiting items waiting to sync"
            statusColor = VineColors.Warning
        }
        else -> {
            statusText = lastSyncedAt?.let { "Up to date · " + relativeTime(it) } ?: "Up to date"
            statusColor = VineColors.Success
        }
    }
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(VineColors.Primary.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                spec.icon,
                contentDescription = null,
                tint = VineColors.Primary,
                modifier = Modifier.size(18.dp),
            )
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                spec.title,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
            )
            Text(statusText, fontSize = 12.sp, color = statusColor)
        }
        if (isSyncing) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                strokeWidth = 2.dp,
                color = VineColors.Primary,
            )
        } else {
            IconButton(onClick = onSync, enabled = online) {
                Icon(
                    Icons.Filled.Sync,
                    contentDescription = "Sync ${spec.title}",
                    tint = if (online) VineColors.Primary else vine.textSecondary.copy(alpha = 0.4f),
                )
            }
        }
    }
}
