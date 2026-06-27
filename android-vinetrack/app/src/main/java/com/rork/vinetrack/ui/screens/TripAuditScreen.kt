package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.TripAuditRepository
import com.rork.vinetrack.data.model.Vineyard
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

/** Problem categories for a trip's vineyard/paddock integrity (parity with iOS). */
private enum class TripProblem(val label: String) {
    NullVineyard("Null vineyard"),
    UnknownVineyard("Unknown / bogus vineyard"),
    DeletedVineyard("Deleted vineyard"),
    ScalarPaddockMismatch("Block id in another vineyard"),
    PaddockIdsMismatch("Block ids in another vineyard"),
    NameOnlyPaddock("Block name only, no reliable id"),
    Unsafe("Cannot safely repair"),
}

/** A single audited trip with its detected problems and inferred repair target. */
private data class AuditTrip(
    val id: String,
    val paddockId: String?,
    val paddockIds: List<String>,
    val paddockName: String?,
    val trackingPattern: String?,
    val personName: String?,
    val startTime: String?,
    val currentVineyardId: String?,
    val currentVineyardName: String?,
    val currentVineyardDeleted: Boolean,
    val inferredVineyardId: String?,
    val inferredVineyardName: String?,
    val problems: List<TripProblem>,
    val canAutoRepair: Boolean,
    val autoRepaired: Boolean = false,
    val manuallyRepaired: Boolean = false,
    val lastError: String? = null,
) {
    val title: String
        get() = personName?.takeIf { it.isNotBlank() }
            ?: paddockName?.takeIf { it.isNotBlank() }
            ?: "Trip"
}

private data class AuditResult(
    val scanned: Int = 0,
    val alreadyCorrect: Int = 0,
    val autoRepaired: Int = 0,
    val needingReview: Int = 0,
    val deletedVineyard: Int = 0,
    val pushFailures: Int = 0,
    val counts: Map<TripProblem, Int> = emptyMap(),
    val ran: Boolean = false,
)

private const val ZERO_UUID = "00000000-0000-0000-0000-000000000000"

/**
 * Owner/manager Trip Audit & repair tool, mirroring iOS `AdminTripAuditView` +
 * `TripAuditService`. Scans every trip the user can see across all accessible
 * vineyards, categorises `vineyard_id` integrity problems, auto-repairs
 * unambiguous cases, and offers a manual reassignment sheet for the rest.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TripAuditScreen(
    vm: AppViewModel,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    val repo = vm.tripAuditRepository
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()

    var autoRepair by remember { mutableStateOf(true) }
    var status by remember { mutableStateOf(AuditStatus.Idle) }
    var trips by remember { mutableStateOf<List<AuditTrip>>(emptyList()) }
    var vineyards by remember { mutableStateOf<List<Vineyard>>(emptyList()) }
    var result by remember { mutableStateOf(AuditResult()) }
    var error by remember { mutableStateOf<String?>(null) }
    var reassignTrip by remember { mutableStateOf<AuditTrip?>(null) }

    val busy = status == AuditStatus.Scanning || status == AuditStatus.Repairing
    val problemTrips = trips.filter { it.problems.isNotEmpty() }

    fun runScan() {
        if (busy) return
        scope.launch {
            status = AuditStatus.Scanning
            error = null
            val outcome = runCatching { performScan(repo, autoRepair) }
            outcome.onSuccess { scan ->
                vineyards = scan.vineyards
                trips = scan.trips
                result = scan.result
                status = AuditStatus.Finished
            }.onFailure {
                error = it.message ?: "Couldn't scan trips."
                status = AuditStatus.Failed
            }
        }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Trip Audit") },
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
            // Controls
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Audit", onLight = true)
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text("Auto-repair unambiguous trips", fontWeight = FontWeight.Medium, color = vine.textPrimary)
                                Text(
                                    "Only runs when block ids resolve to a single live vineyard.",
                                    fontSize = 12.sp,
                                    color = vine.textSecondary,
                                )
                            }
                            Switch(checked = autoRepair, enabled = !busy, onCheckedChange = { autoRepair = it })
                        }
                        Button(
                            onClick = { runScan() },
                            enabled = !busy,
                            modifier = Modifier.fillMaxWidth(),
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                        ) {
                            if (busy) {
                                CircularProgressIndicator(
                                    color = Color.White,
                                    strokeWidth = 2.dp,
                                    modifier = Modifier.size(18.dp),
                                )
                                Spacer(Modifier.size(8.dp))
                                Text(if (status == AuditStatus.Repairing) "Repairing\u2026" else "Scanning\u2026")
                            } else {
                                Icon(Icons.Filled.Search, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.size(8.dp))
                                Text(if (result.ran) "Re-scan all vineyards" else "Scan all vineyards")
                            }
                        }
                        Text(
                            "Scans every trip you can see across every accessible vineyard. Trips on deleted vineyards or with ambiguous blocks need manual review.",
                            fontSize = 11.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            error?.let {
                VineyardCard { Text(it, color = VineColors.Destructive, fontSize = 13.sp) }
            }

            // Summary
            if (result.ran) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Summary", onLight = true)
                    VineyardCard {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            StatRow("Scanned", result.scanned.toString())
                            DividerThin(vine.cardBorder)
                            StatRow("Already correct", result.alreadyCorrect.toString())
                            DividerThin(vine.cardBorder)
                            StatRow("Auto-repaired", result.autoRepaired.toString())
                            DividerThin(vine.cardBorder)
                            StatRow("Needing review", result.needingReview.toString())
                            DividerThin(vine.cardBorder)
                            StatRow("Deleted vineyard", result.deletedVineyard.toString())
                            if (result.pushFailures > 0) {
                                DividerThin(vine.cardBorder)
                                StatRow("Push failures", result.pushFailures.toString(), valueColor = VineColors.Destructive)
                            }
                        }
                    }
                }

                val activeCounts = TripProblem.entries.mapNotNull { p ->
                    result.counts[p]?.takeIf { it > 0 }?.let { p to it }
                }
                if (activeCounts.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        SectionHeader("Problem categories", onLight = true)
                        VineyardCard {
                            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                activeCounts.forEachIndexed { index, (cat, n) ->
                                    if (index > 0) DividerThin(vine.cardBorder)
                                    StatRow(cat.label, n.toString())
                                }
                            }
                        }
                    }
                }
            }

            // Problem trips
            if (problemTrips.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Trips needing attention (${problemTrips.size})", onLight = true)
                    problemTrips.forEach { trip ->
                        AuditTripCard(trip = trip, onReassign = { reassignTrip = trip })
                    }
                }
            } else if (result.ran && error == null) {
                VineyardCard {
                    Text("Every trip resolves to a valid vineyard. Nothing to repair.", color = vine.textSecondary, fontSize = 13.sp)
                }
            }

            Spacer(Modifier.height(8.dp))
        }
    }

    reassignTrip?.let { trip ->
        ReassignSheet(
            trip = trip,
            vineyards = vineyards.filter { it.deletedAt == null },
            onDismiss = { reassignTrip = null },
            onConfirm = { vineyardId, paddockId ->
                reassignTrip = null
                scope.launch {
                    val ok = runCatching {
                        repo.updateTripVineyardAssignment(trip.id, vineyardId, paddockId)
                    }
                    if (ok.isSuccess) {
                        val targetName = vineyards.firstOrNull { it.id == vineyardId }?.name
                        trips = trips.map {
                            if (it.id == trip.id) it.copy(
                                currentVineyardId = vineyardId,
                                currentVineyardName = targetName,
                                currentVineyardDeleted = false,
                                paddockId = paddockId ?: it.paddockId,
                                problems = emptyList(),
                                manuallyRepaired = true,
                                lastError = null,
                            ) else it
                        }
                        result = result.copy(
                            needingReview = trips.count { it.id != trip.id && it.problems.isNotEmpty() },
                        )
                    } else {
                        val msg = ok.exceptionOrNull()?.message ?: "Reassign failed."
                        trips = trips.map { if (it.id == trip.id) it.copy(lastError = msg) else it }
                    }
                }
            },
        )
    }
}

private enum class AuditStatus { Idle, Scanning, Repairing, Finished, Failed }

private class ScanOutcome(
    val vineyards: List<Vineyard>,
    val trips: List<AuditTrip>,
    val result: AuditResult,
)

/**
 * Port of iOS `TripAuditService.scan` + `runAutoRepair`. Fetches all accessible
 * vineyards/paddocks/trips, categorises each trip's integrity, optionally
 * auto-repairs unambiguous cases, and returns the audited rows + summary.
 */
private suspend fun performScan(repo: TripAuditRepository, autoRepair: Boolean): ScanOutcome {
    val fetchedVineyards = repo.fetchAllAccessibleVineyards()
    val fetchedPaddocks = repo.fetchAllAccessiblePaddocks()
    val fetchedTrips = repo.fetchAllAccessibleTrips()

    val vineyardById = fetchedVineyards.associateBy { it.id }
    val paddockToVineyard: Map<String, String> = buildMap {
        fetchedPaddocks.forEach { p -> putIfAbsent(p.id, p.vineyardId) }
    }
    // paddock name -> matching (vineyardId) for non-deleted vineyards only.
    val paddocksByName: Map<String, List<String>> = buildMap<String, MutableList<String>> {
        fetchedPaddocks.forEach { p ->
            val v = vineyardById[p.vineyardId]
            if (v != null && v.deletedAt == null) {
                getOrPut(p.name.lowercase()) { mutableListOf() }.add(p.vineyardId)
            }
        }
    }

    val audited = ArrayList<AuditTrip>(fetchedTrips.size)
    var alreadyCorrect = 0
    var deletedVineyard = 0
    val counts = HashMap<TripProblem, Int>()

    for (trip in fetchedTrips) {
        val currentVineyard = vineyardById[trip.vineyardId]
        val currentDeleted = currentVineyard?.deletedAt != null

        val paddockIds = trip.paddockIds.ifEmpty { trip.paddockId?.let { listOf(it) } ?: emptyList() }
        val resolved = paddockIds.mapNotNull { paddockToVineyard[it] }
        val allResolved = paddockIds.isNotEmpty() && resolved.size == paddockIds.size
        val unique = resolved.toSet()

        val problems = ArrayList<TripProblem>()
        var inferred: String? = null

        if (allResolved && unique.size == 1) {
            val only = unique.first()
            if (vineyardById[only]?.deletedAt == null) inferred = only
        }

        val tripVineyardIsZero = trip.vineyardId == ZERO_UUID
        when {
            tripVineyardIsZero -> problems.add(TripProblem.NullVineyard)
            currentVineyard == null -> problems.add(TripProblem.UnknownVineyard)
            currentDeleted -> problems.add(TripProblem.DeletedVineyard)
        }

        val scalar = trip.paddockId
        if (scalar != null) {
            val scalarVineyard = paddockToVineyard[scalar]
            if (scalarVineyard != null && scalarVineyard != trip.vineyardId && currentVineyard != null) {
                problems.add(TripProblem.ScalarPaddockMismatch)
            }
        }

        if (paddockIds.isNotEmpty() && allResolved && unique.size == 1) {
            val only = unique.first()
            if (only != trip.vineyardId && currentVineyard != null && !currentDeleted) {
                problems.add(TripProblem.PaddockIdsMismatch)
            }
        }

        if (paddockIds.isEmpty() && !trip.paddockName.isNullOrBlank()) {
            val matches = paddocksByName[trip.paddockName!!.lowercase()] ?: emptyList()
            val uniqueMatch = matches.toSet()
            if (uniqueMatch.size == 1) {
                inferred = uniqueMatch.first()
            } else if (matches.isNotEmpty()) {
                problems.add(TripProblem.NameOnlyPaddock)
            }
        }

        val canAutoRepair = inferred != null &&
            !(inferred == trip.vineyardId && !currentDeleted)

        if (problems.isNotEmpty() && !canAutoRepair) {
            problems.add(TripProblem.Unsafe)
        }

        if (problems.isEmpty()) alreadyCorrect++
        problems.forEach { counts[it] = (counts[it] ?: 0) + 1 }
        if (currentDeleted) deletedVineyard++

        audited.add(
            AuditTrip(
                id = trip.id,
                paddockId = trip.paddockId,
                paddockIds = paddockIds,
                paddockName = trip.paddockName,
                trackingPattern = trip.trackingPattern,
                personName = trip.personName,
                startTime = trip.startTime,
                currentVineyardId = if (tripVineyardIsZero) null else trip.vineyardId,
                currentVineyardName = currentVineyard?.name,
                currentVineyardDeleted = currentDeleted,
                inferredVineyardId = inferred,
                inferredVineyardName = inferred?.let { vineyardById[it]?.name },
                problems = problems,
                canAutoRepair = canAutoRepair,
            ),
        )
    }

    var rows: List<AuditTrip> = audited
    var autoRepaired = 0
    var pushFailures = 0

    if (autoRepair) {
        val mutable = rows.toMutableList()
        for (i in mutable.indices) {
            val entry = mutable[i]
            val target = entry.inferredVineyardId
            if (!entry.canAutoRepair || target == null) continue
            val scalar = if (entry.paddockIds.size == 1) entry.paddockIds.first() else entry.paddockId
            val outcome = runCatching {
                repo.updateTripVineyardAssignment(entry.id, target, scalar)
            }
            if (outcome.isSuccess) {
                mutable[i] = entry.copy(
                    autoRepaired = true,
                    currentVineyardId = target,
                    currentVineyardName = vineyardById[target]?.name,
                    currentVineyardDeleted = false,
                    problems = emptyList(),
                )
                autoRepaired++
            } else {
                mutable[i] = entry.copy(lastError = outcome.exceptionOrNull()?.message)
                pushFailures++
            }
        }
        rows = mutable
    }

    val needingReview = rows.count { it.problems.isNotEmpty() && !it.autoRepaired && !it.manuallyRepaired }

    return ScanOutcome(
        vineyards = fetchedVineyards,
        trips = rows,
        result = AuditResult(
            scanned = fetchedTrips.size,
            alreadyCorrect = alreadyCorrect,
            autoRepaired = autoRepaired,
            needingReview = needingReview,
            deletedVineyard = deletedVineyard,
            pushFailures = pushFailures,
            counts = counts,
            ran = true,
        ),
    )
}

// MARK: - Rows / cards

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AuditTripCard(trip: AuditTrip, onReassign: () -> Unit) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    trip.title,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (trip.currentVineyardDeleted) {
                    Badge("deleted vineyard", VineColors.Destructive)
                }
            }
            if (trip.problems.isNotEmpty()) {
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    trip.problems.forEach { Badge(it.label, problemTint(it)) }
                }
            }
            trip.paddockName?.takeIf { it.isNotBlank() }?.let {
                Text("Block: $it", fontSize = 12.sp, color = vine.textSecondary)
            }
            Text(
                "Current vineyard: ${trip.currentVineyardName ?: "(none)"}",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
            if (trip.inferredVineyardName != null && !trip.autoRepaired) {
                Text("Suggested vineyard: ${trip.inferredVineyardName}", fontSize = 12.sp, color = VineColors.LeafGreen)
            }
            trip.lastError?.let {
                Text(it, fontSize = 11.sp, color = VineColors.Destructive)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    trip.id.take(8),
                    fontSize = 11.sp,
                    fontFamily = FontFamily.Monospace,
                    color = vine.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                OutlinedButton(onClick = onReassign) { Text("Reassign\u2026") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReassignSheet(
    trip: AuditTrip,
    vineyards: List<Vineyard>,
    onDismiss: () -> Unit,
    onConfirm: (vineyardId: String, paddockId: String?) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var selected by remember { mutableStateOf<String?>(null) }
    var keepPaddock by remember { mutableStateOf(true) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Reassign trip", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                trip.paddockName?.takeIf { it.isNotBlank() }?.let { StatRow("Block", it) }
                trip.personName?.takeIf { it.isNotBlank() }?.let { StatRow("Person", it) }
                trip.trackingPattern?.let { StatRow("Pattern", it) }
                trip.currentVineyardName?.let {
                    StatRow("Current vineyard", it + if (trip.currentVineyardDeleted) " (deleted)" else "")
                }
            }

            SectionHeader("Reassign to vineyard", onLight = true)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (vineyards.isEmpty()) {
                    Text("No live vineyards available.", fontSize = 13.sp, color = vine.textSecondary)
                }
                vineyards.forEach { v ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (selected == v.id) VineColors.Primary.copy(alpha = 0.12f) else vine.appBackground)
                            .clickable { selected = v.id }
                            .padding(14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(v.name, color = vine.textPrimary, modifier = Modifier.weight(1f))
                        if (selected == v.id) {
                            Text("Selected", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
                        }
                    }
                }
            }

            if (trip.paddockId != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Keep current block id", fontWeight = FontWeight.Medium, color = vine.textPrimary)
                        Text(
                            "Turn off only if the block id does not belong to the new vineyard.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                    Switch(checked = keepPaddock, onCheckedChange = { keepPaddock = it })
                }
            }

            Button(
                onClick = {
                    val v = selected ?: return@Button
                    onConfirm(v, if (keepPaddock) trip.paddockId else null)
                },
                enabled = selected != null,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
            ) {
                Text("Confirm reassignment")
            }
        }
    }
}

@Composable
private fun Badge(text: String, tint: Color) {
    Box(
        modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(tint.copy(alpha = 0.15f)).padding(horizontal = 8.dp, vertical = 3.dp),
    ) {
        Text(text, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = tint)
    }
}

@Composable
private fun StatRow(label: String, value: String, valueColor: Color? = null) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = vine.textSecondary, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Text(value, color = valueColor ?: vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun DividerThin(color: Color) {
    Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(color))
}

private fun problemTint(p: TripProblem): Color = when (p) {
    TripProblem.NullVineyard, TripProblem.UnknownVineyard -> VineColors.Destructive
    TripProblem.DeletedVineyard -> VineColors.Orange
    TripProblem.ScalarPaddockMismatch, TripProblem.PaddockIdsMismatch -> VineColors.Info
    TripProblem.NameOnlyPaddock -> VineColors.Indigo
    TripProblem.Unsafe -> VineColors.Stone
}
