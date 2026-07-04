package com.rork.vinetrack.ui.screens

import android.Manifest
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.Assignment
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CalendarToday
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.LocalDrink
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Paid
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.NearMe
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Route
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Scale
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SortByAlpha
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.FormatListNumbered
import androidx.compose.material.icons.filled.Gesture
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.SyncAlt
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.filled.Timelapse
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldColors
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.CameraMoveStartedReason
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.AppPreferencesStore
import com.rork.vinetrack.data.OperationPrefsStore
import com.rork.vinetrack.data.RowAttachment
import com.rork.vinetrack.data.TrackingPattern
import com.rork.vinetrack.data.TripCostEstimator
import com.rork.vinetrack.data.TripCsvExporter
import com.rork.vinetrack.data.TripPdfExporter
import com.rork.vinetrack.data.TripFuelEstimator
import com.rork.vinetrack.data.TripRowSequencePlanner
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SavedInput
import com.rork.vinetrack.data.model.SeedingBox
import com.rork.vinetrack.data.model.SeedingDetails
import com.rork.vinetrack.data.model.SeedingMixLine
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.fillCalculatedPercentOfMix
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.builtInTripFunctions
import com.rork.vinetrack.data.model.formatTripDuration
import com.rork.vinetrack.data.model.slugifyTripFunction
import com.rork.vinetrack.data.model.tripFunctionDisplayName
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.data.model.resolveTripMachineName
import com.rork.vinetrack.data.model.tripBlocksLabel
import com.rork.vinetrack.data.model.resolveTripOperatorCategory
import com.rork.vinetrack.data.model.resolveTripOperatorName
import com.rork.vinetrack.data.model.resolveTripWorkTask
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.TripSyncBadge
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.components.StatusBadge
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.roundToInt
import java.text.DateFormatSymbols
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

@Composable
fun TripsScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    initialSelectedTripId: String? = null,
    onSelectionConsumed: () -> Unit = {},
    onStartSprayTrip: () -> Unit = {},
) {
    var selectedId by remember { mutableStateOf<String?>(null) }
    var choosing by remember { mutableStateOf(false) }
    var starting by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<Trip?>(null) }

    // When navigated here with a specific trip (e.g. just-started spray job),
    // open that trip's detail once, then clear the external request.
    LaunchedEffect(initialSelectedTripId) {
        if (initialSelectedTripId != null) {
            selectedId = initialSelectedTripId
            onSelectionConsumed()
        }
    }

    val selected = state.trips.firstOrNull { it.id == selectedId }

    AnimatedContent(
        targetState = selected,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "trip-nav",
        modifier = modifier,
    ) { trip ->
        if (trip == null) {
            TripListView(
                state = state,
                onSelect = { selectedId = it.id },
                onStart = { choosing = true },
                onSelectActive = { selectedId = it.id },
            )
        } else {
            TripDetailView(
                vm = vm,
                state = state,
                tripId = trip.id,
                onBack = { selectedId = null },
                onEdit = { editing = it },
            )
        }
    }

    if (choosing) {
        TripTypeChoiceSheet(
            onDismiss = { choosing = false },
            onSelect = { type ->
                choosing = false
                when (type) {
                    TripChoiceType.MAINTENANCE -> starting = true
                    TripChoiceType.SPRAY -> onStartSprayTrip()
                }
            },
        )
    }

    if (starting) {
        StartTripSheet(
            vm = vm,
            state = state,
            onDismiss = { starting = false },
            onStarted = { id -> starting = false; selectedId = id },
        )
    }

    editing?.let { trip ->
        EditTripSheet(
            vm = vm,
            state = state,
            trip = trip,
            onDismiss = { editing = null },
            onSaved = { editing = null },
        )
    }
}

private enum class TripSortOption(val label: String, val icon: ImageVector) {
    DATE("Date", Icons.Filled.Schedule),
    NAME("Name", Icons.Filled.SortByAlpha),
    DURATION("Duration", Icons.Filled.Timer),
}

private enum class TripTypeFilter { ALL, SPRAY, MAINTENANCE }

private fun monthName(month: Int): String =
    DateFormatSymbols(Locale.getDefault()).months.getOrNull(month - 1)?.takeIf { it.isNotBlank() } ?: month.toString()

private fun tripFunctionIcon(raw: String): ImageVector = when (raw) {
    "spraying", "irrigationCheck" -> Icons.Filled.WaterDrop
    "mowing", "shootThinning", "canopyWork", "undervineWeeding", "seeding" -> Icons.Filled.Grass
    "slashing", "mulching", "harrowing", "interRowCultivation", "pruning", "spreading" -> Icons.Filled.Agriculture
    "fertilising" -> Icons.Filled.Science
    "repairs" -> Icons.Filled.Build
    else -> Icons.Filled.MoreHoriz
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripListView(state: AppUiState, onSelect: (Trip) -> Unit, onStart: () -> Unit, onSelectActive: (Trip) -> Unit) {
    val vine = LocalVineColors.current
    val active = state.activeTrip
    val finished = remember(state.trips) { state.trips.filterNot { it.isActive } }

    var search by remember { mutableStateOf("") }
    var typeFilter by remember { mutableStateOf(TripTypeFilter.ALL) }
    var functionFilter by remember { mutableStateOf<String?>(null) }
    var monthFilter by remember { mutableStateOf<Int?>(null) }
    var yearFilter by remember { mutableStateOf<Int?>(null) }
    var sort by remember { mutableStateOf(TripSortOption.DATE) }
    var filterMenu by remember { mutableStateOf(false) }

    val hasActiveFilters = typeFilter != TripTypeFilter.ALL || functionFilter != null ||
        monthFilter != null || yearFilter != null

    val availableYears = remember(finished) {
        finished.mapNotNull { it.startEpochMs }.map { ms ->
            Calendar.getInstance().apply { timeInMillis = ms }.get(Calendar.YEAR)
        }.distinct().sortedDescending()
    }

    val visibleTrips = remember(finished, search, typeFilter, functionFilter, monthFilter, yearFilter, sort, state.sprayRecords) {
        fun hasSpray(trip: Trip) = state.sprayRecords.any { it.tripId == trip.id }
        var list = when (typeFilter) {
            TripTypeFilter.ALL -> finished
            TripTypeFilter.SPRAY -> finished.filter { hasSpray(it) }
            TripTypeFilter.MAINTENANCE -> finished.filterNot { hasSpray(it) }
        }
        functionFilter?.let { fn -> list = list.filter { it.tripFunction == fn } }
        if (monthFilter != null || yearFilter != null) {
            list = list.filter { trip ->
                val ms = trip.startEpochMs ?: return@filter false
                val cal = Calendar.getInstance().apply { timeInMillis = ms }
                (monthFilter == null || cal.get(Calendar.MONTH) + 1 == monthFilter) &&
                    (yearFilter == null || cal.get(Calendar.YEAR) == yearFilter)
            }
        }
        if (search.isNotBlank()) {
            list = list.filter {
                (it.displayLabel + " " + (it.paddockName ?: "") + " " + (it.personName ?: ""))
                    .contains(search, ignoreCase = true)
            }
        }
        when (sort) {
            TripSortOption.DATE -> list.sortedByDescending { it.startEpochMs ?: 0L }
            TripSortOption.NAME -> list.sortedBy { it.displayLabel.lowercase() }
            TripSortOption.DURATION -> list.sortedByDescending { it.activeDurationSeconds ?: 0L }
        }
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Trips") },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
                actions = {
                    if (active == null && finished.isNotEmpty()) {
                        Box {
                            IconButton(onClick = { filterMenu = true }) {
                                Icon(
                                    Icons.Filled.FilterList,
                                    contentDescription = "Filter trips",
                                    tint = if (hasActiveFilters) VineColors.Primary else vine.textSecondary,
                                )
                            }
                            DropdownMenu(expanded = filterMenu, onDismissRequest = { filterMenu = false }) {
                                Text(
                                    "Sort by",
                                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = vine.textSecondary,
                                )
                                TripSortOption.entries.forEach { option ->
                                    DropdownMenuItem(
                                        text = { Text(option.label) },
                                        leadingIcon = { Icon(option.icon, contentDescription = null) },
                                        trailingIcon = {
                                            if (sort == option) Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Primary)
                                        },
                                        onClick = { sort = option; filterMenu = false },
                                    )
                                }
                                HorizontalDivider()
                                Text(
                                    "Month",
                                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.SemiBold,
                                    color = vine.textSecondary,
                                )
                                DropdownMenuItem(
                                    text = { Text("All months") },
                                    leadingIcon = { Icon(Icons.Filled.CalendarToday, contentDescription = null) },
                                    trailingIcon = {
                                        if (monthFilter == null) Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Primary)
                                    },
                                    onClick = { monthFilter = null },
                                )
                                (1..12).forEach { m ->
                                    DropdownMenuItem(
                                        text = { Text(monthName(m)) },
                                        trailingIcon = {
                                            if (monthFilter == m) Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Primary)
                                        },
                                        onClick = { monthFilter = m },
                                    )
                                }
                                if (availableYears.isNotEmpty()) {
                                    HorizontalDivider()
                                    Text(
                                        "Year",
                                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = vine.textSecondary,
                                    )
                                    DropdownMenuItem(
                                        text = { Text("All years") },
                                        leadingIcon = { Icon(Icons.Filled.Schedule, contentDescription = null) },
                                        trailingIcon = {
                                            if (yearFilter == null) Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Primary)
                                        },
                                        onClick = { yearFilter = null },
                                    )
                                    availableYears.forEach { y ->
                                        DropdownMenuItem(
                                            text = { Text(y.toString()) },
                                            trailingIcon = {
                                                if (yearFilter == y) Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Primary)
                                            },
                                            onClick = { yearFilter = y },
                                        )
                                    }
                                }
                                if (hasActiveFilters) {
                                    HorizontalDivider()
                                    DropdownMenuItem(
                                        text = { Text("Clear filters", color = VineColors.Destructive) },
                                        leadingIcon = { Icon(Icons.Filled.Close, contentDescription = null, tint = VineColors.Destructive) },
                                        onClick = {
                                            typeFilter = TripTypeFilter.ALL
                                            functionFilter = null
                                            monthFilter = null
                                            yearFilter = null
                                            filterMenu = false
                                        },
                                    )
                                }
                            }
                        }
                    }
                },
            )
        },
        bottomBar = {
            if (active == null && state.trips.isNotEmpty()) {
                Surface(color = vine.appBackground) {
                    Button(
                        onClick = onStart,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp)
                            .height(52.dp),
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                    ) {
                        Icon(Icons.Filled.PlayArrow, contentDescription = null)
                        Text("  Start Trip", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        },
    ) { padding ->
        when {
            state.isLoadingVineyardData && state.trips.isEmpty() -> {
                Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = VineColors.LeafGreen)
                }
            }

            state.trips.isEmpty() && state.tripError != null -> {
                Box(Modifier.fillMaxSize().padding(padding).padding(16.dp), contentAlignment = Alignment.Center) {
                    EmptyState(
                        icon = Icons.Filled.DirectionsCar,
                        title = "Couldn't load trips",
                        message = state.tripError,
                    )
                }
            }

            state.trips.isEmpty() -> {
                Box(Modifier.fillMaxSize().padding(padding).padding(24.dp), contentAlignment = Alignment.Center) {
                    EmptyState(
                        icon = Icons.Filled.DirectionsCar,
                        title = "No Trips Yet",
                        message = "Trips you record will appear here.",
                    )
                }
            }

            else -> {
                Column(modifier = Modifier.fillMaxSize().padding(padding)) {
                    if (active == null && finished.isNotEmpty()) {
                        OutlinedTextField(
                            value = search,
                            onValueChange = { search = it },
                            placeholder = { Text("Search trips") },
                            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                            trailingIcon = {
                                if (search.isNotEmpty()) {
                                    IconButton(onClick = { search = "" }) {
                                        Icon(Icons.Filled.Close, contentDescription = "Clear search")
                                    }
                                }
                            },
                            singleLine = true,
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                        )
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState())
                                .padding(horizontal = 16.dp, vertical = 6.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            TypeChip("All trips", typeFilter == TripTypeFilter.ALL) { typeFilter = TripTypeFilter.ALL }
                            TypeChip("Spray", typeFilter == TripTypeFilter.SPRAY) {
                                typeFilter = TripTypeFilter.SPRAY; functionFilter = null
                            }
                            TypeChip("Maintenance", typeFilter == TripTypeFilter.MAINTENANCE) {
                                typeFilter = TripTypeFilter.MAINTENANCE; functionFilter = null
                            }
                        }
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState())
                                .padding(horizontal = 16.dp)
                                .padding(bottom = 6.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            builtInTripFunctions.forEach { (raw, label) ->
                                FunctionChip(label, tripFunctionIcon(raw), functionFilter == raw) {
                                    functionFilter = if (functionFilter == raw) null else raw
                                    if (typeFilter == TripTypeFilter.SPRAY) typeFilter = TripTypeFilter.ALL
                                }
                            }
                        }
                    }

                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        if (active != null) {
                            item(key = "active-${active.id}") {
                                ActiveTripBanner(
                                    active,
                                    machineName = resolveTripMachineName(active, state.machines),
                                    operatorName = resolveTripOperatorName(active, state.members),
                                    drivingPath = state.currentDrivingPathNumber,
                                    lockConfidence = if (state.isTracking) state.rowLockConfidence else null,
                                    onClick = { onSelectActive(active) },
                                )
                            }
                        }
                        if (visibleTrips.isNotEmpty()) {
                            item(key = "history-header") {
                                Text(
                                    "History · ${visibleTrips.size}",
                                    color = vine.textSecondary,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium,
                                    modifier = Modifier.padding(top = if (active != null) 8.dp else 0.dp, bottom = 2.dp),
                                )
                            }
                            items(visibleTrips, key = { it.id }) { trip ->
                                TripRow(
                                    trip = trip,
                                    hasSprayRecord = state.sprayRecords.any { it.tripId == trip.id },
                                    syncState = state.tripSyncState(trip.id),
                                    onClick = { onSelect(trip) },
                                )
                            }
                        } else if (active == null) {
                            item(key = "no-match") {
                                Box(Modifier.fillMaxWidth().padding(top = 48.dp), contentAlignment = Alignment.Center) {
                                    Text("No trips match your filters", color = vine.textSecondary, fontSize = 14.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TypeChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (selected) VineColors.Primary else vine.cardBackground)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text(
            label,
            fontSize = 14.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) Color.White else vine.textPrimary,
        )
    }
}

@Composable
private fun FunctionChip(label: String, icon: ImageVector, selected: Boolean, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(if (selected) VineColors.Primary.copy(alpha = 0.85f) else vine.cardBackground)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    ) {
        Icon(
            icon,
            contentDescription = null,
            modifier = Modifier.size(14.dp),
            tint = if (selected) Color.White else vine.textSecondary,
        )
        Text(
            label,
            fontSize = 13.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) Color.White else vine.textPrimary,
        )
    }
}

/** Two-option trip-type chooser shown before the Start-trip form, mirroring iOS. */
private enum class TripChoiceType { MAINTENANCE, SPRAY }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripTypeChoiceSheet(onDismiss: () -> Unit, onSelect: (TripChoiceType) -> Unit) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            AsyncImage(
                model = "https://r2-pub.rork.com/projects/u8ega94cbdz6azh6dulre/assets/9c0a966b-50ac-4bf5-990e-15701eb5616b.png",
                contentDescription = null,
                modifier = Modifier.height(110.dp),
            )
            Text("Start a Trip", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(
                "What type of trip are you starting?",
                fontSize = 14.sp,
                color = vine.textSecondary,
            )
            Spacer(Modifier.height(8.dp))
            TripChoiceCard(
                icon = Icons.Filled.Build,
                tint = VineColors.EarthBrown,
                title = "Maintenance Trip",
                subtitle = "Track a general vineyard trip without spray data",
                onClick = { onSelect(TripChoiceType.MAINTENANCE) },
            )
            TripChoiceCard(
                icon = Icons.Filled.WaterDrop,
                tint = VineColors.LeafGreen,
                title = "Spray Trip",
                subtitle = "Open the Spray Calculator to configure and start a spray job",
                onClick = { onSelect(TripChoiceType.SPRAY) },
            )
        }
    }
}

@Composable
private fun TripChoiceCard(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .clickable(onClick = onClick)
            .padding(14.dp),
    ) {
        Box(
            modifier = Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary, maxLines = 2)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = vine.textSecondary,
        )
    }
}

@Composable
private fun ActiveTripBanner(
    trip: Trip,
    machineName: String?,
    operatorName: String?,
    drivingPath: Double?,
    lockConfidence: Double?,
    onClick: () -> Unit,
) {
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(trip.id, trip.isPaused) {
        while (true) {
            nowMs = System.currentTimeMillis()
            delay(1000)
        }
    }
    val elapsed = liveDurationSeconds(trip, nowMs)

    VineyardCard(modifier = Modifier.clickable(onClick = onClick)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(
                modifier = Modifier.size(44.dp).clip(CircleShape).background(VineColors.Warning.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.DirectionsCar, contentDescription = null, tint = VineColors.Warning)
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(trip.displayLabel, fontWeight = FontWeight.Bold, color = LocalVineColors.current.textPrimary, fontSize = 16.sp, maxLines = 1)
                Text(
                    clockDuration(elapsed) + " · " + (formatDistance(trip.totalDistance) ?: "0 m"),
                    fontSize = 13.sp,
                    color = LocalVineColors.current.textSecondary,
                )
                val subtitle = listOfNotNull(operatorName, machineName).joinToString(" · ")
                if (subtitle.isNotBlank()) {
                    Text(subtitle, fontSize = 12.sp, color = LocalVineColors.current.textSecondary, maxLines = 1)
                }
                // Read-only row-lock diagnostic, shown only once a path is locked.
                if (drivingPath != null && lockConfidence != null) {
                    Text(
                        "Path ${formatPath(drivingPath)} · lock ${(lockConfidence * 100).roundToInt()}%",
                        fontSize = 12.sp,
                        color = if (lockConfidence >= 0.6) VineColors.LeafGreen else LocalVineColors.current.textSecondary,
                        maxLines = 1,
                    )
                }
            }
            StatusBadge(if (trip.isPaused) "Paused" else "Live", if (trip.isPaused) VineColors.Orange else VineColors.Warning)
        }
    }
}

@Composable
private fun TripRow(
    trip: Trip,
    hasSprayRecord: Boolean,
    syncState: TripSyncBadge,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    // Show the trip function as a secondary line only when a custom title is set
    // (otherwise the title already IS the function name), mirroring iOS.
    val functionLabel = trip.tripFunction
        ?.takeIf { !trip.tripTitle.isNullOrBlank() }
        ?.let { tripFunctionDisplayName(it) }
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(
                    trip.displayLabel,
                    fontWeight = FontWeight.SemiBold,
                    color = VineColors.Primary,
                    fontSize = 15.sp,
                    maxLines = 1,
                )
                functionLabel?.let {
                    TripRowLabel(tripFunctionIcon(trip.tripFunction ?: ""), it, vine.textSecondary, 12.sp)
                }
                formatTripRowDateTime(trip.startEpochMs)?.let {
                    TripRowLabel(Icons.Filled.CalendarToday, it, vine.textSecondary, 13.sp)
                }
                trip.paddockName?.takeIf { it.isNotBlank() }?.let {
                    TripRowLabel(Icons.Filled.Grass, it, VineColors.LeafGreen, 13.sp)
                }
                trip.personName?.takeIf { it.isNotBlank() }?.let {
                    TripRowLabel(Icons.Filled.Person, it, vine.textSecondary, 13.sp)
                }
            }
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                TripSyncTick(syncState)
                trip.activeDurationSeconds?.let {
                    TripRowLabel(Icons.Filled.Schedule, formatTripDuration(it), vine.textSecondary, 12.sp, trailing = true)
                }
                formatDistance(trip.totalDistance)?.let {
                    TripRowLabel(Icons.Filled.Timeline, it, vine.textSecondary, 12.sp, trailing = true)
                }
                if (hasSprayRecord) {
                    TripRowLabel(Icons.Filled.WaterDrop, "Spray", VineColors.LeafGreen, 12.sp, trailing = true)
                }
            }
        }
    }
}

/** Compact icon+text label used in trip rows, mirroring SwiftUI `Label`. */
@Composable
private fun TripRowLabel(
    icon: ImageVector,
    text: String,
    tint: Color,
    fontSize: androidx.compose.ui.unit.TextUnit,
    trailing: Boolean = false,
) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size((fontSize.value + 1).dp))
        Text(text, fontSize = fontSize, color = tint, maxLines = if (trailing) 1 else 2)
    }
}

/** Small per-trip sync state pill (icon only), mirroring iOS `RecordSyncBadge`. */
@Composable
private fun TripSyncTick(state: TripSyncBadge) {
    val (icon, tint) = when (state) {
        TripSyncBadge.SYNCED -> Icons.Filled.CheckCircle to VineColors.Success
        TripSyncBadge.QUEUED -> Icons.Filled.Schedule to VineColors.Warning
        TripSyncBadge.SYNCING -> Icons.Filled.Sync to VineColors.Primary
        TripSyncBadge.ERROR -> Icons.Outlined.ErrorOutline to VineColors.Destructive
    }
    Box(
        modifier = Modifier.clip(CircleShape).background(tint.copy(alpha = 0.12f)).padding(horizontal = 6.dp, vertical = 5.dp),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = "Sync status", tint = tint, modifier = Modifier.size(13.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TripDetailView(
    vm: AppViewModel,
    state: AppUiState,
    tripId: String,
    onBack: () -> Unit,
    onEdit: (Trip) -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val trip = state.trips.firstOrNull { it.id == tripId }
    var confirmDelete by remember { mutableStateOf(false) }
    var ending by remember { mutableStateOf(false) }
    var editingSeeding by remember { mutableStateOf(false) }
    var exportMenuOpen by remember { mutableStateOf(false) }
    // Active trips open in the full-screen in-cab HUD; toggle to the scrollable
    // detail (summary, cost, etc.) and back via the top-bar controls.
    var showLiveHud by remember(tripId) { mutableStateOf(true) }

    // The trip can disappear after delete — bail out cleanly.
    LaunchedEffect(trip == null) { if (trip == null) onBack() }
    if (trip == null) return

    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(trip.isActive, trip.isPaused) {
        while (trip.isActive) {
            nowMs = System.currentTimeMillis()
            delay(1000)
        }
    }
    val durationSeconds = if (trip.isActive) liveDurationSeconds(trip, nowMs) else (trip.activeDurationSeconds ?: 0L)

    if (trip.isActive && showLiveHud) {
        ActiveTripHud(
            vm = vm,
            state = state,
            trip = trip,
            durationSeconds = durationSeconds,
            onBack = onBack,
            onShowDetails = { showLiveHud = false },
            onEndConfirmed = { ending = true },
        )
    } else {
    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(trip.displayLabel, maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    if (trip.isActive) {
                        IconButton(onClick = { showLiveHud = true }) {
                            Icon(Icons.Filled.NearMe, contentDescription = "Live map")
                        }
                    }
                    if (!trip.isActive) {
                        val canViewFinancials = state.currentRole == "owner" || state.currentRole == "manager"
                        val blockLabel = tripBlocksLabel(trip, state.paddocks)
                        val operatorName = resolveTripOperatorName(trip, state.members)
                        val linkedSprayForExport = state.sprayRecords.firstOrNull { it.tripId == trip.id }
                        val pinCount = 0
                        fun exportPdf() {
                            val ok = TripPdfExporter.exportAndShare(
                                context = context,
                                trip = trip,
                                vineyardName = state.selectedVineyard?.name ?: "Vineyard",
                                blockLabel = blockLabel,
                                operatorName = operatorName,
                                pinCount = pinCount,
                                includeCostings = canViewFinancials,
                                linkedSpray = linkedSprayForExport,
                                operatorCategories = state.operatorCategories,
                                machines = state.machines,
                                fuelPurchases = state.fuelPurchases,
                                paddocks = state.paddocks,
                                yieldRecords = state.yieldRecords,
                                savedInputs = state.savedInputs,
                                logo = state.selectedVineyardLogo,
                            )
                            if (!ok) Toast.makeText(context, "Couldn't create the PDF. Please try again.", Toast.LENGTH_SHORT).show()
                        }
                        fun exportCsv() {
                            val ok = TripCsvExporter.exportAndShare(
                                context = context,
                                trip = trip,
                                vineyardName = state.selectedVineyard?.name ?: "Vineyard",
                                blockLabel = blockLabel,
                                operatorName = operatorName,
                                includeCostings = canViewFinancials,
                                linkedSpray = linkedSprayForExport,
                                operatorCategories = state.operatorCategories,
                                machines = state.machines,
                                fuelPurchases = state.fuelPurchases,
                                paddocks = state.paddocks,
                                yieldRecords = state.yieldRecords,
                                savedInputs = state.savedInputs,
                            )
                            if (!ok) Toast.makeText(context, "Couldn't create the CSV. Please try again.", Toast.LENGTH_SHORT).show()
                        }
                        IconButton(onClick = { exportMenuOpen = true }) {
                            Icon(Icons.Filled.IosShare, contentDescription = "Export trip")
                        }
                        DropdownMenu(expanded = exportMenuOpen, onDismissRequest = { exportMenuOpen = false }) {
                            DropdownMenuItem(
                                text = { Text("Export PDF") },
                                leadingIcon = { Icon(Icons.Filled.PictureAsPdf, contentDescription = null) },
                                onClick = { exportMenuOpen = false; exportPdf() },
                            )
                            DropdownMenuItem(
                                text = { Text("Export CSV") },
                                leadingIcon = { Icon(Icons.Filled.Description, contentDescription = null) },
                                onClick = { exportMenuOpen = false; exportCsv() },
                            )
                        }
                    }
                    IconButton(onClick = { onEdit(trip) }) {
                        Icon(Icons.Filled.Edit, contentDescription = "Edit trip")
                    }
                },
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
            if (trip.isActive) {
                val activeLinkedSpray = remember(trip.id, state.sprayRecords) {
                    state.sprayRecords.firstOrNull { it.tripId == trip.id }
                }
                ActiveTripControls(
                    vm = vm,
                    trip = trip,
                    linkedSpray = activeLinkedSpray,
                    durationSeconds = durationSeconds,
                    busy = state.tripBusy,
                    tracking = state.isTracking,
                    onEndConfirmed = { ending = true },
                )
            }

            // Path map
            val path = trip.pathPoints?.mapNotNull { it.toLatLng() } ?: emptyList()
            if (path.size >= 2) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Track", onLight = true)
                    TripPathMap(path = path, blocks = state.paddocks)
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Summary", onLight = true)
                VineyardCard {
                    DetailRow(Icons.Filled.Schedule, "Duration", formatTripDuration(durationSeconds), VineColors.Indigo)
                    Divider(vine.cardBorder)
                    DetailRow(Icons.Filled.Straighten, "Distance", formatDistance(trip.totalDistance) ?: "—", VineColors.Cyan)
                    Divider(vine.cardBorder)
                    DetailRow(Icons.Filled.Route, "Rows completed", trip.completedRowCount.toString(), VineColors.LeafGreen)
                    if ((trip.totalTanks ?: 0) > 0) {
                        Divider(vine.cardBorder)
                        DetailRow(Icons.Filled.Grass, "Tanks", trip.totalTanks.toString(), VineColors.Orange)
                    }
                }
            }

            if (trip.rowSequence.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Row plan", onLight = true)
                    TripRowPlanSummaryCard(trip)
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Details", onLight = true)
                val machineName = resolveTripMachineName(trip, state.machines)
                val hasMachineLink = trip.machineId != null || trip.tractorId != null
                val workTask = resolveTripWorkTask(trip, state.workTasks)
                val operatorName = resolveTripOperatorName(trip, state.members)
                val operatorCategory = resolveTripOperatorCategory(trip, state.operatorCategories)
                val blockLabel = tripBlocksLabel(trip, state.paddocks)
                val blockCount = trip.effectivePaddockIds.size
                VineyardCard {
                    DetailRow(
                        Icons.Filled.Grass,
                        if (blockCount > 1) "Blocks ($blockCount)" else "Block",
                        blockLabel,
                        VineColors.LeafGreen,
                    )
                    Divider(vine.cardBorder)
                    DetailRow(
                        Icons.Filled.Person,
                        "Operator",
                        operatorName ?: if (trip.operatorUserId != null) "Linked member unavailable" else "Not recorded",
                        VineColors.EarthBrown,
                    )
                    if (trip.operatorCategoryId != null) {
                        Divider(vine.cardBorder)
                        DetailRow(
                            Icons.Filled.Person,
                            "Operator category",
                            operatorCategory?.displayName ?: "Linked category unavailable",
                            VineColors.EarthBrown,
                        )
                    }
                    Divider(vine.cardBorder)
                    DetailRow(
                        Icons.Filled.Agriculture,
                        "Equipment",
                        machineName ?: if (hasMachineLink) "Linked equipment unavailable" else "No machine linked",
                        VineColors.Orange,
                    )
                    if (trip.workTaskId != null) {
                        Divider(vine.cardBorder)
                        DetailRow(
                            Icons.Filled.Assignment,
                            "Work task",
                            workTask?.displayLabel ?: "Linked task unavailable",
                            VineColors.Indigo,
                        )
                    }
                    Divider(vine.cardBorder)
                    DetailRow(Icons.Filled.Schedule, "Started", formatTripDateTime(trip.startEpochMs) ?: "—", VineColors.Indigo)
                    trip.endEpochMs?.let {
                        Divider(vine.cardBorder)
                        DetailRow(Icons.Filled.Schedule, "Finished", formatTripDateTime(it) ?: "—", VineColors.DarkGreen)
                    }
                }
            }

            // Engine-hour readings (Stage 3F-1), shown only when at least one
            // reading was captured.
            if (trip.startEngineHours != null || trip.endEngineHours != null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Engine hours", onLight = true)
                    VineyardCard {
                        trip.startEngineHours?.let {
                            DetailRow(Icons.Filled.Speed, "Start", "${formatEngineHours(it)} h", VineColors.Indigo)
                        }
                        trip.endEngineHours?.let {
                            if (trip.startEngineHours != null) Divider(vine.cardBorder)
                            DetailRow(Icons.Filled.Speed, "End", "${formatEngineHours(it)} h", VineColors.DarkGreen)
                        }
                        trip.engineHoursUsed?.let {
                            Divider(vine.cardBorder)
                            DetailRow(Icons.Filled.Timelapse, "Hours used", "${formatEngineHours(it)} h", VineColors.Orange)
                        }
                    }
                }
            }

            // Linked spray record (spray_records.trip_id == trip.id), mirroring iOS.
            val linkedSpray = remember(trip.id, state.sprayRecords) {
                state.sprayRecords.firstOrNull { it.tripId == trip.id }
            }

            // Cost breakdown (Stage 3F-3b-i), read-only and owner/manager-only.
            // Combines labour, fuel and chemical cost into a single total via the
            // pure TripCostEstimator. Fuel mirrors the iOS TripCostService logic;
            // labour uses the resolved operator category rate; chemical comes from
            // the linked spray record. cost/ha and cost/tonne are intentionally
            // out of scope for this slice.
            val canViewFinancials = state.currentRole == "owner" || state.currentRole == "manager"
            if (canViewFinancials) {
                val cost = remember(trip, linkedSpray, state.operatorCategories, state.machines, state.fuelPurchases, state.paddocks, state.yieldRecords, state.savedInputs) {
                    TripCostEstimator.estimate(
                        trip,
                        linkedSpray,
                        state.operatorCategories,
                        state.machines,
                        state.fuelPurchases,
                        state.paddocks,
                        state.yieldRecords,
                        state.savedInputs,
                    )
                }
                val fuel = cost.fuel
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Cost breakdown", onLight = true)
                    VineyardCard {
                        DetailRow(
                            Icons.Filled.Person,
                            "Labour",
                            if (cost.labour.cost > 0) {
                                "${formatFuelCurrency(cost.labour.cost)} · ${formatEngineHours(cost.labour.hours)} h"
                            } else "—",
                            VineColors.EarthBrown,
                        )
                        Divider(vine.cardBorder)
                        DetailRow(
                            Icons.Filled.LocalGasStation,
                            "Fuel",
                            fuel.fuelCost?.let { c ->
                                fuel.litres?.let { l -> "${formatFuelCurrency(c)} · ${formatLitres(l)} L" } ?: formatFuelCurrency(c)
                            } ?: "—",
                            VineColors.Orange,
                        )
                        cost.chemical?.let { chem ->
                            Divider(vine.cardBorder)
                            DetailRow(
                                Icons.Filled.Science,
                                "Chemicals",
                                if (chem.cost > 0) formatFuelCurrency(chem.cost) else "—",
                                VineColors.LeafGreen,
                            )
                        }
                        cost.seeding?.let { seed ->
                            Divider(vine.cardBorder)
                            DetailRow(
                                Icons.Filled.Grass,
                                "Seed / inputs",
                                if (seed.cost > 0) formatFuelCurrency(seed.cost) else "—",
                                VineColors.LeafGreen,
                            )
                        }
                        Divider(vine.cardBorder)
                        DetailRow(
                            Icons.Filled.Paid,
                            "Total",
                            if (cost.totalCost > 0) formatFuelCurrency(cost.totalCost) else "—",
                            VineColors.DarkGreen,
                        )
                        cost.treatedAreaHa?.let { area ->
                            Divider(vine.cardBorder)
                            DetailRow(
                                Icons.Filled.Straighten,
                                "Treated area",
                                "${formatLitres(area)} ha",
                                VineColors.LeafGreen,
                            )
                        }
                        cost.costPerHa?.let { perHa ->
                            Divider(vine.cardBorder)
                            DetailRow(
                                Icons.Filled.Paid,
                                "Cost / ha",
                                formatFuelCurrency(perHa),
                                VineColors.DarkGreen,
                            )
                        }
                        cost.yieldTonnes?.let { tonnes ->
                            Divider(vine.cardBorder)
                            DetailRow(
                                Icons.Filled.Scale,
                                "Yield",
                                "${formatTonnes(tonnes)} t",
                                VineColors.LeafGreen,
                            )
                        }
                        cost.costPerTonne?.let { perTonne ->
                            Divider(vine.cardBorder)
                            DetailRow(
                                Icons.Filled.Paid,
                                "Cost / tonne",
                                formatFuelCurrency(perTonne),
                                VineColors.DarkGreen,
                            )
                        }
                        Divider(vine.cardBorder)
                        DetailRow(
                            Icons.Filled.Timelapse,
                            "Fuel basis",
                            "${fuel.basis.label} · ${formatEngineHours(fuel.fuelHours)} h",
                            VineColors.Indigo,
                        )
                        fuel.costPerLitre?.let { perL ->
                            Divider(vine.cardBorder)
                            DetailRow(
                                Icons.Filled.LocalGasStation,
                                "Cost / litre",
                                formatFuelCurrency(perL),
                                VineColors.Orange,
                            )
                        }
                        val costWarnings = buildList {
                            addAll(cost.warnings)
                            cost.areaWarning?.takeIf { cost.totalCost > 0 }?.let { add(it) }
                            cost.yieldWarning?.takeIf { cost.costPerTonne == null && cost.totalCost > 0 }?.let { add(it) }
                        }
                        if (costWarnings.isNotEmpty()) {
                            Spacer(Modifier.height(8.dp))
                            costWarnings.forEach { warning ->
                                Text(warning, fontSize = 12.sp, color = vine.textSecondary)
                            }
                        }
                    }
                }
            }

            // Seeding details — shown for seeding/spreading/fertilising trips.
            // Owners/managers can edit the mix lines + box settings that drive
            // the seed/input cost; other roles see a read-only summary.
            val isSeedingTrip = trip.tripFunction in setOf("seeding", "spreading", "fertilising")
            if (isSeedingTrip || trip.seedingDetails?.hasAnyValue == true) {
                val canManageSeeding = state.currentRole == "owner" || state.currentRole == "manager"
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        SectionHeader("Seeding details", onLight = true, modifier = Modifier.weight(1f))
                        if (canManageSeeding) {
                            TextButton(onClick = { editingSeeding = true }) {
                                Icon(Icons.Filled.Edit, contentDescription = null, tint = VineColors.PrimaryAccent, modifier = Modifier.size(16.dp))
                                Text("  Edit", color = VineColors.PrimaryAccent, fontSize = 13.sp)
                            }
                        }
                    }
                    VineyardCard {
                        val details = trip.seedingDetails
                        val lines = details?.mixLines.orEmpty().filter { it.hasAnyValue }
                        if (details?.hasAnyValue != true) {
                            Text(
                                if (canManageSeeding) "No seeding details yet. Tap Edit to add mix lines and box settings for cost tracking." else "No seeding details recorded.",
                                fontSize = 13.sp,
                                color = vine.textSecondary,
                            )
                        } else {
                            details.sowingDepthCm?.let { depth ->
                                DetailRow(Icons.Filled.Straighten, "Sowing depth", "${formatLitres(depth)} cm", VineColors.EarthBrown)
                            }
                            lines.forEachIndexed { index, line ->
                                if (index > 0 || details.sowingDepthCm != null) Divider(vine.cardBorder)
                                val parts = buildList {
                                    line.kgPerHa?.let { add("${formatLitres(it)} kg/ha") }
                                    line.seedBox?.takeIf { it.isNotBlank() }?.let { add(it) }
                                }.joinToString(" \u00b7 ")
                                DetailRow(
                                    Icons.Filled.Grass,
                                    line.name?.takeIf { it.isNotBlank() } ?: "Mix line ${index + 1}",
                                    parts.ifBlank { "\u2014" },
                                    VineColors.LeafGreen,
                                )
                            }
                        }
                    }
                }
            }

            // Tank fill-timer sessions (Stage 3F-2a), read-only. Shown only when
            // the trip carries recorded sessions or live tank state.
            if (trip.tankSessions.isNotEmpty() || trip.activeTankNumber != null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Tank fills", onLight = true)
                    VineyardCard {
                        trip.activeTankNumber?.let { active ->
                            val state = if (trip.isFillingTank) "Filling tank ${trip.fillingTankNumber ?: active}" else "On tank $active"
                            DetailRow(Icons.Filled.LocalDrink, "Current", state, VineColors.Cyan)
                        }
                        trip.tankSessions.forEachIndexed { index, tank ->
                            if (index > 0 || trip.activeTankNumber != null) Divider(vine.cardBorder)
                            val parts = buildList {
                                tank.fillDurationSeconds?.let { add("fill ${formatTripDuration(it)}") }
                                tank.rowRange.takeIf { it.isNotBlank() }?.let { add(it) }
                                if (tank.isOpen) add("in progress")
                            }
                            val detail = parts.joinToString(" \u00b7 ").ifBlank {
                                formatTripDateTime(tank.startEpochMs) ?: "\u2014"
                            }
                            DetailRow(Icons.Filled.LocalDrink, "Tank ${tank.tankNumber}", detail, VineColors.Indigo)
                        }
                    }
                }
            }

            if (linkedSpray != null) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Spray", onLight = true)
                    VineyardCard {
                        DetailRow(
                            Icons.Filled.WaterDrop,
                            "Spray record",
                            linkedSpray.displayLabel,
                            VineColors.Cyan,
                        )
                        val chems = linkedSpray.chemicalNames
                        if (chems.isNotEmpty()) {
                            Divider(vine.cardBorder)
                            DetailRow(
                                Icons.Filled.Grass,
                                "Chemicals",
                                if (chems.size <= 2) chems.joinToString(", ") else "${chems.take(2).joinToString(", ")} +${chems.size - 2}",
                                VineColors.LeafGreen,
                            )
                        }
                    }
                }
            }

            trip.completionNotes?.takeIf { it.isNotBlank() }?.let { notes ->
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Notes", onLight = true)
                    VineyardCard {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Icon(Icons.Filled.Notes, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(20.dp))
                            Text(notes, fontSize = 14.sp, color = vine.textPrimary)
                        }
                    }
                }
            }

            if (!trip.isActive) {
                TextButton(
                    onClick = { confirmDelete = true },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive)
                    Text("  Delete trip", color = VineColors.Destructive)
                }
            }

            Spacer(Modifier.height(8.dp))
        }
    }
    }

    if (editingSeeding) {
        SeedingDetailsSheet(
            vm = vm,
            state = state,
            trip = trip,
            onDismiss = { editingSeeding = false },
        )
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete trip?") },
            text = { Text("This removes the trip for your whole team. This can't be undone here.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    vm.deleteTrip(trip.id) {}
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }

    if (ending) {
        EndTripSheet(
            vm = vm,
            trip = trip,
            onDismiss = { ending = false },
            onEnded = { ending = false },
        )
    }
}

/**
 * Full-screen in-cab "driving" HUD for an active trip. Mirrors iOS
 * `ActiveTripView`: a follow-the-driver satellite map with the live trail, a
 * top stat bar (time / distance / speed), GPS-quality pill, row guidance, an
 * off-plan warning banner, and the in-trip controls (pause, end, row coverage,
 * tank sessions) docked at the bottom.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ActiveTripHud(
    vm: AppViewModel,
    state: AppUiState,
    trip: Trip,
    durationSeconds: Long,
    onBack: () -> Unit,
    onShowDetails: () -> Unit,
    onEndConfirmed: () -> Unit,
) {
    val vine = LocalVineColors.current
    val path = remember(trip.pathPoints) { trip.pathPoints?.mapNotNull { it.toLatLng() } ?: emptyList() }
    val current = path.lastOrNull()
    val blocks = remember(state.paddocks, trip.paddockId, trip.effectivePaddockIds) {
        val ids = buildSet {
            trip.paddockId?.let { add(it) }
            addAll(trip.effectivePaddockIds)
        }
        state.paddocks.filter { it.id in ids && it.hasGeometry }
    }
    val linkedSpray = remember(trip.id, state.sprayRecords) {
        state.sprayRecords.firstOrNull { it.tripId == trip.id }
    }
    val cameraPositionState = rememberCameraPositionState()
    var followUser by remember { mutableStateOf(true) }
    // Map orientation: false = north-up (iOS default), true = heading-facing.
    var headingUp by remember { mutableStateOf(false) }
    // Zoom held stable across follow updates. Re-captured from the camera only
    // when the operator taps Recenter — GPS ticks never change zoom.
    var followZoom by remember { mutableFloatStateOf(18f) }
    var showRowChips by remember { mutableStateOf(true) }
    // iOS canShowRowSides parity: the side chips are gated on the device-local
    // "row tracking" preference in addition to the on-map toggle.
    val hudContext = LocalContext.current
    val rowTrackingEnabled = remember { AppPreferencesStore(hudContext).load().rowTrackingEnabled }
    var panelExpanded by remember { mutableStateOf(false) }
    // Repairs/Growth quick-pin launcher shown over the HUD (iOS sheet parity).
    var hudLauncherMode by remember { mutableStateOf<String?>(null) }
    var hybrid by remember { mutableStateOf(true) }
    var hudMapLoaded by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    // Measured overlay heights feed the map contentPadding so the Google
    // watermark/controls stay visible and follow-centre sits in the clear area.
    var topOverlayHeightPx by remember { mutableIntStateOf(0) }
    var bottomPanelHeightPx by remember { mutableIntStateOf(0) }
    val topOverlayHeight = with(density) { topOverlayHeightPx.toDp() }
    val bottomPanelHeight = with(density) { bottomPanelHeightPx.toDp() }

    val bearing = state.latestBearingDegrees
    val speedKmh = state.latestSpeedMetresPerSecond?.let { (it * 3.6).coerceAtLeast(0.0) }
    val accuracy = state.latestAccuracyMetres

    // Initial framing on first open.
    LaunchedEffect(Unit) {
        if (current != null) {
            runCatching { cameraPositionState.move(CameraUpdateFactory.newLatLngZoom(current, 18f)) }
        }
    }
    // No GPS fix yet: frame the trip's block geometry so the operator sees the
    // vineyard instead of a world-default camera. Follow mode takes over as
    // soon as the first fix arrives.
    LaunchedEffect(hudMapLoaded, current == null, blocks) {
        if (!hudMapLoaded || current != null) return@LaunchedEffect
        val pts = blocks.flatMap { it.polygonPoints ?: emptyList() }.mapNotNull { it.toLatLng() }
        cameraPositionState.fitToContent(points = pts, paddingPx = 120, singlePointZoom = 16f)
    }
    // Follow-the-driver on a fixed ~1Hz cadence with a STABLE zoom. This is the
    // zoom-jitter fix: the old effect restarted an animation on every GPS or
    // bearing tick and re-read the zoom mid-flight, feeding transient values
    // back into the next camera target so the map appeared to zoom out and
    // back in. Now recentring only moves lat/lng (plus bearing in heading-up
    // mode); zoom/tilt stay fixed and bounds-fitting never runs while tracking.
    val liveTarget by rememberUpdatedState(current)
    val liveBearing by rememberUpdatedState(bearing)
    LaunchedEffect(followUser, headingUp) {
        if (!followUser) return@LaunchedEffect
        while (isActive) {
            val target = liveTarget
            if (target != null) {
                val pos = CameraPosition.Builder()
                    .target(target)
                    .zoom(followZoom)
                    .bearing(if (headingUp) (liveBearing?.toFloat() ?: cameraPositionState.position.bearing) else 0f)
                    .tilt(if (headingUp) 45f else 0f)
                    .build()
                runCatching { cameraPositionState.animate(CameraUpdateFactory.newCameraPosition(pos), 700) }
            }
            delay(350)
        }
    }
    // A manual pan/zoom drops us into free mode until the operator recenters.
    LaunchedEffect(cameraPositionState.isMoving) {
        if (cameraPositionState.isMoving &&
            cameraPositionState.cameraMoveStartedReason == CameraMoveStartedReason.GESTURE
        ) {
            followUser = false
        }
    }

    val livePath = state.currentDrivingPathNumber ?: trip.currentRowNumber
    val plannedPath = trip.rowSequence.getOrNull(trip.sequenceIndex)
    val nextPlanned = remember(trip.rowSequence, trip.sequenceIndex, plannedPath) {
        val seq = trip.rowSequence
        var idx = trip.sequenceIndex + 1
        var result: Double? = null
        while (idx < seq.size) {
            val c = seq[idx]
            val same = plannedPath?.let { kotlin.math.abs(it - c) < 0.01 } ?: false
            if (!same) { result = c; break }
            idx++
        }
        result
    }
    val offPlan = livePath != null && plannedPath != null &&
        kotlin.math.abs(livePath - plannedPath) >= 0.5 && !trip.isPaused

    // ---- Left/right row labels (iOS rowIndicatorOverlay parity) ----
    // Block the tractor is currently inside, falling back to the trip's blocks.
    val currentBlock = remember(blocks, current) {
        blocks.firstOrNull { RowAttachment.containsPoint(it, current?.latitude, current?.longitude) }
            ?: blocks.firstOrNull()
    }
    // Travel bearing latched with hysteresis so the labels don't flicker while
    // turning at headlands or on GPS jitter (mirrors iOS updateTravelBearing):
    // only accept samples roughly along the row vector, and flip the lock only
    // after 3 consecutive opposite samples.
    var lockedTravelBearing by remember { mutableStateOf<Double?>(null) }
    var bearingFlipSamples by remember { mutableIntStateOf(0) }
    LaunchedEffect(bearing, currentBlock?.rowDirection) {
        val b = bearing ?: return@LaunchedEffect
        val rowDir = currentBlock?.rowDirection ?: return@LaunchedEffect
        var diffToRow = b - rowDir
        while (diffToRow < 0) diffToRow += 360
        while (diffToRow >= 360) diffToRow -= 360
        val alongRow = diffToRow < 45 || diffToRow > 315 || (diffToRow > 135 && diffToRow < 225)
        if (!alongRow) return@LaunchedEffect
        val locked = lockedTravelBearing
        if (locked == null) {
            lockedTravelBearing = b
            bearingFlipSamples = 0
            return@LaunchedEffect
        }
        var diffToLocked = b - locked
        while (diffToLocked < 0) diffToLocked += 360
        while (diffToLocked >= 360) diffToLocked -= 360
        if (diffToLocked > 135 && diffToLocked < 225) {
            bearingFlipSamples += 1
            if (bearingFlipSamples >= 3) {
                lockedTravelBearing = b
                bearingFlipSamples = 0
            }
        } else {
            bearingFlipSamples = 0
        }
    }
    val pathForLabels = livePath ?: plannedPath
    val travelingAlongRow = run {
        val locked = lockedTravelBearing
        val rowDir = currentBlock?.rowDirection
        if (locked == null || rowDir == null) {
            true
        } else {
            var diff = locked - rowDir
            while (diff < 0) diff += 360
            while (diff >= 360) diff -= 360
            diff < 90 || diff > 270
        }
    }
    val maxSequenceRow = remember(trip.rowSequence) {
        trip.rowSequence.maxOfOrNull { kotlin.math.ceil(it).toInt() }
    }
    fun sideLabel(row: Int): String = when {
        row < 1 -> "Start"
        maxSequenceRow != null && row > maxSequenceRow -> "End"
        else -> "Row $row"
    }
    val leftRowLabel = pathForLabels?.let { p ->
        val lower = kotlin.math.floor(p).toInt()
        sideLabel(if (travelingAlongRow) lower + 1 else lower)
    }
    val rightRowLabel = pathForLabels?.let { p ->
        val lower = kotlin.math.floor(p).toInt()
        sideLabel(if (travelingAlongRow) lower else lower + 1)
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = cameraPositionState,
            properties = MapProperties(mapType = if (hybrid) MapType.HYBRID else MapType.NORMAL),
            uiSettings = MapUiSettings(
                zoomControlsEnabled = false,
                mapToolbarEnabled = false,
                compassEnabled = false,
                myLocationButtonEnabled = false,
            ),
            contentPadding = PaddingValues(top = topOverlayHeight, bottom = bottomPanelHeight),
            onMapLoaded = { hudMapLoaded = true },
        ) {
            blocks.forEach { block ->
                val poly = block.polygonPoints?.mapNotNull { it.toLatLng() } ?: emptyList()
                if (poly.size >= 3) {
                    Polygon(
                        points = poly,
                        fillColor = VineColors.LeafGreen.copy(alpha = 0.10f),
                        strokeColor = VineColors.LeafGreen.copy(alpha = 0.8f),
                        strokeWidth = 3f,
                        zIndex = 0f,
                    )
                }
            }
            if (path.size >= 2) {
                Polyline(points = path, color = VineColors.Cyan, width = 9f, zIndex = 1f)
            }
            current?.let {
                Marker(
                    state = MarkerState(position = it),
                    rotation = bearing?.toFloat() ?: 0f,
                    flat = true,
                    anchor = Offset(0.5f, 0.5f),
                    icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_AZURE),
                )
            }
        }

        // Top scrim + live stat bar.
        Column(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .onSizeChanged { topOverlayHeightPx = it.height }
                .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.55f), Color.Transparent)))
                .statusBarsPadding()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                HudCircleButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", onClick = onBack)
                Column(modifier = Modifier.weight(1f)) {
                    Text(trip.displayLabel, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp, maxLines = 1)
                    Text(
                        if (trip.isPaused) "Paused" else "Recording",
                        color = if (trip.isPaused) VineColors.Orange else VineColors.Warning,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
                HudCircleButton(Icons.Filled.Notes, "Trip details", onClick = onShowDetails)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                HudStat(Icons.Filled.Schedule, clockDuration(durationSeconds), "Time", Modifier.weight(1f))
                HudStat(Icons.Filled.Straighten, formatDistance(trip.totalDistance) ?: "0 m", "Distance", Modifier.weight(1f))
                HudStat(Icons.Filled.Speed, speedKmh?.let { "%.0f".format(it) } ?: "\u2014", "km/h", Modifier.weight(1f))
            }
            HudGpsPill(accuracy)
            // Repairs / Growth quick-pin actions (iOS tripInfoBar parity).
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                HudActionPill(Icons.Filled.Place, "Repairs", VineColors.Orange, Modifier.weight(1f)) { hudLauncherMode = "Repairs" }
                HudActionPill(Icons.Filled.Place, "Growth", VineColors.LeafGreen, Modifier.weight(1f)) { hudLauncherMode = "Growth" }
            }
        }

        // Map controls docked top-right below the stat bar (iOS mapControls
        // parity) so they never sit behind the bottom panel.
        Column(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(top = topOverlayHeight + 12.dp, end = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            HudCircleButton(
                if (followUser) Icons.Filled.NearMe else Icons.Filled.MyLocation,
                "Recenter",
                active = followUser,
                onClick = {
                    // Respect the operator's manual zoom when re-engaging follow.
                    val z = cameraPositionState.position.zoom
                    followZoom = if (z in 14f..21f) z else 18f
                    followUser = true
                },
            )
            HudCircleButton(
                if (headingUp) Icons.Filled.Navigation else Icons.Filled.Explore,
                if (headingUp) "Switch to north-up" else "Switch to heading-up",
                active = headingUp,
                onClick = {
                    headingUp = !headingUp
                    if (!headingUp && !followUser) {
                        // Flatten to north-up in place without touching zoom.
                        val flat = CameraPosition.Builder(cameraPositionState.position).bearing(0f).tilt(0f).build()
                        scope.launch {
                            runCatching { cameraPositionState.animate(CameraUpdateFactory.newCameraPosition(flat), 400) }
                        }
                    }
                },
            )
            HudCircleButton(
                Icons.Filled.SwapHoriz,
                "Toggle row labels",
                active = showRowChips,
                onClick = { showRowChips = !showRowChips },
            )
            HudCircleButton(Icons.Filled.Layers, "Map type", onClick = { hybrid = !hybrid })
        }

        // Left/right adjacent-row chips (iOS rowIndicatorOverlay parity).
        if (showRowChips && rowTrackingEnabled && leftRowLabel != null && rightRowLabel != null && currentBlock != null) {
            RowSideChip(
                isLeft = true,
                label = leftRowLabel,
                modifier = Modifier.align(Alignment.CenterStart).padding(start = 12.dp),
            )
            RowSideChip(
                isLeft = false,
                label = rightRowLabel,
                modifier = Modifier.align(Alignment.CenterEnd).padding(end = 12.dp),
            )
        }

        // Bottom control panel — compact by default so the map stays the
        // primary focus; secondary controls expand on demand.
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .onSizeChanged { bottomPanelHeightPx = it.height },
        ) {
            if (offPlan && plannedPath != null) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(VineColors.Destructive)
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Outlined.ErrorOutline, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                    Text(
                        "Off planned path \u2014 head to ${formatPath(plannedPath)}",
                        color = Color.White,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            Surface(
                color = vine.cardBackground,
                shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
                shadowElevation = 12.dp,
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 340.dp)
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp, vertical = 12.dp)
                        .navigationBarsPadding(),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    if (trip.rowSequence.isNotEmpty() || livePath != null) {
                        RowGuidanceBar(
                            livePath = livePath,
                            plannedPath = plannedPath,
                            nextPath = nextPlanned,
                            lockConfident = state.rowLockIsConfident,
                        )
                    }
                    if (!state.isTracking) {
                        Text(
                            "GPS tracking is off. Enable location to record this trip's path.",
                            color = VineColors.Orange,
                            fontSize = 12.sp,
                        )
                    }
                    val isSprayTrip = linkedSpray != null ||
                        trip.tripFunction == "spraying" ||
                        (trip.totalTanks ?: 0) > 0 ||
                        trip.tankSessions.isNotEmpty()
                    val hasSecondaryControls = !trip.isPaused && (trip.rowSequence.isNotEmpty() || isSprayTrip)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedButton(
                            onClick = { vm.setTripPaused(trip.id, !trip.isPaused) },
                            enabled = !state.tripBusy,
                            modifier = Modifier.weight(1f),
                        ) {
                            Icon(if (trip.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause, contentDescription = null)
                            Text(if (trip.isPaused) "  Resume" else "  Pause")
                        }
                        Button(
                            onClick = onEndConfirmed,
                            enabled = !state.tripBusy,
                            modifier = Modifier.weight(1f),
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Destructive),
                        ) {
                            Icon(Icons.Filled.Stop, contentDescription = null)
                            Text("  End")
                        }
                        if (hasSecondaryControls) {
                            OutlinedButton(
                                onClick = { panelExpanded = !panelExpanded },
                                modifier = Modifier.height(40.dp),
                                contentPadding = PaddingValues(horizontal = 10.dp),
                            ) {
                                Icon(
                                    if (panelExpanded) Icons.Filled.ExpandMore else Icons.Filled.ExpandLess,
                                    contentDescription = if (panelExpanded) "Hide trip controls" else "More trip controls",
                                )
                            }
                        }
                    }
                    if (panelExpanded && !trip.isPaused) {
                        if (trip.rowSequence.isNotEmpty()) {
                            Divider(vine.cardBorder)
                            RowCoverageControls(vm = vm, trip = trip, busy = state.tripBusy)
                        }
                        if (isSprayTrip) {
                            Divider(vine.cardBorder)
                            TankSessionControls(vm = vm, trip = trip, linkedSpray = linkedSpray, busy = state.tripBusy)
                        }
                    }
                }
            }
        }

        // Repairs/Growth quick-pin launcher over the HUD — mirrors the iOS
        // RepairsGrowthView sheets. Back (or Cancel) returns to the live map.
        hudLauncherMode?.let { mode ->
            BackHandler { hudLauncherMode = null }
            Surface(modifier = Modifier.fillMaxSize(), color = vine.appBackground) {
                PinCategoryLauncherScreen(
                    vm = vm,
                    state = state,
                    initialMode = mode,
                    onBack = { hudLauncherMode = null },
                    onOpenList = { hudLauncherMode = null },
                )
            }
        }
    }
}

/** Tinted Repairs/Growth quick-action pill in the HUD top bar (iOS parity). */
@Composable
private fun HudActionPill(
    icon: ImageVector,
    label: String,
    tint: Color,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(tint.copy(alpha = 0.35f))
            .clickable(onClick = onClick)
            .padding(vertical = 9.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(6.dp))
        Text(label, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** Left/right adjacent-row chip overlaid on the live map (iOS rowChip parity). */
@Composable
private fun RowSideChip(isLeft: Boolean, label: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .width(78.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Color.Black.copy(alpha = 0.55f))
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(
            if (isLeft) Icons.AutoMirrored.Filled.ArrowBack else Icons.AutoMirrored.Filled.ArrowForward,
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(14.dp),
        )
        AnimatedContent(targetState = label, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "rowSide") { v ->
            Text(v, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp)
        }
    }
}

/** Circular translucent map-overlay button used in the active-trip HUD. */
@Composable
private fun HudCircleButton(
    icon: ImageVector,
    contentDescription: String,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(if (active) VineColors.Primary else Color.Black.copy(alpha = 0.55f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = Color.White, modifier = Modifier.size(22.dp))
    }
}

/** A single live stat tile (value + caption) in the HUD top bar. */
@Composable
private fun HudStat(icon: ImageVector, value: String, caption: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(Color.Black.copy(alpha = 0.45f))
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Icon(icon, contentDescription = null, tint = Color.White.copy(alpha = 0.7f), modifier = Modifier.size(13.dp))
            Text(caption, color = Color.White.copy(alpha = 0.7f), fontSize = 10.sp)
        }
        Text(value, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp, maxLines = 1)
    }
}

/** GPS-quality pill driven by the latest horizontal accuracy (metres). */
@Composable
private fun HudGpsPill(accuracyMetres: Double?) {
    val (label, color) = when {
        accuracyMetres == null -> "GPS searching" to VineColors.Orange
        accuracyMetres <= 8 -> "GPS strong" to VineColors.Success
        accuracyMetres <= 20 -> "GPS fair" to VineColors.Warning
        else -> "GPS weak" to VineColors.Destructive
    }
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(Color.Black.copy(alpha = 0.45f))
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(color))
        Text(label, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Medium)
        accuracyMetres?.let {
            Text("\u00b1${it.roundToInt()} m", color = Color.White.copy(alpha = 0.7f), fontSize = 11.sp)
        }
    }
}

/** Current / next driving-path guidance row shown above the HUD controls. */
@Composable
private fun RowGuidanceBar(
    livePath: Double?,
    plannedPath: Double?,
    nextPath: Double?,
    lockConfident: Boolean,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RowGuidanceChip(
            caption = "Current path",
            value = livePath?.let { formatPath(it) } ?: "\u2014",
            accent = if (lockConfident) VineColors.LeafGreen else vine.textSecondary,
            modifier = Modifier.weight(1f),
        )
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = vine.textSecondary,
            modifier = Modifier.size(20.dp),
        )
        RowGuidanceChip(
            caption = "Next path",
            value = nextPath?.let { formatPath(it) } ?: "\u2014",
            accent = VineColors.Primary,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun RowGuidanceChip(caption: String, value: String, accent: Color, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(accent.copy(alpha = 0.12f))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(caption, color = vine.textSecondary, fontSize = 11.sp)
        AnimatedContent(targetState = value, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "path") { v ->
            Text(v, color = accent, fontWeight = FontWeight.Bold, fontSize = 22.sp)
        }
    }
}

@Composable
private fun ActiveTripControls(
    vm: AppViewModel,
    trip: Trip,
    linkedSpray: SprayRecord?,
    durationSeconds: Long,
    busy: Boolean,
    tracking: Boolean,
    onEndConfirmed: () -> Unit,
) {
    val vine = LocalVineColors.current

    // If location permission is granted after the trip started, resume capture.
    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { granted ->
        if (granted.values.any { it }) vm.resumeTrackingForActive()
    }

    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                StatusBadge(if (trip.isPaused) "Paused" else "Recording", if (trip.isPaused) VineColors.Orange else VineColors.Warning)
                Spacer(Modifier.weight(1f))
                Text(clockDuration(durationSeconds), fontWeight = FontWeight.Bold, fontSize = 22.sp, color = vine.textPrimary)
            }

            if (!tracking) {
                Text(
                    "GPS tracking is off. Allow location to record this trip's path.",
                    fontSize = 12.sp,
                    color = VineColors.Orange,
                )
                OutlinedButton(
                    onClick = {
                        permLauncher.launch(
                            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Enable GPS tracking") }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(
                    onClick = { vm.setTripPaused(trip.id, !trip.isPaused) },
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(if (trip.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause, contentDescription = null)
                    Text(if (trip.isPaused) "  Resume" else "  Pause")
                }
                Button(
                    onClick = onEndConfirmed,
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Destructive),
                ) {
                    Icon(Icons.Filled.Stop, contentDescription = null)
                    Text("  End trip")
                }
            }

            if (trip.rowSequence.isNotEmpty()) {
                Divider(vine.cardBorder)
                TripRowPlanProgress(trip)
                // Manual coverage controls hide while paused (capture is stopped).
                if (!trip.isPaused) {
                    RowCoverageControls(vm = vm, trip = trip, busy = busy)
                }
            }

            // Live tank Start/End controls (Stage 3F-2b) — spray trips only.
            val isSprayTrip = linkedSpray != null ||
                trip.tripFunction == "spraying" ||
                (trip.totalTanks ?: 0) > 0 ||
                trip.tankSessions.isNotEmpty()
            if (isSprayTrip && !trip.isPaused) {
                Divider(vine.cardBorder)
                TankSessionControls(vm = vm, trip = trip, linkedSpray = linkedSpray, busy = busy)
            }
        }
    }
}

/**
 * Live tank-session controls (Stage 3F-2b): Start Tank when no tank is open,
 * End Tank (with confirmation) when one is active. Mirrors the iOS tank card
 * semantics. No fill timer (parked for 3F-2c). Spray trips only; hidden while
 * paused. Persists via the dedicated tank-session patch.
 */
@Composable
private fun TankSessionControls(vm: AppViewModel, trip: Trip, linkedSpray: SprayRecord?, busy: Boolean) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val totalTanks = maxOf(linkedSpray?.tankCount ?: 0, trip.totalTanks ?: 0)
    val active = trip.activeTankNumber
    val completedCount = trip.tankSessions.count { !it.isOpen }
    var confirmEnd by remember { mutableStateOf(false) }
    val fillTimerEnabled = remember { OperationPrefsStore(context).load().fillTimerEnabled }
    val isFilling = trip.isFillingTank

    // Live fill timer: tick once a second while a fill is running so the m:ss
    // readout stays current. Driven off the open fill session's start time.
    val fillStartMs = remember(trip.tankSessions, isFilling) {
        if (isFilling) trip.tankSessions.lastOrNull { it.fillStartTime != null && it.fillEndTime == null }?.fillStartEpochMs else null
    }
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(fillStartMs) {
        while (fillStartMs != null) {
            nowMs = System.currentTimeMillis()
            delay(1000)
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Filled.LocalDrink, contentDescription = null, tint = VineColors.Cyan, modifier = Modifier.size(16.dp))
            Text("Tanks", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Spacer(Modifier.weight(1f))
            if (isFilling && fillStartMs != null) {
                val elapsed = ((nowMs - fillStartMs) / 1000).coerceAtLeast(0L)
                Text(
                    "Filling ${formatFillElapsed(elapsed)}",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VineColors.Cyan,
                )
            } else {
                val summary = when {
                    active != null -> if (totalTanks > 0) "Tank $active of $totalTanks" else "Tank $active"
                    totalTanks > 0 -> "$completedCount of $totalTanks done"
                    completedCount > 0 -> "$completedCount done"
                    else -> "Not started"
                }
                Text(summary, fontSize = 12.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
            }
        }
        if (active != null) {
            Button(
                onClick = { confirmEnd = true },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Orange),
            ) {
                Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.size(18.dp))
                Text("  End tank")
            }
        } else {
            Button(
                onClick = { vm.startTankSession(trip.id) },
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Cyan),
            ) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                Text("  Start tank")
            }
        }
        // Optional fill timer (device-local setting). Mirrors iOS: filling a
        // tank happens between tanks, so Start Fill is offered only when no
        // tank is active. Stop Fill is always available while filling.
        if (fillTimerEnabled) {
            if (isFilling) {
                OutlinedButton(
                    onClick = { vm.stopFillTimer(trip.id) },
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.size(18.dp), tint = VineColors.Cyan)
                    Text("  Stop fill", color = VineColors.Cyan)
                }
            } else if (active == null) {
                OutlinedButton(
                    onClick = { vm.startFillTimer(trip.id) },
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.Timer, contentDescription = null, modifier = Modifier.size(18.dp), tint = VineColors.Cyan)
                    Text("  Start fill", color = VineColors.Cyan)
                }
            }
        }
    }

    if (confirmEnd) {
        AlertDialog(
            onDismissRequest = { confirmEnd = false },
            title = { Text("End tank ${active ?: ""}?") },
            text = { Text("This finalizes the current tank session.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmEnd = false
                    vm.endTankSession(trip.id)
                }) { Text("End tank", color = VineColors.Orange) }
            },
            dismissButton = { TextButton(onClick = { confirmEnd = false }) { Text("Cancel") } },
        )
    }
}

/**
 * Manual, operator-driven row coverage controls (Stage 3D-1): mark the current
 * planned path complete, skip it, or undo the last action. No automatic
 * GPS/row-lock completion. Done/Skip disappear once the sequence is fully
 * covered; Undo is disabled at the start of the sequence.
 */
@Composable
private fun RowCoverageControls(vm: AppViewModel, trip: Trip, busy: Boolean) {
    val vine = LocalVineColors.current
    val total = trip.rowSequence.size
    val index = trip.sequenceIndex
    val sequenceComplete = index >= total
    val canUndo = index > 0
    val currentPath = trip.rowSequence.getOrNull(index)

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (sequenceComplete) {
            Text(
                "All planned paths covered.",
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = VineColors.LeafGreen,
            )
        } else {
            currentPath?.let {
                Text(
                    "Acting on path ${TripRowSequencePlanner.formatPath(it)}",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (!sequenceComplete) {
                Button(
                    onClick = { vm.markCurrentPathComplete(trip.id) },
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.LeafGreen),
                ) {
                    Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Done row")
                }
                OutlinedButton(
                    onClick = { vm.skipCurrentPath(trip.id) },
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Filled.SkipNext, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Skip")
                }
            }
            if (canUndo) {
                OutlinedButton(
                    onClick = { vm.undoLastRowAction(trip.id) },
                    enabled = !busy,
                    modifier = if (sequenceComplete) Modifier.fillMaxWidth() else Modifier.weight(1f),
                ) {
                    Icon(Icons.AutoMirrored.Filled.Undo, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Undo")
                }
            }
        }
    }
}

/**
 * Read-only live row-plan progress. Shows the tracking pattern, current/next
 * planned path, sequence position ("X of N") and a progress bar. Never mutates
 * sequence state or coverage — purely reflects what the row plan seeded.
 */
@Composable
private fun TripRowPlanProgress(trip: Trip) {
    val vine = LocalVineColors.current
    val total = trip.rowSequence.size
    if (total == 0) return
    val pattern = TrackingPattern.fromRaw(trip.trackingPattern)
    val index = trip.sequenceIndex.coerceIn(0, total - 1)
    val currentPath = trip.currentRowNumber ?: trip.rowSequence.getOrNull(index)
    val nextPath = trip.nextRowNumber ?: trip.rowSequence.getOrNull(index + 1)

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Filled.Timeline, contentDescription = null, tint = VineColors.Indigo, modifier = Modifier.size(16.dp))
            Text(pattern.title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Spacer(Modifier.weight(1f))
            Text("${index + 1} of $total", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = vine.textSecondary)
        }
        LinearProgressIndicator(
            progress = { ((index + 1).toFloat() / total.toFloat()).coerceIn(0f, 1f) },
            modifier = Modifier.fillMaxWidth(),
            color = VineColors.Indigo,
            trackColor = vine.cardBorder,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            currentPath?.let {
                Text("Current path ${TripRowSequencePlanner.formatPath(it)}", fontSize = 12.sp, color = vine.textSecondary)
            }
            nextPath?.let {
                Text("Next ${TripRowSequencePlanner.formatPath(it)}", fontSize = 12.sp, color = vine.textSecondary)
            }
        }
    }
}

/**
 * Read-only row-plan summary for the Trip detail screen. Reflects the seeded
 * plan and any coverage already recorded by the existing tracking layer.
 */
@Composable
private fun TripRowPlanSummaryCard(trip: Trip) {
    val vine = LocalVineColors.current
    val total = trip.rowSequence.size
    if (total == 0) return
    val pattern = TrackingPattern.fromRaw(trip.trackingPattern)
    val index = trip.sequenceIndex.coerceIn(0, total - 1)
    val currentPath = trip.currentRowNumber ?: trip.rowSequence.getOrNull(index)
    val nextPath = trip.nextRowNumber ?: trip.rowSequence.getOrNull(index + 1)
    val completed = trip.completedPaths?.size ?: 0
    val skipped = trip.skippedPaths?.size ?: 0

    VineyardCard {
        DetailRow(Icons.Filled.Timeline, "Pattern", pattern.title, VineColors.Indigo)
        Divider(vine.cardBorder)
        DetailRow(Icons.Filled.Route, "Paths planned", total.toString(), VineColors.Cyan)
        Divider(vine.cardBorder)
        DetailRow(Icons.Filled.NearMe, "Progress", "${index + 1} of $total", VineColors.Indigo)
        currentPath?.let {
            Divider(vine.cardBorder)
            DetailRow(Icons.Filled.NearMe, "Current path", TripRowSequencePlanner.formatPath(it), VineColors.LeafGreen)
        }
        nextPath?.let {
            Divider(vine.cardBorder)
            DetailRow(Icons.Filled.NearMe, "Next path", TripRowSequencePlanner.formatPath(it), VineColors.EarthBrown)
        }
        if (completed > 0) {
            Divider(vine.cardBorder)
            DetailRow(Icons.Filled.Route, "Paths completed", completed.toString(), VineColors.LeafGreen)
        }
        if (skipped > 0) {
            Divider(vine.cardBorder)
            DetailRow(Icons.Filled.Route, "Paths skipped", skipped.toString(), VineColors.Orange)
        }
    }
}

/** Undervine weeding method subtypes (iOS `TripFunction.undervineWeedingSubtypes` parity). */
private val undervineWeedingSubtypeFunctions: List<Pair<String, String>> = listOf(
    "undervineMowing" to "Mowing",
    "undervineMulticlean" to "Multiclean",
    "undervineRollHacke" to "Roll Hacke",
    "undervineDisc" to "Undervine Disc",
    "undervineKnifing" to "Undervine Knifing",
)

/** Icon for each tracking pattern card (mirrors the iOS `TrackingPattern.icon` intent). */
private fun trackingPatternIcon(pattern: TrackingPattern): ImageVector = when (pattern) {
    TrackingPattern.SEQUENTIAL -> Icons.Filled.FormatListNumbered
    TrackingPattern.EVERY_SECOND_ROW -> Icons.Filled.SwapVert
    TrackingPattern.FIVE_THREE -> Icons.Filled.Shuffle
    TrackingPattern.UP_AND_BACK -> Icons.Filled.Repeat
    TrackingPattern.TWO_ROW_UP_BACK -> Icons.Filled.SyncAlt
    TrackingPattern.CUSTOM -> Icons.Filled.Tune
    TrackingPattern.FREE_DRIVE -> Icons.Filled.Gesture
}

/**
 * Start Maintenance Trip sheet — iOS `StartTripSheet` parity. Card-based
 * guided setup: hero intro, multi-block selector, trip function + Add,
 * trip title, tracking pattern cards, start path & direction, proposed row
 * sequence preview, machine, operator, and a validated Start Trip button.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StartTripSheet(
    vm: AppViewModel,
    state: AppUiState,
    onDismiss: () -> Unit,
    onStarted: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    var paddockIds by remember { mutableStateOf<List<String>>(emptyList()) }
    var functionRaw by remember { mutableStateOf("slashing") }
    var title by remember { mutableStateOf("") }
    var pattern by remember { mutableStateOf(TrackingPattern.SEQUENTIAL) }
    var startPath by remember { mutableStateOf(0.5) }
    var directionHigherFirst by remember { mutableStateOf(true) }
    var machineId by remember { mutableStateOf<String?>(null) }
    var machineDefaulted by remember { mutableStateOf(false) }
    var startEngineHoursText by remember { mutableStateOf("") }
    var operatorName by remember { mutableStateOf(state.userDisplayName ?: "") }
    var saving by remember { mutableStateOf(false) }
    var showBlockPicker by remember { mutableStateOf(false) }
    var showAddFunction by remember { mutableStateOf(false) }
    var functionMenu by remember { mutableStateOf(false) }
    var machineMenu by remember { mutableStateOf(false) }
    var pathMenu by remember { mutableStateOf(false) }

    // Seeding Details (iOS `StartTripSheet` parity — only used when the
    // selected trip function is Seeding). Box pickers default to the iOS
    // defaults: Front 3/4-1-N, Rear Full-3-F.
    var seedingExpanded by remember { mutableStateOf(false) }
    var useFrontBox by remember { mutableStateOf(true) }
    var useBackBox by remember { mutableStateOf(true) }
    var seedFrontMix by remember { mutableStateOf("") }
    var seedBackMix by remember { mutableStateOf("") }
    var seedFrontRate by remember { mutableStateOf("") }
    var seedBackRate by remember { mutableStateOf("") }
    var sowingDepth by remember { mutableStateOf("") }
    var seedFrontShutter by remember { mutableStateOf("3/4") }
    var seedFrontFlap by remember { mutableStateOf("1") }
    var seedFrontWheel by remember { mutableStateOf("N") }
    var seedFrontVolume by remember { mutableStateOf("") }
    var seedFrontGearbox by remember { mutableStateOf("") }
    var seedBackShutter by remember { mutableStateOf("Full") }
    var seedBackFlap by remember { mutableStateOf("3") }
    var seedBackWheel by remember { mutableStateOf("F") }
    var seedBackVolume by remember { mutableStateOf("") }
    var seedBackGearbox by remember { mutableStateOf("") }
    var seedMixLines by remember { mutableStateOf<List<SeedingMixLine>>(emptyList()) }
    var copiedFromNote by remember { mutableStateOf<String?>(null) }
    var copyMissing by remember { mutableStateOf(false) }
    var copyFoundButEmpty by remember { mutableStateOf(false) }

    // Selected blocks sorted lowest-row-first (iOS `rowOrderSort` parity).
    val selectedPaddocks = remember(state.paddocks, paddockIds) {
        state.paddocks.filter { it.id in paddockIds }
            .sortedWith(TripRowSequencePlanner.rowOrderComparator)
    }
    val hasRowGeometry = TripRowSequencePlanner.hasAnyRowGeometry(selectedPaddocks)

    // Clamp/snap the start path whenever the block selection changes.
    LaunchedEffect(paddockIds) {
        startPath = if (selectedPaddocks.isEmpty()) {
            0.5
        } else {
            TripRowSequencePlanner.clampedStartPath(startPath, selectedPaddocks)
        }
    }

    // Machines available for job costing (iOS `availableMachines` parity),
    // defaulting once to the most recently used machine or the only one.
    val machines = remember(state.machines) { state.machines.filter { it.availableForJobCosting } }
    LaunchedEffect(machines) {
        if (!machineDefaulted && machines.isNotEmpty()) {
            machineDefaulted = true
            val availableIds = machines.map { it.id }.toSet()
            val recent = state.trips
                .filter { it.machineId != null }
                .sortedByDescending { it.startEpochMs ?: 0L }
                .firstOrNull { it.machineId in availableIds }
                ?.machineId
            machineId = recent ?: machines.singleOrNull()?.id
        }
    }

    val builtinOptions = remember { builtInTripFunctions.sortedBy { it.second.lowercase() } }
    val customOptions = remember(state.vineyardTripFunctions) {
        state.vineyardTripFunctions
            .filter { it.isSelectable }
            .sortedBy { it.label.lowercase() }
            .map { it.tripFunctionKey to it.label }
    }
    val selectedFunctionLabel = (builtinOptions + undervineWeedingSubtypeFunctions + customOptions)
        .firstOrNull { it.first == functionRaw }?.second ?: "Select function"
    val canManageFunctions = state.currentRole == "owner" || state.currentRole == "manager"

    val sequence = remember(selectedPaddocks, pattern, startPath, directionHigherFirst) {
        if (!hasRowGeometry || pattern == TrackingPattern.FREE_DRIVE) {
            emptyList()
        } else {
            TripRowSequencePlanner.generateSequence(selectedPaddocks, pattern, startPath, directionHigherFirst)
        }
    }
    val isSeedingSelected = functionRaw == "seeding"
    val seedBoxesInvalid = isSeedingSelected && !useFrontBox && !useBackBox
    val canStart = paddockIds.isNotEmpty() && !seedBoxesInvalid

    /** iOS `buildSeedingDetails` parity — tolerant numeric parsing included. */
    fun buildSeedingDetails(): SeedingDetails {
        fun trimmedOrNull(s: String): String? = s.trim().ifBlank { null }
        val front = if (useFrontBox) {
            SeedingBox(
                mixName = trimmedOrNull(seedFrontMix),
                ratePerHa = parseSeedingNumber(seedFrontRate),
                shutterSlide = trimmedOrNull(seedFrontShutter),
                bottomFlap = trimmedOrNull(seedFrontFlap),
                meteringWheel = trimmedOrNull(seedFrontWheel),
                seedVolumeKg = parseSeedingNumber(seedFrontVolume),
                gearboxSetting = parseSeedingNumber(seedFrontGearbox),
            )
        } else {
            null
        }
        val back = if (useBackBox) {
            SeedingBox(
                mixName = trimmedOrNull(seedBackMix),
                ratePerHa = parseSeedingNumber(seedBackRate),
                shutterSlide = trimmedOrNull(seedBackShutter),
                bottomFlap = trimmedOrNull(seedBackFlap),
                meteringWheel = trimmedOrNull(seedBackWheel),
                seedVolumeKg = parseSeedingNumber(seedBackVolume),
                gearboxSetting = parseSeedingNumber(seedBackGearbox),
            )
        } else {
            null
        }
        val lines = fillCalculatedPercentOfMix(seedMixLines.filter { it.hasAnyValue })
        return SeedingDetails(
            frontBox = front,
            backBox = back,
            sowingDepthCm = parseSeedingNumber(sowingDepth),
            mixLines = lines.ifEmpty { null },
        )
    }

    /**
     * iOS `applyPreviousSeedingSetup` parity: find the most recent finished
     * seeding trip, prefer one with genuinely useful operator-entered values,
     * and copy its box toggles, box settings, sowing depth and mix lines into
     * the form. Trip-specific fields (block, operator, pattern) are NOT copied.
     */
    fun applyPreviousSeedingSetup() {
        val vineyardId = state.selectedVineyardId
        val candidates = state.trips
            .filter { t ->
                val raw = t.tripFunction ?: return@filter false
                (vineyardId == null || t.vineyardId == vineyardId) &&
                    (raw == "seeding" || raw.lowercase().contains("seed")) &&
                    !t.isActive && !t.isPaused
            }
            .sortedByDescending { it.endEpochMs ?: it.startEpochMs ?: 0L }
        val chosen = candidates.firstOrNull { it.seedingDetails?.hasMeaningfulValue == true }
            ?: candidates.firstOrNull { it.seedingDetails?.hasAnyValue == true }
            ?: candidates.firstOrNull()
        if (chosen == null) {
            copyMissing = true
            copyFoundButEmpty = false
            copiedFromNote = null
            return
        }
        val details = chosen.seedingDetails ?: SeedingDetails()
        copyMissing = false
        val isUseful = details.hasMeaningfulValue
        copyFoundButEmpty = !isUseful

        val front = details.frontBox
        if (front != null) {
            useFrontBox = true
            seedFrontMix = front.mixName ?: ""
            seedFrontRate = front.ratePerHa?.let(::seedTrimNum) ?: ""
            front.shutterSlide?.takeIf { it.isNotEmpty() }?.let { seedFrontShutter = it }
            front.bottomFlap?.takeIf { it.isNotEmpty() }?.let { seedFrontFlap = it }
            front.meteringWheel?.takeIf { it.isNotEmpty() }?.let { seedFrontWheel = it }
            seedFrontVolume = front.seedVolumeKg?.let(::seedTrimNum) ?: ""
            seedFrontGearbox = front.gearboxSetting?.let(::seedTrimNum) ?: ""
        } else {
            useFrontBox = false
        }
        val back = details.backBox
        if (back != null) {
            useBackBox = true
            seedBackMix = back.mixName ?: ""
            seedBackRate = back.ratePerHa?.let(::seedTrimNum) ?: ""
            back.shutterSlide?.takeIf { it.isNotEmpty() }?.let { seedBackShutter = it }
            back.bottomFlap?.takeIf { it.isNotEmpty() }?.let { seedBackFlap = it }
            back.meteringWheel?.takeIf { it.isNotEmpty() }?.let { seedBackWheel = it }
            seedBackVolume = back.seedVolumeKg?.let(::seedTrimNum) ?: ""
            seedBackGearbox = back.gearboxSetting?.let(::seedTrimNum) ?: ""
        } else {
            useBackBox = false
        }
        // Very early seeding records may have no boxes at all — keep the form
        // usable by defaulting Front Box on after copy (iOS parity).
        if (details.frontBox == null && details.backBox == null) useFrontBox = true
        sowingDepth = details.sowingDepthCm?.let(::seedTrimNum) ?: ""
        // Re-id copied mix lines so edits don't bleed into the source trip.
        seedMixLines = details.mixLines.orEmpty().map { line ->
            SeedingMixLine(
                id = java.util.UUID.randomUUID().toString(),
                name = line.name,
                percentOfMix = line.percentOfMix,
                seedBox = line.seedBox,
                kgPerHa = line.kgPerHa,
                supplierManufacturer = line.supplierManufacturer,
            )
        }
        copiedFromNote = if (isUseful) describeCopiedSeedingTrip(chosen) else null
        seedingExpanded = true
    }

    fun start() {
        if (saving) return
        saving = true
        val primary = selectedPaddocks.firstOrNull()
        val paddockName = when {
            selectedPaddocks.size > 1 -> selectedPaddocks.joinToString(", ") { it.name }
            else -> primary?.name
        }
        val effectivePattern = if (hasRowGeometry) pattern else TrackingPattern.FREE_DRIVE
        val machine = machines.firstOrNull { it.id == machineId }
        val engineHours = if (machineId != null) {
            startEngineHoursText.trim().replace(",", ".").toDoubleOrNull()?.takeIf { it >= 0 }
        } else {
            null
        }
        // Always persist seeding details when the function is Seeding (even if
        // only box toggles) so "Copy from previous seeding job" works next time
        // (iOS parity).
        val seedingDetails = if (isSeedingSelected) {
            buildSeedingDetails().takeIf { it.frontBox != null || it.backBox != null || it.hasAnyValue }
        } else {
            null
        }
        vm.startTrip(
            paddockId = primary?.id,
            paddockName = paddockName,
            paddockIds = selectedPaddocks.map { it.id },
            personName = operatorName.trim(),
            tripFunction = functionRaw,
            tripTitle = title.trim(),
            machineId = machineId,
            tractorId = machine?.legacyTractorId,
            workTaskId = null,
            operatorUserId = state.currentUserId,
            operatorCategoryId = state.members.firstOrNull { it.userId == state.currentUserId }?.operatorCategoryId,
            startEngineHours = engineHours,
            trackingPattern = effectivePattern.rawValue,
            rowSequence = sequence,
            seedingDetails = seedingDetails,
        ) { ok ->
            saving = false
            if (ok) vm.activeTripIdOrNull()?.let(onStarted)
        }
    }

    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { _ -> start() } // start regardless; tracking begins if any permission granted

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = vine.appBackground,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            // Header: Cancel + centred title (iOS nav-bar parity).
            Box(Modifier.fillMaxWidth().padding(horizontal = 8.dp)) {
                TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.CenterStart)) {
                    Text("Cancel", color = VineColors.Primary, fontSize = 15.sp)
                }
                Text(
                    "Start Maintenance Trip",
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                    modifier = Modifier.align(Alignment.Center),
                )
            }

            // Hero / intro
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(76.dp)
                        .clip(CircleShape)
                        .background(VineColors.EarthBrown.copy(alpha = 0.15f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Filled.Build,
                        contentDescription = null,
                        tint = VineColors.EarthBrown,
                        modifier = Modifier.size(34.dp),
                    )
                }
                Spacer(Modifier.height(4.dp))
                Text("Maintenance Trip", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Text(
                    "Track a general vineyard trip with row guidance",
                    fontSize = 14.sp,
                    color = vine.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }

            // BLOCK
            StartTripSection("Block", Icons.Filled.GridView, VineColors.LeafGreen) {
                val (blockTitle, blockSubtitle) = when {
                    selectedPaddocks.size == 1 -> {
                        val p = selectedPaddocks.first()
                        val rows = p.rows.orEmpty().map { it.number }.sorted()
                        val range = if (rows.isEmpty()) "Rows not configured" else TripRowSequencePlanner.compactRowRangeLabel(rows)
                        p.name to listOfNotNull(range, p.primaryVarietyName).joinToString(" · ")
                    }
                    selectedPaddocks.isNotEmpty() ->
                        "${selectedPaddocks.size} blocks selected" to selectedPaddocks.joinToString(", ") { it.name }
                    else ->
                        "No blocks selected" to "Tap to choose one or more blocks (optional)"
                }
                StartTripSelectorCard(
                    icon = Icons.Filled.Grass,
                    tint = VineColors.LeafGreen,
                    title = blockTitle,
                    subtitle = blockSubtitle,
                    onClick = { showBlockPicker = true },
                )
                if (selectedPaddocks.size == 1 && !selectedPaddocks.first().rows.isNullOrEmpty()) {
                    val p = selectedPaddocks.first()
                    val rows = p.rows.orEmpty().map { it.number }.sorted()
                    StartTripStatsRow(
                        listOf(
                            "${p.rowCount}" to TripRowSequencePlanner.compactRowRangeLabel(rows),
                            "%.2f".format(p.areaHectares) to "Hectares",
                            "${p.effectiveVineCount}" to "Vines",
                        ),
                    )
                } else if (selectedPaddocks.size > 1) {
                    StartTripStatsRow(
                        listOf(
                            "${selectedPaddocks.size}" to "Blocks",
                            "%.2f".format(selectedPaddocks.sumOf { it.areaHectares }) to "Hectares",
                            "${selectedPaddocks.sumOf { it.rowCount }}" to "Rows",
                            "${selectedPaddocks.sumOf { it.effectiveVineCount }}" to "Vines",
                        ),
                    )
                }
            }

            // TRIP FUNCTION
            StartTripSection("Trip Function", Icons.Filled.Build, VineColors.EarthBrown) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.weight(1f)) {
                        StartTripSelectorCard(
                            icon = tripFunctionIcon(functionRaw),
                            tint = VineColors.EarthBrown,
                            title = "Function",
                            subtitle = selectedFunctionLabel,
                            onClick = { functionMenu = true },
                        )
                        DropdownMenu(expanded = functionMenu, onDismissRequest = { functionMenu = false }) {
                            StartTripMenuHeader("Built-in")
                            builtinOptions.forEach { (raw, label) ->
                                StartTripMenuItem(label, raw == functionRaw) { functionRaw = raw; functionMenu = false }
                            }
                            StartTripMenuHeader("Undervine Weeding")
                            undervineWeedingSubtypeFunctions.forEach { (raw, label) ->
                                StartTripMenuItem(label, raw == functionRaw) { functionRaw = raw; functionMenu = false }
                            }
                            if (customOptions.isNotEmpty()) {
                                StartTripMenuHeader("Custom")
                                customOptions.forEach { (raw, label) ->
                                    StartTripMenuItem(label, raw == functionRaw) { functionRaw = raw; functionMenu = false }
                                }
                            }
                        }
                    }
                    val addTint = if (canManageFunctions) VineColors.LeafGreen else vine.textSecondary.copy(alpha = 0.5f)
                    Column(
                        modifier = Modifier
                            .size(width = 60.dp, height = 56.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(vine.cardBackground)
                            .clickable(enabled = canManageFunctions) { showAddFunction = true },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                    ) {
                        Icon(
                            Icons.Filled.AddCircle,
                            contentDescription = "Add function",
                            tint = addTint,
                            modifier = Modifier.size(22.dp),
                        )
                        Text("Add", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = addTint)
                    }
                }
                Text(
                    if (canManageFunctions) {
                        "Need another job type? Add or edit trip functions in Settings."
                    } else {
                        "Ask an Owner or Manager to add trip functions in Settings."
                    },
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
                TextField(
                    value = title,
                    onValueChange = { title = it },
                    placeholder = {
                        Text(
                            if (functionRaw == "other") "Trip title (required)" else "Trip title (optional)",
                            color = vine.textSecondary,
                        )
                    },
                    leadingIcon = {
                        Icon(Icons.Filled.Notes, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(20.dp))
                    },
                    singleLine = true,
                    shape = RoundedCornerShape(12.dp),
                    colors = startTripFieldColors(vine.cardBackground),
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            // SEEDING DETAILS — iOS parity: shown only when Seeding is selected.
            if (isSeedingSelected) {
                StartTripSection("Seeding Details", Icons.Filled.Grass, VineColors.LeafGreen) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(vine.cardBackground),
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { seedingExpanded = !seedingExpanded }
                                .padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(
                                "Optional details",
                                fontSize = 14.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = vine.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            Text("All fields optional", fontSize = 11.sp, color = vine.textSecondary)
                            Icon(
                                if (seedingExpanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                                contentDescription = if (seedingExpanded) "Collapse" else "Expand",
                                tint = VineColors.LeafGreen,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                        if (seedingExpanded) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(start = 14.dp, end = 14.dp, bottom = 14.dp),
                                verticalArrangement = Arrangement.spacedBy(14.dp),
                            ) {
                                // Copy from previous seeding job
                                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clip(RoundedCornerShape(10.dp))
                                            .background(vine.appBackground)
                                            .clickable { applyPreviousSeedingSetup() }
                                            .padding(12.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                                    ) {
                                        Icon(
                                            Icons.Filled.ContentCopy,
                                            contentDescription = null,
                                            tint = VineColors.LeafGreen,
                                            modifier = Modifier.size(20.dp),
                                        )
                                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                            Text(
                                                "Copy from previous seeding job",
                                                fontSize = 14.sp,
                                                fontWeight = FontWeight.SemiBold,
                                                color = vine.textPrimary,
                                            )
                                            Text(
                                                "Reuse boxes, rates, depth and mix lines",
                                                fontSize = 12.sp,
                                                color = vine.textSecondary,
                                            )
                                        }
                                    }
                                    val note = copiedFromNote
                                    if (note != null) {
                                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(14.dp))
                                            Text(note, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = VineColors.LeafGreen)
                                        }
                                    } else if (copyFoundButEmpty) {
                                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                            Icon(Icons.Filled.Info, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(14.dp))
                                            Text(
                                                "Previous seeding job found, but it has no useful saved setup.",
                                                fontSize = 11.sp,
                                                color = VineColors.Warning,
                                            )
                                        }
                                    } else if (copyMissing) {
                                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                            Icon(Icons.Filled.Info, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(14.dp))
                                            Text("No previous seeding setup found.", fontSize = 11.sp, color = vine.textSecondary)
                                        }
                                    }
                                }

                                StartTripSeedBoxToggle("Use Front Box", useFrontBox) { useFrontBox = it }
                                StartTripSeedBoxToggle("Use Rear Box", useBackBox) { useBackBox = it }
                                if (!useFrontBox && !useBackBox) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                        Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Warning, modifier = Modifier.size(14.dp))
                                        Text(
                                            "Enable at least one seed box for a Seeding trip.",
                                            fontSize = 11.sp,
                                            fontWeight = FontWeight.SemiBold,
                                            color = VineColors.Warning,
                                        )
                                    }
                                }

                                // Main fields (iOS `seedingMainFields` parity)
                                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                    if (useFrontBox) {
                                        StartTripSeedingFieldRow("Seed/Fert mix — Front Box", seedFrontMix, { seedFrontMix = it }, "e.g. Ryecorn + Vetch", fieldBg = vine.appBackground)
                                        StartTripSeedingFieldRow("Rate/ha — Front Box", seedFrontRate, { seedFrontRate = it }, "0", numeric = true, suffix = "kg/ha", fieldBg = vine.appBackground)
                                    }
                                    if (useBackBox) {
                                        StartTripSeedingFieldRow("Seed/Fert mix — Rear Box", seedBackMix, { seedBackMix = it }, "e.g. Tic Beans", fieldBg = vine.appBackground)
                                        StartTripSeedingFieldRow("Rate/ha — Rear Box", seedBackRate, { seedBackRate = it }, "0", numeric = true, suffix = "kg/ha", fieldBg = vine.appBackground)
                                    }
                                    StartTripSeedingFieldRow("Sowing depth", sowingDepth, { sowingDepth = it }, "0", numeric = true, suffix = "cm", fieldBg = vine.appBackground)
                                }

                                if (useFrontBox) {
                                    StartTripSeedBoxCard(
                                        title = "Front Box",
                                        shutter = seedFrontShutter, onShutter = { seedFrontShutter = it },
                                        flap = seedFrontFlap, onFlap = { seedFrontFlap = it },
                                        wheel = seedFrontWheel, onWheel = { seedFrontWheel = it },
                                        volume = seedFrontVolume, onVolume = { seedFrontVolume = it },
                                        gearbox = seedFrontGearbox, onGearbox = { seedFrontGearbox = it },
                                    )
                                }
                                if (useBackBox) {
                                    StartTripSeedBoxCard(
                                        title = "Rear Box",
                                        shutter = seedBackShutter, onShutter = { seedBackShutter = it },
                                        flap = seedBackFlap, onFlap = { seedBackFlap = it },
                                        wheel = seedBackWheel, onWheel = { seedBackWheel = it },
                                        volume = seedBackVolume, onVolume = { seedBackVolume = it },
                                        gearbox = seedBackGearbox, onGearbox = { seedBackGearbox = it },
                                    )
                                }

                                StartTripSeedMixCard(
                                    lines = seedMixLines,
                                    seedInputs = state.savedInputs.filter { input ->
                                        input.inputType == "seed" &&
                                            (state.selectedVineyardId == null || input.vineyardId == state.selectedVineyardId)
                                    }.sortedBy { it.displayName.lowercase() },
                                    onLinesChange = { seedMixLines = it },
                                )
                            }
                        }
                    }
                }
            }

            // TRACKING PATTERN
            StartTripSection("Tracking Pattern", Icons.Filled.SwapVert, VineColors.Purple) {
                TrackingPattern.entries.forEach { p ->
                    StartTripPatternCard(pattern = p, selected = pattern == p) { pattern = p }
                }
            }

            if (hasRowGeometry && pattern != TrackingPattern.FREE_DRIVE) {
                // START PATH & DIRECTION
                StartTripSection("Start Path & Direction", Icons.Filled.SwapVert, VineColors.Info) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(Icons.Filled.Info, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(13.dp))
                        Text(
                            "Row guidance follows ${if (selectedPaddocks.size > 1) "all selected blocks" else "selected block"} " +
                                "(${TripRowSequencePlanner.combinedRangeLabel(selectedPaddocks)} · ${TripRowSequencePlanner.combinedPathsLabel(selectedPaddocks)})",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                    Box {
                        StartTripSelectorCard(
                            icon = Icons.Filled.Route,
                            tint = VineColors.Info,
                            title = "Start path",
                            subtitle = TripRowSequencePlanner.pathMenuLabel(startPath, selectedPaddocks),
                            onClick = { pathMenu = true },
                        )
                        DropdownMenu(expanded = pathMenu, onDismissRequest = { pathMenu = false }) {
                            TripRowSequencePlanner.availablePaths(selectedPaddocks).forEach { path ->
                                StartTripMenuItem(
                                    TripRowSequencePlanner.pathMenuLabel(path, selectedPaddocks),
                                    kotlin.math.abs(path - startPath) < 0.01,
                                ) { startPath = path; pathMenu = false }
                            }
                        }
                    }
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(vine.cardBackground)
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("Sequence direction", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            StartTripDirectionChip("Higher to lower", !directionHigherFirst, Modifier.weight(1f)) {
                                directionHigherFirst = false
                            }
                            StartTripDirectionChip("Lower to higher", directionHigherFirst, Modifier.weight(1f)) {
                                directionHigherFirst = true
                            }
                        }
                    }
                }

                // PROPOSED ROW SEQUENCE
                StartTripSection("Proposed Row Sequence", Icons.Filled.FormatListNumbered, VineColors.Purple) {
                    TripRowSequencePlanner.patternPreviewNote(pattern)?.let { note ->
                        Text(note, fontSize = 12.sp, color = vine.textSecondary)
                    }
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(vine.cardBackground)
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        if (sequence.isEmpty()) {
                            Text("No sequence available for the current selection.", fontSize = 12.sp, color = vine.textSecondary)
                        } else {
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.Top) {
                                Icon(
                                    Icons.Filled.AutoAwesome,
                                    contentDescription = null,
                                    tint = VineColors.Purple,
                                    modifier = Modifier.size(13.dp),
                                )
                                Text(
                                    TripRowSequencePlanner.sequencePreviewText(sequence),
                                    fontSize = 12.sp,
                                    color = vine.textPrimary,
                                    maxLines = 3,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            Text(
                                "${sequence.size} path${if (sequence.size == 1) "" else "s"} planned",
                                fontSize = 11.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                }
            }

            if (pattern == TrackingPattern.FREE_DRIVE) {
                StartTripSection("Free Drive", Icons.Filled.Gesture, VineColors.Cyan) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(vine.cardBackground)
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(Icons.Filled.Info, contentDescription = null, tint = VineColors.Cyan, modifier = Modifier.size(18.dp))
                            Text("No planned row sequence", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        }
                        Text(
                            "Drive freely — the app detects the row/path you are in from GPS, ticks it off when covered, and keeps recording distance, pins and trip history. No wrong-row warnings.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }

            // MACHINE
            StartTripSection("Machine", Icons.Filled.DirectionsCar, VineColors.Indigo) {
                Box {
                    StartTripSelectorCard(
                        icon = Icons.Filled.DirectionsCar,
                        tint = VineColors.Indigo,
                        title = "Machine",
                        subtitle = machines.firstOrNull { it.id == machineId }?.displayName
                            ?: if (machines.isEmpty()) "No vineyard machines configured" else "No machine selected",
                        onClick = { if (machines.isNotEmpty()) machineMenu = true },
                    )
                    DropdownMenu(expanded = machineMenu, onDismissRequest = { machineMenu = false }) {
                        StartTripMenuItem("No machine", machineId == null) { machineId = null; machineMenu = false }
                        machines.forEach { m ->
                            StartTripMenuItem(m.displayName, machineId == m.id) { machineId = m.id; machineMenu = false }
                        }
                    }
                }
                if (machines.isEmpty()) {
                    Text(
                        "Add vineyard machines in Equipment to enable fuel cost estimates.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
                } else if (machineId == null) {
                    Text(
                        "Optional — select a machine so fuel cost can be estimated.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
                }
                if (machineId != null) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(vine.cardBackground)
                            .padding(horizontal = 14.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Icon(Icons.Filled.Speed, contentDescription = null, tint = VineColors.Indigo, modifier = Modifier.size(20.dp))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text("Start engine hours", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                            Text("Optional — for accurate fuel use", fontSize = 12.sp, color = vine.textSecondary)
                        }
                        TextField(
                            value = startEngineHoursText,
                            onValueChange = { startEngineHoursText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                            placeholder = { Text("hrs", color = vine.textSecondary) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                            colors = startTripFieldColors(vine.cardBackground),
                            modifier = Modifier.width(96.dp),
                        )
                    }
                }
            }

            // OPERATOR
            StartTripSection("Operator", Icons.Filled.Person, VineColors.Orange) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(vine.cardBackground)
                        .padding(start = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Filled.Person, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(26.dp))
                    TextField(
                        value = operatorName,
                        onValueChange = { operatorName = it },
                        placeholder = { Text("Name (optional)", color = vine.textSecondary) },
                        singleLine = true,
                        colors = startTripFieldColors(vine.cardBackground),
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            // START TRIP
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Button(
                    onClick = {
                        permLauncher.launch(
                            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION),
                        )
                    },
                    enabled = canStart && !saving,
                    modifier = Modifier.fillMaxWidth().height(52.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = VineColors.Primary,
                        disabledContainerColor = vine.textSecondary.copy(alpha = 0.3f),
                        disabledContentColor = Color.White,
                    ),
                ) {
                    if (saving) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                    } else {
                        Icon(Icons.Filled.PlayArrow, contentDescription = null)
                        Text("  Start Trip", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
                if (paddockIds.isEmpty()) {
                    Text(
                        "Select at least one block to start the trip.",
                        fontSize = 11.sp,
                        color = vine.textSecondary,
                    )
                } else if (seedBoxesInvalid) {
                    Text(
                        "Enable at least one seed box for a Seeding trip.",
                        fontSize = 11.sp,
                        color = VineColors.Warning,
                    )
                }
            }
        }
    }

    if (showBlockPicker) {
        StartTripBlockPickerDialog(
            paddocks = state.paddocks.sortedBy { it.name.lowercase() },
            selectedIds = paddockIds,
            onToggle = { id -> paddockIds = if (id in paddockIds) paddockIds - id else paddockIds + id },
            onDismiss = { showBlockPicker = false },
        )
    }

    if (showAddFunction) {
        StartTripAddFunctionDialog(
            vm = vm,
            onDismiss = { showAddFunction = false },
            onCreated = { key -> functionRaw = key },
        )
    }
}

/** Uppercase section header with a tinted icon (iOS `sectionContainer` parity). */
@Composable
private fun StartTripSection(
    title: String,
    icon: ImageVector,
    tint: Color,
    content: @Composable ColumnScope.() -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(15.dp))
            Text(
                title.uppercase(),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 0.5.sp,
                color = vine.textSecondary,
            )
        }
        content()
    }
}

/** Rounded white selector card with icon tile, title, subtitle and chevron. */
@Composable
private fun StartTripSelectorCard(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .clickable(onClick = onClick)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(subtitle, fontSize = 12.sp, color = vine.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Icon(
            Icons.Filled.UnfoldMore,
            contentDescription = null,
            tint = vine.textSecondary.copy(alpha = 0.7f),
            modifier = Modifier.size(18.dp),
        )
    }
}

/** Tracking pattern option card with purple selected styling (iOS `patternRow` parity). */
@Composable
private fun StartTripPatternCard(pattern: TrackingPattern, selected: Boolean, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    val accent = VineColors.Purple
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .border(
                BorderStroke(1.5.dp, if (selected) accent.copy(alpha = 0.5f) else Color.Transparent),
                RoundedCornerShape(12.dp),
            )
            .clickable(onClick = onClick)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(10.dp))
                .background((if (selected) accent else vine.textSecondary).copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                trackingPatternIcon(pattern),
                contentDescription = null,
                tint = if (selected) accent else vine.textSecondary,
                modifier = Modifier.size(22.dp),
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(pattern.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(pattern.subtitle, fontSize = 12.sp, color = vine.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Icon(
            if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (selected) accent else vine.textSecondary.copy(alpha = 0.5f),
            modifier = Modifier.size(24.dp),
        )
    }
}

/** Two-option segmented chip for the sequence direction picker. */
@Composable
private fun StartTripDirectionChip(
    label: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(8.dp))
            .background(if (selected) VineColors.Info.copy(alpha = 0.15f) else vine.appBackground)
            .border(
                BorderStroke(1.dp, if (selected) VineColors.Info.copy(alpha = 0.5f) else vine.cardBorder),
                RoundedCornerShape(8.dp),
            )
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            fontSize = 13.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            color = if (selected) VineColors.Info else vine.textSecondary,
        )
    }
}

/** Evenly divided block stats strip (iOS `blockStatsRow` parity). */
@Composable
private fun StartTripStatsRow(cells: List<Pair<String, String>>) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(vine.cardBackground)
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        cells.forEachIndexed { index, (value, label) ->
            if (index > 0) {
                Box(Modifier.width(0.5.dp).height(32.dp).background(vine.cardBorder))
            }
            Column(
                modifier = Modifier.weight(1f).padding(horizontal = 4.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(value, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Text(label, fontSize = 10.sp, color = vine.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Small uppercase group label inside a dropdown menu. */
@Composable
private fun StartTripMenuHeader(label: String) {
    val vine = LocalVineColors.current
    Text(
        label.uppercase(),
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        color = vine.textSecondary,
        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

/** Dropdown row with a trailing checkmark on the selected option. */
@Composable
private fun StartTripMenuItem(label: String, selected: Boolean, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label) },
        trailingIcon = if (selected) {
            { Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp)) }
        } else {
            null
        },
        onClick = onClick,
    )
}

/** Borderless field colors so text inputs blend into their card. */
@Composable
private fun startTripFieldColors(container: Color): TextFieldColors = TextFieldDefaults.colors(
    focusedContainerColor = container,
    unfocusedContainerColor = container,
    disabledContainerColor = container,
    focusedIndicatorColor = Color.Transparent,
    unfocusedIndicatorColor = Color.Transparent,
    disabledIndicatorColor = Color.Transparent,
)

/**
 * Tolerant numeric parser (iOS `parseNumber` parity): trims whitespace, accepts
 * comma decimals, and strips common unit suffixes ("20 kg", "20kg/ha") so
 * operator-entered values still persist correctly.
 */
private fun parseSeedingNumber(s: String): Double? {
    val raw = s.trim()
    if (raw.isEmpty()) return null
    raw.replace(',', '.').toDoubleOrNull()?.let { return it }
    val cleaned = raw.replace(',', '.').filter { it.isDigit() || it == '.' || it == '-' }
    return cleaned.toDoubleOrNull()
}

/** iOS `describeCopiedTrip` parity: "Copied setup from Seeding — Block — Date". */
private fun describeCopiedSeedingTrip(trip: Trip): String {
    val epoch = trip.endEpochMs ?: trip.startEpochMs
    val date = epoch?.let {
        java.text.SimpleDateFormat("d MMM yyyy", java.util.Locale.getDefault()).format(java.util.Date(it))
    }
    val block = trip.paddockName?.trim().orEmpty()
    return when {
        block.isEmpty() && date == null -> "Copied setup from Seeding"
        block.isEmpty() -> "Copied setup from Seeding — $date"
        date == null -> "Copied setup from Seeding — $block"
        else -> "Copied setup from Seeding — $block — $date"
    }
}

/** iOS `boxToggleRow` parity — tinted seed-box enable toggle. */
@Composable
private fun StartTripSeedBoxToggle(title: String, checked: Boolean, onToggle: (Boolean) -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.appBackground)
            .padding(horizontal = 12.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.Inventory2, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(18.dp))
        Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onToggle,
            colors = SwitchDefaults.colors(checkedTrackColor = VineColors.LeafGreen),
        )
    }
}

/**
 * Compact left-label field row (iOS `seedingTextField` / `seedingNumericField`
 * parity). [fieldBg] lets nested cards alternate backgrounds like iOS's
 * secondary/tertiary grouped fills.
 */
@Composable
private fun StartTripSeedingFieldRow(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    placeholder: String,
    numeric: Boolean = false,
    suffix: String? = null,
    fieldBg: Color,
) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, fontSize = 12.sp, color = vine.textSecondary, modifier = Modifier.width(128.dp))
        Box(Modifier.weight(1f)) {
            BasicTextField(
                value = value,
                onValueChange = { new ->
                    onChange(if (numeric) new.filter { c -> c.isDigit() || c == '.' || c == ',' } else new)
                },
                singleLine = true,
                textStyle = TextStyle(fontSize = 14.sp, color = vine.textPrimary),
                cursorBrush = SolidColor(VineColors.Primary),
                keyboardOptions = if (numeric) {
                    KeyboardOptions(keyboardType = KeyboardType.Decimal)
                } else {
                    KeyboardOptions.Default
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp))
                    .background(fieldBg)
                    .padding(horizontal = 10.dp, vertical = 10.dp),
            )
            if (value.isEmpty()) {
                Text(
                    placeholder,
                    fontSize = 14.sp,
                    color = vine.textSecondary.copy(alpha = 0.6f),
                    maxLines = 1,
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .padding(horizontal = 10.dp),
                )
            }
        }
        if (suffix != null) {
            Text(suffix, fontSize = 11.sp, color = vine.textSecondary)
        }
    }
}

/** Left-label segmented option row (iOS `seedingPicker` parity). */
@Composable
private fun StartTripSeedingChoiceRow(
    label: String,
    selection: String,
    options: List<String>,
    fieldBg: Color,
    onSelect: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, fontSize = 12.sp, color = vine.textSecondary, modifier = Modifier.width(128.dp))
        Row(
            modifier = Modifier
                .weight(1f)
                .clip(RoundedCornerShape(8.dp))
                .background(fieldBg)
                .padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            options.forEach { option ->
                val selected = option == selection
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(6.dp))
                        .background(if (selected) VineColors.LeafGreen else Color.Transparent)
                        .clickable { onSelect(option) }
                        .padding(vertical = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        option,
                        fontSize = 12.sp,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (selected) Color.White else vine.textPrimary,
                    )
                }
            }
        }
    }
}

/** Front/Rear seed box settings card (iOS `seedingBoxCard` parity). */
@Composable
private fun StartTripSeedBoxCard(
    title: String,
    shutter: String, onShutter: (String) -> Unit,
    flap: String, onFlap: (String) -> Unit,
    wheel: String, onWheel: (String) -> Unit,
    volume: String, onVolume: (String) -> Unit,
    gearbox: String, onGearbox: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.appBackground)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(title.uppercase(), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = vine.textSecondary)
        StartTripSeedingChoiceRow("Shutter Slide", shutter, listOf("3/4", "Full"), vine.cardBackground, onShutter)
        StartTripSeedingChoiceRow("Bottom Flap", flap, listOf("1", "3"), vine.cardBackground, onFlap)
        StartTripSeedingChoiceRow("Metering Wheel", wheel, listOf("N", "F"), vine.cardBackground, onWheel)
        StartTripSeedingFieldRow("Volume of Seed", volume, onVolume, "0", numeric = true, suffix = "kg", fieldBg = vine.cardBackground)
        StartTripSeedingFieldRow("Seed Rate Gearbox", gearbox, onGearbox, "0", numeric = true, fieldBg = vine.cardBackground)
    }
}

/** Seed Mix Breakdown card with add/remove lines (iOS `seedingMixLinesCard` parity). */
@Composable
private fun StartTripSeedMixCard(
    lines: List<SeedingMixLine>,
    seedInputs: List<SavedInput>,
    onLinesChange: (List<SeedingMixLine>) -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.appBackground)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "SEED MIX BREAKDOWN",
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textSecondary,
                modifier = Modifier.weight(1f),
            )
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .clickable {
                        onLinesChange(lines + SeedingMixLine(id = java.util.UUID.randomUUID().toString(), seedBox = "Front"))
                    }
                    .padding(horizontal = 6.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(Icons.Filled.AddCircle, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(16.dp))
                Text("Add line", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = VineColors.LeafGreen)
            }
        }
        if (lines.isEmpty()) {
            Text("Optional. Tap Add line to record seed components.", fontSize = 11.sp, color = vine.textSecondary)
        } else {
            lines.forEachIndexed { index, line ->
                StartTripSeedingMixLineCard(
                    index = index,
                    line = line,
                    seedInputs = seedInputs,
                    onChange = { updated -> onLinesChange(lines.toMutableList().also { it[index] = updated }) },
                    onRemove = { onLinesChange(lines.toMutableList().also { it.removeAt(index) }) },
                )
            }
        }
    }
}

/**
 * One editable seed mix line (iOS `seedingMixLineRow` parity): Saved Input
 * link, name, % of mix, seed box, kg/ha and supplier. Numeric fields hold
 * local text state keyed on the line id so decimal typing stays smooth.
 */
@Composable
private fun StartTripSeedingMixLineCard(
    index: Int,
    line: SeedingMixLine,
    seedInputs: List<SavedInput>,
    onChange: (SeedingMixLine) -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    var inputMenu by remember { mutableStateOf(false) }
    var percentText by remember(line.id) { mutableStateOf(line.percentOfMix?.let(::seedTrimNum) ?: "") }
    var kgText by remember(line.id) { mutableStateOf(line.kgPerHa?.let(::seedTrimNum) ?: "") }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(vine.cardBackground)
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Line ${index + 1}",
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textSecondary,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onRemove, modifier = Modifier.size(28.dp)) {
                Icon(Icons.Filled.Delete, contentDescription = "Remove line", tint = VineColors.Destructive, modifier = Modifier.size(16.dp))
            }
        }
        // Saved Input link — picking one snapshots name + cost per unit.
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Saved Input", fontSize = 12.sp, color = vine.textSecondary, modifier = Modifier.width(128.dp))
            Box(Modifier.weight(1f)) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(vine.appBackground)
                        .clickable { inputMenu = true }
                        .padding(horizontal = 10.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    val linked = seedInputs.firstOrNull { it.id == line.savedInputId }
                    Text(
                        linked?.displayName ?: "Manual entry",
                        fontSize = 13.sp,
                        color = if (linked == null) vine.textSecondary else vine.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Icon(Icons.Filled.UnfoldMore, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(14.dp))
                }
                DropdownMenu(expanded = inputMenu, onDismissRequest = { inputMenu = false }) {
                    DropdownMenuItem(
                        text = { Text("Manual entry") },
                        onClick = {
                            onChange(line.copy(savedInputId = null))
                            inputMenu = false
                        },
                    )
                    seedInputs.forEach { si ->
                        DropdownMenuItem(
                            text = { Text(si.displayName) },
                            onClick = {
                                onChange(
                                    line.copy(
                                        savedInputId = si.id,
                                        name = si.name,
                                        inputType = si.inputType,
                                        unit = si.unit,
                                        costPerUnit = si.costPerUnit,
                                        supplierManufacturer = line.supplierManufacturer?.takeIf { it.isNotBlank() }
                                            ?: si.supplier?.trim()?.takeIf { it.isNotBlank() },
                                    ),
                                )
                                inputMenu = false
                            },
                        )
                    }
                }
            }
        }
        if (seedInputs.isEmpty()) {
            Text(
                "No saved seed inputs yet. Add them in Settings → Spray & Equipment → Saved Inputs.",
                fontSize = 10.sp,
                color = vine.textSecondary.copy(alpha = 0.7f),
            )
        }
        StartTripSeedingFieldRow("Name", line.name ?: "", { onChange(line.copy(name = it.ifBlank { null })) }, "e.g. Ryecorn", fieldBg = vine.appBackground)
        StartTripSeedingFieldRow(
            "% of Mix", percentText,
            { percentText = it; onChange(line.copy(percentOfMix = parseSeedingNumber(it))) },
            "0", numeric = true, suffix = "%", fieldBg = vine.appBackground,
        )
        StartTripSeedingChoiceRow("Seed Box", line.seedBox ?: "Front", listOf("Front", "Back"), vine.appBackground) {
            onChange(line.copy(seedBox = it))
        }
        StartTripSeedingFieldRow(
            "Kg/ha", kgText,
            { kgText = it; onChange(line.copy(kgPerHa = parseSeedingNumber(it))) },
            "0", numeric = true, suffix = "kg/ha", fieldBg = vine.appBackground,
        )
        StartTripSeedingFieldRow("Supplier", line.supplierManufacturer ?: "", { onChange(line.copy(supplierManufacturer = it.ifBlank { null })) }, "Manufacturer", fieldBg = vine.appBackground)
    }
}

/** Multi-select block picker (iOS `MultiPaddockPickerSheet` parity). */
@Composable
private fun StartTripBlockPickerDialog(
    paddocks: List<Paddock>,
    selectedIds: List<String>,
    onToggle: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Select Blocks") },
        text = {
            if (paddocks.isEmpty()) {
                Text("No blocks available. Add blocks in Vineyard Setup.")
            } else {
                Column(
                    modifier = Modifier
                        .heightIn(max = 420.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    paddocks.forEach { p ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onToggle(p.id) }
                                .padding(vertical = 2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(checked = p.id in selectedIds, onCheckedChange = { onToggle(p.id) })
                            Column(Modifier.padding(start = 4.dp)) {
                                Text(p.name, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary)
                                val rows = p.rows.orEmpty().map { it.number }.sorted()
                                Text(
                                    if (rows.isEmpty()) "Rows not configured" else TripRowSequencePlanner.compactRowRangeLabel(rows),
                                    fontSize = 12.sp,
                                    color = vine.textSecondary,
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

/** Create a custom vineyard trip function and select it (iOS `AddCustomTripFunctionSheet` parity). */
@Composable
private fun StartTripAddFunctionDialog(
    vm: AppViewModel,
    onDismiss: () -> Unit,
    onCreated: (String) -> Unit,
) {
    var label by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add Trip Function") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Create a custom job type for this vineyard. It appears in the Function list on all devices.", fontSize = 13.sp)
                OutlinedTextField(
                    value = label,
                    onValueChange = { label = it },
                    label = { Text("Function name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = label.trim().isNotEmpty() && !saving,
                onClick = {
                    saving = true
                    val slug = slugifyTripFunction(label.trim())
                    vm.createTripFunction(label.trim()) { ok ->
                        saving = false
                        if (ok) {
                            onCreated("custom:$slug")
                            onDismiss()
                        }
                    }
                },
            ) { Text(if (saving) "Adding…" else "Add") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EndTripSheet(vm: AppViewModel, trip: Trip, onDismiss: () -> Unit, onEnded: () -> Unit) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    var notes by remember { mutableStateOf("") }
    var endEngineHoursText by remember { mutableStateOf("") }
    var saving by remember { mutableStateOf(false) }

    val endEngineHours = endEngineHoursText.trim().replace(",", ".").toDoubleOrNull()
    // Block finishing only when both readings exist and the end reading is below
    // the start reading — a blank end reading always allows the trip to end.
    val engineHoursInvalid = endEngineHours != null &&
        trip.startEngineHours != null && endEngineHours < trip.startEngineHours

    val sequence = trip.rowSequence
    val hasRowPlan = sequence.isNotEmpty()
    val completedSet = remember(trip.completedPaths) { trip.completedPaths.orEmpty().toSet() }
    val skippedSet = remember(trip.skippedPaths) { trip.skippedPaths.orEmpty().toSet() }
    // Paths the operator ticks complete during review (only ones not already
    // completed or skipped). Additive only — never removes prior coverage.
    val reviewCompletes = remember { mutableStateListOf<Double>() }
    val missedPaths = remember(sequence, completedSet, skippedSet) {
        sequence.filter { it !in completedSet && it !in skippedSet }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        // Scrollable review content with the Finish button pinned below it, so the
        // confirmation action is always reachable even with long row lists.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .imePadding()
                .navigationBarsPadding()
                .padding(bottom = 16.dp),
        ) {
            Column(
                modifier = Modifier
                    .weight(1f, fill = false)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text("End trip", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                Text("Add any completion notes before finishing.", fontSize = 13.sp, color = vine.textSecondary)

                if (hasRowPlan) {
                    EndTripRowReview(
                        sequence = sequence,
                        completedSet = completedSet,
                        skippedSet = skippedSet,
                        missedPaths = missedPaths,
                        reviewCompletes = reviewCompletes,
                    )
                }

                OutlinedTextField(
                    value = endEngineHoursText,
                    onValueChange = { endEngineHoursText = it.filter { c -> c.isDigit() || c == '.' || c == ',' } },
                    label = { Text("End engine hours (optional)") },
                    placeholder = {
                        Text(trip.startEngineHours?.let { "Start was ${formatEngineHours(it)}" } ?: "e.g. 1246.0")
                    },
                    singleLine = true,
                    isError = engineHoursInvalid,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
                if (engineHoursInvalid) {
                    Text(
                        "End hours can't be lower than the start reading (${formatEngineHours(trip.startEngineHours ?: 0.0)}). Fix or clear it to finish.",
                        fontSize = 12.sp,
                        color = VineColors.Destructive,
                    )
                }

                OutlinedTextField(
                    value = notes,
                    onValueChange = { notes = it },
                    label = { Text("Completion notes (optional)") },
                    modifier = Modifier.fillMaxWidth().height(110.dp),
                )
            }

            Spacer(Modifier.height(16.dp))
            Button(
                onClick = {
                    saving = true
                    val extra = reviewCompletes.toList()
                    vm.endTripWithRowReview(extra, notes.trim().ifBlank { null }, endEngineHours) { ok ->
                        saving = false; if (ok) onEnded()
                    }
                },
                enabled = !saving && !engineHoursInvalid,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Destructive),
            ) {
                if (saving) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                } else {
                    Icon(Icons.Filled.Stop, contentDescription = null)
                    Text("  Finish trip")
                }
            }
        }
    }
}

/**
 * End-trip row review (Stage 3D-4). Lists every planned path with its current
 * status — Completed, Skipped, or Not complete — and lets the operator tick
 * any still-uncovered paths as completed before finishing. Paths already
 * completed or skipped are read-only: this slice never removes prior coverage.
 * On Free Drive / no row plan the whole section is hidden by the caller.
 */
@Composable
private fun EndTripRowReview(
    sequence: List<Double>,
    completedSet: Set<Double>,
    skippedSet: Set<Double>,
    missedPaths: List<Double>,
    reviewCompletes: SnapshotStateList<Double>,
) {
    val vine = LocalVineColors.current
    val completedCount = completedSet.count { it in sequence }
    val skippedCount = skippedSet.count { it in sequence }
    val missedRemaining = missedPaths.count { it !in reviewCompletes }

    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.Route, contentDescription = null, tint = VineColors.Indigo, modifier = Modifier.size(16.dp))
                Text("Row review", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                Spacer(Modifier.weight(1f))
                Text(
                    "$completedCount done · $skippedCount skipped · $missedRemaining left",
                    fontSize = 11.sp,
                    color = vine.textSecondary,
                )
            }
            Text(
                "Tick any rows you drove but the app missed. Already completed or skipped rows stay as they are.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )

            if (missedPaths.isNotEmpty() && missedRemaining > 0) {
                OutlinedButton(
                    onClick = { missedPaths.forEach { if (it !in reviewCompletes) reviewCompletes.add(it) } },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text("  Mark all $missedRemaining remaining complete")
                }
            }

            sequence.forEach { path ->
                val isCompleted = path in completedSet
                val isSkipped = path in skippedSet
                val isTicked = path in reviewCompletes
                val statusLabel: String
                val statusColor: Color
                when {
                    isCompleted -> { statusLabel = "Completed"; statusColor = VineColors.LeafGreen }
                    isTicked -> { statusLabel = "Will complete"; statusColor = VineColors.LeafGreen }
                    isSkipped -> { statusLabel = "Skipped"; statusColor = VineColors.Orange }
                    else -> { statusLabel = "Not complete"; statusColor = VineColors.Destructive }
                }
                val canTick = !isCompleted && !isSkipped
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        "Path ${TripRowSequencePlanner.formatPath(path)}",
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = vine.textPrimary,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(statusLabel, fontSize = 12.sp, fontWeight = FontWeight.Medium, color = statusColor)
                    if (canTick) {
                        Checkbox(
                            checked = isTicked,
                            onCheckedChange = { checked ->
                                if (checked) { if (path !in reviewCompletes) reviewCompletes.add(path) }
                                else reviewCompletes.remove(path)
                            },
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EditTripSheet(
    vm: AppViewModel,
    state: AppUiState,
    trip: Trip,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)

    var paddockIds by remember { mutableStateOf(trip.effectivePaddockIds) }
    val paddockId: String? = paddockIds.firstOrNull()
    val selectableFunctions = remember(state.vineyardTripFunctions, trip.tripFunction) {
        val customActive = state.vineyardTripFunctions
            .filter { it.isSelectable }
            .sortedBy { it.label.lowercase() }
            .map { it.tripFunctionKey to it.label }
        val base = builtInTripFunctions + customActive
        // Preserve the trip's current custom function even if it was archived
        // since the trip was created, so the picker can still display it.
        val current = trip.tripFunction
        if (current != null && current.startsWith("custom:") && base.none { it.first == current }) {
            base + (current to trip.displayLabel)
        } else {
            base
        }
    }
    var functionRaw by remember {
        mutableStateOf(trip.tripFunction?.takeIf { raw -> selectableFunctions.any { it.first == raw } } ?: builtInTripFunctions.first().first)
    }
    var operator by remember { mutableStateOf(trip.personName ?: "") }
    var operatorUserId by remember { mutableStateOf(trip.operatorUserId) }
    var operatorCategoryId by remember { mutableStateOf(trip.operatorCategoryId) }
    var title by remember { mutableStateOf(trip.tripTitle ?: "") }
    var machineId by remember { mutableStateOf(trip.machineId) }
    var workTaskId by remember { mutableStateOf(trip.workTaskId) }
    var saving by remember { mutableStateOf(false) }
    var functionMenu by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("Edit trip", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

            ExposedDropdownMenuBox(expanded = functionMenu, onExpandedChange = { functionMenu = it }) {
                OutlinedTextField(
                    value = selectableFunctions.firstOrNull { it.first == functionRaw }?.second ?: "Trip",
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Operation") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = functionMenu) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                )
                ExposedDropdownMenu(expanded = functionMenu, onDismissRequest = { functionMenu = false }) {
                    selectableFunctions.forEach { (raw, label) ->
                        DropdownMenuItem(text = { Text(label) }, onClick = { functionRaw = raw; functionMenu = false })
                    }
                }
            }

            MultiBlockPicker(
                paddocks = state.paddocks,
                selectedIds = paddockIds,
                onToggle = { id ->
                    paddockIds = if (id in paddockIds) paddockIds - id else paddockIds + id
                },
                // Offline-resilient fallback: when the block list is unavailable
                // (e.g. offline restart) show the trip's stored snapshot so a
                // selected block isn't wrongly implied as cleared.
                fallbackLabel = trip.paddockName?.takeIf { it.isNotBlank() },
            )

            OperatorPicker(
                state = state,
                operatorUserId = operatorUserId,
                operatorName = operator,
                operatorCategoryId = operatorCategoryId,
                onSelectMember = { member ->
                    operatorUserId = member?.userId
                    if (member != null) {
                        operator = member.name
                        if (operatorCategoryId == null) operatorCategoryId = member.operatorCategoryId
                    }
                },
                onOperatorNameChange = { operator = it },
                onSelectCategory = { operatorCategoryId = it },
            )

            MachinePicker(state = state, selectedId = machineId, onSelect = { machineId = it })
            WorkTaskPicker(state = state, selectedId = workTaskId, onSelect = { workTaskId = it })

            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text("Notes / title") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            if (trip.machineId != null && machineId == null || trip.workTaskId != null && workTaskId == null) {
                Text(
                    "Clearing an existing equipment or work-task link isn't supported yet — pick a different one to change it.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                )
            }

            Button(
                onClick = {
                    saving = true
                    val paddock = state.paddocks.firstOrNull { it.id == paddockId }
                    vm.updateTripMetadata(
                        tripId = trip.id,
                        paddockId = paddockId,
                        paddockName = paddock?.name,
                        paddockIds = paddockIds,
                        personName = operator.trim(),
                        tripFunction = functionRaw,
                        tripTitle = title.trim(),
                        machineId = machineId,
                        workTaskId = workTaskId,
                        operatorUserId = operatorUserId,
                        operatorCategoryId = operatorCategoryId,
                    ) { ok -> saving = false; if (ok) onSaved() }
                },
                enabled = !saving,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.PrimaryAccent),
            ) {
                Text("Save changes")
            }
        }
    }
}

@Composable
private fun TripPathMap(path: List<LatLng>, blocks: List<Paddock>) {
    val cameraPositionState = rememberCameraPositionState()
    var mapLoaded by remember { mutableStateOf(false) }

    // Frame the recorded track once the map is laid out (falling back to the
    // trip's block geometry when there is no track), re-framing if the data
    // arrives after the map loads.
    LaunchedEffect(mapLoaded, path, blocks) {
        if (!mapLoaded) return@LaunchedEffect
        val pts = path.ifEmpty {
            blocks.filter { it.hasGeometry }
                .flatMap { it.polygonPoints ?: emptyList() }
                .mapNotNull { it.toLatLng() }
        }
        cameraPositionState.fitToContent(points = pts, paddingPx = 80)
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(240.dp)
            .clip(RoundedCornerShape(16.dp)),
    ) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = cameraPositionState,
            properties = MapProperties(mapType = MapType.HYBRID),
            uiSettings = MapUiSettings(
                zoomControlsEnabled = false,
                mapToolbarEnabled = false,
                scrollGesturesEnabled = true,
                zoomGesturesEnabled = true,
            ),
            onMapLoaded = { mapLoaded = true },
        ) {
            // Subtle block context behind the track.
            blocks.filter { it.hasGeometry }.forEach { block ->
                val poly = block.polygonPoints?.mapNotNull { it.toLatLng() } ?: emptyList()
                if (poly.size >= 3) {
                    Polygon(
                        points = poly,
                        fillColor = VineColors.LeafGreen.copy(alpha = 0.12f),
                        strokeColor = VineColors.LeafGreen.copy(alpha = 0.7f),
                        strokeWidth = 3f,
                        // Block layout sits behind the recorded track.
                        zIndex = 0f,
                    )
                }
            }
            Polyline(points = path, color = VineColors.Cyan, width = 7f, zIndex = 1f)
            path.firstOrNull()?.let {
                Marker(state = MarkerState(position = it), title = "Start", icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_GREEN))
            }
            path.lastOrNull()?.let {
                Marker(state = MarkerState(position = it), title = "End", icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_RED))
            }
        }
    }
}

/**
 * Editor for a seeding trip's structured details (mix lines + box settings).
 * Mix lines drive seed/input cost: each line can be linked to a Saved Input so
 * its cost-per-unit is snapshotted onto the trip. Front/rear box settings carry
 * operational metadata. Owner/manager only (gated by caller).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SeedingDetailsSheet(
    vm: AppViewModel,
    state: AppUiState,
    trip: Trip,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val existing = trip.seedingDetails

    var sowingDepth by remember { mutableStateOf(existing?.sowingDepthCm?.let { seedTrimNum(it) } ?: "") }
    var useFront by remember { mutableStateOf(existing?.frontBox?.hasAnyValue == true) }
    var useRear by remember { mutableStateOf(existing?.backBox?.hasAnyValue == true) }
    var frontMix by remember { mutableStateOf(existing?.frontBox?.mixName ?: "") }
    var frontRate by remember { mutableStateOf(existing?.frontBox?.ratePerHa?.let { seedTrimNum(it) } ?: "") }
    var rearMix by remember { mutableStateOf(existing?.backBox?.mixName ?: "") }
    var rearRate by remember { mutableStateOf(existing?.backBox?.ratePerHa?.let { seedTrimNum(it) } ?: "") }
    var lines by remember {
        mutableStateOf(existing?.mixLines.orEmpty().ifEmpty {
            listOf(SeedingMixLine(id = java.util.UUID.randomUUID().toString()))
        })
    }
    var saving by remember { mutableStateOf(false) }

    fun build(): SeedingDetails {
        val cleanLines = lines.filter { it.hasAnyValue }.ifEmpty { null }
        return SeedingDetails(
            frontBox = if (useFront) SeedingBox(
                mixName = frontMix.trim().ifBlank { null },
                ratePerHa = frontRate.seedDouble(),
            ).takeIf { it.hasAnyValue } else null,
            backBox = if (useRear) SeedingBox(
                mixName = rearMix.trim().ifBlank { null },
                ratePerHa = rearRate.seedDouble(),
            ).takeIf { it.hasAnyValue } else null,
            sowingDepthCm = sowingDepth.seedDouble(),
            mixLines = cleanLines,
        )
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Seeding details", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(
                "Capture the seed mix to track input cost. Link a mix line to a Saved Input to pull in its cost per unit.",
                fontSize = 12.sp,
                color = vine.textSecondary,
            )

            OutlinedTextField(
                value = sowingDepth,
                onValueChange = { sowingDepth = it.seedNumericFilter() },
                label = { Text("Sowing depth (cm, optional)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )

            SeedingBoxEditor(
                title = "Front box",
                enabled = useFront,
                onToggle = { useFront = it },
                mixName = frontMix,
                onMixName = { frontMix = it },
                rate = frontRate,
                onRate = { frontRate = it.seedNumericFilter() },
            )
            SeedingBoxEditor(
                title = "Rear box",
                enabled = useRear,
                onToggle = { useRear = it },
                mixName = rearMix,
                onMixName = { rearMix = it },
                rate = rearRate,
                onRate = { rearRate = it.seedNumericFilter() },
            )

            HorizontalDivider(color = vine.cardBorder)
            Text("Mix lines", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)

            lines.forEachIndexed { index, line ->
                SeedingMixLineEditor(
                    line = line,
                    savedInputs = state.savedInputs,
                    canRemove = lines.size > 1,
                    onChange = { updated -> lines = lines.toMutableList().also { it[index] = updated } },
                    onRemove = { lines = lines.toMutableList().also { it.removeAt(index) } },
                )
            }
            TextButton(onClick = {
                lines = lines + SeedingMixLine(id = java.util.UUID.randomUUID().toString())
            }) {
                Icon(Icons.Filled.Add, contentDescription = null, tint = VineColors.PrimaryAccent, modifier = Modifier.size(18.dp))
                Text("  Add mix line", color = VineColors.PrimaryAccent)
            }

            Spacer(Modifier.height(4.dp))
            Button(
                onClick = {
                    saving = true
                    vm.updateTripSeedingDetails(trip.id, build()) { ok -> saving = false; if (ok) onDismiss() }
                },
                enabled = !saving,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.PrimaryAccent),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text("Save seeding details")
            }
        }
    }
}

@Composable
private fun SeedingBoxEditor(
    title: String,
    enabled: Boolean,
    onToggle: (Boolean) -> Unit,
    mixName: String,
    onMixName: (String) -> Unit,
    rate: String,
    onRate: (String) -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
                Switch(checked = enabled, onCheckedChange = onToggle)
            }
            if (enabled) {
                OutlinedTextField(
                    value = mixName,
                    onValueChange = onMixName,
                    label = { Text("Mix name (optional)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = rate,
                    onValueChange = onRate,
                    label = { Text("Rate / ha (optional)") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SeedingMixLineEditor(
    line: SeedingMixLine,
    savedInputs: List<SavedInput>,
    canRemove: Boolean,
    onChange: (SeedingMixLine) -> Unit,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    var inputMenu by remember { mutableStateOf(false) }
    var boxMenu by remember { mutableStateOf(false) }
    VineyardCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    line.name?.takeIf { it.isNotBlank() } ?: "Mix line",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = vine.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                if (canRemove) {
                    IconButton(onClick = onRemove) {
                        Icon(Icons.Filled.Delete, contentDescription = "Remove mix line", tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                    }
                }
            }
            // Saved Input link — picking one snapshots its name + cost per unit.
            if (savedInputs.isNotEmpty()) {
                ExposedDropdownMenuBox(expanded = inputMenu, onExpandedChange = { inputMenu = it }) {
                    OutlinedTextField(
                        value = line.savedInputId?.let { id -> savedInputs.firstOrNull { it.id == id }?.displayName }
                            ?: "Not linked",
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Saved Input") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = inputMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = inputMenu, onDismissRequest = { inputMenu = false }) {
                        DropdownMenuItem(text = { Text("Not linked") }, onClick = {
                            onChange(line.copy(savedInputId = null))
                            inputMenu = false
                        })
                        savedInputs.forEach { si ->
                            DropdownMenuItem(text = { Text(si.displayName) }, onClick = {
                                onChange(
                                    line.copy(
                                        savedInputId = si.id,
                                        name = line.name?.takeIf { it.isNotBlank() } ?: si.name,
                                        unit = si.unit,
                                        inputType = si.inputType,
                                        costPerUnit = si.costPerUnit,
                                    ),
                                )
                                inputMenu = false
                            })
                        }
                    }
                }
            }
            OutlinedTextField(
                value = line.name ?: "",
                onValueChange = { onChange(line.copy(name = it.ifBlank { null })) },
                label = { Text("Name (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                ExposedDropdownMenuBox(
                    expanded = boxMenu,
                    onExpandedChange = { boxMenu = it },
                    modifier = Modifier.weight(1f),
                ) {
                    OutlinedTextField(
                        value = line.seedBox ?: "—",
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Box") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = boxMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = boxMenu, onDismissRequest = { boxMenu = false }) {
                        listOf("—", "Front", "Back").forEach { b ->
                            DropdownMenuItem(text = { Text(b) }, onClick = {
                                onChange(line.copy(seedBox = b.takeIf { it != "—" }))
                                boxMenu = false
                            })
                        }
                    }
                }
                OutlinedTextField(
                    value = line.kgPerHa?.let { seedTrimNum(it) } ?: "",
                    onValueChange = { onChange(line.copy(kgPerHa = it.seedNumericFilter().seedDouble())) },
                    label = { Text("kg/ha") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }
            OutlinedTextField(
                value = line.costPerUnit?.let { seedTrimNum(it) } ?: "",
                onValueChange = { onChange(line.copy(costPerUnit = it.seedNumericFilter().seedDouble())) },
                label = { Text("Cost per ${line.unit ?: "unit"} (optional)") },
                placeholder = { Text("0.00") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

private fun seedTrimNum(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.2f".format(value)

private fun String.seedNumericFilter(): String = filter { c -> c.isDigit() || c == '.' || c == ',' }

private fun String.seedDouble(): Double? =
    replace(',', '.').trim().takeIf { it.isNotBlank() }?.toDoubleOrNull()?.takeIf { it > 0 }

/**
 * Multi-select block picker for trips (iOS `Trip.paddockIds` parity). Shows a
 * read-only summary of the chosen blocks and a checkbox menu to toggle each.
 * The first selected block is treated as the trip's primary `paddockId`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MultiBlockPicker(
    paddocks: List<Paddock>,
    selectedIds: List<String>,
    onToggle: (String) -> Unit,
    fallbackLabel: String? = null,
) {
    var open by remember { mutableStateOf(false) }
    val byId = remember(paddocks) { paddocks.associateBy { it.id } }
    val summary = when {
        selectedIds.isEmpty() -> "No block"
        else -> selectedIds.joinToString(", ") { id ->
            byId[id]?.name ?: fallbackLabel?.takeIf { selectedIds.size == 1 } ?: "Block unavailable"
        }
    }
    val label = if (selectedIds.size > 1) "Blocks (${selectedIds.size})" else "Block"
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
        OutlinedTextField(
            value = summary,
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            if (paddocks.isEmpty()) {
                DropdownMenuItem(text = { Text("No blocks available") }, onClick = { open = false })
            }
            paddocks.forEach { p ->
                val checked = p.id in selectedIds
                DropdownMenuItem(
                    text = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = checked, onCheckedChange = { onToggle(p.id) })
                            Spacer(Modifier.width(4.dp))
                            Text(p.name)
                        }
                    },
                    onClick = { onToggle(p.id) },
                )
            }
        }
    }
}

/** Equipment dropdown sourced from the vineyard's machines (incl. backfilled tractors). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MachinePicker(state: AppUiState, selectedId: String?, onSelect: (String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val machines = state.machines
    val selectedName = machines.firstOrNull { it.id == selectedId }?.displayName
        ?: if (selectedId != null) "Linked equipment unavailable" else "No equipment"
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
        OutlinedTextField(
            value = selectedName,
            onValueChange = {},
            readOnly = true,
            label = { Text("Equipment") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text("No equipment") }, onClick = { onSelect(null); open = false })
            machines.forEach { m ->
                DropdownMenuItem(text = { Text(m.displayName) }, onClick = { onSelect(m.id); open = false })
            }
        }
    }
}

/** Work-task dropdown sourced from the vineyard's active work tasks. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WorkTaskPicker(state: AppUiState, selectedId: String?, onSelect: (String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val tasks = state.workTasks
    val selectedLabel = tasks.firstOrNull { it.id == selectedId }?.displayLabel
        ?: if (selectedId != null) "Linked task unavailable" else "No work task"
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
        OutlinedTextField(
            value = selectedLabel,
            onValueChange = {},
            readOnly = true,
            label = { Text("Work task") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text("No work task") }, onClick = { onSelect(null); open = false })
            tasks.forEach { t ->
                DropdownMenuItem(
                    text = {
                        val sub = formatTripDate(t.startEpochMs)
                        Text(if (sub != null) "${t.displayLabel} · $sub" else t.displayLabel)
                    },
                    onClick = { onSelect(t.id); open = false },
                )
            }
        }
    }
}

/**
 * Operator picker: link the trip to a real team member (resolved via the
 * `get_vineyard_team_members` RPC) and/or an operator category, while keeping
 * free-text entry as a fallback for legacy records and people not on the team.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OperatorPicker(
    state: AppUiState,
    operatorUserId: String?,
    operatorName: String,
    operatorCategoryId: String?,
    onSelectMember: (VineyardMember?) -> Unit,
    onOperatorNameChange: (String) -> Unit,
    onSelectCategory: (String?) -> Unit,
) {
    val members = state.members
    val categories = state.operatorCategories
    var memberMenu by remember { mutableStateOf(false) }
    var categoryMenu by remember { mutableStateOf(false) }

    val selectedMember = members.firstOrNull { it.userId == operatorUserId }
    val memberFieldValue = when {
        operatorUserId != null && selectedMember != null -> selectedMember.name
        operatorUserId != null -> "Linked member unavailable"
        else -> "Manual entry"
    }

    // Member dropdown is only useful when the team has loaded members.
    if (members.isNotEmpty()) {
        ExposedDropdownMenuBox(expanded = memberMenu, onExpandedChange = { memberMenu = it }) {
            OutlinedTextField(
                value = memberFieldValue,
                onValueChange = {},
                readOnly = true,
                label = { Text("Operator") },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = memberMenu) },
                modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
            )
            ExposedDropdownMenu(expanded = memberMenu, onDismissRequest = { memberMenu = false }) {
                DropdownMenuItem(text = { Text("Manual entry") }, onClick = { onSelectMember(null); memberMenu = false })
                members.forEach { m ->
                    DropdownMenuItem(
                        text = {
                            val sub = m.operatorCategoryName?.takeIf { it.isNotBlank() }
                            Text(if (sub != null) "${m.name} · $sub" else m.name)
                        },
                        onClick = { onSelectMember(m); memberMenu = false },
                    )
                }
            }
        }
    }

    // Free-text name: editable when no member is linked (manual / legacy).
    if (operatorUserId == null) {
        OutlinedTextField(
            value = operatorName,
            onValueChange = onOperatorNameChange,
            label = { Text(if (members.isEmpty()) "Operator (optional)" else "Operator name") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
    }

    // Operator category dropdown (only when the vineyard has categories).
    if (categories.isNotEmpty()) {
        val selectedCategory = categories.firstOrNull { it.id == operatorCategoryId }
        val categoryValue = when {
            operatorCategoryId != null && selectedCategory != null -> selectedCategory.displayName
            operatorCategoryId != null -> "Linked category unavailable"
            else -> "No category"
        }
        ExposedDropdownMenuBox(expanded = categoryMenu, onExpandedChange = { categoryMenu = it }) {
            OutlinedTextField(
                value = categoryValue,
                onValueChange = {},
                readOnly = true,
                label = { Text("Operator category") },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = categoryMenu) },
                modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
            )
            ExposedDropdownMenu(expanded = categoryMenu, onDismissRequest = { categoryMenu = false }) {
                DropdownMenuItem(text = { Text("No category") }, onClick = { onSelectCategory(null); categoryMenu = false })
                categories.forEach { c ->
                    DropdownMenuItem(text = { Text(c.displayName) }, onClick = { onSelectCategory(c.id); categoryMenu = false })
                }
            }
        }
    }
}

@Composable
private fun DetailRow(icon: ImageVector, label: String, value: String, tint: Color) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(28.dp).clip(CircleShape).background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        }
        Text(label, color = vine.textSecondary, fontSize = 14.sp, modifier = Modifier.weight(1f))
        Text(value, color = vine.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun Divider(color: Color) {
    Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(color))
}

/** Live elapsed seconds for an active trip, holding still while paused. */
private fun liveDurationSeconds(trip: Trip, nowMs: Long): Long {
    val start = trip.startEpochMs ?: return 0L
    val end = if (trip.isActive) nowMs else (trip.endEpochMs ?: nowMs)
    return ((end - start) / 1000).coerceAtLeast(0)
}

/** HH:MM:SS style for the live timer. */
private fun clockDuration(seconds: Long): String {
    val s = seconds.coerceAtLeast(0)
    val h = s / 3600
    val m = (s % 3600) / 60
    val sec = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%02d:%02d".format(m, sec)
}

/** Live fill-timer readout: minutes:seconds (e.g. "2:05"), mirroring iOS. */
private fun formatFillElapsed(seconds: Long): String {
    val s = seconds.coerceAtLeast(0)
    val m = s / 60
    val sec = s % 60
    return "%d:%02d".format(m, sec)
}

private fun formatDistance(metres: Double?): String? {
    if (metres == null || metres <= 0) return null
    return if (metres >= 1000) "${"%.2f".format(metres / 1000)} km" else "${metres.toInt()} m"
}

/** Driving path label: whole paths show as integers, mid-rows as X.5. */
private fun formatPath(path: Double): String =
    if (path % 1.0 == 0.0) path.toInt().toString() else "%.1f".format(path)

private fun formatTripDate(epochMs: Long?): String? {
    epochMs ?: return null
    return SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(epochMs))
}

/**
 * Trip-row date + time, mirroring the iOS `.abbreviated, .shortened` style
 * ("22 Jun 2026 at 9:47"). Uses the device locale's short time so it follows
 * the 12/24-hour setting like iOS does.
 */
private fun formatTripRowDateTime(epochMs: Long?): String? {
    epochMs ?: return null
    val date = SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(epochMs))
    val time = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT, Locale.getDefault()).format(Date(epochMs))
    return "$date at $time"
}

private fun formatTripDateTime(epochMs: Long?): String? {
    epochMs ?: return null
    return SimpleDateFormat("d MMM yyyy, h:mm a", Locale.getDefault()).format(Date(epochMs))
}

/** Litres formatted to at most one decimal, dropping a trailing .0. */
private fun formatLitres(litres: Double): String {
    val rounded = Math.round(litres * 10.0) / 10.0
    return if (rounded % 1.0 == 0.0) "%,d".format(rounded.toLong()) else "%,.1f".format(rounded)
}

/** Compact currency label for fuel costs (e.g. "$1,250", "$2.15"), matching the spray formatter. */
private fun formatFuelCurrency(value: Double): String {
    val rounded = if (value % 1.0 == 0.0) "%,d".format(value.toLong()) else "%,.2f".format(value)
    return "$$rounded"
}

/** Tonnes label with at most two decimals, dropping a trailing .0 (e.g. "12", "4.25"). */
private fun formatTonnes(tonnes: Double): String {
    val rounded = Math.round(tonnes * 100.0) / 100.0
    return if (rounded % 1.0 == 0.0) "%,d".format(rounded.toLong()) else "%,.2f".format(rounded)
}

/** Trim engine-hour readings to at most one decimal, dropping a trailing .0. */
private fun formatEngineHours(hours: Double): String {
    val rounded = Math.round(hours * 10.0) / 10.0
    return if (rounded % 1.0 == 0.0) rounded.toInt().toString() else rounded.toString()
}

private fun com.rork.vinetrack.data.model.CoordinatePoint.toLatLng(): LatLng? =
    LatLng(latitude, longitude)
