package com.rork.vinetrack.ui.screens

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Agriculture
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Calculate
import androidx.compose.material.icons.filled.CalendarToday
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material.icons.filled.Opacity
import androidx.compose.material.icons.filled.Paid
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SortByAlpha
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.UploadFile
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.LocalDrink
import androidx.compose.material.icons.filled.LocalGasStation
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDatePickerState
import com.rork.vinetrack.ui.components.rememberGuardedSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.SprayProgramCsvExporter
import com.rork.vinetrack.data.SprayProgramCsvImporter
import com.rork.vinetrack.data.TrackingPattern
import com.rork.vinetrack.data.TripCostEstimator
import com.rork.vinetrack.data.TripRowSequencePlanner
import com.rork.vinetrack.data.SprayProgramPdfExporter
import com.rork.vinetrack.data.SprayRecordPdfExporter
import com.rork.vinetrack.data.SprayRecordRepository
import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayStatus
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.VineyardMachine
import com.rork.vinetrack.data.model.formatTripDuration
import com.rork.vinetrack.data.model.resolveSprayEquipmentName
import com.rork.vinetrack.data.model.resolveSprayTrip
import com.rork.vinetrack.data.model.resolveSprayWorkTask
import com.rork.vinetrack.data.model.resolveTripWorkTask
import com.rork.vinetrack.data.model.sprayRecordStatus
import com.rork.vinetrack.data.model.sprayOperationTypes
import com.rork.vinetrack.data.model.windDirectionOptions
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.EmptyState
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.text.SimpleDateFormat
import java.time.Instant
import java.util.Date
import java.util.Locale
import java.util.UUID

@Composable
fun SpraysScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenTrip: ((String) -> Unit)? = null,
    initialOpenCalculator: Boolean = false,
    onCalculatorConsumed: () -> Unit = {},
) {
    var selectedId by remember { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(false) }
    var creatingTemplate by remember { mutableStateOf(false) }
    var calculating by remember { mutableStateOf(false) }

    // When navigated here to start a spray trip (e.g. the Trips chooser),
    // open the Spray Calculator once, then clear the external request.
    LaunchedEffect(initialOpenCalculator) {
        if (initialOpenCalculator) {
            calculating = true
            onCalculatorConsumed()
        }
    }
    var editing by remember { mutableStateOf<SprayRecord?>(null) }
    // A template selected to seed a brand-new operational record (job -> record).
    var prefillFromTemplate by remember { mutableStateOf<SprayRecord?>(null) }

    val selected = state.sprayRecords.firstOrNull { it.id == selectedId }
        ?: state.sprayJobTemplates.firstOrNull { it.id == selectedId }

    if (calculating) {
        androidx.activity.compose.BackHandler { calculating = false }
        SprayCalculatorScreen(
            vm = vm,
            state = state,
            modifier = modifier,
            onBack = { calculating = false },
            onSaved = { calculating = false },
            onJobStarted = onOpenTrip,
        )
        return
    }

    AnimatedContent(
        targetState = selected,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "spray-nav",
        modifier = modifier,
    ) { record ->
        if (record == null) {
            SprayListView(
                vm = vm,
                state = state,
                onBack = onBack,
                onSelect = { selectedId = it.id },
                onAdd = { creating = true },
                onAddTemplate = { creatingTemplate = true },
                onOpenCalculator = { calculating = true },
            )
        } else {
            SprayDetailView(
                vm = vm,
                state = state,
                recordId = record.id,
                onBack = { selectedId = null },
                onEdit = { editing = it },
                onUseTemplate = { prefillFromTemplate = it; selectedId = null },
                onJobStarted = onOpenTrip,
            )
        }
    }

    if (creating) {
        SpraySheet(vm = vm, state = state, existing = null, asTemplate = false, onDismiss = { creating = false }, onSaved = { creating = false })
    }
    if (creatingTemplate) {
        SpraySheet(vm = vm, state = state, existing = null, asTemplate = true, onDismiss = { creatingTemplate = false }, onSaved = { creatingTemplate = false })
    }
    prefillFromTemplate?.let { tmpl ->
        SpraySheet(vm = vm, state = state, existing = tmpl, asTemplate = false, fromTemplate = true, onDismiss = { prefillFromTemplate = null }, onSaved = { prefillFromTemplate = null })
    }
    editing?.let { rec ->
        SpraySheet(vm = vm, state = state, existing = rec, asTemplate = rec.isTemplate, onDismiss = { editing = null }, onSaved = { editing = null })
    }
}

/** Status/segment filters for the spray list, mirroring the iOS SprayStatusFilter. */
private enum class SprayFilter(val label: String) {
    ALL("All"),
    IN_PROGRESS("In Progress"),
    NOT_STARTED("Not Started"),
    COMPLETED("Completed"),
    TEMPLATES("Templates"),
}

/** Sort options for the spray list, mirroring the iOS SprayProgramSortOption (plus oldest-first). */
private enum class SpraySort(val label: String) {
    DATE_NEWEST("Date (newest)"),
    DATE_OLDEST("Date (oldest)"),
    NAME_AZ("Name (A–Z)"),
}

/**
 * Case-insensitive client-side match for an operational spray record, mirroring iOS
 * `SprayProgramView.operationalRecords` search: reference, paddock, chemicals, notes, equipment.
 */
private fun sprayRecordMatches(record: SprayRecord, trips: List<com.rork.vinetrack.data.model.Trip>, query: String): Boolean {
    val paddock = resolveSprayTrip(record, trips)?.paddockName ?: ""
    val chemicals = record.chemicalNames.joinToString(" ")
    val combined = "${record.displayLabel} $paddock $chemicals ${record.notes ?: ""} ${record.equipmentType ?: ""}"
    return combined.contains(query, ignoreCase = true)
}

/** Search match for templates, mirroring iOS `templateRecords`: reference, chemicals, notes only. */
private fun sprayTemplateMatches(record: SprayRecord, query: String): Boolean {
    val chemicals = record.chemicalNames.joinToString(" ")
    val combined = "${record.displayLabel} $chemicals ${record.notes ?: ""}"
    return combined.contains(query, ignoreCase = true)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayListView(
    vm: AppViewModel,
    state: AppUiState,
    onBack: (() -> Unit)?,
    onSelect: (SprayRecord) -> Unit,
    onAdd: () -> Unit,
    onAddTemplate: () -> Unit,
    onOpenCalculator: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    var filter by remember { mutableStateOf(SprayFilter.ALL) }
    var addMenu by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    var sort by remember { mutableStateOf(SpraySort.DATE_NEWEST) }
    var sortMenu by remember { mutableStateOf(false) }
    // CSV import: pick a document, parse it, then confirm in a preview sheet.
    var importResult by remember { mutableStateOf<SprayProgramCsvImporter.ImportResult?>(null) }
    var importErrorMsg by remember { mutableStateOf<String?>(null) }
    var importing by remember { mutableStateOf(false) }
    val importPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val bytes = SprayProgramCsvImporter.readBytes(context, uri)
        if (bytes == null) {
            importErrorMsg = "Couldn't read that file. Please try another."
            return@rememberLauncherForActivityResult
        }
        try {
            importResult = SprayProgramCsvImporter.parseCsv(
                data = bytes,
                savedChemicals = state.savedChemicals,
                allowCostPrefill = state.currentRole == "owner" || state.currentRole == "manager",
            )
        } catch (e: SprayProgramCsvImporter.ImportError) {
            importErrorMsg = e.userMessage
        } catch (e: Exception) {
            importErrorMsg = "Couldn't read that CSV. Please use the provided template."
        }
    }
    val query = search.trim()
    val hasSearch = query.isNotEmpty()

    val all = remember(state.sprayRecords) { state.sprayRecords }
    // Templates merge two sources: legacy templates stored in spray_records and
    // read-only portal templates from spray_jobs (Lovable-created), deduped by id.
    val templates = remember(state.sprayRecords, state.sprayJobTemplates, query) {
        val local = state.sprayRecords.asSequence().filter { it.isTemplate }
        val localIds = local.map { it.id }.toSet()
        val portal = state.sprayJobTemplates.asSequence().filter { it.id !in localIds }
        (local + portal)
            .filter { query.isEmpty() || sprayTemplateMatches(it, query) }
            .sortedBy { it.displayLabel.lowercase() }
            .toList()
    }
    val operational = remember(state.sprayRecords, query, sort, state.trips) {
        val base = state.sprayRecords.asSequence()
            .filter { !it.isTemplate }
            .filter { query.isEmpty() || sprayRecordMatches(it, state.trips, query) }
            .toList()
        when (sort) {
            SpraySort.DATE_NEWEST -> base.sortedByDescending { it.dateEpochMs ?: 0L }
            SpraySort.DATE_OLDEST -> base.sortedBy { it.dateEpochMs ?: 0L }
            SpraySort.NAME_AZ -> base.sortedBy { it.displayLabel.lowercase() }
        }
    }
    val filtered = remember(operational, filter, state.trips) {
        when (filter) {
            SprayFilter.ALL -> operational
            SprayFilter.IN_PROGRESS -> operational.filter { sprayRecordStatus(it, state.trips) == SprayStatus.IN_PROGRESS }
            SprayFilter.NOT_STARTED -> operational.filter { sprayRecordStatus(it, state.trips) == SprayStatus.NOT_STARTED }
            SprayFilter.COMPLETED -> operational.filter { sprayRecordStatus(it, state.trips) == SprayStatus.COMPLETED }
            SprayFilter.TEMPLATES -> emptyList()
        }
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Spray Program") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                actions = {
                    // Add (+) first, then the sort/menu — mirroring the iOS Spray
                    // Program toolbar where both actions sit at the top trailing.
                    Box {
                        IconButton(onClick = { addMenu = true }) {
                            Icon(Icons.Filled.Add, contentDescription = "New spray")
                        }
                        androidx.compose.material3.DropdownMenu(expanded = addMenu, onDismissRequest = { addMenu = false }) {
                            DropdownMenuItem(
                                text = { Text("Spray calculator") },
                                leadingIcon = { Icon(Icons.Filled.Calculate, contentDescription = null) },
                                onClick = { addMenu = false; onOpenCalculator() },
                            )
                            DropdownMenuItem(
                                text = { Text("Log a spray record") },
                                leadingIcon = { Icon(Icons.Filled.WaterDrop, contentDescription = null) },
                                onClick = { addMenu = false; onAdd() },
                            )
                            DropdownMenuItem(
                                text = { Text("New template") },
                                leadingIcon = { Icon(Icons.Filled.ContentCopy, contentDescription = null) },
                                onClick = { addMenu = false; onAddTemplate() },
                            )
                        }
                    }
                    Box {
                        IconButton(onClick = { sortMenu = true }) {
                            Icon(Icons.Filled.FilterList, contentDescription = "Sort", tint = vine.textSecondary)
                        }
                        androidx.compose.material3.DropdownMenu(expanded = sortMenu, onDismissRequest = { sortMenu = false }) {
                            SpraySort.entries.forEach { option ->
                                DropdownMenuItem(
                                    text = { Text(option.label) },
                                    leadingIcon = {
                                        Icon(
                                            if (option == SpraySort.NAME_AZ) Icons.Filled.SortByAlpha else Icons.Filled.CalendarToday,
                                            contentDescription = null,
                                        )
                                    },
                                    trailingIcon = {
                                        if (option == sort) Icon(Icons.Filled.Check, contentDescription = null, tint = VineColors.Primary)
                                    },
                                    onClick = { sort = option; sortMenu = false },
                                )
                            }
                            HorizontalDivider()
                            DropdownMenuItem(
                                text = { Text("Export CSV") },
                                leadingIcon = { Icon(Icons.Filled.TableChart, contentDescription = null) },
                                enabled = operational.isNotEmpty(),
                                onClick = {
                                    sortMenu = false
                                    val ok = SprayProgramCsvExporter.exportAndShare(
                                        context = context,
                                        records = operational,
                                        trips = state.trips,
                                        vineyardName = state.selectedVineyard?.name ?: "Vineyard",
                                        canViewFinancials = state.currentRole == "owner" || state.currentRole == "manager",
                                        machines = state.machines,
                                        fuelPurchases = state.fuelPurchases,
                                        operatorCategories = state.operatorCategories,
                                        paddocks = state.paddocks,
                                    )
                                    if (!ok) {
                                        Toast.makeText(context, "Couldn't export the CSV. Please try again.", Toast.LENGTH_SHORT).show()
                                    }
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("Export PDF") },
                                leadingIcon = { Icon(Icons.Filled.PictureAsPdf, contentDescription = null) },
                                enabled = operational.isNotEmpty(),
                                onClick = {
                                    sortMenu = false
                                    val ok = SprayProgramPdfExporter.exportAndShare(
                                        context = context,
                                        records = operational,
                                        trips = state.trips,
                                        vineyardName = state.selectedVineyard?.name ?: "Vineyard",
                                        canViewFinancials = state.currentRole == "owner" || state.currentRole == "manager",
                                        machines = state.machines,
                                        fuelPurchases = state.fuelPurchases,
                                        operatorCategories = state.operatorCategories,
                                        paddocks = state.paddocks,
                                        logo = state.selectedVineyardLogo,
                                    )
                                    if (!ok) {
                                        Toast.makeText(context, "Couldn't export the PDF. Please try again.", Toast.LENGTH_SHORT).show()
                                    }
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("CSV Template") },
                                leadingIcon = { Icon(Icons.Filled.Description, contentDescription = null) },
                                onClick = {
                                    sortMenu = false
                                    val ok = SprayProgramCsvExporter.exportTemplateAndShare(context = context)
                                    if (!ok) {
                                        Toast.makeText(context, "Couldn't export the template. Please try again.", Toast.LENGTH_SHORT).show()
                                    }
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("Import CSV") },
                                leadingIcon = { Icon(Icons.Filled.UploadFile, contentDescription = null) },
                                onClick = {
                                    sortMenu = false
                                    importPicker.launch(arrayOf("*/*"))
                                },
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            // Search bar
            OutlinedTextField(
                value = search,
                onValueChange = { search = it },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                placeholder = { Text("Search spray records") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                trailingIcon = {
                    if (hasSearch) {
                        IconButton(onClick = { search = "" }) {
                            Icon(Icons.Filled.Close, contentDescription = "Clear search")
                        }
                    }
                },
                singleLine = true,
                shape = RoundedCornerShape(12.dp),
            )

            // Status filter chips
            androidx.compose.foundation.lazy.LazyRow(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(SprayFilter.entries.toList()) { f ->
                    val active = f == filter
                    Text(
                        f.label,
                        fontSize = 13.sp,
                        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (active) Color.White else vine.textSecondary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(if (active) VineColors.Primary else vine.cardBackground)
                            .clickable { filter = f }
                            .padding(horizontal = 14.dp, vertical = 7.dp),
                    )
                }
            }

            when {
                state.isLoadingVineyardData && all.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(color = VineColors.Primary)
                    }
                }

                all.isEmpty() -> {
                    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                        EmptyState(
                            icon = Icons.Filled.WaterDrop,
                            title = "No Spray Records",
                            message = "Tap + to create a spray record.",
                            actionLabel = "Log a spray",
                            onAction = onAdd,
                        )
                    }
                }

                filter == SprayFilter.TEMPLATES && templates.isEmpty() -> {
                    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                        EmptyState(
                            icon = Icons.Filled.ContentCopy,
                            title = "No Templates",
                            message = "Create templates in the admin portal or mark a spray record as a template to reuse it for future spray jobs.",
                        )
                    }
                }

                hasSearch && filtered.isEmpty() && templates.isEmpty() -> {
                    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                        EmptyState(
                            icon = Icons.Filled.Search,
                            title = "No results",
                            message = "No spray records match \u201C$query\u201D.",
                        )
                    }
                }

                filter != SprayFilter.TEMPLATES && filtered.isEmpty() && templates.isEmpty() -> {
                    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
                        EmptyState(
                            icon = Icons.Filled.WaterDrop,
                            title = "No Spray Records",
                            message = "Tap + to create a spray record.",
                        )
                    }
                }

                else -> {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        if (filter == SprayFilter.TEMPLATES) {
                            items(templates, key = { it.id }) { record ->
                                SprayRow(record, state.machines, state.trips, onClick = { onSelect(record) })
                            }
                        } else {
                            if (filter == SprayFilter.ALL && templates.isNotEmpty()) {
                                item { SectionHeader("Templates", onLight = true) }
                                items(templates, key = { "tmpl-${it.id}" }) { record ->
                                    SprayRow(record, state.machines, state.trips, onClick = { onSelect(record) })
                                }
                            }
                            items(filtered, key = { it.id }) { record ->
                                SprayRow(record, state.machines, state.trips, onClick = { onSelect(record) })
                            }
                        }
                    }
                }
            }
        }
    }

    importResult?.let { result ->
        SprayImportPreviewSheet(
            result = result,
            paddocks = state.paddocks,
            importing = importing,
            onCancel = { if (!importing) importResult = null },
            onConfirm = {
                importing = true
                vm.importSprayRecords(result.rows) { outcome ->
                    importing = false
                    importResult = null
                    val msg = when {
                        outcome.imported == 0 -> "Couldn't import any records. Please try again."
                        outcome.failed > 0 -> "Imported ${outcome.imported} record${if (outcome.imported == 1) "" else "s"}, ${outcome.failed} failed."
                        else -> "Imported ${outcome.imported} spray record${if (outcome.imported == 1) "" else "s"}."
                    }
                    Toast.makeText(context, msg, Toast.LENGTH_LONG).show()
                }
            },
        )
    }

    importErrorMsg?.let { msg ->
        AlertDialog(
            onDismissRequest = { importErrorMsg = null },
            icon = { Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Orange) },
            title = { Text("Import failed") },
            text = { Text(msg) },
            confirmButton = { TextButton(onClick = { importErrorMsg = null }) { Text("OK") } },
        )
    }
}

/**
 * Confirmation sheet shown after a Spray Program CSV is parsed. Summarises how
 * many records will be imported (records vs templates), how many blocks matched
 * a mapped paddock, and lists row-level warnings before the user commits. The
 * import only runs when the user taps the confirm button.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayImportPreviewSheet(
    result: SprayProgramCsvImporter.ImportResult,
    paddocks: List<com.rork.vinetrack.data.model.Paddock>,
    importing: Boolean,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    val rows = result.rows
    val templateCount = remember(rows) { rows.count { it.isTemplate } }
    val recordCount = rows.size - templateCount
    val unmatchedBlocks = remember(rows, paddocks) {
        rows.mapNotNull { it.blockName.takeIf { n -> n.isNotBlank() } }
            .distinct()
            .filter { name ->
                paddocks.none { p ->
                    p.name.equals(name, ignoreCase = true) ||
                        p.name.contains(name, ignoreCase = true) ||
                        name.contains(p.name, ignoreCase = true)
                }
            }
    }

    ModalBottomSheet(onDismissRequest = onCancel, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Import spray records", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
            Text(
                "Review what will be added before importing. Nothing is saved until you tap Import.",
                fontSize = 13.sp,
                color = vine.textSecondary,
            )

            VineyardCard {
                ImportStatRow("Spray records", recordCount.toString())
                if (templateCount > 0) {
                    DividerSP(vine.cardBorder)
                    ImportStatRow("Templates", templateCount.toString())
                }
                DividerSP(vine.cardBorder)
                ImportStatRow("Warnings", result.warnings.size.toString())
            }

            val links = result.chemicalLinks
            if (links.hasLibrary) {
                VineyardCard {
                    ImportStatRow("Chemicals linked", links.matched.toString())
                    if (links.unmatched > 0) {
                        DividerSP(vine.cardBorder)
                        ImportStatRow("Chemicals not in library", links.unmatched.toString())
                    }
                    if (links.ambiguous > 0) {
                        DividerSP(vine.cardBorder)
                        ImportStatRow("Ambiguous chemicals", links.ambiguous.toString())
                    }
                }
            }

            if (unmatchedBlocks.isNotEmpty()) {
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(18.dp))
                        Text("Unmatched blocks", fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 14.sp)
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "These block names didn't match a mapped paddock and will be kept as plain text: " +
                            unmatchedBlocks.joinToString(", "),
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
            }

            if (result.warnings.isNotEmpty()) {
                Text("Warnings", fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 14.sp)
                Column(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 200.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    result.warnings.take(50).forEach { w ->
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Row ${w.row}", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = VineColors.Orange)
                            Text(w.message, fontSize = 12.sp, color = vine.textSecondary)
                        }
                    }
                    if (result.warnings.size > 50) {
                        Text("+ ${result.warnings.size - 50} more", fontSize = 12.sp, color = vine.textSecondary)
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onCancel, enabled = !importing, modifier = Modifier.weight(1f)) {
                    Text("Cancel")
                }
                Button(
                    onClick = onConfirm,
                    enabled = !importing && rows.isNotEmpty(),
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                ) {
                    if (importing) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                    else Text("Import ${rows.size}")
                }
            }
        }
    }
}

@Composable
private fun ImportStatRow(label: String, value: String) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 14.sp, color = vine.textSecondary, modifier = Modifier.weight(1f))
        Text(value, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
    }
}

@Composable
private fun SprayRow(record: SprayRecord, machines: List<VineyardMachine>, trips: List<com.rork.vinetrack.data.model.Trip>, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    val status = if (record.isTemplate) null else sprayRecordStatus(record, trips)
    val (icon, iconTint) = when {
        record.isTemplate -> Icons.Filled.ContentCopy to VineColors.Purple
        status == SprayStatus.IN_PROGRESS -> Icons.Filled.FiberManualRecord to VineColors.Destructive
        status == SprayStatus.NOT_STARTED -> Icons.Filled.Schedule to VineColors.Orange
        status == SprayStatus.COMPLETED -> Icons.Filled.CheckCircle to VineColors.LeafGreen
        else -> Icons.Filled.WaterDrop to VineColors.Cyan
    }
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(
                modifier = Modifier.size(40.dp).clip(CircleShape).background(iconTint.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, contentDescription = null, tint = iconTint)
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(record.displayLabel, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 16.sp, maxLines = 1)
                val sub = listOfNotNull(
                    if (record.isTemplate) "Template" else record.operationType?.takeIf { it.isNotBlank() },
                    if (record.isTemplate) null else formatSprayDate(record.dateEpochMs),
                ).joinToString(" · ")
                if (sub.isNotBlank()) Text(sub, fontSize = 13.sp, color = vine.textSecondary, maxLines = 1)
                val chems = record.chemicalNames
                val chemLine = when {
                    chems.isEmpty() && record.tankCount > 0 -> "${record.tankCount} tank${if (record.tankCount == 1) "" else "s"}"
                    chems.isEmpty() -> null
                    chems.size <= 2 -> chems.joinToString(", ")
                    else -> "${chems.take(2).joinToString(", ")} +${chems.size - 2}"
                }
                chemLine?.let { Text(it, fontSize = 12.sp, color = vine.textSecondary, maxLines = 1) }
            }
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayDetailView(
    vm: AppViewModel,
    state: AppUiState,
    recordId: String,
    onBack: () -> Unit,
    onEdit: (SprayRecord) -> Unit,
    onUseTemplate: (SprayRecord) -> Unit,
    onJobStarted: ((String) -> Unit)? = null,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    // Portal templates (spray_jobs) are read-only on mobile: no edit, no delete.
    val isPortalTemplate = state.sprayRecords.none { it.id == recordId } &&
        state.sprayJobTemplates.any { it.id == recordId }
    val record = state.sprayRecords.firstOrNull { it.id == recordId }
        ?: state.sprayJobTemplates.firstOrNull { it.id == recordId }
    var confirmDelete by remember { mutableStateOf(false) }
    var starting by remember { mutableStateOf(false) }

    if (record == null) {
        LaunchedEffectBack(onBack)
        return
    }

    fun exportPdf() {
        val ok = SprayRecordPdfExporter.exportAndShare(
            context = context,
            record = record,
            vineyardName = state.selectedVineyard?.name ?: "Vineyard",
            machines = state.machines,
            equipment = state.sprayEquipment,
            trip = resolveSprayTrip(record, state.trips),
            workTask = resolveSprayWorkTask(record, state.trips, state.workTasks),
            canViewFinancials = state.currentRole == "owner" || state.currentRole == "manager",
            fuelPurchases = state.fuelPurchases,
            operatorCategories = state.operatorCategories,
            paddocks = state.paddocks,
            logo = state.selectedVineyardLogo,
        )
        if (!ok) {
            Toast.makeText(context, "Couldn't create the PDF. Please try again.", Toast.LENGTH_SHORT).show()
        }
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(record.displayLabel, maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                },
                actions = {
                    IconButton(onClick = { exportPdf() }) { Icon(Icons.Filled.PictureAsPdf, contentDescription = "Export as PDF") }
                    if (!isPortalTemplate) {
                        IconButton(onClick = { onEdit(record) }) { Icon(Icons.Filled.Edit, contentDescription = "Edit record") }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            if (record.isTemplate) {
                VineyardCard {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box(
                            modifier = Modifier.size(36.dp).clip(CircleShape).background(VineColors.Purple.copy(alpha = 0.15f)),
                            contentAlignment = Alignment.Center,
                        ) { Icon(Icons.Filled.ContentCopy, contentDescription = null, tint = VineColors.Purple, modifier = Modifier.size(20.dp)) }
                        Column(Modifier.weight(1f)) {
                            Text("Reusable template", fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontSize = 15.sp)
                            Text("Start a new spray record from this template.", fontSize = 12.sp, color = vine.textSecondary)
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    Button(
                        onClick = { onUseTemplate(record) },
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                        Text("  Use template for new record")
                    }
                }
            }
            // Details
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SectionHeader("Job Details", onLight = true)
                VineyardCard {
                    DetailRowSP(Icons.Filled.Science, "Operation", record.operationType?.takeIf { it.isNotBlank() } ?: "—", VineColors.Indigo)
                    DividerSP(vine.cardBorder)
                    DetailRowSP(Icons.Filled.Schedule, "Date", formatSprayDate(record.dateEpochMs) ?: "—", VineColors.Cyan)
                    record.sprayReference?.takeIf { it.isNotBlank() }?.let {
                        DividerSP(vine.cardBorder)
                        DetailRowSP(Icons.Filled.WaterDrop, "Reference", it, VineColors.LeafGreen)
                    }
                }
            }

            // Equipment (placed right after Job Details, mirroring iOS where the
            // equipment fields live inside the Job Details card before weather).
            val machineName = record.displayMachine(state.machines)
            val sprayEquipName = resolveSprayEquipmentName(record, state.sprayEquipment)
            val equipParts = buildList {
                sprayEquipName?.let { add(Triple(Icons.Filled.Agriculture, "Spray equipment", it)) }
                machineName?.let { add(Triple(Icons.Filled.Agriculture, "Machine", it)) }
                record.tractorGear?.takeIf { it.isNotBlank() }?.let { add(Triple(Icons.Filled.Agriculture, "Tractor Gear", it)) }
                record.numberOfFansJets?.takeIf { it.isNotBlank() }?.let { add(Triple(Icons.Filled.Air, "No. Fans/Jets", it)) }
                record.averageSpeed?.let { add(Triple(Icons.Filled.Schedule, "Avg speed", "${trimNum(it)} km/h")) }
            }
            if (equipParts.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Equipment", onLight = true)
                    VineyardCard {
                        equipParts.forEachIndexed { i, (icon, label, value) ->
                            if (i > 0) DividerSP(vine.cardBorder)
                            DetailRowSP(icon, label, value, VineColors.Orange)
                        }
                    }
                }
            }

            // Weather
            val weatherParts = buildList {
                record.temperature?.let { add(Triple(Icons.Filled.Thermostat, "Temperature", "${trimNum(it)}°C")) }
                record.windSpeed?.let { add(Triple(Icons.Filled.Air, "Wind Speed (10 min avg)", "${trimNum(it)} km/h")) }
                record.windDirection?.takeIf { it.isNotBlank() }?.let { add(Triple(Icons.Filled.Air, "Wind Direction", it)) }
                record.humidity?.let { add(Triple(Icons.Filled.Opacity, "Humidity", "${trimNum(it)}%")) }
            }
            if (weatherParts.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Weather Conditions", onLight = true)
                    VineyardCard {
                        weatherParts.forEachIndexed { i, (icon, label, value) ->
                            if (i > 0) DividerSP(vine.cardBorder)
                            DetailRowSP(icon, label, value, VineColors.Cyan)
                        }
                    }
                }
            }

            // Tanks
            val tanks = record.tanks.orEmpty()
            if (tanks.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Tanks · ${tanks.size}", onLight = true)
                    tanks.forEach { tank ->
                        VineyardCard {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                Box(
                                    modifier = Modifier.size(28.dp).clip(CircleShape).background(VineColors.Cyan.copy(alpha = 0.15f)),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(Icons.Filled.WaterDrop, contentDescription = null, tint = VineColors.Cyan, modifier = Modifier.size(16.dp))
                                }
                                Text("Tank ${tank.tankNumber}", fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
                                if (tank.areaPerTank > 0) {
                                    Text("${trimNum(tank.areaPerTank)} ha/tank", fontSize = 12.sp, color = vine.textSecondary)
                                }
                            }
                            val specs = buildList {
                                if (tank.waterVolume > 0) add("${trimNum(tank.waterVolume)} L water")
                                if (tank.sprayRatePerHa > 0) add("${trimNum(tank.sprayRatePerHa)} L/ha")
                                if (tank.concentrationFactor > 0 && tank.concentrationFactor != 1.0) add("${trimNum(tank.concentrationFactor)}× conc.")
                            }
                            if (specs.isNotEmpty()) {
                                Spacer(Modifier.height(6.dp))
                                Text(specs.joinToString(" · "), fontSize = 13.sp, color = vine.textSecondary)
                            }
                            tank.chemicals.filter { it.name.isNotBlank() || it.volumePerTank > 0 }.forEach { chem ->
                                DividerSP(vine.cardBorder)
                                Row(
                                    modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Icon(Icons.Filled.Science, contentDescription = null, tint = VineColors.LeafGreen, modifier = Modifier.size(16.dp))
                                    Text(chem.name.takeIf { it.isNotBlank() } ?: "Chemical", color = vine.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f), maxLines = 1)
                                    val cdesc = buildList {
                                        if (chem.ratePerHa > 0) add("${trimNum(chem.ratePerHa)}/ha")
                                        if (chem.volumePerTank > 0) add("${trimNum(chem.volumePerTank)}/tank")
                                    }.joinToString(" · ")
                                    Column(horizontalAlignment = Alignment.End) {
                                        if (cdesc.isNotBlank()) Text(cdesc, color = vine.textSecondary, fontSize = 12.sp)
                                        if (chem.hasCost) {
                                            Text(
                                                formatSprayCurrency(chem.costPerTank, state.regionFormatter),
                                                color = VineColors.LeafGreen,
                                                fontSize = 12.sp,
                                                fontWeight = FontWeight.SemiBold,
                                            )
                                        }
                                    }
                                }
                            }
                            if (tank.hasCost) {
                                DividerSP(vine.cardBorder)
                                Row(
                                    modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                ) {
                                    Text("Tank cost", color = vine.textSecondary, fontSize = 13.sp)
                                    Text(
                                        formatSprayCurrency(tank.totalChemicalCost, state.regionFormatter),
                                        color = vine.textPrimary,
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.SemiBold,
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // Cost summary — only shown when chemical cost data is present.
            if (record.hasCostData) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Costs", onLight = true)
                    VineyardCard {
                        DetailRowSP(
                            Icons.Filled.Paid,
                            "Total chemical cost",
                            formatSprayCurrency(record.totalChemicalCost, state.regionFormatter),
                            VineColors.LeafGreen,
                        )
                        record.costPerHectare?.let { perHa ->
                            DividerSP(vine.cardBorder)
                            DetailRowSP(
                                Icons.Filled.Agriculture,
                                "Cost / ha",
                                "${formatSprayCurrency(perHa, state.regionFormatter)} · ${trimNum(record.totalSprayArea)} ha",
                                VineColors.LeafGreen,
                            )
                        }
                    }
                }
            }

            // Links: resolved trip + work task derived through that trip (iOS pattern).
            if (record.tripId != null) {
                val linkedTrip = resolveSprayTrip(record, state.trips)
                val linkedTask = resolveSprayWorkTask(record, state.trips, state.workTasks)
                // A linked, inactive trip with no end time is a "Not Started" spray
                // job that can be activated in place to begin live GPS tracking.
                val canStart = linkedTrip != null &&
                    !linkedTrip.isActive &&
                    record.endTime?.isNotBlank() != true
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SectionHeader("Links", onLight = true)
                    VineyardCard {
                        DetailRowSP(
                            Icons.Filled.Schedule,
                            "Trip",
                            linkedTrip?.displayLabel ?: "Linked trip unavailable",
                            VineColors.Indigo,
                        )
                        if (linkedTask != null) {
                            DividerSP(vine.cardBorder)
                            DetailRowSP(Icons.Filled.Notes, "Work task", linkedTask.displayLabel, VineColors.LeafGreen)
                        }
                        // Read-only row-plan summary for the linked spray job.
                        if (linkedTrip != null && linkedTrip.rowSequence.isNotEmpty()) {
                            val planTotal = linkedTrip.rowSequence.size
                            val planPattern = TrackingPattern.fromRaw(linkedTrip.trackingPattern)
                            val planIndex = linkedTrip.sequenceIndex.coerceIn(0, planTotal - 1)
                            val planCurrent = linkedTrip.currentRowNumber ?: linkedTrip.rowSequence.getOrNull(planIndex)
                            DividerSP(vine.cardBorder)
                            DetailRowSP(Icons.Filled.Schedule, "Row plan", planPattern.title, VineColors.Indigo)
                            DividerSP(vine.cardBorder)
                            DetailRowSP(
                                Icons.Filled.Schedule,
                                "Paths",
                                planCurrent?.let { "${planIndex + 1} of $planTotal · path ${TripRowSequencePlanner.formatPath(it)}" }
                                    ?: "${planIndex + 1} of $planTotal",
                                VineColors.Cyan,
                            )
                        }
                        // Read-only tank fill-timer summary (Stage 3F-2a).
                        if (linkedTrip != null && linkedTrip.tankSessions.isNotEmpty()) {
                            val filled = linkedTrip.tankSessions.count { it.fillDurationSeconds != null }
                            val totalFill = linkedTrip.tankSessions.sumOf { it.fillDurationSeconds ?: 0L }
                            val summary = if (filled > 0) {
                                "${linkedTrip.tankSessions.size} tanks \u00b7 fill ${formatTripDuration(totalFill)}"
                            } else {
                                "${linkedTrip.tankSessions.size} tanks"
                            }
                            DividerSP(vine.cardBorder)
                            DetailRowSP(Icons.Filled.LocalDrink, "Tank fills", summary, VineColors.Cyan)
                        }
                        // Owner/manager-only cost breakdown for the linked trip
                        // (Stage 3F-3b-i), read-only and mirroring the Trip detail
                        // card: total + fuel + labour + chemicals.
                        val canViewFinancials = state.currentRole == "owner" || state.currentRole == "manager"
                        if (canViewFinancials && linkedTrip != null) {
                            val cost = TripCostEstimator.estimate(
                                linkedTrip,
                                record,
                                state.operatorCategories,
                                state.machines,
                                state.fuelPurchases,
                                state.paddocks,
                            )
                            val fuel = cost.fuel
                            if (cost.totalCost > 0) {
                                DividerSP(vine.cardBorder)
                                DetailRowSP(
                                    Icons.Filled.Paid,
                                    "Total cost",
                                    formatSprayCurrency(cost.totalCost, state.regionFormatter),
                                    VineColors.DarkGreen,
                                )
                                if (cost.labour.cost > 0) {
                                    DividerSP(vine.cardBorder)
                                    DetailRowSP(Icons.Filled.Person, "Labour", formatSprayCurrency(cost.labour.cost, state.regionFormatter), VineColors.EarthBrown)
                                }
                                fuel.fuelCost?.let { fc ->
                                    DividerSP(vine.cardBorder)
                                    DetailRowSP(
                                        Icons.Filled.LocalGasStation,
                                        "Fuel",
                                        fuel.litres?.let { "${formatSprayCurrency(fc, state.regionFormatter)} · ${trimNum(it)} L" } ?: formatSprayCurrency(fc, state.regionFormatter),
                                        VineColors.Orange,
                                    )
                                }
                                cost.chemical?.takeIf { it.cost > 0 }?.let { chem ->
                                    DividerSP(vine.cardBorder)
                                    DetailRowSP(Icons.Filled.Science, "Chemicals", formatSprayCurrency(chem.cost, state.regionFormatter), VineColors.LeafGreen)
                                }
                                cost.costPerHa?.let { perHa ->
                                    DividerSP(vine.cardBorder)
                                    DetailRowSP(Icons.Filled.Paid, "Cost / ha", formatSprayCurrency(perHa, state.regionFormatter), VineColors.DarkGreen)
                                }
                            } else if (linkedTrip.machineId != null || linkedTrip.tractorId != null) {
                                cost.warnings.firstOrNull()?.let { warning ->
                                    DividerSP(vine.cardBorder)
                                    DetailRowSP(Icons.Filled.Paid, "Cost estimate", warning, VineColors.Orange)
                                }
                            }
                        }
                    }
                    if (canStart && linkedTrip != null) {
                        val hasActiveTrip = state.activeTrip != null
                        Button(
                            onClick = {
                                if (starting) return@Button
                                starting = true
                                vm.startSprayJob(linkedTrip.id) { ok ->
                                    starting = false
                                    Toast.makeText(
                                        context,
                                        if (ok) "Spray job started — tracking your trip."
                                        else state.sprayError ?: "Couldn't start the spray job.",
                                        Toast.LENGTH_SHORT,
                                    ).show()
                                    // On success, jump to the live trip experience so the
                                    // user can continue field work immediately.
                                    if (ok) onJobStarted?.invoke(linkedTrip.id)
                                }
                            },
                            enabled = !starting && !hasActiveTrip,
                            modifier = Modifier.fillMaxWidth(),
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                        ) {
                            Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                            Text(if (starting) "  Starting…" else "  Start job now")
                        }
                        if (hasActiveTrip) {
                            Text(
                                "Finish the active trip before starting this spray job.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }
                }
            }

            record.notes?.takeIf { it.isNotBlank() }?.let { notes ->
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

            if (isPortalTemplate) {
                Text(
                    "This template is managed in the admin portal.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            } else {
                TextButton(onClick = { confirmDelete = true }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Delete, contentDescription = null, tint = VineColors.Destructive)
                    Text(if (record.isTemplate) "  Delete template" else "  Delete spray record", color = VineColors.Destructive)
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete Spray Record") },
            text = { Text("Are you sure you want to delete this spray record? This action cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    vm.deleteSprayRecord(record.id) { ok -> if (ok) onBack() }
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun LaunchedEffectBack(onBack: () -> Unit) {
    androidx.compose.runtime.LaunchedEffect(Unit) { onBack() }
}

/** Mutable editor state for a single tank in the spray sheet. */
private class TankDraft(
    val id: String,
    var tankNumber: Int,
    waterVolume: String,
    sprayRate: String,
    concentration: String,
    chemicals: List<ChemicalDraft>,
    val rowApplications: List<com.rork.vinetrack.data.model.TankRowApplication>,
) {
    var waterVolume by mutableStateOf(waterVolume)
    var sprayRate by mutableStateOf(sprayRate)
    var concentration by mutableStateOf(concentration)
    val chemicals: SnapshotStateList<ChemicalDraft> = mutableStateListOf<ChemicalDraft>().apply { addAll(chemicals) }
}

private class ChemicalDraft(
    val id: String,
    name: String,
    ratePerHa: String,
    volumePerTank: String,
    val ratePer100L: Double,
    costPerUnit: String,
    unit: String,
    savedChemicalId: String?,
) {
    var name by mutableStateOf(name)
    var ratePerHa by mutableStateOf(ratePerHa)
    var volumePerTank by mutableStateOf(volumePerTank)
    var costPerUnit by mutableStateOf(costPerUnit)
    var unit by mutableStateOf(unit)
    var savedChemicalId by mutableStateOf(savedChemicalId)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SpraySheet(
    vm: AppViewModel,
    state: AppUiState,
    existing: SprayRecord?,
    asTemplate: Boolean,
    fromTemplate: Boolean = false,
    onDismiss: () -> Unit,
    onSaved: () -> Unit,
) {
    val vine = LocalVineColors.current
    val sheetState = rememberGuardedSheetState(skipPartiallyExpanded = true)
    // When seeding from a template we prefill from `existing` but still create a
    // brand-new operational record (no id reuse, fresh date, not a template).
    val isEdit = existing != null && !fromTemplate
    var isTemplate by remember { mutableStateOf(asTemplate) }
    // Mirror iOS `canViewFinancials`: only owners/managers may see/edit costing.
    val canEditCost = state.currentRole == "owner" || state.currentRole == "manager"

    var reference by remember { mutableStateOf(existing?.sprayReference ?: "") }
    var operationType by remember { mutableStateOf(existing?.operationType ?: sprayOperationTypes.first()) }
    var dateMs by remember { mutableStateOf(existing?.dateEpochMs ?: System.currentTimeMillis()) }
    var temperature by remember { mutableStateOf(existing?.temperature?.let { trimNum(it) } ?: "") }
    var windSpeed by remember { mutableStateOf(existing?.windSpeed?.let { trimNum(it) } ?: "") }
    var windDirection by remember { mutableStateOf(existing?.windDirection ?: "") }
    var humidity by remember { mutableStateOf(existing?.humidity?.let { trimNum(it) } ?: "") }
    var equipmentType by remember { mutableStateOf(existing?.equipmentType ?: "") }
    var tractorText by remember { mutableStateOf(existing?.tractor ?: "") }
    var machineId by remember { mutableStateOf(existing?.machineId) }
    var sprayEquipmentId by remember { mutableStateOf(existing?.sprayEquipmentId) }
    var tractorGear by remember { mutableStateOf(existing?.tractorGear ?: "") }
    var fansJets by remember { mutableStateOf(existing?.numberOfFansJets ?: "") }
    var avgSpeed by remember { mutableStateOf(existing?.averageSpeed?.let { trimNum(it) } ?: "") }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var tripId by remember { mutableStateOf(if (fromTemplate) null else existing?.tripId) }

    val tanks = remember {
        val initial = existing?.tanks?.takeIf { it.isNotEmpty() }?.map { it.toDraft() }
            ?: listOf(TankDraft(UUID.randomUUID().toString(), 1, "", "", "", emptyList(), emptyList()))
        mutableStateListOf<TankDraft>().apply { addAll(initial) }
    }

    var operationMenu by remember { mutableStateOf(false) }
    var windMenu by remember { mutableStateOf(false) }
    var machineMenu by remember { mutableStateOf(false) }

    // Tank capacity (L) of the currently selected spray equipment, if any. Used
    // to default blank/new tank water volumes, mirroring how iOS seeds tank
    // volumes from `spray_equipment.tank_capacity_litres`.
    val selectedTankCapacity: Double? = remember(sprayEquipmentId, state.sprayEquipment) {
        state.sprayEquipment.firstOrNull { it.id == sprayEquipmentId }?.tankCapacityLitres?.takeIf { it > 0 }
    }
    var showDatePicker by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }

    fun buildInput(): SprayRecordRepository.SprayInput {
        val iso = Instant.ofEpochMilli(dateMs).toString()
        val tankModels = tanks.mapIndexed { idx, t -> t.toModel(idx + 1) }
        return SprayRecordRepository.SprayInput(
            date = iso,
            startTime = if (isEdit) existing?.startTime ?: iso else iso,
            temperature = temperature.toDoubleSafe(),
            windSpeed = windSpeed.toDoubleSafe(),
            windDirection = windDirection.ifBlank { null },
            humidity = humidity.toDoubleSafe(),
            sprayReference = reference.trim().ifBlank { null },
            notes = notes.trim().ifBlank { null },
            numberOfFansJets = fansJets.trim().ifBlank { null },
            averageSpeed = avgSpeed.toDoubleSafe(),
            equipmentType = equipmentType.trim().ifBlank { null },
            tractor = tractorText.trim().ifBlank { null },
            tractorGear = tractorGear.trim().ifBlank { null },
            machineId = machineId,
            sprayEquipmentId = sprayEquipmentId,
            operationType = operationType,
            tripId = tripId,
            isTemplate = isTemplate,
            tanks = tankModels,
        )
    }

    fun save() {
        if (saving) return
        saving = true
        val input = buildInput()
        if (isEdit) {
            vm.updateSprayRecord(existing!!.id, input) { ok -> saving = false; if (ok) onSaved() }
        } else {
            vm.createSprayRecord(input) { ok -> saving = false; if (ok) onSaved() }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            val title = when {
                isEdit && isTemplate -> "Edit template"
                isEdit -> "Edit spray"
                fromTemplate -> "New record from template"
                isTemplate -> "New template"
                else -> "Log a spray"
            }
            Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)

            OutlinedTextField(
                value = reference,
                onValueChange = { reference = it },
                label = { Text(if (isTemplate) "Template name" else "Spray reference") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            // Template toggle (a record can be promoted to/from a reusable template).
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Filled.ContentCopy, contentDescription = null, tint = VineColors.Indigo, modifier = Modifier.size(20.dp))
                Column(Modifier.weight(1f)) {
                    Text("Save as template", fontWeight = FontWeight.Medium, color = vine.textPrimary, fontSize = 15.sp)
                    Text("Reusable program, not a dated record", fontSize = 12.sp, color = vine.textSecondary)
                }
                androidx.compose.material3.Switch(checked = isTemplate, onCheckedChange = { isTemplate = it })
            }

            // Operation type
            ExposedDropdownMenuBox(expanded = operationMenu, onExpandedChange = { operationMenu = it }) {
                OutlinedTextField(
                    value = operationType,
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Operation type") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = operationMenu) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                )
                ExposedDropdownMenu(expanded = operationMenu, onDismissRequest = { operationMenu = false }) {
                    sprayOperationTypes.forEach { op ->
                        DropdownMenuItem(text = { Text(op) }, onClick = { operationType = op; operationMenu = false })
                    }
                }
            }

            OutlinedButton(onClick = { showDatePicker = true }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Schedule, contentDescription = null, modifier = Modifier.size(18.dp))
                Text("  " + (formatSprayDate(dateMs) ?: "Pick date"))
            }

            // Weather
            SectionHeader("Conditions", onLight = true)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = temperature,
                    onValueChange = { temperature = it.numericFilter() },
                    label = { Text("Temp °C") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = humidity,
                    onValueChange = { humidity = it.numericFilter() },
                    label = { Text("Humidity %") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = windSpeed,
                    onValueChange = { windSpeed = it.numericFilter() },
                    label = { Text("Wind km/h") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                ExposedDropdownMenuBox(expanded = windMenu, onExpandedChange = { windMenu = it }, modifier = Modifier.weight(1f)) {
                    OutlinedTextField(
                        value = windDirection.ifBlank { "—" },
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Wind dir") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = windMenu) },
                        modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                    )
                    ExposedDropdownMenu(expanded = windMenu, onDismissRequest = { windMenu = false }) {
                        DropdownMenuItem(text = { Text("None") }, onClick = { windDirection = ""; windMenu = false })
                        windDirectionOptions.forEach { d ->
                            DropdownMenuItem(text = { Text(d) }, onClick = { windDirection = d; windMenu = false })
                        }
                    }
                }
            }

            // Tanks
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionHeader("Tanks · ${tanks.size}", onLight = true, modifier = Modifier.weight(1f))
                TextButton(onClick = {
                    val defaultVol = selectedTankCapacity?.let { trimNum(it) } ?: ""
                    tanks.add(TankDraft(UUID.randomUUID().toString(), tanks.size + 1, defaultVol, "", "", emptyList(), emptyList()))
                }) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp), tint = VineColors.PrimaryAccent)
                    Text("  Tank", color = VineColors.PrimaryAccent)
                }
            }
            selectedTankCapacity?.let { cap ->
                Text(
                    "New tanks default to ${trimNum(cap)} L from selected spray equipment.",
                    fontSize = 12.sp,
                    color = vine.textSecondary,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            tanks.forEachIndexed { idx, tank ->
                TankEditor(
                    tank = tank,
                    index = idx,
                    canRemove = tanks.size > 1,
                    canEditCost = canEditCost,
                    savedChemicals = state.savedChemicals,
                    savedSprayPresets = state.savedSprayPresets,
                    fmt = state.regionFormatter,
                    onRemove = { tanks.removeAt(idx) },
                )
            }

            // Equipment
            SectionHeader("Equipment", onLight = true)
            // Spray-equipment picker. Selecting a rig also fills the
            // `equipment_type` text snapshot and stores the stable link,
            // matching iOS. Typing a different equipment type below clears the
            // link so the snapshot stays authoritative.
            SprayEquipmentPicker(
                state = state,
                selectedId = sprayEquipmentId,
                onSelect = { eq ->
                    sprayEquipmentId = eq?.id
                    if (eq != null) {
                        equipmentType = eq.displayName
                        // Prefill only blank tank water volumes; never overwrite
                        // a value the operator already entered.
                        eq.tankCapacityLitres?.takeIf { it > 0 }?.let { cap ->
                            val capText = trimNum(cap)
                            tanks.forEach { t -> if (t.waterVolume.isBlank()) t.waterVolume = capText }
                        }
                    }
                },
            )
            OutlinedTextField(
                value = equipmentType,
                onValueChange = {
                    equipmentType = it
                    // Drop the stable link unless the text still matches the rig.
                    val linked = state.sprayEquipment.firstOrNull { eq -> eq.id == sprayEquipmentId }
                    if (linked != null && linked.displayName != it) sprayEquipmentId = null
                },
                label = { Text("Equipment type (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            // Machine picker (also fills the tractor text snapshot, matching iOS).
            ExposedDropdownMenuBox(expanded = machineMenu, onExpandedChange = { machineMenu = it }) {
                OutlinedTextField(
                    value = tractorText.ifBlank { "No machine" },
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Machine / tractor") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = machineMenu) },
                    modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
                )
                ExposedDropdownMenu(expanded = machineMenu, onDismissRequest = { machineMenu = false }) {
                    DropdownMenuItem(text = { Text("No machine") }, onClick = { machineId = null; tractorText = ""; machineMenu = false })
                    state.machines.forEach { m ->
                        DropdownMenuItem(text = { Text(m.displayName) }, onClick = {
                            machineId = m.id; tractorText = m.displayName; machineMenu = false
                        })
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = tractorGear,
                    onValueChange = { tractorGear = it },
                    label = { Text("Gear") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = fansJets,
                    onValueChange = { fansJets = it },
                    label = { Text("Fans / jets") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                )
            }
            OutlinedTextField(
                value = avgSpeed,
                onValueChange = { avgSpeed = it.numericFilter() },
                label = { Text("Average speed km/h (optional)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )

            // Links: trip (the only schema-supported link). Selecting a trip also
            // surfaces the trip's work task, mirroring the iOS derived-task pattern.
            SectionHeader("Links", onLight = true)
            SprayTripPicker(state = state, selectedId = tripId, onSelect = { tripId = it })
            val linkedTrip = remember(tripId, state.trips) { state.trips.firstOrNull { it.id == tripId } }
            val derivedTask = remember(linkedTrip, state.workTasks) {
                linkedTrip?.let { resolveTripWorkTask(it, state.workTasks) }
            }
            if (tripId != null) {
                val taskLabel = when {
                    derivedTask != null -> derivedTask.displayLabel
                    linkedTrip == null -> "Linked trip unavailable"
                    else -> "No work task on this trip"
                }
                Text(
                    "Work task: $taskLabel",
                    fontSize = 13.sp,
                    color = vine.textSecondary,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                modifier = Modifier.fillMaxWidth().height(100.dp),
            )

            Button(
                onClick = { save() },
                enabled = !saving,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
            ) {
                if (saving) CircularProgressIndicator(modifier = Modifier.size(18.dp), color = Color.White)
                else Text(if (isEdit) "Save changes" else if (isTemplate) "Save template" else "Save spray record")
            }
        }
    }

    if (showDatePicker) {
        val dpState = rememberDatePickerState(initialSelectedDateMillis = dateMs)
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    dpState.selectedDateMillis?.let { dateMs = it }
                    showDatePicker = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { showDatePicker = false }) { Text("Cancel") } },
        ) { DatePicker(state = dpState) }
    }
}

/**
 * Chemical name field with a saved-chemical picker. Behaves as a free-text
 * field (so manual/unknown chemicals still work), but offers matching saved
 * chemicals in a dropdown. Selecting one links it, copies its unit, and — for
 * owner/manager — prefills the per-unit cost when the cost field is still blank
 * (never overwriting a value the user already typed).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChemicalNameField(
    chem: ChemicalDraft,
    savedChemicals: List<com.rork.vinetrack.data.model.SavedChemical>,
    canEditCost: Boolean,
    fmt: RegionFormatter,
    onRemove: () -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val matches = remember(chem.name, savedChemicals) {
        val query = chem.name.trim()
        if (savedChemicals.isEmpty()) emptyList()
        else if (query.isEmpty()) savedChemicals.take(8)
        else savedChemicals.filter { it.displayName.contains(query, ignoreCase = true) }.take(8)
    }
    val hasSuggestions = matches.isNotEmpty()
    ExposedDropdownMenuBox(
        expanded = open && hasSuggestions,
        onExpandedChange = { if (hasSuggestions) open = it },
    ) {
        OutlinedTextField(
            value = chem.name,
            onValueChange = {
                chem.name = it
                // Editing the name by hand breaks the saved-chemical link so a
                // stale id never sticks to a renamed/free-text chemical.
                chem.savedChemicalId = null
                open = true
            },
            label = { Text("Chemical name") },
            singleLine = true,
            trailingIcon = {
                IconButton(onClick = onRemove) {
                    Icon(Icons.Filled.Delete, contentDescription = "Remove chemical", tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                }
            },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryEditable),
        )
        if (hasSuggestions) {
            ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                matches.forEach { saved ->
                    DropdownMenuItem(
                        text = {
                            val sub = buildList {
                                if (saved.ratePerHa > 0) add("${trimNum(saved.ratePerHa)} ${saved.unit}/ha")
                                if (canEditCost) saved.costPerUnit?.takeIf { it > 0 }?.let { add("${formatSprayCurrency(it, fmt)}/${saved.unit}") }
                            }.joinToString(" · ")
                            Column {
                                Text(saved.displayName)
                                if (sub.isNotEmpty()) Text(sub, fontSize = 12.sp, color = LocalVineColors.current.textSecondary)
                            }
                        },
                        onClick = {
                            chem.name = saved.displayName
                            chem.savedChemicalId = saved.id
                            chem.unit = saved.unit
                            if (saved.ratePerHa > 0 && chem.ratePerHa.isBlank()) chem.ratePerHa = trimNum(saved.ratePerHa)
                            // Prefill cost only for owner/manager and only when
                            // the user hasn't already entered one.
                            if (canEditCost && chem.costPerUnit.isBlank()) {
                                saved.costPerUnit?.takeIf { it > 0 }?.let { chem.costPerUnit = trimNum(it) }
                            }
                            open = false
                        },
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TankEditor(
    tank: TankDraft,
    index: Int,
    canRemove: Boolean,
    canEditCost: Boolean,
    savedChemicals: List<com.rork.vinetrack.data.model.SavedChemical>,
    savedSprayPresets: List<com.rork.vinetrack.data.model.SavedSprayPreset>,
    fmt: RegionFormatter,
    onRemove: () -> Unit,
) {
    val vine = LocalVineColors.current
    var presetMenu by remember { mutableStateOf(false) }
    var pendingPreset by remember { mutableStateOf<com.rork.vinetrack.data.model.SavedSprayPreset?>(null) }

    // Apply a preset's dosing values to this tank, overwriting the tank fields.
    fun applyPreset(preset: com.rork.vinetrack.data.model.SavedSprayPreset) {
        tank.waterVolume = preset.waterVolume.takeIf { it > 0 }?.let { trimNum(it) } ?: ""
        tank.sprayRate = preset.sprayRatePerHa.takeIf { it > 0 }?.let { trimNum(it) } ?: ""
        tank.concentration = preset.concentrationFactor.takeIf { it > 0 }?.let { trimNum(it) } ?: ""
    }

    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Tank ${index + 1}", fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
            if (savedSprayPresets.isNotEmpty()) {
                Box {
                    TextButton(onClick = { presetMenu = true }) {
                        Icon(Icons.Filled.Science, contentDescription = null, modifier = Modifier.size(15.dp), tint = VineColors.PrimaryAccent)
                        Text("  Preset", color = VineColors.PrimaryAccent, fontSize = 13.sp)
                    }
                    DropdownMenu(expanded = presetMenu, onDismissRequest = { presetMenu = false }) {
                        savedSprayPresets.forEach { preset ->
                            DropdownMenuItem(
                                text = {
                                    Column {
                                        Text(preset.displayName)
                                        Text(
                                            "${trimNum(preset.waterVolume)} L · ${trimNum(preset.sprayRatePerHa)} L/ha · CF ${"%.1f".format(preset.concentrationFactor)}",
                                            fontSize = 12.sp,
                                            color = vine.textSecondary,
                                        )
                                    }
                                },
                                onClick = {
                                    presetMenu = false
                                    // Confirm before clobbering values the user already typed.
                                    val hasData = tank.waterVolume.isNotBlank() || tank.sprayRate.isNotBlank() ||
                                        (tank.concentration.isNotBlank() && tank.concentration != "1")
                                    if (hasData) pendingPreset = preset else applyPreset(preset)
                                },
                            )
                        }
                    }
                }
            }
            if (canRemove) {
                IconButton(onClick = onRemove, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.Delete, contentDescription = "Remove tank", tint = VineColors.Destructive, modifier = Modifier.size(18.dp))
                }
            }
        }
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(
                value = tank.waterVolume,
                onValueChange = { tank.waterVolume = it.numericFilter() },
                label = { Text("Water L") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.weight(1f),
            )
            OutlinedTextField(
                value = tank.sprayRate,
                onValueChange = { tank.sprayRate = it.numericFilter() },
                label = { Text("L/ha") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.weight(1f),
            )
            OutlinedTextField(
                value = tank.concentration,
                onValueChange = { tank.concentration = it.numericFilter() },
                label = { Text("Conc.") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.weight(1f),
            )
        }
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Chemicals", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = vine.textPrimary, modifier = Modifier.weight(1f))
            TextButton(onClick = {
                tank.chemicals.add(ChemicalDraft(UUID.randomUUID().toString(), "", "", "", 0.0, "", "Litres", null))
            }) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp), tint = VineColors.PrimaryAccent)
                Text("  Add", color = VineColors.PrimaryAccent, fontSize = 13.sp)
            }
        }
        tank.chemicals.forEachIndexed { ci, chem ->
            Spacer(Modifier.height(6.dp))
            ChemicalNameField(
                chem = chem,
                savedChemicals = savedChemicals,
                canEditCost = canEditCost,
                fmt = fmt,
                onRemove = { tank.chemicals.removeAt(ci) },
            )
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = chem.ratePerHa,
                    onValueChange = { chem.ratePerHa = it.numericFilter() },
                    label = { Text("Rate/ha") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = chem.volumePerTank,
                    onValueChange = { chem.volumePerTank = it.numericFilter() },
                    label = { Text("Vol/tank") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
            }
            if (canEditCost) {
                Spacer(Modifier.height(6.dp))
                OutlinedTextField(
                    value = chem.costPerUnit,
                    onValueChange = { chem.costPerUnit = it.numericFilter() },
                    label = { Text("Cost per unit") },
                    placeholder = { Text("0.00") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
                val unitCost = chem.costPerUnit.toDoubleSafe() ?: 0.0
                val vol = chem.volumePerTank.toDoubleSafe() ?: 0.0
                if (unitCost > 0 && vol > 0) {
                    Text(
                        "Line cost: ${formatSprayCurrency(unitCost * vol, fmt)}",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                        modifier = Modifier.fillMaxWidth().padding(top = 2.dp),
                    )
                }
            }
        }
    }

    pendingPreset?.let { preset ->
        AlertDialog(
            onDismissRequest = { pendingPreset = null },
            title = { Text("Replace tank values?") },
            text = { Text("Applying \"${preset.displayName}\" will overwrite the water volume, spray rate, and concentration for Tank ${index + 1}. Chemicals are unaffected.") },
            confirmButton = {
                TextButton(onClick = {
                    applyPreset(preset)
                    pendingPreset = null
                }) { Text("Apply") }
            },
            dismissButton = { TextButton(onClick = { pendingPreset = null }) { Text("Cancel") } },
        )
    }
}

/**
 * Trip picker for spray records — links the record to a logged trip via
 * `spray_records.trip_id`. Lists the vineyard's trips most-recent-first; the
 * default "No trip linked" clears the link. Shows a friendly fallback label
 * when the saved trip can no longer be resolved (e.g. deleted).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayEquipmentPicker(
    state: AppUiState,
    selectedId: String?,
    onSelect: (com.rork.vinetrack.data.model.SprayEquipment?) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    val equipment = remember(state.sprayEquipment) { state.sprayEquipment.sortedBy { it.displayName } }
    val selectedLabel = equipment.firstOrNull { it.id == selectedId }?.displayName
        ?: if (selectedId != null) "Spray equipment unavailable" else "No spray equipment"
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
        OutlinedTextField(
            value = selectedLabel,
            onValueChange = {},
            readOnly = true,
            label = { Text("Spray equipment") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text("None") }, onClick = { onSelect(null); open = false })
            equipment.forEach { eq ->
                DropdownMenuItem(
                    text = {
                        val cap = eq.tankCapacityLitres?.takeIf { it > 0 }?.let { "${trimNum(it)} L" }
                        Text(if (cap != null) "${eq.displayName} · $cap" else eq.displayName)
                    },
                    onClick = { onSelect(eq); open = false },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SprayTripPicker(state: AppUiState, selectedId: String?, onSelect: (String?) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val trips = remember(state.trips) { state.trips.sortedByDescending { it.startEpochMs ?: 0L } }
    val selectedLabel = trips.firstOrNull { it.id == selectedId }?.displayLabel
        ?: if (selectedId != null) "Linked trip unavailable" else "No trip linked"
    ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
        OutlinedTextField(
            value = selectedLabel,
            onValueChange = {},
            readOnly = true,
            label = { Text("Trip") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = open) },
            modifier = Modifier.fillMaxWidth().menuAnchor(MenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text("No trip linked") }, onClick = { onSelect(null); open = false })
            trips.forEach { t ->
                DropdownMenuItem(
                    text = {
                        val sub = formatSprayDate(t.startEpochMs)
                        Text(if (sub != null) "${t.displayLabel} · $sub" else t.displayLabel)
                    },
                    onClick = { onSelect(t.id); open = false },
                )
            }
        }
    }
}

@Composable
private fun DetailRowSP(icon: ImageVector, label: String, value: String, tint: Color) {
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
private fun DividerSP(color: Color) {
    Box(modifier = Modifier.fillMaxWidth().height(0.5.dp).background(color))
}

private fun SprayTank.toDraft(): TankDraft = TankDraft(
    id = id,
    tankNumber = tankNumber,
    waterVolume = waterVolume.takeIf { it > 0 }?.let { trimNum(it) } ?: "",
    sprayRate = sprayRatePerHa.takeIf { it > 0 }?.let { trimNum(it) } ?: "",
    concentration = concentrationFactor.takeIf { it > 0 }?.let { trimNum(it) } ?: "",
    chemicals = chemicals.map { it.toDraft() },
    rowApplications = rowApplications,
)

private fun SprayChemical.toDraft(): ChemicalDraft = ChemicalDraft(
    id = id,
    name = name,
    ratePerHa = ratePerHa.takeIf { it > 0 }?.let { trimNum(it) } ?: "",
    volumePerTank = volumePerTank.takeIf { it > 0 }?.let { trimNum(it) } ?: "",
    ratePer100L = ratePer100L,
    costPerUnit = costPerUnit.takeIf { it > 0 }?.let { trimNum(it) } ?: "",
    unit = unit,
    savedChemicalId = savedChemicalId,
)

private fun TankDraft.toModel(number: Int): SprayTank = SprayTank(
    id = id,
    tankNumber = number,
    waterVolume = waterVolume.toDoubleSafe() ?: 0.0,
    sprayRatePerHa = sprayRate.toDoubleSafe() ?: 0.0,
    concentrationFactor = concentration.toDoubleSafe() ?: 0.0,
    rowApplications = rowApplications,
    chemicals = chemicals
        .filter { it.name.isNotBlank() || it.ratePerHa.isNotBlank() || it.volumePerTank.isNotBlank() }
        .map { it.toModel() },
)

private fun ChemicalDraft.toModel(): SprayChemical = SprayChemical(
    id = id,
    name = name.trim(),
    volumePerTank = volumePerTank.toDoubleSafe() ?: 0.0,
    ratePerHa = ratePerHa.toDoubleSafe() ?: 0.0,
    ratePer100L = ratePer100L,
    costPerUnit = costPerUnit.toDoubleSafe() ?: 0.0,
    unit = unit,
    savedChemicalId = savedChemicalId,
)

private fun String.numericFilter(): String = filter { c -> c.isDigit() || c == '.' || c == ',' }

private fun String.toDoubleSafe(): Double? = replace(',', '.').trim().takeIf { it.isNotBlank() }?.toDoubleOrNull()

private fun formatSprayDate(epochMs: Long?): String? {
    epochMs ?: return null
    return SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(epochMs))
}

private fun trimNum(value: Double): String =
    if (value % 1.0 == 0.0) value.toInt().toString() else "%.1f".format(value)

/** Compact, region-aware currency label (e.g. "$1,250", "£42.50"). */
private fun formatSprayCurrency(value: Double, fmt: RegionFormatter): String =
    fmt.formatCompactCurrency(value)
