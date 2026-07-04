package com.rork.vinetrack.ui.screens

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudQueue
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Directions
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.NearMe
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PostAdd
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.outlined.AddAPhoto
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.filled.Check
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.rork.vinetrack.data.PinDuplicateChecker
import com.rork.vinetrack.data.PinExporter
import com.rork.vinetrack.data.RowAttachment
import com.rork.vinetrack.data.model.LauncherButton
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.PinSyncState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.StatusBadge
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import com.rork.vinetrack.data.AppPreferencesStore
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PinsScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    initialMode: String? = null,
    initialViewMode: PinsViewMode = PinsViewMode.Map,
    onOpenLauncher: ((String) -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    var editing by remember { mutableStateOf<PinEditTarget?>(null) }
    // Pin selected from a map marker tap — shows the detail bottom sheet first
    // (iOS PinDetailSheet parity); the edit form only opens from its Edit action.
    var detailPinId by rememberSaveable { mutableStateOf<String?>(null) }
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    // Map / List / Stats, mirroring the iOS segmented picker.
    var viewMode by remember { mutableStateOf(initialViewMode) }
    // null = All; otherwise a PinMode raw value ("Repairs" / "Growth").
    var modeFilter by remember { mutableStateOf<String?>(initialMode) }
    // null = All statuses; true = Completed; false = Open. Defaults to Open
    // ("Not done"), mirroring the iOS shared completion filter.
    var statusFilter by remember { mutableStateOf<Boolean?>(false) }

    // Per-pin action state (iOS list-row parity).
    var photoTarget by remember { mutableStateOf<Pin?>(null) }
    var uploadingPinId by remember { mutableStateOf<String?>(null) }
    var deleteTarget by remember { mutableStateOf<Pin?>(null) }
    var showExportSheet by remember { mutableStateOf(false) }
    var isExporting by remember { mutableStateOf(false) }
    // Current GPS fix, used to show each pin's distance (iOS PinRowView parity).
    var userLocation by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    LaunchedEffect(Unit) {
        if (vm.hasLocationPermission()) {
            vm.fetchCurrentLocation { userLocation = it }
        }
    }

    val visiblePins = remember(state.pins, modeFilter, statusFilter) {
        state.pins.filter { pin ->
            (modeFilter == null || pin.mode == modeFilter) &&
                (statusFilter == null || pin.isCompleted == statusFilter)
        }
            // Newest first, mirroring the iOS pin list ordering.
            .sortedByDescending { parseIsoMillis(it.createdAt) ?: Long.MIN_VALUE }
    }
    // Resolve each pin's configured colour (iOS nameColorMap parity).
    val colorMap = remember(state.repairButtons, state.growthButtons) { pinColorMap(state) }

    // Photo picker for attaching/replacing an existing pin's photo.
    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri: Uri? ->
        val pin = photoTarget
        photoTarget = null
        if (uri != null && pin != null) {
            uploadingPinId = pin.id
            vm.uploadPinPhoto(pin, uri) { ok ->
                uploadingPinId = null
                scope.launch {
                    snackbarHostState.showSnackbar(if (ok) "Photo added to pin" else "Couldn't add the photo")
                }
            }
        }
    }

    /** Open the pin's location in the device's maps app. */
    fun openMap(pin: Pin) {
        val lat = pin.latitude
        val lon = pin.longitude
        if (lat == null || lon == null) {
            scope.launch { snackbarHostState.showSnackbar("This pin has no saved location yet.") }
            return
        }
        val label = Uri.encode(pin.displayTitle)
        // Show the pin on Google Maps. Prefer the Google Maps app explicitly so a
        // tap lands on the map (not a browser page); fall back to the generic
        // geo: handler, then a plain web URL only as a last resort.
        val mapsApp = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("https://www.google.com/maps/search/?api=1&query=$lat,$lon"),
        ).setPackage("com.google.android.apps.maps")
        val geo = Intent(Intent.ACTION_VIEW, Uri.parse("geo:$lat,$lon?q=$lat,$lon($label)"))
        val web = Intent(Intent.ACTION_VIEW, Uri.parse("https://www.google.com/maps/search/?api=1&query=$lat,$lon"))
        for (intent in listOf(mapsApp, geo, web)) {
            try {
                context.startActivity(intent)
                return
            } catch (_: Exception) {
                // Try the next fallback.
            }
        }
        scope.launch { snackbarHostState.showSnackbar("No maps app available to open this location.") }
    }

    /** Launch turn-by-turn navigation to the pin (Google Maps, with a generic fallback). */
    fun openDirections(pin: Pin) {
        val lat = pin.latitude
        val lon = pin.longitude
        if (lat == null || lon == null) {
            scope.launch { snackbarHostState.showSnackbar("This pin has no saved location yet.") }
            return
        }
        // Directions to the pin (a direct route from the current location).
        // 1) Google Maps turn-by-turn, 2) Google Maps directions URL in the app,
        // 3) browser directions URL as a final fallback.
        val nav = Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=$lat,$lon"))
            .setPackage("com.google.android.apps.maps")
        val dirApp = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("https://www.google.com/maps/dir/?api=1&destination=$lat,$lon"),
        ).setPackage("com.google.android.apps.maps")
        val web = Intent(Intent.ACTION_VIEW, Uri.parse("https://www.google.com/maps/dir/?api=1&destination=$lat,$lon"))
        for (intent in listOf(nav, dirApp, web)) {
            try {
                context.startActivity(intent)
                return
            } catch (_: Exception) {
                // Try the next fallback.
            }
        }
        scope.launch { snackbarHostState.showSnackbar("No maps app available for directions.") }
    }

    fun runExport(format: PinExporter.Format) {
        if (visiblePins.isEmpty() || isExporting) return
        isExporting = true
        val ok = PinExporter.exportAndShare(
            context = context,
            pins = visiblePins,
            vineyardName = state.selectedVineyard?.name ?: "Vineyard",
            paddocks = state.paddocks,
            format = format,
            logo = state.selectedVineyardLogo,
        )
        isExporting = false
        if (!ok) scope.launch { snackbarHostState.showSnackbar("Couldn't create the export.") }
    }

    Scaffold(
        modifier = modifier,
        containerColor = vine.appBackground,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { Text("Pins") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                actions = {
                    IconButton(
                        onClick = { showExportSheet = true },
                        enabled = visiblePins.isNotEmpty() && !isExporting,
                    ) {
                        if (isExporting) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = vine.textSecondary)
                        } else {
                            Icon(Icons.Filled.Share, contentDescription = "Export pins", tint = vine.textSecondary)
                        }
                    }
                    PinsViewModeControl(viewMode) { viewMode = it }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            PinsFilterBar(
                modeFilter = modeFilter,
                statusFilter = statusFilter,
                onModeFilter = { modeFilter = it },
                onStatusFilter = { statusFilter = it },
            )
            when (viewMode) {
                PinsViewMode.Map -> VineyardMapContent(
                    state = state,
                    pins = visiblePins,
                    modifier = Modifier.fillMaxSize(),
                    onPinClick = { detailPinId = it.id },
                )
                PinsViewMode.List -> PinsListMode(
                    vm = vm,
                    visiblePins = visiblePins,
                    state = state,
                    colorMap = colorMap,
                    userLocation = userLocation,
                    modeFilter = modeFilter,
                    statusFilter = statusFilter,
                    uploadingPinId = uploadingPinId,
                    onEdit = { editing = PinEditTarget.Existing(it) },
                    onToggle = { vm.togglePinCompleted(it) },
                    onMap = { openMap(it) },
                    onDirections = { openDirections(it) },
                    onPhoto = {
                        photoTarget = it
                        photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    },
                    onDelete = { deleteTarget = it },
                )
                PinsViewMode.Stats -> PinsStatsMode(visiblePins, colorMap)
            }
        }
    }

    val target = editing
    if (target != null) {
        PinEditSheetHost(
            vm, state, target,
            onDismiss = { editing = null },
            onConfirmation = { msg -> scope.launch { snackbarHostState.showSnackbar(msg) } },
        )
    }

    // Selected-pin detail sheet (map tap → summary first, iOS parity). Resolved
    // fresh from state so completion/photo/sync changes update live; if the pin
    // is deleted while open, the sheet closes itself.
    val detailPin = detailPinId?.let { id -> state.pins.firstOrNull { it.id == id } }
    if (detailPinId != null && detailPin == null) {
        LaunchedEffect(detailPinId) { detailPinId = null }
    }
    if (detailPin != null) {
        PinDetailSheet(
            vm = vm,
            pin = detailPin,
            color = pinColor(detailPin, colorMap),
            paddockName = state.paddocks.firstOrNull { it.id == detailPin.paddockId }?.name,
            sync = state.pinSyncState(detailPin.id),
            canDelete = state.currentRole in setOf("owner", "manager", "supervisor"),
            photoBusy = uploadingPinId == detailPin.id,
            onDismiss = { detailPinId = null },
            onEdit = {
                detailPinId = null
                editing = PinEditTarget.Existing(detailPin)
            },
            onDirections = { openDirections(detailPin) },
            onPhoto = {
                photoTarget = detailPin
                photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            },
            onToggle = { vm.togglePinCompleted(detailPin) },
            onDelete = { deleteTarget = detailPin },
        )
    }

    deleteTarget?.let { pin ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete Pin?") },
            text = { Text("Delete \"${pin.displayTitle}\" pin? This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    deleteTarget = null
                    vm.deletePin(pin.id) { ok ->
                        scope.launch {
                            snackbarHostState.showSnackbar(if (ok) "Pin deleted" else "Couldn't delete the pin")
                        }
                    }
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) { Text("Cancel") }
            },
        )
    }

    if (showExportSheet) {
        AlertDialog(
            onDismissRequest = { showExportSheet = false },
            title = { Text("Export Pins") },
            text = { Text("Choose export format for ${visiblePins.size} pins") },
            confirmButton = {
                Column {
                    TextButton(onClick = { showExportSheet = false; runExport(PinExporter.Format.PDF) }) { Text("Export as PDF") }
                    TextButton(onClick = { showExportSheet = false; runExport(PinExporter.Format.CSV) }) { Text("Export as CSV (Excel)") }
                    TextButton(onClick = { showExportSheet = false; runExport(PinExporter.Format.BOTH) }) { Text("Export Both (PDF + CSV)") }
                }
            },
            dismissButton = {
                TextButton(onClick = { showExportSheet = false }) { Text("Cancel") }
            },
        )
    }
}

/** Pins surface view modes — Map / List / Stats, mirroring the iOS segmented picker. */
enum class PinsViewMode { Map, List, Stats }

/** Compact icon segmented control shown in the Pins top bar (Map / List / Stats). */
@Composable
private fun PinsViewModeControl(mode: PinsViewMode, onChange: (PinsViewMode) -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .padding(end = 8.dp)
            .clip(RoundedCornerShape(20.dp))
            .background(vine.textSecondary.copy(alpha = 0.12f))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        PinsViewModeButton(Icons.Filled.Map, "Map view", mode == PinsViewMode.Map) { onChange(PinsViewMode.Map) }
        PinsViewModeButton(Icons.AutoMirrored.Filled.List, "List view", mode == PinsViewMode.List) { onChange(PinsViewMode.List) }
        PinsViewModeButton(Icons.Filled.BarChart, "Stats view", mode == PinsViewMode.Stats) { onChange(PinsViewMode.Stats) }
    }
}

@Composable
private fun PinsViewModeButton(icon: ImageVector, desc: String, selected: Boolean, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(if (selected) VineColors.Primary else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = desc, tint = if (selected) Color.White else vine.textSecondary, modifier = Modifier.size(18.dp))
    }
}

/** Shared mode + status filter bar shown above every Pins view mode (iOS parity). */
@Composable
private fun PinsFilterBar(
    modeFilter: String?,
    statusFilter: Boolean?,
    onModeFilter: (String?) -> Unit,
    onStatusFilter: (Boolean?) -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PinModeFilterChip("All", modeFilter == null, vine.textSecondary) { onModeFilter(null) }
        PinModeFilterChip("Repairs", modeFilter == "Repairs", RepairColor) { onModeFilter("Repairs") }
        PinModeFilterChip("Growth", modeFilter == "Growth", GrowthColor) { onModeFilter("Growth") }
        Box(Modifier.size(width = 1.dp, height = 22.dp).background(vine.textSecondary.copy(alpha = 0.3f)))
        PinModeFilterChip("Both", statusFilter == null, vine.textSecondary) { onStatusFilter(null) }
        PinModeFilterChip("Not Done", statusFilter == false, VineColors.Warning) { onStatusFilter(false) }
        PinModeFilterChip("Done", statusFilter == true, VineColors.Success) { onStatusFilter(true) }
    }
}

/** List view: quick-add entry cards plus the observation list (iOS list-mode parity). */
@Composable
private fun PinsListMode(
    vm: AppViewModel,
    visiblePins: kotlin.collections.List<Pin>,
    state: AppUiState,
    colorMap: Map<String, String>,
    userLocation: Pair<Double, Double>?,
    modeFilter: String?,
    statusFilter: Boolean?,
    uploadingPinId: String?,
    onEdit: (Pin) -> Unit,
    onToggle: (Pin) -> Unit,
    onMap: (Pin) -> Unit,
    onDirections: (Pin) -> Unit,
    onPhoto: (Pin) -> Unit,
    onDelete: (Pin) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (visiblePins.isEmpty()) {
            item(key = "__empty") {
                Box(Modifier.fillMaxWidth().padding(top = 24.dp), contentAlignment = Alignment.Center) {
                    val modeWord = when (modeFilter) {
                        "Repairs" -> "repair"
                        "Growth" -> "growth"
                        else -> null
                    }
                    val statusWord = when (statusFilter) {
                        true -> "completed"
                        false -> "open"
                        else -> null
                    }
                    val icon = when (modeFilter) {
                        "Repairs" -> Icons.Filled.Build
                        "Growth" -> Icons.Filled.Grass
                        else -> Icons.Filled.LocationOn
                    }
                    val title = if (statusWord == null && modeWord == null) {
                        "No observations yet"
                    } else {
                        "No " + listOfNotNull(statusWord, modeWord).joinToString(" ") + " observations"
                    }
                    val message = when {
                        modeFilter == "Repairs" && statusFilter == null ->
                            "Tap Repairs above to log a repair, hazard or fault for your team."
                        modeFilter == "Growth" && statusFilter == null ->
                            "Tap Growth above to record a canopy, phenology or growth-stage observation."
                        statusFilter == false -> "Nothing outstanding here — open observations will appear once logged."
                        statusFilter == true -> "Completed observations will appear here once they're marked done."
                        else -> "Drop pins for repairs and growth observations. They sync to your team automatically."
                    }
                    EmptyState(icon = icon, title = title, message = message)
                }
            }
        } else {
            items(visiblePins, key = { it.id }) { pin ->
                PinRow(
                    vm = vm,
                    pin = pin,
                    color = pinColor(pin, colorMap),
                    paddockName = state.paddocks.firstOrNull { it.id == pin.paddockId }?.name,
                    userLocation = userLocation,
                    sync = state.pinSyncState(pin.id),
                    photoBusy = uploadingPinId == pin.id,
                    onClick = { onEdit(pin) },
                    onToggle = { onToggle(pin) },
                    onMap = { onMap(pin) },
                    onDirections = { onDirections(pin) },
                    onPhoto = { onPhoto(pin) },
                    onDelete = { onDelete(pin) },
                )
            }
        }
    }
}

/** Aggregated per-category totals for the Pins Stats view. */
private data class PinCategoryStat(
    val name: String,
    val color: Color,
    val total: Int,
    val open: Int,
    val done: Int,
)

/** Stats view: overview totals + per-category breakdown (iOS PinsSummaryView parity). */
@Composable
private fun PinsStatsMode(pins: kotlin.collections.List<Pin>, colorMap: Map<String, String>) {
    val vine = LocalVineColors.current
    if (pins.isEmpty()) {
        Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            EmptyState(
                icon = Icons.Filled.BarChart,
                title = "Nothing to summarise yet",
                message = "Drop pins for repairs and growth observations to see a breakdown here.",
            )
        }
        return
    }
    val total = pins.size
    val completed = pins.count { it.isCompleted }
    val active = total - completed
    val growth = pins.count { it.mode?.contains("growth", ignoreCase = true) == true }
    val repairs = total - growth
    val stats = remember(pins) {
        pins.groupBy { it.displayTitle.trim().lowercase() }
            .map { (_, group) ->
                val first = group.first()
                PinCategoryStat(
                    name = first.displayTitle,
                    color = pinColor(first, colorMap),
                    total = group.size,
                    open = group.count { !it.isCompleted },
                    done = group.count { it.isCompleted },
                )
            }
            .sortedByDescending { it.total }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Overview", fontWeight = FontWeight.Bold, color = vine.textPrimary, fontSize = 17.sp)
                PinStatRow("Total pins", total.toString(), vine.textPrimary)
                PinStatRow("Active", active.toString(), VineColors.Warning)
                PinStatRow("Completed", completed.toString(), VineColors.Success)
                PinStatRow("Repairs", repairs.toString(), RepairColor)
                PinStatRow("Growth", growth.toString(), GrowthColor)
            }
        }
        VineyardCard {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text("By Category", fontWeight = FontWeight.Bold, color = vine.textPrimary, fontSize = 17.sp)
                stats.forEach { stat -> PinCategoryStatRow(stat) }
            }
        }
    }
}

@Composable
private fun PinStatRow(label: String, value: String, valueColor: Color) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = vine.textSecondary, fontSize = 14.sp)
        Text(value, color = valueColor, fontWeight = FontWeight.Bold, fontSize = 16.sp)
    }
}

@Composable
private fun PinCategoryStatRow(stat: PinCategoryStat) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(14.dp).clip(CircleShape).background(stat.color))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stat.name, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 14.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (stat.open > 0) Text("${stat.open} open", fontSize = 12.sp, color = VineColors.Warning)
                if (stat.done > 0) Text("${stat.done} done", fontSize = 12.sp, color = VineColors.Success)
            }
        }
        Text(stat.total.toString(), fontWeight = FontWeight.Bold, fontSize = 18.sp, color = vine.textPrimary)
    }
}

/**
 * Wraps [PinEditSheet] with the standard create/update/delete wiring so both the
 * Observations list and the Repairs/Growth launcher share one save path.
 */
@Composable
private fun PinEditSheetHost(
    vm: AppViewModel,
    state: AppUiState,
    target: PinEditTarget,
    onDismiss: () -> Unit,
    onConfirmation: (String) -> Unit = {},
) {
    // Pending duplicate confirmation for a launcher GPS pin that snapped onto a
    // row already carrying a nearby open pin. Holds the candidate match plus the
    // deferred save action so "Create anyway" can proceed.
    var pendingDuplicate by remember { mutableStateOf<PendingPinDuplicate?>(null) }

    PinEditSheet(
        vm = vm,
        state = state,
        target = target,
        paddocks = state.paddocks,
        onDismiss = onDismiss,
        onSave = { fields, photoUri, onDone ->
            when (target) {
                is PinEditTarget.New -> {
                    // Prefer the GPS fix captured when the category was tapped;
                    // fall back to the paddock centroid / vineyard coordinate.
                    val hasGps = target.latitude != null && target.longitude != null
                    val loc = if (hasGps) {
                        target.latitude to target.longitude
                    } else {
                        defaultLocation(fields.paddockId, state)
                    }
                    // Resolve the snapped row attachment up front so both the
                    // duplicate check and the post-save confirmation can reuse it.
                    // Only snap when we have a real GPS fix; a centroid fallback
                    // would produce a meaningless along-row distance.
                    val paddock = state.paddocks.firstOrNull { it.id == fields.paddockId }
                    val attachment = if (hasGps) {
                        RowAttachment.resolve(
                            paddock = paddock,
                            latitude = target.latitude,
                            longitude = target.longitude,
                            side = fields.side?.ifBlank { null },
                        )
                    } else {
                        null
                    }
                    // Customer-friendly confirmation echoing the attached row/side
                    // when the pin snapped to a mapped row. Null when not attached,
                    // so an un-snapped pin never shows a misleading row line.
                    val dropConfirmation = attachment?.let { att ->
                        val rowLabel = if (att.pinRowNumber % 1.0 == 0.0) {
                            att.pinRowNumber.toInt().toString()
                        } else {
                            att.pinRowNumber.toString()
                        }
                        val sideLabel = att.pinSide?.lowercase()
                            ?.takeIf { it == "left" || it == "right" }
                        if (sideLabel != null) {
                            "Pin saved — attached to row $rowLabel · $sideLabel side"
                        } else {
                            "Pin saved — attached to row $rowLabel"
                        }
                    }
                    val doCreate: () -> Unit = {
                        vm.createPin(
                            title = fields.title,
                            mode = fields.mode,
                            category = fields.category,
                            notes = fields.notes,
                            side = fields.side,
                            paddockId = fields.paddockId,
                            rowNumber = fields.rowNumber,
                            isCompleted = fields.isCompleted,
                            latitude = loc?.first,
                            longitude = loc?.second,
                            attachToRow = hasGps,
                            photoUri = photoUri,
                        ) { ok ->
                            onDone(ok)
                            if (ok) {
                                dropConfirmation?.let(onConfirmation)
                                onDismiss()
                            }
                        }
                    }
                    // Duplicate detection runs only for launcher pins with a real
                    // GPS fix. The preferred path snaps to a row and compares
                    // along-row distance; legacy pins lacking row attachment are
                    // caught by a conservative raw-distance fallback.
                    // Preferred: along-row duplicate using the snapped attachment.
                    val alongRowDup = attachment?.let {
                        PinDuplicateChecker.nearbyAlongRow(
                            candidate = it,
                            paddockId = fields.paddockId,
                            mode = fields.mode,
                            pins = state.pins,
                        )
                    }
                    // Fallback: raw-distance match against older pins without row
                    // attachment, scoped to the same block / mode / side / manual row.
                    val duplicate = alongRowDup ?: if (hasGps) {
                        PinDuplicateChecker.nearbyRawDistance(
                            latitude = target.latitude,
                            longitude = target.longitude,
                            paddockId = fields.paddockId,
                            mode = fields.mode,
                            side = fields.side?.ifBlank { null },
                            manualRowNumber = fields.rowNumber,
                            paddock = paddock,
                            pins = state.pins,
                        )
                    } else {
                        null
                    }
                    if (duplicate != null) {
                        // Stop the save spinner and ask before creating.
                        onDone(false)
                        pendingDuplicate = PendingPinDuplicate(
                            existing = duplicate.pin,
                            rowNumber = if (duplicate.alongRow) attachment?.pinRowNumber else null,
                            side = if (duplicate.alongRow) {
                                attachment?.pinSide?.lowercase()
                                    ?.takeIf { it == "left" || it == "right" }
                            } else {
                                null
                            },
                            distanceM = duplicate.distanceM,
                            alongRow = duplicate.alongRow,
                            onCreateAnyway = doCreate,
                        )
                    } else {
                        doCreate()
                    }
                }
                is PinEditTarget.Existing -> {
                    vm.updatePin(
                        pinId = target.pin.id,
                        title = fields.title,
                        mode = fields.mode,
                        category = fields.category,
                        notes = fields.notes,
                        side = fields.side,
                        paddockId = fields.paddockId,
                        rowNumber = fields.rowNumber,
                        isCompleted = fields.isCompleted,
                    ) { ok -> onDone(ok); if (ok) onDismiss() }
                }
            }
        },
        onDelete = { onDone ->
            if (target is PinEditTarget.Existing) {
                vm.deletePin(target.pin.id) { ok -> onDone(ok); if (ok) onDismiss() }
            }
        },
    )

    pendingDuplicate?.let { dup ->
        val distLabel = String.format(java.util.Locale.US, "%.1f", dup.distanceM)
        val message = if (dup.alongRow && dup.rowNumber != null) {
            val rowLabel = if (dup.rowNumber % 1.0 == 0.0) dup.rowNumber.toInt().toString() else dup.rowNumber.toString()
            // Echo the snapped row, plus side when known, in the same friendly
            // "row 19.5 · left side" style used by the list/detail/callout labels.
            val rowAndSide = dup.side?.let { "row $rowLabel · $it side" } ?: "row $rowLabel"
            "A similar open item (\"${dup.existing.displayTitle}\") is already on " +
                "$rowAndSide, about $distLabel m away. Create another one here anyway?"
        } else {
            // Raw-distance fallback: the existing pin predates row attachment, so
            // we only know straight-line distance within the block.
            "A similar open item (\"${dup.existing.displayTitle}\") is already nearby in this block, " +
                "about $distLabel m away. Create another one here anyway?"
        }
        AlertDialog(
            onDismissRequest = { pendingDuplicate = null },
            title = { Text("Possible duplicate") },
            text = { Text(message) },
            confirmButton = {
                TextButton(onClick = {
                    pendingDuplicate = null
                    dup.onCreateAnyway()
                }) { Text("Create anyway") }
            },
            dismissButton = {
                TextButton(onClick = { pendingDuplicate = null }) { Text("Cancel") }
            },
        )
    }
}

/** Deferred-save payload for the duplicate-warning confirmation dialog. */
private data class PendingPinDuplicate(
    val existing: Pin,
    /** Attached row of the new pin for along-row matches; null for raw-distance fallback. */
    val rowNumber: Double?,
    /** Snapped side ("left"/"right") of the new pin for along-row matches; null otherwise. */
    val side: String?,
    val distanceM: Double,
    /** True when matched along the snapped row; false for the legacy raw-distance fallback. */
    val alongRow: Boolean,
    /** Block name of the existing pin, for the duplicate sheet's context line. */
    val blockName: String? = null,
    val onCreateAnyway: () -> Unit,
)

/** Floating success card payload shown after a quick pin is dropped. */
private data class QuickPinToast(
    val title: String,
    val subtitle: String,
    val offline: Boolean,
)

/** Friendly row label, e.g. 19 or 19.5 (drops a trailing .0). */
private fun pinRowLabel(row: Double): String =
    if (row % 1.0 == 0.0) row.toInt().toString() else row.toString()

/**
 * Quick-pin success subtitle (no internal geometry terms). Prefers the attached
 * row + side; otherwise echoes the operator's chosen side.
 */
private fun quickPinSubtitle(side: String, attachment: RowAttachment.Attachment?): String {
    val sideLabel = when (side.lowercase()) {
        "left" -> "Left hand side"
        "right" -> "Right hand side"
        else -> side
    }
    if (attachment == null) return sideLabel
    val rowLabel = pinRowLabel(attachment.pinRowNumber)
    val attachedSide = attachment.pinSide?.lowercase()?.takeIf { it == "left" || it == "right" }
    return if (attachedSide != null) {
        "Attached to row $rowLabel \u00b7 $attachedSide side"
    } else {
        "Attached to row $rowLabel"
    }
}

/**
 * Floating success card (iOS pin-dropped toast parity). Title + a friendly
 * side/row subtitle, plus a calm offline line when saved without a connection.
 */
@Composable
private fun QuickPinSuccessToast(toast: QuickPinToast, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(vine.cardBackground)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(VineColors.Success.copy(alpha = 0.16f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.Success)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(toast.title, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(toast.subtitle, fontSize = 13.sp, color = vine.textSecondary)
            if (toast.offline) {
                Text(
                    "Saved offline \u2014 will sync when connected",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VineColors.Warning,
                )
            }
        }
    }
}

/**
 * Duplicate-warning bottom sheet for a quick-tapped pin (iOS parity). Shows the
 * existing pin's title/category/status/block plus distance and row/side context,
 * with Cancel / Create anyway actions. UI only — the detection algorithm and
 * thresholds are unchanged.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun QuickPinDuplicateSheet(
    duplicate: PendingPinDuplicate,
    onDismiss: () -> Unit,
    onCreateAnyway: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val existing = duplicate.existing
    val distLabel = String.format(java.util.Locale.US, "%.1f", duplicate.distanceM)
    val status = if (existing.isCompleted) "Completed" else "Open"
    // Friendly row/side context line, e.g. "On row 19.5 \u00b7 left side".
    val rowSideLine: String? = duplicate.rowNumber?.let { row ->
        val rowLabel = pinRowLabel(row)
        duplicate.side?.let { "On row $rowLabel \u00b7 $it side" } ?: "On row $rowLabel"
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(VineColors.Warning.copy(alpha = 0.16f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.WarningAmber, contentDescription = null, tint = VineColors.Warning)
                }
                Column {
                    Text("Duplicate?", fontSize = 19.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                    Text("Possible duplicate pin nearby", fontSize = 13.sp, color = vine.textSecondary)
                }
            }

            // Existing pin context card.
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(vine.textSecondary.copy(alpha = 0.08f))
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(existing.displayTitle, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                val meta = buildList {
                    existing.category?.takeIf { it.isNotBlank() }?.let { add(it) }
                    add(status)
                    duplicate.blockName?.takeIf { it.isNotBlank() }?.let { add(it) }
                }.joinToString(" \u00b7 ")
                if (meta.isNotBlank()) {
                    Text(meta, fontSize = 13.sp, color = vine.textSecondary)
                }
                rowSideLine?.let { Text(it, fontSize = 13.sp, color = vine.textSecondary) }
                Text("$distLabel m away", fontSize = 13.sp, color = vine.textSecondary)
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onDismiss, modifier = Modifier.weight(1f)) {
                    Text("Cancel")
                }
                Button(
                    onClick = onCreateAnyway,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                ) {
                    Text("Create anyway")
                }
            }
        }
    }
}

/**
 * Optional "Add a photo?" prompt shown after a successful quick pin when the
 * auto-photo preference is on. Counts down from 3s and auto-skips on zero
 * (iOS AutoPhotoConfirmSheet parity). Skip / Take Photo are explicit actions.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AutoPhotoPromptSheet(
    onSkip: () -> Unit,
    onTakePhoto: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    var remaining by remember { mutableStateOf(3) }
    var responded by remember { mutableStateOf(false) }

    // 3 \u2192 0 countdown; auto-skips when it reaches zero unless already answered.
    LaunchedEffect(Unit) {
        for (value in 2 downTo 0) {
            delay(1000)
            remaining = value
        }
        delay(1000)
        if (!responded) {
            responded = true
            onSkip()
        }
    }

    ModalBottomSheet(onDismissRequest = { if (!responded) { responded = true; onSkip() } }, sheetState = sheetState, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(56.dp)
                    .clip(CircleShape)
                    .background(VineColors.Primary.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.PhotoCamera, contentDescription = null, tint = VineColors.Primary, modifier = Modifier.size(28.dp))
            }
            Text("Add a photo?", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(
                "Auto-skipping in ${remaining}s",
                fontSize = 14.sp,
                color = vine.textSecondary,
            )
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedButton(
                    onClick = { if (!responded) { responded = true; onSkip() } },
                    modifier = Modifier.weight(1f),
                ) { Text("Skip") }
                Button(
                    onClick = { if (!responded) { responded = true; onTakePhoto() } },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                ) {
                    Icon(Icons.Filled.PhotoCamera, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Take Photo")
                }
            }
        }
    }
}

/**
 * iOS PinDropView parity — a quick-action category launcher. Shows a Repairs /
 * Growth toggle and a 2-column grid of large colour-coded category buttons with
 * LEFT / RIGHT columns. Tapping a category opens the shared pin create sheet
 * pre-filled with the chosen mode, category and side. The Observations list
 * (PinsScreen) remains the place to review, edit, complete and delete pins.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PinCategoryLauncherScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    initialMode: String = "Repairs",
    onBack: () -> Unit,
    onOpenList: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    var mode by rememberSaveable { mutableStateOf(if (initialMode == "Growth") "Growth" else "Repairs") }
    var editing by remember { mutableStateOf<PinEditTarget?>(null) }
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    var showGrowthStageSheet by remember { mutableStateOf(false) }
    var showEditButtons by remember { mutableStateOf(false) }
    var showTemplates by remember { mutableStateOf(false) }
    var locating by remember { mutableStateOf(false) }
    val vineyardName = state.selectedVineyard?.name?.takeIf { it.isNotBlank() } ?: "Vineyard"

    // Quick-pin workflow state (iOS RepairsGrowthView parity).
    // Pending duplicate confirmation sheet for a quick-tapped pin.
    var duplicatePrompt by remember { mutableStateOf<PendingPinDuplicate?>(null) }
    // Floating success card shown after a quick pin is dropped (auto-dismisses).
    var successToast by remember { mutableStateOf<QuickPinToast?>(null) }
    // The freshly-created pin awaiting the optional "Add a photo?" prompt.
    var autoPhotoPin by remember { mutableStateOf<Pin?>(null) }
    var showAutoPhoto by remember { mutableStateOf(false) }

    // Category pending a GPS fix / permission decision before creation.
    var pendingSelection by remember { mutableStateOf<Pair<String, String>?>(null) }

    // Auto-dismiss the success card after a short moment, like the iOS toast.
    LaunchedEffect(successToast) {
        if (successToast != null) {
            delay(2800)
            successToast = null
        }
    }

    // Photo picker for the optional auto-photo prompt. Reuses the existing
    // pin-photo upload / pending-photo queue via [attachQuickPinPhoto].
    val autoPhotoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri: Uri? ->
        val pin = autoPhotoPin
        autoPhotoPin = null
        if (uri != null && pin != null) {
            vm.attachQuickPinPhoto(pin, uri) { ok ->
                scope.launch {
                    snackbarHostState.showSnackbar(if (ok) "Photo added to pin" else "Couldn't add the photo")
                }
            }
        }
    }

    /**
     * Quick-create a pin for [category]/[side] at a real GPS [loc], reusing the
     * existing row/path snapping ([RowAttachment]), duplicate detection
     * ([PinDuplicateChecker]) and offline-safe create ([AppViewModel.createPin]).
     * No full form is shown for this common path.
     */
    fun quickCreate(category: String, side: String, loc: Pair<Double, Double>) {
        val lat = loc.first
        val lng = loc.second
        val paddock = state.paddocks.firstOrNull { RowAttachment.containsPoint(it, lat, lng) }
        val paddockId = paddock?.id
        val attachment = RowAttachment.resolve(paddock, lat, lng, side)
        val offline = !state.isOnline
        val autoPhotoEnabled = AppPreferencesStore(context).load().autoPhotoPrompt

        val doCreate: () -> Unit = {
            vm.createPin(
                title = category,
                mode = mode,
                category = category,
                notes = null,
                side = side,
                paddockId = paddockId,
                rowNumber = null,
                isCompleted = false,
                latitude = lat,
                longitude = lng,
                attachToRow = true,
                photoUri = null,
                onCreatedPin = { pin ->
                    successToast = QuickPinToast(
                        title = "$category pin dropped",
                        subtitle = quickPinSubtitle(side, attachment),
                        offline = offline,
                    )
                    if (autoPhotoEnabled) {
                        autoPhotoPin = pin
                        showAutoPhoto = true
                    }
                },
            ) { ok ->
                if (!ok) scope.launch { snackbarHostState.showSnackbar("Couldn't drop the pin. Please try again.") }
            }
        }

        // Preferred along-row duplicate using the snapped attachment, with the
        // conservative raw-distance fallback for legacy pins (unchanged algorithm).
        val alongRowDup = attachment?.let {
            PinDuplicateChecker.nearbyAlongRow(
                candidate = it,
                paddockId = paddockId,
                mode = mode,
                pins = state.pins,
            )
        }
        val duplicate = alongRowDup ?: PinDuplicateChecker.nearbyRawDistance(
            latitude = lat,
            longitude = lng,
            paddockId = paddockId,
            mode = mode,
            side = side,
            manualRowNumber = null,
            paddock = paddock,
            pins = state.pins,
        )
        if (duplicate != null) {
            duplicatePrompt = PendingPinDuplicate(
                existing = duplicate.pin,
                rowNumber = if (duplicate.alongRow) attachment?.pinRowNumber else null,
                side = if (duplicate.alongRow) {
                    attachment?.pinSide?.lowercase()?.takeIf { it == "left" || it == "right" }
                } else {
                    null
                },
                distanceM = duplicate.distanceM,
                alongRow = duplicate.alongRow,
                blockName = state.paddocks.firstOrNull { it.id == duplicate.pin.paddockId }?.name,
                onCreateAnyway = doCreate,
            )
        } else {
            doCreate()
        }
    }

    /** Open the full New Pin form for manual/custom creation (current [mode]). */
    fun openFullForm() {
        editing = PinEditTarget.New(mode = mode)
    }

    /** Quick-tap a category: capture a GPS fix, then quick-create or fall back. */
    fun launchCategory(category: String, side: String) {
        locating = true
        vm.fetchCurrentLocation { loc ->
            locating = false
            if (loc != null) {
                quickCreate(category, side, loc)
            } else {
                // Parity with iOS: a quick button never forces the full form.
                // Without a location we can't safely snap row/path, so we show a
                // calm message. The full New Pin form stays available from the
                // toolbar for manual block/coordinate entry.
                scope.launch {
                    snackbarHostState.showSnackbar("Location unavailable \u2014 enable location services to drop a pin.")
                }
            }
        }
    }

    val locationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { _ ->
        // Proceed regardless of the grant decision: with permission we capture a
        // GPS fix, without it we fall back to the paddock centroid.
        pendingSelection?.let { (cat, side) -> launchCategory(cat, side) }
        pendingSelection = null
    }

    /** Entry point for a category tap: ensure permission, then launch the sheet. */
    fun onCategoryTap(category: String, side: String) {
        if (vm.hasLocationPermission()) {
            launchCategory(category, side)
        } else {
            pendingSelection = category to side
            locationPermission.launch(
                arrayOf(
                    android.Manifest.permission.ACCESS_FINE_LOCATION,
                    android.Manifest.permission.ACCESS_COARSE_LOCATION,
                ),
            )
        }
    }

    Box(modifier = modifier) {
    Scaffold(
        containerColor = vine.appBackground,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(if (mode == "Repairs") "Repairs" else "Growth", fontWeight = FontWeight.Bold)
                        Text(vineyardName, fontSize = 12.sp, color = vine.textSecondary)
                    }
                },
                navigationIcon = { BackNavIcon(onBack) },
                actions = {
                    IconButton(onClick = { openFullForm() }) {
                        Icon(Icons.Filled.PostAdd, contentDescription = "New pin (full form)", tint = vine.textSecondary)
                    }
                    IconButton(onClick = onOpenList) {
                        Icon(Icons.Filled.LocationOn, contentDescription = "Observations list", tint = vine.textSecondary)
                    }
                    IconButton(onClick = { showEditButtons = true }) {
                        Icon(Icons.Filled.Tune, contentDescription = "Customise buttons", tint = vine.textSecondary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Repairs / Growth toggle.
            Row(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(vine.textSecondary.copy(alpha = 0.12f)).padding(4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                ModeToggleButton("Repairs", mode == "Repairs", Modifier.weight(1f)) { mode = "Repairs" }
                ModeToggleButton("Growth", mode == "Growth", Modifier.weight(1f)) { mode = "Growth" }
            }

            // Growth Stage full-width button (Growth mode only). Opens the
            // canonical E-L growth-stage authoring sheet (shared with the Growth
            // screen) rather than a generic Growth pin.
            if (mode == "Growth") {
                GrowthStageButton { showGrowthStageSheet = true }
            }

            // LEFT / RIGHT column labels.
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("LEFT", fontSize = 11.sp, fontWeight = FontWeight.Black, color = vine.textSecondary, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                Text("RIGHT", fontSize = 11.sp, fontWeight = FontWeight.Black, color = vine.textSecondary, modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }

            // Prefer the vineyard's shared button configuration (synced with
            // iOS/portal); fall back to the built-in defaults when none exists.
            // Growth Stage buttons are excluded here — they have their own
            // dedicated full-width button above.
            val remoteButtons = if (mode == "Repairs") state.repairButtons else state.growthButtons
            val categories: List<PinCategory> = remoteButtons
                .filterNot { it.isGrowthStageButton }
                .distinctBy { it.name + "|" + it.color }
                .map { PinCategory(it.name, launcherColor(it.color)) }
                .ifEmpty { if (mode == "Repairs") repairCategories else growthCategories }
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxWidth().weight(1f),
            ) {
                Column(
                    modifier = Modifier.weight(1f).fillMaxHeight(),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    categories.forEach { cat ->
                        CategoryTile(cat, enabled = !locating, modifier = Modifier.weight(1f)) {
                            onCategoryTap(cat.name, "Left")
                        }
                    }
                }
                Column(
                    modifier = Modifier.weight(1f).fillMaxHeight(),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    categories.forEach { cat ->
                        CategoryTile(cat, enabled = !locating, modifier = Modifier.weight(1f)) {
                            onCategoryTap(cat.name, "Right")
                        }
                    }
                }
            }
        }
    }

        // Floating success card (iOS pin-dropped toast parity), above content.
        successToast?.let { toast ->
            QuickPinSuccessToast(
                toast = toast,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 16.dp, vertical = 24.dp),
            )
        }
    }

    val target = editing
    if (target != null) {
        PinEditSheetHost(
            vm, state, target,
            onDismiss = { editing = null },
            onConfirmation = { msg -> scope.launch { snackbarHostState.showSnackbar(msg) } },
        )
    }

    if (showGrowthStageSheet) {
        GrowthSheet(
            vm = vm,
            state = state,
            existing = null,
            onDismiss = { showGrowthStageSheet = false },
            onSaved = { showGrowthStageSheet = false },
        )
    }

    if (showEditButtons) {
        EditLauncherButtonsSheet(
            vm = vm,
            state = state,
            mode = mode,
            onDismiss = { showEditButtons = false },
            onOpenTemplates = {
                showEditButtons = false
                showTemplates = true
            },
        )
    }

    if (showTemplates) {
        ButtonTemplatesSheet(
            vm = vm,
            state = state,
            mode = mode,
            onDismiss = { showTemplates = false },
        )
    }

    // Duplicate-warning bottom sheet for a quick-tapped pin (iOS parity).
    duplicatePrompt?.let { dup ->
        QuickPinDuplicateSheet(
            duplicate = dup,
            onDismiss = { duplicatePrompt = null },
            onCreateAnyway = {
                duplicatePrompt = null
                dup.onCreateAnyway()
            },
        )
    }

    // Optional "Add a photo?" prompt after a successful quick pin (3s auto-skip).
    if (showAutoPhoto) {
        AutoPhotoPromptSheet(
            onSkip = {
                showAutoPhoto = false
                autoPhotoPin = null
            },
            onTakePhoto = {
                showAutoPhoto = false
                autoPhotoPicker.launch(
                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                )
            },
        )
    }
}

/** A single editable launcher row (paired Left/Right on save). */
private data class ButtonRowDraft(
    val name: String,
    val color: String,
    val isGrowthStage: Boolean,
)

/** iOS-parity built-in defaults, mirroring `ButtonConfig.default*Buttons`. */
private fun defaultButtonDrafts(mode: String): List<ButtonRowDraft> =
    if (mode == "Growth") {
        listOf(
            ButtonRowDraft("Growth Stage", "darkgreen", true),
            ButtonRowDraft("Powdery", "gray", false),
            ButtonRowDraft("Downy", "yellow", false),
            ButtonRowDraft("Blackberries", "red", false),
        )
    } else {
        listOf(
            ButtonRowDraft("Irrigation", "blue", false),
            ButtonRowDraft("Broken Post", "brown", false),
            ButtonRowDraft("Vine Issue", "green", false),
            ButtonRowDraft("Other", "red", false),
        )
    }

/** Build the first-four draft rows from the current synced config (or defaults). */
private fun draftsFromConfig(mode: String, buttons: List<LauncherButton>): List<ButtonRowDraft> {
    val sorted = buttons.sortedBy { it.index }.take(4)
    if (sorted.isEmpty()) return defaultButtonDrafts(mode)
    val fallback = defaultButtonDrafts(mode)
    return (0 until 4).map { i ->
        val b = sorted.getOrNull(i)
        if (b != null) {
            ButtonRowDraft(b.name, b.color.ifBlank { fallback[i].color }, b.isGrowthStageButton)
        } else {
            fallback[i]
        }
    }
}

/**
 * iOS `EditButtonsSheet` parity for Android: edit the four Repairs/Growth launcher
 * rows (paired Left & Right) for the selected vineyard. Owners/managers can rename,
 * recolour, toggle the Growth Stage row (Growth mode) and reset to defaults; the
 * config is saved to the shared `vineyard_button_configs` contract and re-read so
 * iOS stays canonical. Other members see a read-only view.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EditLauncherButtonsSheet(
    vm: AppViewModel,
    state: AppUiState,
    mode: String,
    onDismiss: () -> Unit,
    onOpenTemplates: () -> Unit,
) {
    val vine = LocalVineColors.current
    val canEdit = state.canEditLauncherButtons
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val source = if (mode == "Repairs") state.repairButtons else state.growthButtons
    var rows by remember(mode, source) { mutableStateOf(draftsFromConfig(mode, source)) }
    var expandedColorIndex by remember { mutableStateOf<Int?>(null) }

    val colorTokens = rows.map { it.color.lowercase() }
    val hasDuplicateColors = colorTokens.toSet().size != colorTokens.size
    val allNamed = rows.all { it.name.trim().isNotEmpty() }
    val canSave = canEdit && !hasDuplicateColors && allNamed && !state.buttonConfigBusy

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState, containerColor = vine.cardBackground) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "Edit ${if (mode == "Growth") "Growth" else "Repairs"} Buttons",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )
            Text(
                "Four rows, each shown on both the Left and Right columns. Changes sync to iOS and the web portal.",
                fontSize = 13.sp,
                color = vine.textSecondary,
            )

            if (!canEdit) {
                Text(
                    "Only vineyard owners and managers can customise these buttons.",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textSecondary,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(vine.textSecondary.copy(alpha = 0.10f))
                        .padding(12.dp),
                )
            }

            rows.forEachIndexed { index, row ->
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box(
                            modifier = Modifier
                                .size(32.dp)
                                .clip(CircleShape)
                                .background(launcherColor(row.color))
                                .then(
                                    if (canEdit) Modifier.clickable {
                                        expandedColorIndex = if (expandedColorIndex == index) null else index
                                    } else Modifier,
                                ),
                        )
                        OutlinedTextField(
                            value = row.name,
                            onValueChange = { v -> rows = rows.toMutableList().also { it[index] = row.copy(name = v) } },
                            enabled = canEdit,
                            singleLine = true,
                            label = { Text("Row ${index + 1}") },
                            modifier = Modifier.weight(1f),
                        )
                        if (mode == "Growth") {
                            IconButton(
                                enabled = canEdit,
                                onClick = { rows = rows.toMutableList().also { it[index] = row.copy(isGrowthStage = !row.isGrowthStage) } },
                            ) {
                                Icon(
                                    Icons.Filled.Grass,
                                    contentDescription = "Growth Stage button",
                                    tint = if (row.isGrowthStage) VineColors.LeafGreen else vine.textSecondary,
                                )
                            }
                        }
                    }
                    if (expandedColorIndex == index && canEdit) {
                        val used = rows.filterIndexed { i, r -> i != index }.map { it.color.lowercase() }.toSet()
                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            launcherColorTokens.forEach { token ->
                                val isUsed = used.contains(token)
                                Box(
                                    modifier = Modifier
                                        .size(28.dp)
                                        .clip(CircleShape)
                                        .background(launcherColor(token).copy(alpha = if (isUsed) 0.3f else 1f))
                                        .then(
                                            if (!isUsed) Modifier.clickable {
                                                rows = rows.toMutableList().also { it[index] = row.copy(color = token) }
                                                expandedColorIndex = null
                                            } else Modifier,
                                        ),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (row.color.equals(token, ignoreCase = true)) {
                                        Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (hasDuplicateColors) {
                Text("Each button must use a different colour.", fontSize = 12.sp, color = VineColors.Destructive)
            } else if (!allNamed) {
                Text("Every button needs a name.", fontSize = 12.sp, color = VineColors.Destructive)
            }
            state.buttonConfigError?.let { err ->
                Text(err, fontSize = 12.sp, color = VineColors.Destructive)
            }

            OutlinedButton(
                onClick = onOpenTemplates,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Filled.GridView, contentDescription = null, modifier = Modifier.size(18.dp))
                Box(Modifier.size(6.dp))
                Text("${if (mode == "Growth") "Growth" else "Repairs"} Templates")
            }

            if (canEdit) {
                TextButton(
                    onClick = { rows = defaultButtonDrafts(mode); expandedColorIndex = null },
                    enabled = !state.buttonConfigBusy,
                ) { Text("Reset to defaults") }

                Button(
                    onClick = {
                        val payload = buildList {
                            rows.forEachIndexed { i, r ->
                                val name = r.name.trim()
                                add(LauncherButton(name = name, color = r.color, index = i, mode = mode, isGrowthStageButton = r.isGrowthStage))
                                add(LauncherButton(name = name, color = r.color, index = i + 4, mode = mode, isGrowthStageButton = r.isGrowthStage))
                            }
                        }
                        vm.saveLauncherButtons(mode, payload) { ok -> if (ok) onDismiss() }
                    },
                    enabled = canSave,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                ) {
                    if (state.buttonConfigBusy) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
                    } else {
                        Text("Save")
                    }
                }
            }
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text(if (canEdit) "Cancel" else "Close") }
        }
    }
}

private data class PinCategory(val name: String, val color: Color)

private val repairCategories = listOf(
    PinCategory("Irrigation", VineColors.Primary),
    PinCategory("Broken Post", VineColors.EarthBrown),
    PinCategory("Vine Issue", VineColors.LeafGreen),
    PinCategory("Other", VineColors.Destructive),
)

private val growthCategories = listOf(
    PinCategory("Powdery", Color(0xFF8E8E93)),
    PinCategory("Downy", Color(0xFFE6B800)),
    PinCategory("Blackberries", VineColors.Destructive),
)

@Composable
private fun ModeToggleButton(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(9.dp))
            .background(if (selected) VineColors.Primary else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (selected) Color.White else LocalVineColors.current.textSecondary,
        )
    }
}

@Composable
private fun GrowthStageButton(onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(VineColors.DarkGreen)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.Grass, contentDescription = null, tint = Color.White)
        Column(modifier = Modifier.weight(1f)) {
            Text("Growth Stage", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White)
            Text("Record the current E-L stage", fontSize = 12.sp, color = Color.White.copy(alpha = 0.9f))
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Color.White.copy(alpha = 0.85f))
    }
}

@Composable
private fun CategoryTile(
    category: PinCategory,
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val light = category.color.luminance() > 0.6f
    val fg = if (light) Color.Black else Color.White
    Column(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 80.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(category.color)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(10.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Filled.LocationOn, contentDescription = null, tint = fg)
        Text(
            category.name,
            fontSize = 16.sp,
            fontWeight = FontWeight.Black,
            color = fg,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            maxLines = 2,
        )
    }
}

/** Centroid of the selected paddock, falling back to the vineyard coordinate. */
private fun defaultLocation(paddockId: String?, state: AppUiState): Pair<Double, Double>? {
    val paddock = state.paddocks.firstOrNull { it.id == paddockId }
    val points = paddock?.polygonPoints
    if (!points.isNullOrEmpty()) {
        val lat = points.sumOf { it.latitude } / points.size
        val lon = points.sumOf { it.longitude } / points.size
        return lat to lon
    }
    val v = state.selectedVineyard
    val lat = v?.latitude
    val lon = v?.longitude
    return if (lat != null && lon != null) lat to lon else null
}

@Composable
private fun PinRow(
    vm: AppViewModel,
    pin: Pin,
    color: Color,
    paddockName: String?,
    userLocation: Pair<Double, Double>?,
    sync: PinSyncState,
    photoBusy: Boolean,
    onClick: () -> Unit,
    onToggle: () -> Unit,
    onMap: () -> Unit,
    onDirections: () -> Unit,
    onPhoto: () -> Unit,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    // Foreground colour that reads on the coloured header bar.
    val onColor = if (color.luminance() > 0.6f) Color.Black else Color.White
    VineyardCard {
        Column(
            modifier = Modifier.alpha(if (pin.isCompleted) 0.7f else 1f),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // Coloured header bar in the pin's actual colour (iOS PinRowView parity).
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(color)
                    .clickable(onClick = onClick)
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (pin.hasPhoto) {
                    PinRowThumbnail(vm = vm, photoPath = pin.photoPath, tint = onColor)
                }
                if (pin.isCompleted) {
                    Icon(Icons.Filled.Check, contentDescription = "Completed", tint = onColor, modifier = Modifier.size(18.dp))
                }
                Text(
                    pin.displayTitle,
                    fontWeight = FontWeight.Bold,
                    fontSize = 16.sp,
                    color = onColor,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                // Sync status tick, mirroring the iOS RecordSyncBadge in the
                // coloured header bar.
                PinHeaderSyncIcon(sync = sync, tint = onColor)
                Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = onColor.copy(alpha = 0.8f), modifier = Modifier.size(18.dp))
            }

            // Structured detail lines mirroring iOS PinRowView:
            //  1. "Row 14.5 — Right hand side facing North"
            //  2. "<Block> row 14.5"
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(pinFacingLine(pin), fontSize = 14.sp, color = vine.textPrimary)
                Text(pinBlockRowLine(pin, paddockName), fontSize = 12.sp, color = vine.textSecondary)
                if (!pin.notes.isNullOrBlank()) {
                    Text(pin.notes, fontSize = 13.sp, color = vine.textSecondary, maxLines = 3)
                }
            }

            // Metadata row: distance · bearing · created date+time (iOS InfoTag
            // parity). Each tag sizes to its content with flexible spacers between,
            // matching the iOS HStack(spacing:0)+Spacer layout so the full date and
            // time string is never clipped.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PinInfoTag(Icons.Filled.NearMe, pinDistanceText(pin, userLocation))
                Spacer(Modifier.weight(1f))
                PinInfoTag(Icons.Filled.Explore, pinBearingText(pin))
                Spacer(Modifier.weight(1f))
                PinInfoTag(Icons.Filled.Schedule, pinCreatedText(pin))
            }

            // Sync-only badges. The Repairs/Growth and Open/Done bubbles were
            // removed (their meaning is already conveyed by the header colour,
            // the completion tick and the filter bar). This row only surfaces an
            // unsynced/blocked state, so it collapses to nothing when synced.
            if (sync.hasAny) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    if ((sync.pendingCreate || sync.pendingCompletion) && !sync.needsAttention) StatusBadge("Pending sync", VineColors.Warning)
                    if (sync.pendingPhoto && !sync.needsAttention) StatusBadge("Photo waiting", VineColors.Warning)
                    if (sync.needsAttention) StatusBadge("Needs attention", VineColors.Destructive)
                }
            }

            // Per-pin quick actions, evenly distributed so the row aligns (iOS parity).
            Row(modifier = Modifier.fillMaxWidth()) {
                PinActionButton(Icons.Filled.Map, "Map", VineColors.Primary, modifier = Modifier.weight(1f), onClick = onMap)
                PinActionButton(Icons.Filled.Directions, "Directions", VineColors.LeafGreen, modifier = Modifier.weight(1f), onClick = onDirections)
                PinActionButton(Icons.Filled.PhotoCamera, "Photo", VineColors.Purple, modifier = Modifier.weight(1f), busy = photoBusy, onClick = onPhoto)
                PinActionButton(
                    icon = Icons.Filled.CheckCircle,
                    label = if (pin.isCompleted) "Undo" else "Complete",
                    color = if (pin.isCompleted) VineColors.Warning else VineColors.Success,
                    modifier = Modifier.weight(1f),
                    onClick = onToggle,
                )
                PinActionButton(Icons.Filled.Delete, "Delete", VineColors.Destructive, modifier = Modifier.weight(1f), onClick = onDelete)
            }
        }
    }
}

/**
 * Small leading photo thumbnail shown in a pin list row's coloured header bar
 * (iOS PinRowView parity). Loads the signed URL on demand and shows a calm
 * fallback glyph while loading or when the photo can't be fetched (e.g.
 * offline). Display-only — it never mutates the photo queue or triggers retries.
 */
@Composable
private fun PinRowThumbnail(vm: AppViewModel, photoPath: String?, tint: Color) {
    var signedUrl by remember(photoPath) { mutableStateOf<String?>(null) }
    var unavailable by remember(photoPath) { mutableStateOf(false) }
    LaunchedEffect(photoPath) {
        signedUrl = null
        unavailable = false
        if (!photoPath.isNullOrBlank()) {
            vm.requestPinPhotoUrl(photoPath) { url ->
                signedUrl = url
                unavailable = url.isNullOrBlank()
            }
        }
    }
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(tint.copy(alpha = 0.18f)),
        contentAlignment = Alignment.Center,
    ) {
        val url = signedUrl
        when {
            url != null -> AsyncImage(
                model = url,
                contentDescription = "Pin photo",
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            unavailable || photoPath.isNullOrBlank() -> Icon(
                Icons.Filled.Photo,
                contentDescription = "Photo",
                tint = tint.copy(alpha = 0.85f),
                modifier = Modifier.size(16.dp),
            )
            else -> CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                strokeWidth = 2.dp,
                color = tint.copy(alpha = 0.85f),
            )
        }
    }
}

/**
 * Small sync-state tick shown in a pin row's coloured header bar (iOS
 * RecordSyncBadge parity): a synced tick when everything is up to date, a queued
 * glyph while waiting, and a warning glyph when something needs attention.
 */
@Composable
private fun PinHeaderSyncIcon(sync: PinSyncState, tint: Color) {
    val (icon, desc) = when {
        sync.needsAttention -> Icons.Filled.ErrorOutline to "Needs attention"
        sync.hasAny -> Icons.Filled.CloudQueue to "Waiting to sync"
        else -> Icons.Filled.CloudDone to "Synced"
    }
    Icon(
        icon,
        contentDescription = desc,
        tint = if (sync.needsAttention) tint else tint.copy(alpha = 0.85f),
        modifier = Modifier.size(17.dp),
    )
}

/** Compact icon+label quick-action button used in the Pins list rows (iOS ActionButton parity). */
@Composable
private fun PinActionButton(
    icon: ImageVector,
    label: String,
    color: Color,
    modifier: Modifier = Modifier,
    busy: Boolean = false,
    onClick: () -> Unit,
) {
    Column(
        modifier = modifier
            .padding(horizontal = 3.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(color.copy(alpha = 0.1f))
            .clickable(enabled = !busy, onClick = onClick)
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        if (busy) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), color = color, strokeWidth = 2.dp)
        } else {
            Icon(icon, contentDescription = label, tint = color, modifier = Modifier.size(18.dp))
        }
        Text(label, fontSize = 9.sp, fontWeight = FontWeight.Medium, color = color)
    }
}

/** Small icon + value metadata tag used in the pin row's distance/bearing/date line. */
@Composable
private fun PinInfoTag(
    icon: ImageVector,
    text: String,
    modifier: Modifier = Modifier,
    center: Boolean = false,
    end: Boolean = false,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = modifier,
        horizontalArrangement = when {
            end -> Arrangement.End
            center -> Arrangement.Center
            else -> Arrangement.Start
        },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(13.dp))
        Spacer(Modifier.size(4.dp))
        Text(text, fontSize = 12.sp, color = vine.textSecondary, maxLines = 1)
    }
}

/** Eight-point compass abbreviation for a heading in degrees (337.5–22.5 → "N"). */
private fun compassAbbrev(heading: Double): String {
    val n = ((heading % 360) + 360) % 360
    return when {
        n >= 337.5 || n < 22.5 -> "N"
        n < 67.5 -> "NE"
        n < 112.5 -> "E"
        n < 157.5 -> "SE"
        n < 202.5 -> "S"
        n < 247.5 -> "SW"
        n < 292.5 -> "W"
        else -> "NW"
    }
}

/** Full compass name for a heading in degrees (45 → "Northeast"), mirroring iOS. */
private fun compassFullName(heading: Double): String {
    val n = ((heading % 360) + 360) % 360
    return when {
        n >= 337.5 || n < 22.5 -> "North"
        n < 67.5 -> "Northeast"
        n < 112.5 -> "East"
        n < 157.5 -> "Southeast"
        n < 202.5 -> "South"
        n < 247.5 -> "Southwest"
        n < 292.5 -> "West"
        else -> "Northwest"
    }
}

/** Trim a row number, keeping fractional values (14.5) and whole ones (15). */
private fun rowText(row: Double): String =
    if (row % 1.0 == 0.0) row.toInt().toString() else row.toString()

/**
 * Primary detail line, e.g. "Row 14.5 — Right hand side facing North".
 * Falls back gracefully when the driving path or heading aren't recorded.
 */
private fun pinFacingLine(pin: Pin): String {
    val side = (pin.pinSide ?: pin.side)?.lowercase()?.let {
        when (it) { "left" -> "Left"; "right" -> "Right"; else -> null }
    }
    val sidePart = side?.let { "$it hand side" }
    val facingPart = pin.heading?.let { "facing ${compassFullName(it)}" }
    val drivingRow = pin.drivingRowNumber ?: pin.rowNumber?.let { it + 0.5 }
    val tail = listOfNotNull(sidePart, facingPart).joinToString(" ")
    return when {
        drivingRow != null && tail.isNotBlank() -> "Row ${rowText(drivingRow)} — $tail"
        drivingRow != null -> "Row ${rowText(drivingRow)}"
        tail.isNotBlank() -> tail
        else -> "Location not snapped to a row"
    }
}

/** Secondary line, e.g. "Pinot Noir row 14.5" — block name plus the attached row. */
private fun pinBlockRowLine(pin: Pin, paddockName: String?): String {
    val block = paddockName?.takeIf { it.isNotBlank() }
    val row = pin.pinRowNumber ?: pin.rowNumber?.toDouble()
    return when {
        block != null && row != null -> "$block row ${rowText(row)}"
        block != null -> block
        row != null -> "Row ${rowText(row)}"
        else -> "Unassigned block"
    }
}

/**
 * Distance from the current GPS fix to the pin, formatted for the device's
 * locale (iOS RegionFormatter.formatShortDistance parity): metres/kilometres in
 * metric locales, feet/miles in imperial ones (US/Liberia/Myanmar). Returns "—"
 * when there's no fix or the pin has no coordinates.
 */
private fun pinDistanceText(pin: Pin, userLocation: Pair<Double, Double>?): String {
    val lat = pin.latitude
    val lon = pin.longitude
    if (userLocation == null || lat == null || lon == null) return "—"
    val metres = haversineMetres(userLocation.first, userLocation.second, lat, lon)
    return formatShortDistance(metres)
}

/** True when the device locale uses imperial distance units. */
private fun usesImperialDistance(): Boolean =
    when (java.util.Locale.getDefault().country.uppercase(java.util.Locale.ROOT)) {
        "US", "LR", "MM" -> true
        else -> false
    }

/** Short navigation-style distance honouring the device's measurement system. */
private fun formatShortDistance(metres: Double): String {
    if (usesImperialDistance()) {
        val feet = metres * 3.280839895
        return if (feet < 5280) "${feet.roundToInt()}ft"
        else "${"%.1f".format(metres / 1000.0 * 0.621371)}mi"
    }
    return if (metres < 1000) "${metres.roundToInt()}m"
    else "${"%.1f".format(metres / 1000.0)}km"
}

/** Bearing tag, e.g. "N (351°)", or "—" when no heading was captured. */
private fun pinBearingText(pin: Pin): String {
    val h = pin.heading ?: return "—"
    return "${compassAbbrev(h)} (${h.roundToInt()}°)"
}

/** Created date/time, e.g. "05/05/2026 21:20", or "—" when unknown. */
private fun pinCreatedText(pin: Pin): String {
    val millis = parseIsoMillis(pin.createdAt) ?: return "—"
    return pinDateTimeFormat.format(java.util.Date(millis))
}

private val pinDateTimeFormat = java.text.SimpleDateFormat("dd/MM/yyyy HH:mm", java.util.Locale.getDefault())

/** Tolerant ISO-8601 parse returning epoch millis, or null. */
private fun parseIsoMillis(value: String?): Long? {
    if (value.isNullOrBlank()) return null
    return runCatching {
        java.time.OffsetDateTime.parse(value).toInstant().toEpochMilli()
    }.recoverCatching {
        java.time.LocalDateTime.parse(value).toInstant(java.time.ZoneOffset.UTC).toEpochMilli()
    }.getOrNull()
}

/** Great-circle distance between two lat/lon points in metres. */
private fun haversineMetres(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
    val r = 6_371_000.0
    val dLat = Math.toRadians(lat2 - lat1)
    val dLon = Math.toRadians(lon2 - lon1)
    val a = kotlin.math.sin(dLat / 2).let { it * it } +
        kotlin.math.cos(Math.toRadians(lat1)) * kotlin.math.cos(Math.toRadians(lat2)) *
        kotlin.math.sin(dLon / 2).let { it * it }
    return r * 2 * kotlin.math.atan2(kotlin.math.sqrt(a), kotlin.math.sqrt(1 - a))
}

private sealed interface PinEditTarget {
    data class New(
        val mode: String,
        val category: String? = null,
        val side: String? = null,
        val titleDefault: String? = null,
        /** GPS fix captured at launch time; null falls back to paddock centroid. */
        val latitude: Double? = null,
        val longitude: Double? = null,
    ) : PinEditTarget
    data class Existing(val pin: Pin) : PinEditTarget
}

/** Mode-specific glyph for a pin's stored `mode` raw value. */
private fun pinModeIcon(mode: String?): ImageVector =
    if (mode?.contains("growth", ignoreCase = true) == true) Icons.Filled.Grass else Icons.Filled.Build

/** Large colour-coded entry card that opens the create sheet with a preset mode. */
@Composable
private fun PinModeEntryCard(
    title: String,
    subtitle: String,
    icon: ImageVector,
    color: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(color)
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier.size(40.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.22f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = Color.White)
        }
        Text(title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color.White)
        Text(subtitle, fontSize = 12.sp, color = Color.White.copy(alpha = 0.9f))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PinModeFilterChip(label: String, selected: Boolean, accent: Color, onClick: () -> Unit) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(label) },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = accent.copy(alpha = 0.18f),
            selectedLabelColor = accent,
        ),
    )
}

/**
 * Conservative status banner shown on the pin edit sheet when a pin is saved
 * locally but not yet fully synced, or its photo is still waiting / blocked.
 * Display-only and matches the Sync Status wording; it never offers retry
 * controls and gently warns against relying on offline edit/delete for an
 * unsynced pin.
 */
@Composable
private fun PinSyncBanner(sync: PinSyncState) {
    val vine = LocalVineColors.current
    val accent = if (sync.needsAttention) VineColors.Destructive else VineColors.Warning
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(accent.copy(alpha = 0.12f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (sync.pendingCreate) {
            Text("Pending sync", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = accent)
            Text(
                "This pin is saved on this device and will sync when you reconnect. Editing or deleting it works best once it has synced.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
        }
        if (sync.pendingCompletion && !sync.pendingCreate && !sync.needsAttention) {
            Text("Pending sync", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = accent)
            Text(
                "This pin's Done/Open change is saved on this device and will sync when you reconnect.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
        }
        if (sync.pendingPhoto && !sync.needsAttention) {
            Text("Photo waiting to upload", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = accent)
            Text(
                "The photo for this pin is saved on this device and uploads automatically once the pin has synced.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
        }
        if (sync.needsAttention) {
            Text("Needs attention", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = accent)
            Text(
                "Something is preventing this pin from finishing sync. It will keep trying when you have a connection.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )
        }
    }
}

private data class PinFields(
    val title: String,
    val mode: String,
    val category: String?,
    val notes: String?,
    val side: String?,
    val paddockId: String?,
    val rowNumber: Int?,
    val isCompleted: Boolean,
)

private val pinModes = listOf("Repairs", "Growth")

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PinEditSheet(
    vm: AppViewModel,
    state: AppUiState,
    target: PinEditTarget,
    paddocks: List<Paddock>,
    onDismiss: () -> Unit,
    onSave: (PinFields, Uri?, (Boolean) -> Unit) -> Unit,
    onDelete: ((Boolean) -> Unit) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    // Re-read the live pin so the photo section reflects uploads/removals.
    val existing = (target as? PinEditTarget.Existing)?.let { t ->
        state.pins.firstOrNull { it.id == t.pin.id } ?: t.pin
    }

    val newTarget = target as? PinEditTarget.New
    val initialMode = newTarget?.mode ?: "Repairs"
    var title by remember { mutableStateOf(existing?.title ?: newTarget?.titleDefault ?: newTarget?.category ?: "") }
    var mode by remember { mutableStateOf(existing?.mode?.takeIf { it in pinModes } ?: initialMode) }
    var category by remember { mutableStateOf(existing?.category ?: newTarget?.category ?: "") }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    // Side persists to pins.side. Seeded from the launcher column or the live pin.
    var side by remember { mutableStateOf(existing?.side ?: newTarget?.side) }
    var paddockId by remember { mutableStateOf(existing?.paddockId) }
    var rowText by remember { mutableStateOf(existing?.rowNumber?.toString() ?: "") }
    var isCompleted by remember { mutableStateOf(existing?.isCompleted ?: false) }
    var saving by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var paddockMenu by remember { mutableStateOf(false) }
    // Photo selected for a brand-new pin (uploaded after the pin is created).
    var pendingPhotoUri by remember { mutableStateOf<Uri?>(null) }

    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        if (existing != null) {
            vm.uploadPinPhoto(existing, uri) {}
        } else {
            pendingPhotoUri = uri
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                if (existing == null) "New pin" else "Edit pin",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = vine.textPrimary,
            )

            existing?.let { ex ->
                val sync = state.pinSyncState(ex.id)
                if (sync.hasAny) PinSyncBanner(sync)
            }

            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text("Title") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            // Mode selector
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Type", fontSize = 13.sp, color = vine.textSecondary)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    pinModes.forEach { option ->
                        val accent = pinModeColor(option)
                        FilterChip(
                            selected = mode == option,
                            onClick = { mode = option },
                            label = { Text(option) },
                            leadingIcon = {
                                Icon(pinModeIcon(option), contentDescription = null, modifier = Modifier.size(18.dp))
                            },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = accent.copy(alpha = 0.18f),
                                selectedLabelColor = accent,
                                selectedLeadingIconColor = accent,
                            ),
                        )
                    }
                }
            }

            OutlinedTextField(
                value = category,
                onValueChange = { category = it },
                label = { Text("Category (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            // Paddock dropdown
            ExposedDropdownMenuBox(
                expanded = paddockMenu,
                onExpandedChange = { paddockMenu = it },
            ) {
                OutlinedTextField(
                    value = paddocks.firstOrNull { it.id == paddockId }?.name ?: "None",
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Block") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = paddockMenu) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                )
                ExposedDropdownMenu(expanded = paddockMenu, onDismissRequest = { paddockMenu = false }) {
                    DropdownMenuItem(text = { Text("None") }, onClick = { paddockId = null; paddockMenu = false })
                    paddocks.forEach { p ->
                        DropdownMenuItem(text = { Text(p.name) }, onClick = { paddockId = p.id; paddockMenu = false })
                    }
                }
            }

            OutlinedTextField(
                value = rowText,
                onValueChange = { v -> rowText = v.filter { it.isDigit() } },
                label = { Text("Row number (optional)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
            )

            // Read-only row-attachment summary when the pin snapped to a mapped row.
            existing?.rowAttachmentLabel?.let { label ->
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(
                            Icons.Filled.Grass,
                            contentDescription = null,
                            tint = VineColors.LeafGreen,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(label, fontSize = 13.sp, color = vine.textSecondary)
                    }
                    existing.rowAttachmentDetail?.let { detail ->
                        Text(
                            detail,
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                            modifier = Modifier.padding(start = 22.dp),
                        )
                    }
                }
            }

            // Left / Right / None side selector — persists to pins.side.
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Side", fontSize = 13.sp, color = vine.textSecondary)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("Left", "Right", "None").forEach { option ->
                        val isSelected = (side ?: "None") == option
                        FilterChip(
                            selected = isSelected,
                            onClick = { side = if (option == "None") null else option },
                            label = { Text(option) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = VineColors.Primary.copy(alpha = 0.18f),
                                selectedLabelColor = VineColors.Primary,
                            ),
                        )
                    }
                }
            }

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes") },
                modifier = Modifier.fillMaxWidth().height(110.dp),
            )

            PinPhotoSection(
                vm = vm,
                pin = existing,
                pendingPhotoUri = pendingPhotoUri,
                busy = state.pinPhotoBusy,
                onPick = {
                    photoPicker.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                    )
                },
                onRemove = {
                    if (existing != null) vm.removePinPhoto(existing) {} else pendingPhotoUri = null
                },
            )

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Switch(checked = isCompleted, onCheckedChange = { isCompleted = it })
                Text("Completed", color = vine.textPrimary)
            }

            Button(
                onClick = {
                    saving = true
                    onSave(
                        PinFields(
                            title = title.trim(),
                            mode = mode,
                            category = category.trim().ifBlank { null },
                            notes = notes.trim().ifBlank { null },
                            side = side,
                            paddockId = paddockId,
                            rowNumber = rowText.toIntOrNull(),
                            isCompleted = isCompleted,
                        ),
                        pendingPhotoUri,
                    ) { saving = false }
                },
                enabled = !saving && title.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.PrimaryAccent),
            ) {
                Text(if (existing == null) "Add pin" else "Save changes")
            }

            if (existing != null) {
                TextButton(
                    onClick = { confirmDelete = true },
                    enabled = !saving,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive)
                    Text("  Delete pin", color = VineColors.Destructive)
                }
            }
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete pin?") },
            text = { Text("This removes the pin for your whole team. This can't be undone here.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    saving = true
                    onDelete { saving = false }
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = {
                TextButton(onClick = { confirmDelete = false }) { Text("Cancel") }
            },
        )
    }
}

/**
 * Photo attachment for a pin. Shows the synced photo (existing pin) or the
 * locally picked image (new pin), an add/replace action, a remove action, and
 * an upload progress overlay. One photo per pin, matching the shared
 * `vineyard-pin-photos` storage pattern used by iOS and the web portal.
 */
@Composable
private fun PinPhotoSection(
    vm: AppViewModel,
    pin: Pin?,
    pendingPhotoUri: Uri?,
    busy: Boolean,
    onPick: () -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    val photoPath = pin?.photoPath
    var signedUrl by remember(photoPath) { mutableStateOf<String?>(null) }
    // Whether the signed-URL request has finished without producing a URL
    // (offline, or a transient sign failure). Lets the UI show a calm
    // "unavailable offline" note instead of an endless spinner. Display-only:
    // it changes no upload/retry/storage behaviour.
    var photoUnavailable by remember(photoPath) { mutableStateOf(false) }

    LaunchedEffect(photoPath) {
        signedUrl = null
        photoUnavailable = false
        if (!photoPath.isNullOrBlank()) {
            vm.requestPinPhotoUrl(photoPath) { url ->
                signedUrl = url
                photoUnavailable = url.isNullOrBlank()
            }
        }
    }

    val hasImage = pendingPhotoUri != null || !photoPath.isNullOrBlank()

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Photo", fontSize = 13.sp, color = vine.textSecondary)

        if (hasImage) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(4f / 3f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(vine.textSecondary.copy(alpha = 0.1f)),
                contentAlignment = Alignment.Center,
            ) {
                val model: Any? = pendingPhotoUri ?: signedUrl
                if (model != null) {
                    AsyncImage(
                        model = model,
                        contentDescription = "Pin photo",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxWidth().aspectRatio(4f / 3f),
                    )
                } else if (photoUnavailable) {
                    Text(
                        "Photo unavailable offline",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                } else {
                    CircularProgressIndicator(color = VineColors.PrimaryAccent)
                }
                if (busy) {
                    Box(
                        modifier = Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.35f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(color = androidx.compose.ui.graphics.Color.White)
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onPick, enabled = !busy, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Filled.PhotoCamera, contentDescription = null)
                    Text("  Replace")
                }
                TextButton(onClick = onRemove, enabled = !busy) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive)
                    Text("  Remove", color = VineColors.Destructive)
                }
            }
        } else {
            OutlinedButton(
                onClick = onPick,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (busy) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), color = VineColors.PrimaryAccent)
                } else {
                    Icon(Icons.Outlined.AddAPhoto, contentDescription = null)
                    Text("  Add photo")
                }
            }
        }
    }
}

// MARK: Selected-pin detail sheet (map tap), iOS PinDetailSheet parity.

/**
 * Bottom sheet shown when a pin marker is tapped on the map (iOS
 * `PinDetailSheet` parity). The map stays visible behind it; the sheet shows
 * the pin's summary, quick actions, photo, notes and details. The full edit
 * form only opens from the explicit Edit action.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PinDetailSheet(
    vm: AppViewModel,
    pin: Pin,
    color: Color,
    paddockName: String?,
    sync: PinSyncState,
    canDelete: Boolean,
    photoBusy: Boolean,
    onDismiss: () -> Unit,
    onEdit: () -> Unit,
    onDirections: () -> Unit,
    onPhoto: () -> Unit,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    // Half-height first so the tapped pin stays visible on the map; drag up for
    // the full details.
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = false)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = vine.cardBackground,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // Header: coloured disc + title + sync state + row-attachment context.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(Brush.verticalGradient(listOf(color, color.copy(alpha = 0.8f)))),
                    contentAlignment = Alignment.Center,
                ) {
                    if (pin.isCompleted) {
                        Icon(Icons.Filled.Check, contentDescription = "Completed", tint = Color.White, modifier = Modifier.size(20.dp))
                    }
                }
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            pin.displayTitle,
                            fontSize = 19.sp,
                            fontWeight = FontWeight.Bold,
                            color = vine.textPrimary,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        PinHeaderSyncIcon(sync = sync, tint = vine.textSecondary)
                    }
                    pin.rowAttachmentLabel?.let {
                        Text(it, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = VineColors.LeafGreen)
                    }
                    pin.rowAttachmentDetail?.let {
                        Text(it, fontSize = 12.sp, color = vine.textSecondary)
                    }
                    pin.heading?.let {
                        Text("Facing ${compassAbbrev(it)}", fontSize = 12.sp, color = vine.textSecondary)
                    }
                }
            }

            // Type + status chips.
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val isGrowth = pin.mode?.contains("growth", ignoreCase = true) == true
                StatusBadge(if (isGrowth) "Growth" else "Repair", if (isGrowth) GrowthColor else RepairColor)
                StatusBadge(if (pin.isCompleted) "Done" else "Open", if (pin.isCompleted) VineColors.Success else VineColors.Warning)
                if (sync.hasAny && !sync.needsAttention) StatusBadge("Pending sync", VineColors.Warning)
                if (sync.needsAttention) StatusBadge("Needs attention", VineColors.Destructive)
            }

            // Quick actions (iOS ActionButton row parity, plus explicit Edit).
            Row(modifier = Modifier.fillMaxWidth()) {
                PinActionButton(Icons.Filled.Edit, "Edit", VineColors.Primary, modifier = Modifier.weight(1f), onClick = onEdit)
                PinActionButton(Icons.Filled.Directions, "Directions", VineColors.LeafGreen, modifier = Modifier.weight(1f), onClick = onDirections)
                PinActionButton(Icons.Filled.PhotoCamera, "Photo", VineColors.Purple, modifier = Modifier.weight(1f), busy = photoBusy, onClick = onPhoto)
                PinActionButton(
                    icon = Icons.Filled.CheckCircle,
                    label = if (pin.isCompleted) "Undo" else "Complete",
                    color = if (pin.isCompleted) VineColors.Warning else VineColors.Success,
                    modifier = Modifier.weight(1f),
                    onClick = onToggle,
                )
                if (canDelete) {
                    PinActionButton(Icons.Filled.Delete, "Delete", VineColors.Destructive, modifier = Modifier.weight(1f), onClick = onDelete)
                }
            }

            // Photo preview (hidden entirely when the pin has no photo).
            if (pin.hasPhoto) {
                PinDetailPhoto(vm = vm, photoPath = pin.photoPath)
            }

            // Notes preview.
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(vine.textSecondary.copy(alpha = 0.08f))
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text("Notes", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                Text(
                    pin.notes?.takeIf { it.isNotBlank() } ?: "No notes",
                    fontSize = 14.sp,
                    color = if (pin.notes.isNullOrBlank()) vine.textSecondary else vine.textPrimary,
                )
            }

            // Details (iOS Details section parity).
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(vine.textSecondary.copy(alpha = 0.08f))
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("Details", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                PinDetailRow("Block", paddockName ?: "\u2014")
                pin.pinRowNumber?.let { PinDetailRow("On row", "Row ${rowText(it)}") }
                if (pin.drivingRowNumber != null || pin.heading != null || pin.pinSide != null || pin.side != null) {
                    PinDetailRow("Driving path", pinFacingLine(pin))
                }
                pin.heading?.let { PinDetailRow("Facing", "${compassAbbrev(it)} (${it.roundToInt()}\u00b0)") }
                PinDetailRow("Created", pinCreatedText(pin))
                pin.latitude?.let { PinDetailRow("Latitude", String.format(java.util.Locale.US, "%.6f", it)) }
                pin.longitude?.let { PinDetailRow("Longitude", String.format(java.util.Locale.US, "%.6f", it)) }
                PinDetailRow("Status", if (pin.isCompleted) "Completed" else "Active")
            }

            // Completion context (iOS Completion section parity).
            if (pin.isCompleted) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(vine.textSecondary.copy(alpha = 0.08f))
                        .padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text("Completion", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
                    completedByLabel(pin)?.let { PinDetailRow("Completed by", it) }
                    parseIsoMillis(pin.completedAt)?.let {
                        PinDetailRow("Completed", pinDateTimeFormat.format(java.util.Date(it)))
                    }
                }
            }

            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text("Done") }
        }
    }
}

/** Label/value row used in the pin detail sheet's Details card. */
@Composable
private fun PinDetailRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 14.sp, color = vine.textSecondary)
        Text(
            value,
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = vine.textPrimary,
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
            modifier = Modifier.padding(start = 16.dp),
        )
    }
}

/**
 * Read-only photo preview inside the pin detail sheet. Loads the signed URL on
 * demand and collapses quietly when the photo can't be fetched (e.g. offline).
 */
@Composable
private fun PinDetailPhoto(vm: AppViewModel, photoPath: String?) {
    val vine = LocalVineColors.current
    var signedUrl by remember(photoPath) { mutableStateOf<String?>(null) }
    var unavailable by remember(photoPath) { mutableStateOf(false) }
    LaunchedEffect(photoPath) {
        signedUrl = null
        unavailable = false
        if (!photoPath.isNullOrBlank()) {
            vm.requestPinPhotoUrl(photoPath) { url ->
                signedUrl = url
                unavailable = url.isNullOrBlank()
            }
        }
    }
    if (unavailable) return
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(190.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(vine.textSecondary.copy(alpha = 0.08f)),
        contentAlignment = Alignment.Center,
    ) {
        val url = signedUrl
        if (url != null) {
            AsyncImage(
                model = url,
                contentDescription = "Pin photo",
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp, color = vine.textSecondary)
        }
    }
}

/** Completed-by label, hiding raw UUID values (iOS resolveDisplayName parity). */
private fun completedByLabel(pin: Pin): String? {
    val raw = pin.completedBy?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    val uuidRegex = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    return raw.takeUnless { uuidRegex.matches(it) }
}
