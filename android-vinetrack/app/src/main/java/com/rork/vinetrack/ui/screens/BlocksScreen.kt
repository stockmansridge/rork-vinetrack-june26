package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CloudQueue
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.Grass
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.net.Uri
import android.widget.Toast
import com.rork.vinetrack.data.GddSettingsStore
import com.rork.vinetrack.data.OperationPrefsStore
import com.rork.vinetrack.data.PaddockTransferService
import com.rork.vinetrack.data.SharedGrapeVarietyCatalogRepository
import com.rork.vinetrack.data.SoilProfileRepository
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.BuiltInGrapeVarietyGDD
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.LauncherButton
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.SectionHeader
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.main.ToolRoute
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import com.google.android.gms.maps.model.CameraPosition
import java.util.Locale

private sealed interface BlockNav {
    data object List : BlockNav
    data object VineyardLocation : BlockNav
    data object GrapeVarieties : BlockNav
    data object GrowthStageConfig : BlockNav
    data object GrowthStageImages : BlockNav
    data object Weather : BlockNav
    data object RegionUnits : BlockNav
    data class Detail(val id: String) : BlockNav
    /**
     * Block editor. [fromSetupMap] marks an edit opened by tapping a block on
     * the Vineyard Setup map (iOS `selectedPaddockOnMap` parity): save/cancel
     * returns straight to the setup list rather than the read-only detail.
     */
    data class Edit(val id: String?, val fromSetupMap: Boolean = false) : BlockNav
}

/** Roles allowed to create/edit blocks (iOS canCreateOperationalRecords). */
private fun canCreateBlocks(role: String?): Boolean =
    role == "owner" || role == "manager" || role == "supervisor" || role == "operator"

/** Roles allowed to archive/delete blocks (iOS canDeleteOperationalRecords). */
private fun canDeleteBlocks(role: String?): Boolean =
    role == "owner" || role == "manager" || role == "supervisor"

/** Roles allowed to export blocks (iOS canExport). */
private fun canExportBlocks(role: String?): Boolean =
    role == "owner" || role == "manager"

/** Roles allowed to import / change settings (iOS canChangeSettings). */
private fun canChangeSettings(role: String?): Boolean =
    role == "owner" || role == "manager"

/** Block list sort options, mirroring the iOS Vineyard Setup hub. */
private enum class BlockSortOption(val label: String) {
    RowNumber("Row Number"),
    VarietyAZ("Variety A\u2013Z"),
    RowCount("Number of Rows"),
    VineCount("Number of Vines"),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BlocksScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    onOpenTool: ((ToolRoute) -> Unit)? = null,
) {
    var nav by remember { mutableStateOf<BlockNav>(BlockNav.List) }
    // Last settled Vineyard Setup map camera, kept for this screen instance so
    // returning from the editor restores the operator's view (never persisted).
    var setupMapCamera by remember(state.selectedVineyardId) { mutableStateOf<CameraPosition?>(null) }
    val canCreate = canCreateBlocks(state.currentRole)
    val canDelete = canDeleteBlocks(state.currentRole)
    val canExport = canExportBlocks(state.currentRole)
    val canImport = canChangeSettings(state.currentRole)

    val current: BlockNav = nav

    AnimatedContent(
        targetState = current,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "block-nav",
        modifier = modifier,
    ) { target ->
        when (target) {
            is BlockNav.List -> VineyardSetupHub(
                vm = vm,
                state = state,
                canCreate = canCreate,
                canExport = canExport,
                canImport = canImport,
                onSelect = { nav = BlockNav.Detail(it.id) },
                onCreate = { nav = BlockNav.Edit(null) },
                onSelectOnMap = { block -> if (canCreate) nav = BlockNav.Edit(block.id, fromSetupMap = true) },
                canEditFromMap = canCreate,
                setupMapCamera = setupMapCamera,
                onSetupMapCameraSettled = { setupMapCamera = it },
                onBack = onBack,
                onOpenLocation = { nav = BlockNav.VineyardLocation },
                onOpenVarieties = { nav = BlockNav.GrapeVarieties },
                onOpenGrowthStageConfig = { nav = BlockNav.GrowthStageConfig },
                onOpenGrowthStageImages = { nav = BlockNav.GrowthStageImages },
                onOpenWeather = { nav = BlockNav.Weather },
                onOpenRegionUnits = { nav = BlockNav.RegionUnits },
            )
            BlockNav.VineyardLocation -> {
                BackHandler { nav = BlockNav.List }
                VineyardLocationScreen(vm, state, onBack = { nav = BlockNav.List })
            }
            BlockNav.GrapeVarieties -> {
                BackHandler { nav = BlockNav.List }
                GrapeVarietiesCatalogScreen(vm, state, onBack = { nav = BlockNav.List })
            }
            BlockNav.GrowthStageConfig -> {
                BackHandler { nav = BlockNav.List }
                GrowthStageConfigScreen(onBack = { nav = BlockNav.List })
            }
            BlockNav.GrowthStageImages -> {
                BackHandler { nav = BlockNav.List }
                GrowthStageImagesScreen(vm, state, onBack = { nav = BlockNav.List })
            }
            BlockNav.Weather -> {
                BackHandler { nav = BlockNav.List }
                WeatherDataScreen(state, onBack = { nav = BlockNav.List }, onOpenTool = onOpenTool)
            }
            BlockNav.RegionUnits -> {
                BackHandler { nav = BlockNav.List }
                RegionUnitsSettingsScreen(vm, state, onBack = { nav = BlockNav.List })
            }
            is BlockNav.Detail -> {
                val block = state.paddocks.firstOrNull { it.id == target.id }
                if (block == null) {
                    nav = BlockNav.List
                } else {
                    BlockDetailView(
                        block = block,
                        state = state,
                        canEdit = canCreate,
                        canDelete = canDelete,
                        onEdit = { nav = BlockNav.Edit(block.id) },
                        onArchive = { vm.archivePaddock(block.id) { ok -> if (ok) nav = BlockNav.List } },
                        onDelete = { vm.hardDeletePaddock(block.id) { ok -> if (ok) nav = BlockNav.List } },
                        loadReferenceCounts = { cb -> vm.loadPaddockReferenceCounts(block.id, cb) },
                        onBack = { nav = BlockNav.List },
                    )
                }
            }
            is BlockNav.Edit -> {
                val existing = target.id?.let { id -> state.paddocks.firstOrNull { it.id == id } }
                val returnTo: BlockNav = if (existing != null && !target.fromSetupMap) BlockNav.Detail(existing.id) else BlockNav.List
                if (target.fromSetupMap) BackHandler { vm.clearBlockEditError(); nav = returnTo }
                EditBlockScreen(
                    vm = vm,
                    state = state,
                    existing = existing,
                    canDelete = canDelete,
                    // Archive/delete from the Danger Zone also land here; the
                    // Detail branch already falls back to the list when the
                    // block no longer exists.
                    onDone = { nav = returnTo },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun VineyardSetupHub(
    vm: AppViewModel,
    state: AppUiState,
    canCreate: Boolean,
    canExport: Boolean,
    canImport: Boolean,
    onSelect: (Paddock) -> Unit,
    onCreate: () -> Unit,
    onSelectOnMap: (Paddock) -> Unit,
    canEditFromMap: Boolean,
    setupMapCamera: CameraPosition?,
    onSetupMapCameraSettled: (CameraPosition) -> Unit,
    onBack: (() -> Unit)?,
    onOpenLocation: () -> Unit,
    onOpenVarieties: () -> Unit,
    onOpenGrowthStageConfig: () -> Unit,
    onOpenGrowthStageImages: () -> Unit,
    onOpenWeather: () -> Unit,
    onOpenRegionUnits: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current

    var sortOption by remember { mutableStateOf(BlockSortOption.RowNumber) }
    var importSummary by remember { mutableStateOf<PaddockTransferService.ImportSummary?>(null) }
    var importError by remember { mutableStateOf<String?>(null) }
    var editButtonMode by remember { mutableStateOf<String?>(null) }
    var templateMode by remember { mutableStateOf<String?>(null) }
    // True while a finger is down on the setup map; page scrolling is released
    // for exactly that window so map pan/pinch are never intercepted.
    var isMapInteracting by remember { mutableStateOf(false) }

    // Shared catalogue size (iOS masterVarietyCount parity): cached value first,
    // then the authoritative `get_grape_variety_catalog` read; built-in fallback
    // only while neither is available.
    val catalogRepo = remember { SharedGrapeVarietyCatalogRepository(context, SessionStore(context)) }
    var sharedCatalogCount by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        val cached = catalogRepo.loadCached().count { it.isActive }
        if (cached > 0) sharedCatalogCount = cached
        val fresh = runCatching { catalogRepo.refresh() }.getOrNull()?.count { it.isActive } ?: 0
        if (fresh > 0) sharedCatalogCount = fresh
    }
    val gddSettings = remember(state.selectedVineyardId) { GddSettingsStore(context).load() }
    val operationSettings = remember(state.selectedVineyardId) { OperationPrefsStore(context).load() }

    // Which paddocks have a soil profile (drives the "Soil" checklist tick).
    var soilPaddockIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var soilVineyardId by remember { mutableStateOf<String?>(null) }
    var isSoilLoading by remember { mutableStateOf(false) }
    var soilLoadFailed by remember { mutableStateOf(false) }
    val soilRepo = remember { SoilProfileRepository(SessionStore(context)) }
    LaunchedEffect(state.selectedVineyardId, state.paddocks.size) {
        val vineyardId = state.selectedVineyardId
        soilVineyardId = vineyardId
        soilPaddockIds = emptySet()
        soilLoadFailed = false
        if (vineyardId == null) {
            isSoilLoading = false
            return@LaunchedEffect
        }
        isSoilLoading = true
        try {
            soilPaddockIds = soilRepo.listVineyardSoilProfiles(vineyardId)
                .filter { it.vineyardId.equals(vineyardId, ignoreCase = true) }
                .mapNotNull { it.paddockId }
                .toSet()
        } catch (_: Exception) {
            soilLoadFailed = true
        } finally {
            isSoilLoading = false
        }
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val raw = try {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
        } catch (e: Exception) {
            null
        }
        if (raw == null) {
            importError = "Couldn't read the selected file."
            return@rememberLauncherForActivityResult
        }
        vm.importPaddocks(raw) { summary, error ->
            if (summary != null) importSummary = summary else importError = error ?: "Import failed."
        }
    }

    val paddocks = state.paddocks
    val sortedPaddocks = remember(paddocks, sortOption, state.grapeVarieties) {
        sortPaddocks(paddocks, sortOption, state.grapeVarieties)
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Vineyard Setup") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        when {
            state.isLoadingVineyardData && paddocks.isEmpty() -> {
                Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = VineColors.Primary)
                }
            }

            else -> {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding)
                        .verticalScroll(rememberScrollState(), enabled = !isMapInteracting)
                        .padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(24.dp),
                ) {
                    // Vineyard Map
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        SectionLabel("Vineyard Map", Icons.Filled.Map, VineColors.Info)
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(300.dp)
                                .clip(RoundedCornerShape(14.dp))
                                .background(vine.cardBackground),
                        ) {
                            key(state.selectedVineyardId) {
                                SetupVineyardMapContent(
                                    state = state,
                                    modifier = Modifier.fillMaxSize(),
                                    savedCamera = setupMapCamera,
                                    onCameraSettled = onSetupMapCameraSettled,
                                    onBlockSelected = if (canEditFromMap) onSelectOnMap else null,
                                    onInteractionChanged = { isMapInteracting = it },
                                )
                            }
                        }
                        Text(
                            if (canEditFromMap) {
                                "Tap a block on the map to edit its boundary and rows. Select a block below to view its setup details."
                            } else {
                                "Review the vineyard layout here. Select a block below to view its setup details."
                            },
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }

                    // Blocks
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (state.membershipLoading || state.membershipError != null) {
                            MembershipStatusCard(
                                isLoading = state.membershipLoading,
                                error = state.membershipError,
                                onRetry = { vm.refresh() },
                            )
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            SectionLabel("Blocks", Icons.Filled.Grass, VineColors.LeafGreen, modifier = Modifier.weight(1f))
                            if (paddocks.size > 1) {
                                SortMenu(sortOption) { sortOption = it }
                            }
                        }
                        VineyardCard {
                            if (canCreate) {
                                AddBlockRow(onCreate)
                                if (sortedPaddocks.isNotEmpty()) RowDivider(vine.cardBorder)
                            }
                            sortedPaddocks.forEachIndexed { idx, block ->
                                BlockSetupRow(
                                    block = block,
                                    varietiesOk = blockVarietiesCompleteness(block, state),
                                    soilOk = if (soilVineyardId == state.selectedVineyardId && !isSoilLoading && !soilLoadFailed) {
                                        soilPaddockIds.contains(block.id)
                                    } else null,
                                    onClick = { onSelect(block) },
                                )
                                if (idx < sortedPaddocks.lastIndex) RowDivider(vine.cardBorder)
                            }
                            if (sortedPaddocks.isEmpty() && !canCreate) {
                                Text(
                                    "Blocks you map will appear here with variety, area and row details.",
                                    fontSize = 13.sp,
                                    color = vine.textSecondary,
                                    modifier = Modifier.padding(vertical = 8.dp),
                                )
                            }
                        }
                        Text(
                            "Define block boundaries and row layouts for your vineyard.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }

                    // Vineyard Location
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            SectionLabel("Vineyard Location", Icons.Filled.Thermostat, VineColors.Orange)
                            VineyardCard {
                                SetupValueRow("Latitude", state.selectedVineyard?.latitude?.let { String.format(Locale.US, "%.5f°", it) } ?: "Not set", onOpenLocation)
                                RowDivider(vine.cardBorder)
                                SetupValueRow("Longitude", state.selectedVineyard?.longitude?.let { String.format(Locale.US, "%.5f°", it) } ?: "Not set", onOpenLocation)
                                RowDivider(vine.cardBorder)
                                SetupValueRow("Elevation", state.selectedVineyard?.elevationMetres?.let { String.format(Locale.US, "%.0f m", it) } ?: "Not set", onOpenLocation)
                                RowDivider(vine.cardBorder)
                                SetupValueRow("Calculation", gddSettings.calculationMode.shortName, onOpenLocation)
                                RowDivider(vine.cardBorder)
                                SetupValueRow("Reset Point", gddSettings.resetMode.displayName, onOpenLocation)
                            }
                            Text(
                                "Coordinates and elevation improve degree-day accuracy. Standard GDD is base 10°C. BEDD caps daily temps at 19°C, adds a diurnal-range bonus, and applies a day-length factor from latitude. Reset Point determines when accumulation starts each season (overridable per block).",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }

                        // Varieties
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            SectionLabel("Varieties", Icons.Filled.Spa, VineColors.LeafGreen)
                            VineyardCard {
                                NavRow(
                                    icon = Icons.Filled.Spa,
                                    tint = VineColors.LeafGreen,
                                    title = "Grape Varieties",
                                    value = varietyCatalogSummary(state, sharedCatalogCount),
                                    onClick = onOpenVarieties,
                                )
                            }
                            Text(
                                "Master list of grape varieties and their optimal ripeness (Growing Degree Days). Used when assigning varieties to blocks.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                            if (state.grapeVarietyReferenceError != null) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        "Reference list unavailable; saved allocation names are still shown.",
                                        fontSize = 12.sp,
                                        color = VineColors.Warning,
                                        modifier = Modifier.weight(1f),
                                    )
                                    TextButton(onClick = { vm.refresh() }) { Text("Retry") }
                                }
                            }
                        }

                    // Export / Import
                    if (canExport || canImport) {
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            SectionLabel("Export / Import", Icons.Filled.FileUpload, VineColors.Info)
                            VineyardCard {
                                if (canExport) {
                                    ActionRow(
                                        icon = Icons.Filled.FileUpload,
                                        tint = VineColors.Info,
                                        title = "Export Blocks",
                                        value = "${paddocks.size} block${if (paddocks.size == 1) "" else "s"}",
                                        enabled = paddocks.isNotEmpty(),
                                        onClick = {
                                            val ok = PaddockTransferService.exportAndShare(
                                                context = context,
                                                paddocks = paddocks,
                                                vineyardId = state.selectedVineyardId,
                                                vineyardName = state.selectedVineyard?.name ?: "Vineyard",
                                            )
                                            if (!ok) Toast.makeText(context, "Nothing to export", Toast.LENGTH_SHORT).show()
                                        },
                                    )
                                }
                                if (canExport && canImport) RowDivider(vine.cardBorder)
                                if (canImport) {
                                    ActionRow(
                                        icon = Icons.Filled.FileDownload,
                                        tint = VineColors.Info,
                                        title = "Import Blocks",
                                        value = null,
                                        enabled = true,
                                        onClick = { importLauncher.launch(arrayOf("application/json", "text/json", "*/*")) },
                                    )
                                }
                            }
                            Text(
                                "Export your block data as JSON to share or back up. Import blocks from a previously exported file.",
                                fontSize = 12.sp,
                                color = vine.textSecondary,
                            )
                        }
                    }

                    // Button Customisation
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        SectionLabel("Button Customisation", Icons.Filled.GridView, VineColors.Info)
                        VineyardCard {
                            ButtonCustomisationRow("Repair Buttons", Icons.Filled.Build, state.repairButtons) { editButtonMode = "Repairs" }
                            RowDivider(vine.cardBorder)
                            ButtonCustomisationRow("Repair Templates", Icons.Filled.GridView, emptyList()) { templateMode = "Repairs" }
                            RowDivider(vine.cardBorder)
                            ButtonCustomisationRow("Growth Buttons", Icons.Filled.Spa, state.growthButtons) { editButtonMode = "Growth" }
                            RowDivider(vine.cardBorder)
                            ButtonCustomisationRow("Growth Templates", Icons.Filled.GridView, emptyList()) { templateMode = "Growth" }
                        }
                        Text(
                            "Customize buttons directly or create templates to quickly switch between different button sets. Templates pair rows left and right.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }

                    // Growth Stages
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        SectionLabel("Growth Stages", Icons.Filled.Checklist, VineColors.LeafGreen)
                        VineyardCard {
                            NavRow(
                                icon = Icons.Filled.Checklist,
                                tint = VineColors.LeafGreen,
                                title = "E-L Growth Stages",
                                value = "${operationSettings.enabledGrowthStageCodes.size}/${GrowthStage.allStages.size}",
                                onClick = onOpenGrowthStageConfig,
                            )
                            RowDivider(vine.cardBorder)
                            NavRow(
                                icon = Icons.Filled.PhotoLibrary,
                                tint = VineColors.LeafGreen,
                                title = "Growth Stage Images",
                                value = null,
                                onClick = onOpenGrowthStageImages,
                            )
                        }
                        Text(
                            "Configure which E-L growth stages are available and manage reference images for visual confirmation.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }

                    // Weather
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        SectionLabel("Weather", Icons.Filled.CloudQueue, VineColors.Orange)
                        VineyardCard {
                            NavRow(
                                icon = Icons.Filled.CloudQueue,
                                tint = VineColors.Info,
                                title = "Weather Data & Forecasting",
                                value = null,
                                onClick = onOpenWeather,
                            )
                        }
                        Text(
                            "Manage forecast and local observation sources, station credentials and rainfall backfill from a single place.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }

                    // Region / Units
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        SectionLabel("Region / Units", Icons.Filled.Straighten, VineColors.Cyan)
                        VineyardCard {
                            NavRow(
                                icon = Icons.Filled.Straighten,
                                tint = VineColors.Indigo,
                                title = "Region & Units",
                                value = null,
                                onClick = onOpenRegionUnits,
                            )
                        }
                        Text(
                            "Set the country, currency, units, date format and terminology used to display and export records.",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                }
            }
        }
    }

    editButtonMode?.let { mode ->
        EditLauncherButtonsSheet(
            vm = vm,
            state = state,
            mode = mode,
            onDismiss = { editButtonMode = null },
            onOpenTemplates = {
                editButtonMode = null
                templateMode = mode
            },
        )
    }

    templateMode?.let { mode ->
        ButtonTemplatesSheet(vm = vm, state = state, mode = mode, onDismiss = { templateMode = null })
    }

    importSummary?.let { summary ->
        AlertDialog(
            onDismissRequest = { importSummary = null },
            title = { Text("Import Complete") },
            text = { Text(PaddockTransferService.summaryMessage(summary)) },
            confirmButton = { TextButton(onClick = { importSummary = null }) { Text("OK") } },
        )
    }

    importError?.let { message ->
        AlertDialog(
            onDismissRequest = { importError = null },
            title = { Text("Import Failed") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = { importError = null }) { Text("OK") } },
        )
    }
}

private fun sortPaddocks(
    paddocks: List<Paddock>,
    option: BlockSortOption,
    varieties: List<com.rork.vinetrack.data.model.GrapeVarietyRow>,
): List<Paddock> = when (option) {
    BlockSortOption.RowNumber -> paddocks.sortedWith(
        compareBy({ it.rows?.minOfOrNull { r -> r.number } ?: Int.MAX_VALUE }, { it.name.lowercase() }),
    )
    BlockSortOption.VarietyAZ -> paddocks.sortedWith(
        compareBy(
            { block ->
                block.varietyAllocations.orEmpty()
                    .maxByOrNull { it.displayPercent ?: 0.0 }
                    ?.let { VineyardVarietyPresentation.resolve(it, varieties).name }
                    ?.lowercase()
                    ?: "\uFFFF"
            },
            { it.name.lowercase() },
        ),
    )
    BlockSortOption.RowCount -> paddocks.sortedWith(
        compareByDescending<Paddock> { it.rowCount }.thenBy { it.name.lowercase() },
    )
    BlockSortOption.VineCount -> paddocks.sortedWith(
        compareByDescending<Paddock> { it.effectiveVineCount }.thenBy { it.name.lowercase() },
    )
}

/**
 * Grape Varieties card value (iOS `masterVarietyCount` + `customVarietyCount`
 * parity): the shared catalogue's active built-in count when known, otherwise
 * the bundled built-in size; custom entries for this vineyard are appended.
 */
private fun varietyCatalogSummary(state: AppUiState, sharedCatalogCount: Int): String {
    val vineyardId = state.selectedVineyardId
    val customCount = state.grapeVarieties.count {
        it.isCustom && it.isActive && (vineyardId == null || it.vineyardId.equals(vineyardId, ignoreCase = true))
    }
    val base = (if (sharedCatalogCount > 0) sharedCatalogCount else BuiltInGrapeVarietyGDD.catalogSize).toString()
    return if (customCount > 0) "$base · +$customCount custom" else base
}

@Composable
private fun SectionLabel(title: String, icon: ImageVector, tint: Color, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        SectionHeader(title, onLight = true, modifier = Modifier.weight(1f, fill = false))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SortMenu(selected: BlockSortOption, onSelect: (BlockSortOption) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .clip(CircleShape)
                .background(VineColors.Info.copy(alpha = 0.12f))
                .clickable { open = true }
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(Icons.Filled.SwapVert, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(16.dp))
            Text(selected.label, color = VineColors.Info, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            BlockSortOption.entries.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option.label) },
                    onClick = { onSelect(option); open = false },
                )
            }
        }
    }
}

@Composable
private fun AddBlockRow(onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            modifier = Modifier.size(30.dp).clip(CircleShape).background(VineColors.PrimaryAccent),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Add, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
        }
        Text("Add Block", color = VineColors.PrimaryAccent, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun BlockSetupRow(
    block: Paddock,
    varietiesOk: Boolean?,
    soilOk: Boolean?,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(block.name, fontWeight = FontWeight.Bold, color = VineColors.PrimaryAccent, fontSize = 17.sp)

            Text(
                buildList {
                    add(rowRange(block))
                    add("${block.rowCount} rows")
                    if (block.effectiveVineCount > 0) add("${"%,d".format(block.effectiveVineCount)} vines")
                }.joinToString("  \u2022  "),
                fontSize = 13.sp,
                color = VineColors.PrimaryAccent.copy(alpha = 0.75f),
            )

            irrigationSummary(block)?.let {
                Text(it, fontSize = 13.sp, color = VineColors.PrimaryAccent.copy(alpha = 0.75f))
            }

            SetupChecklist(
                boundariesOk = block.hasGeometry,
                rowsOk = block.hasRows,
                trellisOk = (block.rowWidth ?: 0.0) > 0,
                varietiesOk = varietiesOk,
                irrigationOk = irrigationComplete(block),
                soilOk = soilOk,
            )
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = vine.textSecondary,
        )
    }
}

private fun rowRange(block: Paddock): String {
    val nums = block.rows?.map { it.number }?.sorted().orEmpty()
    val first = nums.firstOrNull()
    val last = nums.lastOrNull()
    return when {
        first == null || last == null -> "No rows"
        first == last -> "Row $first"
        else -> "Row $first to Row $last"
    }
}

private fun blockVarietiesCompleteness(block: Paddock, state: AppUiState): Boolean? {
    val allocations = block.varietyAllocations.orEmpty()
    if (allocations.isEmpty()) return false
    val total = allocations.sumOf { it.displayPercent ?: 0.0 }
    if (kotlin.math.abs(total - 100.0) >= 0.5) return false
    if (VineyardVarietyPresentation.isComplete(allocations, state.grapeVarieties)) return true
    return if (state.grapeVarietyReferenceLoading || state.grapeVarietyReferenceError != null) null else false
}

private fun irrigationSummary(block: Paddock): String? {
    val parts = mutableListOf<String>()
    block.flowPerEmitter?.takeIf { it > 0 }?.let { parts.add(String.format(Locale.US, "%.1f L/hr", it)) }
    block.mmPerHour?.takeIf { it > 0 }?.let { parts.add(String.format(Locale.US, "%.2f mm/hr", it)) }
    return parts.joinToString("  \u2022  ").takeIf { it.isNotBlank() }
}

private fun irrigationComplete(block: Paddock): Boolean {
    val mm = block.mmPerHour ?: return false
    if (mm <= 0) return false
    if ((block.flowPerEmitter ?: 0.0) <= 0) return false
    if ((block.emitterSpacing ?: 0.0) <= 0) return false
    return (block.rowWidth ?: 0.0) > 0
}

@Composable
private fun SetupChecklist(
    boundariesOk: Boolean,
    rowsOk: Boolean,
    trellisOk: Boolean,
    varietiesOk: Boolean?,
    irrigationOk: Boolean,
    soilOk: Boolean?,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ChecklistItem("Boundaries", boundariesOk, Modifier.weight(1f))
            ChecklistItem("Rows", rowsOk, Modifier.weight(1f))
            ChecklistItem("Trellis", trellisOk, Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ChecklistItem("Varieties", varietiesOk, Modifier.weight(1f))
            ChecklistItem("Irrigation", irrigationOk, Modifier.weight(1f))
            ChecklistItem("Soil", soilOk, Modifier.weight(1f))
        }
    }
}

@Composable
private fun ChecklistItem(label: String, ok: Boolean?, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    val tint = when (ok) {
        true -> VineColors.Success
        false -> VineColors.Destructive
        null -> vine.textSecondary
    }
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            modifier = Modifier.size(16.dp).clip(CircleShape).background(tint.copy(alpha = if (ok == true) 1f else 0.85f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                when (ok) {
                    true -> Icons.Filled.Done
                    false -> Icons.Filled.Close
                    null -> Icons.Filled.MoreHoriz
                },
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(11.dp),
            )
        }
        Text(label, fontSize = 12.sp, color = vine.textSecondary, maxLines = 1)
    }
}

@Composable
private fun SetupValueRow(label: String, value: String, onClick: () -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(label, color = vine.textPrimary, modifier = Modifier.weight(0.45f))
        Text(value, color = vine.textSecondary, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(0.55f))
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
    }
}

@Composable
private fun MembershipStatusCard(isLoading: Boolean, error: String?, onRetry: () -> Unit) {
    val vine = LocalVineColors.current
    VineyardCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (isLoading) CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            Column(modifier = Modifier.weight(1f)) {
                Text(if (isLoading) "Checking vineyard access…" else "Vineyard access unavailable", color = vine.textPrimary, fontWeight = FontWeight.SemiBold)
                error?.let { Text(it, color = vine.textSecondary, fontSize = 12.sp) }
            }
            if (!isLoading) TextButton(onClick = onRetry) { Text("Retry") }
        }
    }
}

@Composable
private fun ButtonCustomisationRow(
    title: String,
    icon: ImageVector,
    buttons: List<LauncherButton>,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(VineColors.Info.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = VineColors.Info, modifier = Modifier.size(20.dp))
        }
        Text(title, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
        if (buttons.isNotEmpty()) {
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                buttons.sortedBy { it.index }.distinctBy { it.index % 4 }.take(4).forEach { button ->
                    Box(Modifier.size(9.dp).clip(CircleShape).background(launcherColor(button.color)))
                }
            }
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = vine.textSecondary)
    }
}

@Composable
private fun NavRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    value: String?,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable { onClick() }.padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        }
        Text(title, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, modifier = Modifier.weight(1f))
        if (value != null) {
            Text(value, fontSize = 13.sp, color = vine.textSecondary)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = vine.textSecondary,
        )
    }
}

@Composable
private fun ActionRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    value: String?,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    val alpha = if (enabled) 1f else 0.4f
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (enabled) it.clickable { onClick() } else it }
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(tint.copy(alpha = 0.15f * alpha)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint.copy(alpha = alpha), modifier = Modifier.size(20.dp))
        }
        Text(title, fontWeight = FontWeight.SemiBold, color = tint.copy(alpha = alpha), modifier = Modifier.weight(1f))
        if (value != null) {
            Text(value, fontSize = 13.sp, color = vine.textSecondary.copy(alpha = alpha))
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = vine.textSecondary.copy(alpha = alpha),
        )
    }
}

@Composable
private fun RowDivider(color: Color) {
    Box(modifier = Modifier.fillMaxWidth().size(0.5.dp).background(color))
}
