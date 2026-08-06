package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddLocationAlt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.RowAttachment
import com.rork.vinetrack.data.model.ManualIssue
import com.rork.vinetrack.data.model.ManualIssueCategories
import com.rork.vinetrack.data.model.ManualIssueContract
import com.rork.vinetrack.data.model.ManualIssueCreateParams
import com.rork.vinetrack.data.model.ManualIssueLatLng
import com.rork.vinetrack.data.model.ManualIssuePriorities
import com.rork.vinetrack.data.model.ManualIssueScopes
import com.rork.vinetrack.data.model.ManualIssueSegment
import com.rork.vinetrack.data.model.ManualIssueStatuses
import com.rork.vinetrack.data.model.ManualIssueUpdateParams
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.theme.VineColors
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Manual Issues (sql/169): list + creation flow + detail, mirroring the iOS
 * ManualIssuesListView / ManualIssueComposerView / ManualIssueDetailView.
 *
 * A manual issue never asks for labour, cost, machinery, worker type or Work
 * Task data. Map markers ride the shared pins list (mode = ManualIssue, amber).
 */
@Composable
fun ManualIssuesScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    initialCompose: Boolean = false,
) {
    var composing by rememberSaveable { mutableStateOf(initialCompose) }
    var editingId by rememberSaveable { mutableStateOf<String?>(null) }
    var detailId by rememberSaveable { mutableStateOf<String?>(null) }
    var includeFinished by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(includeFinished) { vm.refreshManualIssues(includeFinished) }

    // Internal back: composer → where it came from, detail → list.
    BackHandler(enabled = composing || detailId != null) {
        when {
            composing -> { composing = false; editingId = null }
            else -> detailId = null
        }
    }

    val issues = state.manualIssues.filter { it.vineyardId == state.selectedVineyardId }
    val detail = detailId?.let { id -> issues.firstOrNull { it.id == id } }

    when {
        composing -> ManualIssueComposer(
            vm = vm,
            state = state,
            existing = editingId?.let { id -> issues.firstOrNull { it.id == id } },
            modifier = modifier,
            onDone = { composing = false; editingId = null },
            onCancel = { composing = false; editingId = null },
        )
        detail != null -> ManualIssueDetail(
            vm = vm,
            state = state,
            issue = detail,
            modifier = modifier,
            onBack = { detailId = null },
            onEdit = { editingId = detail.id; composing = true },
            onDeleted = { detailId = null },
        )
        else -> ManualIssueList(
            vm = vm,
            state = state,
            issues = issues,
            includeFinished = includeFinished,
            modifier = modifier,
            onBack = onBack,
            onAdd = { composing = true },
            onOpen = { detailId = it },
            onIncludeFinishedChange = { includeFinished = it },
        )
    }
}

// MARK: - List

@Composable
private fun ManualIssueList(
    vm: AppViewModel,
    state: AppUiState,
    issues: List<ManualIssue>,
    includeFinished: Boolean,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onAdd: () -> Unit,
    onOpen: (String) -> Unit,
    onIncludeFinishedChange: (Boolean) -> Unit,
) {
    var search by rememberSaveable { mutableStateOf("") }
    var statusFilter by rememberSaveable { mutableStateOf<String?>(null) }
    var priorityFilter by rememberSaveable { mutableStateOf<String?>(null) }
    var blockFilter by rememberSaveable { mutableStateOf<String?>(null) }
    var assigneeFilter by rememberSaveable { mutableStateOf<String?>(null) }

    val filtered = issues.filter { issue ->
        val statusOk = when {
            statusFilter != null -> issue.status == statusFilter
            includeFinished -> true
            else -> ManualIssueStatuses.isActive(issue.status)
        }
        statusOk &&
            (priorityFilter == null || issue.priority == priorityFilter) &&
            (blockFilter == null || issue.paddockId == blockFilter) &&
            (assigneeFilter == null || issue.assignedUserId == assigneeFilter) &&
            (search.isBlank() || "${issue.title} ${issue.description.orEmpty()}".contains(search, ignoreCase = true))
    }
    val pendingCount = vm.manualIssuePendingCount()

    Column(modifier = modifier.fillMaxSize().statusBarsPadding()) {
        ScreenHeader(title = "Manual Issues", onBack = onBack) {
            IconButton(onClick = onAdd) {
                Icon(Icons.Filled.Add, contentDescription = "Add manual issue", tint = ManualIssueColor)
            }
        }
        if (pendingCount > 0) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            ) {
                Icon(Icons.Filled.Sync, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(14.dp))
                Text("$pendingCount change(s) waiting to sync", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        OutlinedTextField(
            value = search,
            onValueChange = { search = it },
            placeholder = { Text("Search issues") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            FilterDropdown(
                label = statusFilter?.let { ManualIssueStatuses.label(it) } ?: if (includeFinished) "All statuses" else "Active",
                active = statusFilter != null || includeFinished,
                options = listOf("Active (default)", "All statuses") + ManualIssueStatuses.all.map { ManualIssueStatuses.label(it) },
                onSelect = { index ->
                    when (index) {
                        0 -> { statusFilter = null; onIncludeFinishedChange(false) }
                        1 -> { statusFilter = null; onIncludeFinishedChange(true) }
                        else -> {
                            val status = ManualIssueStatuses.all[index - 2]
                            statusFilter = status
                            if (!ManualIssueStatuses.isActive(status)) onIncludeFinishedChange(true)
                        }
                    }
                },
            )
            FilterDropdown(
                label = priorityFilter?.let { ManualIssuePriorities.label(it) } ?: "Priority",
                active = priorityFilter != null,
                options = listOf("Any priority") + ManualIssuePriorities.all.map { ManualIssuePriorities.label(it) },
                onSelect = { index ->
                    priorityFilter = if (index == 0) null else ManualIssuePriorities.all[index - 1]
                },
            )
            FilterDropdown(
                label = blockFilter?.let { id -> state.paddocks.firstOrNull { it.id == id }?.name } ?: "Block",
                active = blockFilter != null,
                options = listOf("All blocks") + state.paddocks.map { it.name },
                onSelect = { index ->
                    blockFilter = if (index == 0) null else state.paddocks.getOrNull(index - 1)?.id
                },
            )
            FilterDropdown(
                label = assigneeFilter?.let { id -> state.members.firstOrNull { it.userId == id }?.let(::memberLabel) } ?: "Assignee",
                active = assigneeFilter != null,
                options = listOf("Anyone") + state.members.map(::memberLabel),
                onSelect = { index ->
                    assigneeFilter = if (index == 0) null else state.members.getOrNull(index - 1)?.userId
                },
            )
        }
        if (filtered.isEmpty()) {
            Column(
                modifier = Modifier.fillMaxSize().padding(32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Filled.AddLocationAlt, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(36.dp))
                Text("No manual issues", fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                Text(
                    if (includeFinished || statusFilter != null) "Nothing matches these filters." else "Open and in-progress issues appear here.",
                    fontSize = 13.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(filtered, key = { it.id }) { issue ->
                    ManualIssueCard(
                        issue = issue,
                        blockName = state.paddocks.firstOrNull { it.id == issue.paddockId }?.name,
                        assigneeName = issue.assignedUserId?.let { id -> state.members.firstOrNull { it.userId == id }?.let(::memberLabel) },
                        pending = vm.isManualIssuePending(issue.id),
                        onClick = { onOpen(issue.id) },
                    )
                }
            }
        }
    }
}

@Composable
private fun ManualIssueCard(
    issue: ManualIssue,
    blockName: String?,
    assigneeName: String?,
    pending: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier.fillMaxWidth().clickable { onClick() },
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(priorityColor(issue.priority)))
                Text(
                    issue.title,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                if (pending) {
                    Icon(Icons.Filled.Sync, contentDescription = "Waiting to sync", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(14.dp))
                }
                StatusBadge(issue.status)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                blockName?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                Text(issue.locationSummary, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(ManualIssuePriorities.label(issue.priority), fontSize = 11.sp, color = priorityColor(issue.priority), fontWeight = FontWeight.Medium)
                assigneeName?.let { Text(it, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                issue.dueDate?.let { Text("Due $it", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
    }
}

// MARK: - Detail

@Composable
private fun ManualIssueDetail(
    vm: AppViewModel,
    state: AppUiState,
    issue: ManualIssue,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onEdit: () -> Unit,
    onDeleted: () -> Unit,
) {
    var confirmCancel by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val canDelete = state.currentRole in listOf("owner", "manager", "supervisor")

    Column(modifier = modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())) {
        ScreenHeader(title = "Manual Issue", onBack = onBack) {
            TextButton(onClick = onEdit) { Text("Edit") }
        }

        val markerLat = if (issue.snappedToRow) issue.snappedLatitude ?: issue.latitude else issue.latitude
        val markerLon = if (issue.snappedToRow) issue.snappedLongitude ?: issue.longitude else issue.longitude
        if (markerLat != null && markerLon != null) {
            val camera = rememberCameraPositionState {
                position = CameraPosition.fromLatLngZoom(LatLng(markerLat, markerLon), 17f)
            }
            GoogleMap(
                cameraPositionState = camera,
                properties = MapProperties(mapType = MapType.HYBRID),
                uiSettings = MapUiSettings(
                    zoomControlsEnabled = false,
                    scrollGesturesEnabled = false,
                    zoomGesturesEnabled = false,
                    tiltGesturesEnabled = false,
                    rotationGesturesEnabled = false,
                ),
                modifier = Modifier.fillMaxWidth().height(180.dp).padding(horizontal = 16.dp).clip(RoundedCornerShape(12.dp)),
            ) {
                Marker(state = MarkerState(position = LatLng(markerLat, markerLon)), title = issue.title)
            }
        }

        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(issue.title, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.weight(1f))
                StatusBadge(issue.status)
            }
            issue.description?.takeIf { it.isNotBlank() }?.let {
                Text(it, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurface)
            }
            DetailRow("Category", ManualIssueCategories.label(issue.category))
            DetailRow("Priority", ManualIssuePriorities.label(issue.priority))
            DetailRow("Applies to", ManualIssueScopes.label(issue.locationScope))
            state.paddocks.firstOrNull { it.id == issue.paddockId }?.let { DetailRow("Block", it.name) }
            DetailRow("Where", issue.locationSummary)
            DetailRow(
                "Assigned to",
                issue.assignedUserId?.let { id -> state.members.firstOrNull { it.userId == id }?.let(::memberLabel) } ?: "Unassigned",
            )
            issue.dueDate?.let { DetailRow("Due date", it) }
            issue.createdBy?.let { id ->
                state.members.firstOrNull { it.userId == id }?.let { DetailRow("Created by", memberLabel(it)) }
            }
            issue.createdAt?.let { DetailRow("Created", it.take(10)) }
            if (issue.status == ManualIssueStatuses.COMPLETED) {
                issue.completedAt?.let { DetailRow("Completed", it.take(10)) }
                issue.completedBy?.let { DetailRow("Completed by", it) }
            }

            // Status actions — server-authoritative via set_manual_issue_status.
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                when (issue.status) {
                    ManualIssueStatuses.OPEN -> {
                        OutlinedButton(onClick = { vm.setManualIssueStatus(issue.id, ManualIssueStatuses.IN_PROGRESS) }, modifier = Modifier.weight(1f)) {
                            Text("Start Progress")
                        }
                        Button(onClick = { vm.setManualIssueStatus(issue.id, ManualIssueStatuses.COMPLETED) }, modifier = Modifier.weight(1f)) {
                            Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Complete")
                        }
                    }
                    ManualIssueStatuses.IN_PROGRESS -> {
                        OutlinedButton(onClick = { vm.setManualIssueStatus(issue.id, ManualIssueStatuses.OPEN) }, modifier = Modifier.weight(1f)) {
                            Text("Back to Open")
                        }
                        Button(onClick = { vm.setManualIssueStatus(issue.id, ManualIssueStatuses.COMPLETED) }, modifier = Modifier.weight(1f)) {
                            Text("Complete")
                        }
                    }
                    else -> {
                        OutlinedButton(onClick = { vm.setManualIssueStatus(issue.id, ManualIssueStatuses.OPEN) }, modifier = Modifier.weight(1f)) {
                            Text("Reopen")
                        }
                    }
                }
            }
            if (issue.status != ManualIssueStatuses.CANCELLED) {
                OutlinedButton(onClick = { confirmCancel = true }, modifier = Modifier.fillMaxWidth()) {
                    Text("Cancel Issue", color = VineColors.Destructive)
                }
            }
            if (canDelete) {
                OutlinedButton(onClick = { confirmDelete = true }, modifier = Modifier.fillMaxWidth()) {
                    Text("Delete", color = VineColors.Destructive)
                }
            }
        }
    }

    if (confirmCancel) {
        AlertDialog(
            onDismissRequest = { confirmCancel = false },
            title = { Text("Cancel this issue?") },
            text = { Text("The issue stays in history as cancelled.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmCancel = false
                    vm.cancelOrDeleteManualIssue(issue.id, "cancel")
                }) { Text("Cancel Issue", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmCancel = false }) { Text("Keep") } },
        )
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete this issue?") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    vm.cancelOrDeleteManualIssue(issue.id, "delete")
                    onDeleted()
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Keep") } },
        )
    }
}

// MARK: - Composer

/** Snapping captured when the user taps a point on the composer map. */
private data class ComposerPointSnap(
    val paddockId: String?,
    val rowNumber: Int?,
    val snapped: LatLng?,
    val alongM: Double?,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ManualIssueComposer(
    vm: AppViewModel,
    state: AppUiState,
    existing: ManualIssue?,
    modifier: Modifier = Modifier,
    onDone: () -> Unit,
    onCancel: () -> Unit,
) {
    var title by rememberSaveable { mutableStateOf(existing?.title.orEmpty()) }
    var description by rememberSaveable { mutableStateOf(existing?.description.orEmpty()) }
    var category by rememberSaveable { mutableStateOf(existing?.category ?: ManualIssueContract.DEFAULT_CATEGORY) }
    var priority by rememberSaveable { mutableStateOf(existing?.priority ?: ManualIssueContract.DEFAULT_PRIORITY) }
    var scope by rememberSaveable { mutableStateOf(existing?.locationScope ?: ManualIssueScopes.POINT) }
    var paddockId by rememberSaveable { mutableStateOf(existing?.paddockId) }
    var assigneeId by rememberSaveable { mutableStateOf(existing?.assignedUserId) }
    var dueDate by rememberSaveable { mutableStateOf(existing?.dueDate) }
    var showDatePicker by remember { mutableStateOf(false) }
    var tapped by remember {
        mutableStateOf(
            if (existing?.locationScope == ManualIssueScopes.POINT && existing.latitude != null && existing.longitude != null) {
                LatLng(existing.latitude, existing.longitude)
            } else {
                null
            },
        )
    }
    var snap by remember {
        mutableStateOf(
            if (existing?.snappedToRow == true && existing.snappedLatitude != null && existing.snappedLongitude != null) {
                ComposerPointSnap(
                    paddockId = existing.paddockId,
                    rowNumber = existing.pinRowNumber?.toInt(),
                    snapped = LatLng(existing.snappedLatitude, existing.snappedLongitude),
                    alongM = existing.alongRowDistanceM,
                )
            } else {
                null
            },
        )
    }
    var segments by remember { mutableStateOf(existing?.segments.orEmpty().toSet()) }
    var validationMessage by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }

    val selectedPaddock = state.paddocks.firstOrNull { it.id == paddockId }

    fun place(latLng: LatLng) {
        tapped = latLng
        snap = null
        validationMessage = null
        val paddock = state.paddocks.firstOrNull {
            RowAttachment.containsPoint(it, latLng.latitude, latLng.longitude)
        } ?: return
        paddockId = paddock.id
        val hit = RowAttachment.nearestRow(paddock, latLng.latitude, latLng.longitude) ?: run {
            snap = ComposerPointSnap(paddock.id, null, null, null)
            return
        }
        // Same confidence rule as iOS: only attach within half a row width
        // (min 3 m) of a row centreline.
        val threshold = max(3.0, hit.rowWidthM)
        if (hit.perpendicularDistanceM > threshold) {
            snap = ComposerPointSnap(paddock.id, null, null, null)
            return
        }
        val row = paddock.rows.orEmpty().firstOrNull { it.number == hit.rowNumber }
        val projected = row?.let { r ->
            val start = r.startPoint
            val end = r.endPoint
            if (start != null && end != null) {
                projectOntoSegment(
                    latLng.latitude, latLng.longitude,
                    start.latitude, start.longitude,
                    end.latitude, end.longitude,
                )
            } else {
                null
            }
        }
        snap = ComposerPointSnap(
            paddockId = paddock.id,
            rowNumber = hit.rowNumber,
            snapped = projected?.first,
            alongM = projected?.second,
        )
    }

    Column(modifier = modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())) {
        ScreenHeader(title = if (existing == null) "Add Manual Issue" else "Edit Manual Issue", onBack = onCancel) {
            TextButton(
                enabled = !saving,
                onClick = {
                    val trimmedTitle = title.trim()
                    val canonical = ManualIssueContract.canonicalSegments(segments.toList())
                    val marker: ManualIssueLatLng? = when (scope) {
                        ManualIssueScopes.POINT -> tapped?.let { ManualIssueLatLng(it.latitude, it.longitude) }
                        ManualIssueScopes.ROW -> selectedPaddock?.let { paddock ->
                            val rowLines = paddock.rows.orEmpty()
                                .filter { it.startPoint != null && it.endPoint != null }
                                .associate { row ->
                                    row.number to Pair(
                                        ManualIssueLatLng(row.startPoint!!.latitude, row.startPoint.longitude),
                                        ManualIssueLatLng(row.endPoint!!.latitude, row.endPoint.longitude),
                                    )
                                }
                            ManualIssueContract.markerCoordinate(canonical, rowLines)
                                ?: ManualIssueContract.blockCentroid(
                                    paddock.polygonPoints.orEmpty().map { ManualIssueLatLng(it.latitude, it.longitude) },
                                )
                        }
                        else -> selectedPaddock?.let { paddock ->
                            ManualIssueContract.blockCentroid(
                                paddock.polygonPoints.orEmpty().map { ManualIssueLatLng(it.latitude, it.longitude) },
                            )
                        }
                    }
                    val error = ManualIssueContract.validationError(
                        title = trimmedTitle,
                        scope = scope,
                        latitude = marker?.latitude,
                        longitude = marker?.longitude,
                        paddockId = if (scope == ManualIssueScopes.POINT) (snap?.paddockId ?: paddockId ?: "point") else paddockId,
                        segments = canonical,
                    )
                    if (error != null || marker == null) {
                        validationMessage = error ?: "A map location is required."
                        return@TextButton
                    }
                    saving = true
                    validationMessage = null
                    val stamp = Instant.now().toString()
                    val onResult: (Boolean, String?) -> Unit = { ok, message ->
                        saving = false
                        if (ok) onDone() else validationMessage = message ?: "The issue couldn't be saved."
                    }
                    if (existing == null) {
                        vm.createManualIssue(
                            ManualIssueCreateParams(
                                id = UUID.randomUUID().toString(),
                                vineyardId = state.selectedVineyardId.orEmpty(),
                                title = trimmedTitle,
                                locationScope = scope,
                                paddockId = if (scope == ManualIssueScopes.POINT) (snap?.paddockId ?: paddockId) else paddockId,
                                description = description.trim().ifEmpty { null },
                                category = category,
                                priority = priority,
                                latitude = marker.latitude,
                                longitude = marker.longitude,
                                snappedLatitude = if (scope == ManualIssueScopes.POINT) snap?.snapped?.latitude else null,
                                snappedLongitude = if (scope == ManualIssueScopes.POINT) snap?.snapped?.longitude else null,
                                drivingRowNumber = if (scope == ManualIssueScopes.POINT) snap?.rowNumber?.toDouble() else null,
                                pinRowNumber = if (scope == ManualIssueScopes.POINT) snap?.rowNumber?.toDouble() else null,
                                alongRowDistanceM = if (scope == ManualIssueScopes.POINT) snap?.alongM else null,
                                snappedToRow = scope == ManualIssueScopes.POINT && snap?.snapped != null,
                                assignedUserId = assigneeId,
                                dueDate = dueDate,
                                clientUpdatedAt = stamp,
                                segments = if (scope == ManualIssueScopes.ROW) canonical else null,
                            ),
                            onResult,
                        )
                    } else {
                        vm.updateManualIssue(
                            ManualIssueUpdateParams(
                                id = existing.id,
                                title = trimmedTitle,
                                locationScope = scope,
                                paddockId = if (scope == ManualIssueScopes.POINT) (snap?.paddockId ?: paddockId) else paddockId,
                                description = description.trim().ifEmpty { null },
                                category = category,
                                priority = priority,
                                latitude = marker.latitude,
                                longitude = marker.longitude,
                                snappedLatitude = if (scope == ManualIssueScopes.POINT) snap?.snapped?.latitude else null,
                                snappedLongitude = if (scope == ManualIssueScopes.POINT) snap?.snapped?.longitude else null,
                                drivingRowNumber = if (scope == ManualIssueScopes.POINT) snap?.rowNumber?.toDouble() else null,
                                pinRowNumber = if (scope == ManualIssueScopes.POINT) snap?.rowNumber?.toDouble() else null,
                                alongRowDistanceM = if (scope == ManualIssueScopes.POINT) snap?.alongM else null,
                                snappedToRow = scope == ManualIssueScopes.POINT && snap?.snapped != null,
                                assignedUserId = assigneeId,
                                dueDate = dueDate,
                                clientUpdatedAt = stamp,
                                segments = if (scope == ManualIssueScopes.ROW) canonical else null,
                            ),
                            onResult,
                        )
                    }
                },
            ) { Text(if (existing == null) "Save" else "Update", fontWeight = FontWeight.SemiBold) }
        }

        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text("Title (required)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = description,
                onValueChange = { description = it },
                label = { Text("Description") },
                minLines = 2,
                modifier = Modifier.fillMaxWidth(),
            )
            FieldLabel("Category")
            FilterDropdown(
                label = ManualIssueCategories.label(category),
                active = true,
                options = ManualIssueCategories.all.map { ManualIssueCategories.label(it) },
                onSelect = { category = ManualIssueCategories.all[it] },
            )
            FieldLabel("Priority")
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                ManualIssuePriorities.all.forEach { value ->
                    FilterChip(
                        selected = priority == value,
                        onClick = { priority = value },
                        label = { Text(ManualIssuePriorities.label(value)) },
                    )
                }
            }
            FieldLabel("Assign to")
            FilterDropdown(
                label = assigneeId?.let { id -> state.members.firstOrNull { it.userId == id }?.let(::memberLabel) } ?: "Unassigned",
                active = assigneeId != null,
                options = listOf("Unassigned") + state.members.map(::memberLabel),
                onSelect = { index ->
                    assigneeId = if (index == 0) null else state.members.getOrNull(index - 1)?.userId
                },
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Due date", fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.weight(1f))
                dueDate?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(end = 8.dp)) }
                Switch(
                    checked = dueDate != null,
                    onCheckedChange = { on ->
                        if (on) showDatePicker = true else dueDate = null
                    },
                )
            }
            dueDate?.let {
                TextButton(onClick = { showDatePicker = true }) { Text("Change due date") }
            }

            FieldLabel("Applies to")
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                ManualIssueScopes.all.forEach { value ->
                    FilterChip(
                        selected = scope == value,
                        onClick = {
                            // Changing the location type replaces the previous
                            // location data — no stale snapping/segments survive.
                            scope = value
                            validationMessage = null
                        },
                        label = { Text(ManualIssueScopes.label(value)) },
                    )
                }
            }

            when (scope) {
                ManualIssueScopes.POINT -> {
                    Text("Tap the map to place the pin", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    val start = tapped
                        ?: selectedPaddock?.polygonPoints?.let { pts ->
                            ManualIssueContract.blockCentroid(pts.map { ManualIssueLatLng(it.latitude, it.longitude) })
                                ?.let { LatLng(it.latitude, it.longitude) }
                        }
                        ?: state.paddocks.firstOrNull { !it.polygonPoints.isNullOrEmpty() }?.polygonPoints?.let { pts ->
                            ManualIssueContract.blockCentroid(pts.map { ManualIssueLatLng(it.latitude, it.longitude) })
                                ?.let { LatLng(it.latitude, it.longitude) }
                        }
                    val camera = rememberCameraPositionState {
                        position = CameraPosition.fromLatLngZoom(start ?: LatLng(-34.9, 138.6), if (start != null) 16f else 5f)
                    }
                    GoogleMap(
                        cameraPositionState = camera,
                        properties = MapProperties(mapType = MapType.HYBRID),
                        uiSettings = MapUiSettings(zoomControlsEnabled = false),
                        onMapClick = { place(it) },
                        modifier = Modifier.fillMaxWidth().height(260.dp).clip(RoundedCornerShape(12.dp)),
                    ) {
                        tapped?.let { Marker(state = MarkerState(position = it)) }
                    }
                    val snapLabel = ManualIssueContract.attachedRowLabel(
                        drivingRowNumber = snap?.rowNumber?.toDouble(),
                        pinRowNumber = snap?.rowNumber?.toDouble(),
                        side = null,
                    )
                    when {
                        snapLabel != null -> Text(snapLabel, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        tapped != null -> Text("Pin placed (not attached to a row)", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                ManualIssueScopes.ROW -> {
                    BlockDropdown(state.paddocks, paddockId) { paddockId = it; segments = emptySet(); validationMessage = null }
                    val rows = selectedPaddock?.rows.orEmpty()
                        .filter { it.startPoint != null && it.endPoint != null }
                        .sortedBy { it.number }
                    if (selectedPaddock != null && rows.isEmpty()) {
                        Text(
                            "This block has no mapped rows — flag the whole block instead",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (segments.isNotEmpty()) {
                        Text(
                            ManualIssueContract.rowSelectionSummary(segments.toList()),
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium,
                            color = ManualIssueColor,
                        )
                    }
                    rows.forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            val all = (1..4).map { ManualIssueSegment(row.number, it) }
                            val wholeSelected = all.all { it in segments }
                            Box(
                                modifier = Modifier
                                    .width(38.dp)
                                    .heightIn(min = 28.dp)
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(if (wholeSelected) ManualIssueColor else MaterialTheme.colorScheme.surfaceVariant)
                                    .clickable {
                                        segments = if (wholeSelected) segments - all.toSet() else segments + all.toSet()
                                    },
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    "${row.number}",
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = if (wholeSelected) Color.White else MaterialTheme.colorScheme.onSurface,
                                )
                            }
                            (1..4).forEach { quarter ->
                                val segment = ManualIssueSegment(row.number, quarter)
                                val selected = segment in segments
                                Box(
                                    modifier = Modifier
                                        .weight(1f)
                                        .heightIn(min = 28.dp)
                                        .clip(RoundedCornerShape(5.dp))
                                        .background(if (selected) ManualIssueColor else MaterialTheme.colorScheme.surfaceVariant)
                                        .clickable {
                                            segments = if (selected) segments - segment else segments + segment
                                        },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (selected) {
                                        Icon(Icons.Filled.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(13.dp))
                                    }
                                }
                            }
                        }
                    }
                }
                else -> {
                    BlockDropdown(state.paddocks, paddockId) { paddockId = it; validationMessage = null }
                    if (selectedPaddock != null) {
                        Text("The whole block will be flagged", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            validationMessage?.let {
                Text(it, fontSize = 13.sp, color = VineColors.Destructive)
            }
            Spacer(Modifier.height(24.dp))
        }
    }

    if (showDatePicker) {
        val pickerState = rememberDatePickerState()
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    pickerState.selectedDateMillis?.let { millis ->
                        dueDate = Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate().toString()
                    }
                    showDatePicker = false
                }) { Text("Set") }
            },
            dismissButton = { TextButton(onClick = { showDatePicker = false }) { Text("Cancel") } },
        ) {
            DatePicker(state = pickerState)
        }
    }
}

// MARK: - Shared pieces

@Composable
private fun ScreenHeader(title: String, onBack: () -> Unit, actions: @Composable () -> Unit = {}) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
    ) {
        IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
        }
        Text(
            title,
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        actions()
    }
}

@Composable
private fun FieldLabel(text: String) {
    Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth()) {
        Text(label, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(110.dp))
        Text(value, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun StatusBadge(status: String) {
    val color = statusColor(status)
    Text(
        ManualIssueStatuses.label(status),
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold,
        color = color,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.15f))
            .padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

@Composable
private fun FilterDropdown(
    label: String,
    active: Boolean,
    options: List<String>,
    onSelect: (Int) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Text(
            label,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = if (active) Color.White else MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(if (active) ManualIssueColor else MaterialTheme.colorScheme.surfaceVariant)
                .clickable { expanded = true }
                .padding(horizontal = 10.dp, vertical = 6.dp),
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEachIndexed { index, option ->
                DropdownMenuItem(text = { Text(option) }, onClick = { expanded = false; onSelect(index) })
            }
        }
    }
}

@Composable
private fun BlockDropdown(paddocks: List<Paddock>, selectedId: String?, onSelect: (String?) -> Unit) {
    FilterDropdown(
        label = selectedId?.let { id -> paddocks.firstOrNull { it.id == id }?.name } ?: "Select a block",
        active = selectedId != null,
        options = paddocks.map { it.name },
        onSelect = { index -> onSelect(paddocks.getOrNull(index)?.id) },
    )
}

private fun memberLabel(member: VineyardMember): String =
    member.displayName?.takeIf { it.isNotBlank() }
        ?: member.fullName?.takeIf { it.isNotBlank() }
        ?: member.email?.takeIf { it.isNotBlank() }
        ?: "Member"

private fun priorityColor(priority: String): Color = when (priority) {
    ManualIssuePriorities.LOW -> Color(0xFF8E8E93)
    ManualIssuePriorities.HIGH -> VineColors.Orange
    ManualIssuePriorities.URGENT -> VineColors.Destructive
    else -> VineColors.Primary
}

private fun statusColor(status: String): Color = when (status) {
    ManualIssueStatuses.IN_PROGRESS -> VineColors.Primary
    ManualIssueStatuses.COMPLETED -> VineColors.LeafGreen
    ManualIssueStatuses.CANCELLED -> Color(0xFF8E8E93)
    else -> ManualIssueColor
}

/**
 * Project (lat, lon) onto the segment start→end using the same
 * equirectangular metres-per-degree approximation as iOS RowGuidance.snap,
 * returning the snapped point and the along-segment distance in metres.
 */
private fun projectOntoSegment(
    lat: Double,
    lon: Double,
    startLat: Double,
    startLon: Double,
    endLat: Double,
    endLon: Double,
): Pair<LatLng, Double>? {
    val centroidLat = (startLat + endLat + lat) / 3.0
    val mPerDegLat = 111_320.0
    val mPerDegLon = 111_320.0 * cos(Math.toRadians(centroidLat))
    val ax = startLon * mPerDegLon
    val ay = startLat * mPerDegLat
    val bx = endLon * mPerDegLon
    val by = endLat * mPerDegLat
    val px = lon * mPerDegLon
    val py = lat * mPerDegLat
    val dx = bx - ax
    val dy = by - ay
    val lengthSq = dx * dx + dy * dy
    if (lengthSq <= 0.0) return null
    val t = (((px - ax) * dx + (py - ay) * dy) / lengthSq).coerceIn(0.0, 1.0)
    val sx = ax + t * dx
    val sy = ay + t * dy
    val along = sqrt((sx - ax) * (sx - ax) + (sy - ay) * (sy - ay))
    return Pair(LatLng(sy / mPerDegLat, sx / mPerDegLon), along)
}
