package com.rork.vinetrack.ui.screens

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddLocationAlt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.TableRows
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.CameraPositionState
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.GoogleMapComposable
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.PinPlacement
import com.rork.vinetrack.data.model.CustomPinCreateParams
import com.rork.vinetrack.data.model.CustomPinType
import com.rork.vinetrack.data.model.GrowthStage
import com.rork.vinetrack.data.model.ManualIssueContract
import com.rork.vinetrack.data.model.ManualIssueLatLng
import com.rork.vinetrack.data.model.ManualIssueSegment
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.UnifiedPinContract
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.AutoPhotoPromptSheet
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.MapMyLocationButton
import com.rork.vinetrack.ui.components.hasDeviceLocationPermission
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

/**
 * Unified "Add Pin / Action" composer (sql/170) — an extension of the
 * existing pin workflow, not a separate issue system.
 *
 * Location-first flow:
 *  1. Choose how to add the pin: drop a pin manually / select a row /
 *     select a block.
 *  2. Pick the location using the chosen method (map tap with canonical
 *     row snapping, block + row/quarter selection, or block only).
 *  3. Swipeable Repair | Growth | Custom tabs; tap a type, then Save Pin.
 *
 * Repair and Growth saves go through the existing pin create path (mode
 * Repairs/Growth); Custom saves use the simplified `create_custom_pin` RPC
 * (mode ManualIssue) referencing the vineyard-shared custom type. There is
 * no Left/Right selection and no category/priority/due-date/assignee/status
 * controls anywhere in this flow. The saved pin lands on the existing Pins
 * map/list through normal pin sync.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UnifiedPinComposerScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
    onSaved: () -> Unit,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    // Step state: 0 = location method, 1 = location, 2 = type + save.
    var step by remember { mutableStateOf(0) }
    var method by remember { mutableStateOf(UnifiedPinContract.SCOPE_POINT) }
    // True once the user has explicitly picked a method — drives the
    // location-choice cards' selected state when stepping back.
    var methodChosen by remember { mutableStateOf(false) }

    // Location state.
    var tapped by remember { mutableStateOf<LatLng?>(null) }
    var paddockId by remember { mutableStateOf<String?>(null) }
    var segments by remember { mutableStateOf<Set<ManualIssueSegment>>(emptySet()) }

    // Type selection.
    var selection by remember { mutableStateOf<ComposerTypeSelection?>(null) }
    var showAddCustom by remember { mutableStateOf(false) }
    var validationMessage by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }

    // Growth Stage picker — the EXISTING E-L stage list + image confirmation
    // (shared with the Growth screen), reused here without a second stage list.
    var showStagePicker by remember { mutableStateOf(false) }
    var stageSearch by remember { mutableStateOf("") }
    var stageToConfirm by remember { mutableStateOf<GrowthStage?>(null) }
    val stageImagesByCode = remember(state.growthStageImages) {
        state.growthStageImages.associateBy { it.stageCode }
    }

    val selectedPaddock = state.paddocks.firstOrNull { it.id == paddockId }

    LaunchedEffect(Unit) { vm.refreshCustomPinTypes() }

    // Hardware/gesture back steps backwards through the flow. Stepping back
    // never clears the location or the chosen type — both are held above
    // this `when`, so adjusting the pin and returning finds the type still
    // selected.
    BackHandler {
        when (step) {
            0 -> onBack()
            else -> step -= 1
        }
    }

    // The pin this composer just created, waiting on the photo question. Only
    // its id is held: the pin is saved FIRST, so ignoring the question,
    // swiping it away or cancelling the picker can never lose it.
    var photoPinId by remember { mutableStateOf<String?>(null) }
    var showAutoPhoto by remember { mutableStateOf(false) }
    // Latches the instant a pin is created. Together with [finished] below it
    // makes the whole save single-shot: no timeout, dismissal or photo
    // callback can create or finish a second time.
    var pinCreated by remember { mutableStateOf(false) }
    var finished by remember { mutableStateOf(false) }

    fun finish() {
        if (finished) return
        finished = true
        photoPinId = null
        onSaved()
    }

    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri: Uri? ->
        val pin = photoPinId?.let { id -> state.pins.firstOrNull { it.id == id } }
        if (uri != null && pin != null) {
            // The EXISTING upload / pending-photo queue, attached to the exact
            // pin just created.
            vm.attachQuickPinPhoto(pin, uri) { ok ->
                scope.launch {
                    snackbarHostState.showSnackbar(if (ok) "Photo added to pin" else "Couldn't add the photo")
                }
            }
        }
        // A cancelled picker ends exactly like a successful one: the pin is
        // already saved, it simply keeps no photo.
        finish()
    }

    /**
     * Ask the photo question for the pin that was just created.
     *
     * This runs for EVERY save out of this composer — Repair, Growth, Growth
     * Stage and Custom, across the map, row and block methods — and
     * deliberately does not consult the auto-photo preference. That setting
     * still governs the ordinary quick Repair/Growth taps elsewhere and is
     * left untouched.
     */
    fun promptForPhoto(pinId: String) {
        pinCreated = true
        photoPinId = pinId
        saving = false
        showAutoPhoto = true
    }

    fun markerCoordinate(): ManualIssueLatLng? = when (method) {
        UnifiedPinContract.SCOPE_POINT -> tapped?.let { ManualIssueLatLng(it.latitude, it.longitude) }
        UnifiedPinContract.SCOPE_ROW -> selectedPaddock?.let { paddock ->
            val rowLines = buildMap {
                paddock.rows.orEmpty().forEach { row ->
                    val start = row.startPoint
                    val end = row.endPoint
                    if (start != null && end != null) {
                        put(
                            row.number,
                            ManualIssueLatLng(start.latitude, start.longitude) to
                                ManualIssueLatLng(end.latitude, end.longitude),
                        )
                    }
                }
            }
            ManualIssueContract.markerCoordinate(segments.toList(), rowLines)
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

    fun save() {
        // Single-shot: the pin is created once and the photo question runs
        // after it, never instead of it.
        if (pinCreated) return
        val chosen = selection
        val marker = markerCoordinate()
        val canonical = ManualIssueContract.canonicalSegments(segments.toList())
        val error = UnifiedPinContract.validationError(
            scope = method,
            hasSelectedType = chosen != null,
            latitude = marker?.latitude,
            longitude = marker?.longitude,
            paddockId = paddockId,
            segments = canonical,
        )
        if (error != null || chosen == null || marker == null) {
            validationMessage = error ?: "Select a pin type."
            return
        }
        validationMessage = null
        saving = true

        // Resolved AGAIN here from the FINAL marker coordinate, through the
        // same canonical resolver the live preview label uses. A pin dragged
        // from row 69 to row 70 after the label was drawn therefore cannot be
        // stored against the row it merely used to be near.
        val placement = if (method == UnifiedPinContract.SCOPE_POINT) {
            PinPlacement.resolve(
                paddocks = state.paddocks,
                selectedPaddockId = null,
                latitude = marker.latitude,
                longitude = marker.longitude,
                side = null, // Left/Right is not part of this workflow.
            )
        } else {
            null
        }
        val resolvedBlock = when (method) {
            UnifiedPinContract.SCOPE_POINT -> placement?.paddockId
            else -> paddockId
        }
        val rowSegments = if (method == UnifiedPinContract.SCOPE_ROW) canonical else null

        when (chosen) {
            is ComposerTypeSelection.GrowthStageSel -> {
                // A normal Growth pin carrying the EXACT stage identifier the
                // existing growth-stage workflow stores — never a second list.
                val title = UnifiedPinContract.growthStagePinTitle(chosen.stage.code)
                vm.createPin(
                    title = title,
                    mode = "Growth",
                    category = null,
                    notes = chosen.stage.description,
                    side = null,
                    paddockId = resolvedBlock,
                    rowNumber = null,
                    isCompleted = false,
                    latitude = marker.latitude,
                    longitude = marker.longitude,
                    buttonName = title,
                    buttonColor = UnifiedPinContract.GROWTH_STAGE_PIN_COLOR,
                    heading = null,
                    placement = placement,
                    locationScope = method,
                    segments = rowSegments,
                    growthStageCode = chosen.stage.code,
                    onCreatedPin = { pin -> promptForPhoto(pin.id) },
                ) { ok ->
                    saving = false
                    if (!ok) {
                        scope.launch { snackbarHostState.showSnackbar("Couldn't save the pin. Please try again.") }
                    }
                }
            }
            is ComposerTypeSelection.Standard -> {
                vm.createPin(
                    title = chosen.name,
                    mode = chosen.mode,
                    category = chosen.name,
                    notes = null,
                    side = null, // no side selection in the unified composer
                    paddockId = resolvedBlock,
                    rowNumber = null,
                    isCompleted = false,
                    latitude = marker.latitude,
                    longitude = marker.longitude,
                    buttonName = chosen.name,
                    buttonColor = chosen.colorToken,
                    heading = null,
                    placement = placement,
                    locationScope = method,
                    segments = rowSegments,
                    onCreatedPin = { pin -> promptForPhoto(pin.id) },
                ) { ok ->
                    saving = false
                    if (!ok) {
                        scope.launch { snackbarHostState.showSnackbar("Couldn't save the pin. Please try again.") }
                    }
                }
            }
            is ComposerTypeSelection.Custom -> {
                val vineyardId = state.selectedVineyardId ?: run {
                    saving = false
                    validationMessage = "No vineyard selected."
                    return
                }
                val customPinId = UUID.randomUUID().toString()
                vm.createCustomPin(
                    CustomPinCreateParams(
                        id = customPinId,
                        vineyardId = vineyardId,
                        title = chosen.type.name,
                        locationScope = method,
                        customTypeId = chosen.type.id,
                        paddockId = resolvedBlock,
                        latitude = marker.latitude,
                        longitude = marker.longitude,
                        snappedLatitude = placement?.snappedLatitude,
                        snappedLongitude = placement?.snappedLongitude,
                        pinRowNumber = placement?.pinRowNumber,
                        alongRowDistanceM = placement?.alongRowDistanceM,
                        snappedToRow = placement?.snappedToRow ?: false,
                        clientUpdatedAt = Instant.now().toString(),
                        segments = rowSegments,
                    ),
                ) { ok, message ->
                    saving = false
                    if (ok) {
                        promptForPhoto(customPinId)
                    } else {
                        scope.launch { snackbarHostState.showSnackbar(message ?: "Couldn't save the pin.") }
                    }
                }
            }
        }
    }

    Scaffold(
        containerColor = vine.appBackground,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(UnifiedPinContract.QUICK_ACTION_TITLE, fontWeight = FontWeight.Bold, fontSize = 17.sp, maxLines = 1)
                        Text(
                            when (step) {
                                0 -> "How do you want to add the pin?"
                                1 -> when (method) {
                                    UnifiedPinContract.SCOPE_ROW -> "Select rows — the block is detected automatically"
                                    UnifiedPinContract.SCOPE_BLOCK -> "Select a block"
                                    else -> "Tap the map to place the pin"
                                }
                                else -> "Choose the pin type"
                            },
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                },
                navigationIcon = { BackNavIcon(onBack = { if (step == 0) onBack() else step -= 1 }) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
        ) {
            when (step) {
                0 -> MethodStep(
                    selectedMethod = if (methodChosen) method else null,
                    onSelect = { selected ->
                        if (methodChosen && method != selected) {
                            // Changing the method clears location state so no
                            // stale snapping/segments survive.
                            tapped = null
                            paddockId = null
                            segments = emptySet()
                        }
                        method = selected
                        methodChosen = true
                        validationMessage = null
                        step = 1
                    },
                )
                1 -> LocationStep(
                    method = method,
                    state = state,
                    tapped = tapped,
                    onTap = { tapped = it; validationMessage = null },
                    paddockId = paddockId,
                    onPaddock = { paddockId = it; segments = emptySet(); validationMessage = null },
                    segments = segments,
                    // Row-first: tapping a row DERIVES its block from the tapped
                    // geometry; switching blocks starts a fresh selection.
                    onRowTap = { blockId, tappedSegments ->
                        val result = UnifiedPinContract.applyRowTap(paddockId, blockId, segments, tappedSegments)
                        paddockId = result.first
                        segments = result.second
                        validationMessage = null
                    },
                    validationMessage = validationMessage,
                    onContinue = {
                        val marker = markerCoordinate()
                        val error = when (method) {
                            UnifiedPinContract.SCOPE_POINT ->
                                if (tapped == null) UnifiedPinContract.ERROR_TAP_MAP else null
                            UnifiedPinContract.SCOPE_ROW -> when {
                                ManualIssueContract.canonicalSegments(segments.toList()).isEmpty() ->
                                    UnifiedPinContract.ERROR_SELECT_ROW
                                paddockId == null -> UnifiedPinContract.ERROR_ROW_BLOCK
                                else -> null
                            }
                            else -> if (paddockId == null) UnifiedPinContract.ERROR_SELECT_BLOCK else null
                        } ?: if (marker == null) UnifiedPinContract.ERROR_LOCATION_REQUIRED else null
                        if (error != null) {
                            validationMessage = error
                        } else {
                            validationMessage = null
                            step = 2
                        }
                    },
                )
                else -> TypeStep(
                    state = state,
                    selection = selection,
                    onSelect = { selection = it; validationMessage = null },
                    onAddCustom = { showAddCustom = true },
                    onGrowthStage = { showStagePicker = true },
                    validationMessage = validationMessage,
                    saving = saving,
                    onSave = { save() },
                )
            }
        }
    }

    // The EXISTING E-L growth-stage picker (same list, images, order and
    // identifiers as the Growth screen). Cancelling changes nothing — no pin
    // is created until Save Pin is tapped with a confirmed selection.
    if (showStagePicker) {
        ModalBottomSheet(
            onDismissRequest = {
                showStagePicker = false
                stageToConfirm = null
                stageSearch = ""
            },
        ) {
            val confirm = stageToConfirm
            if (confirm == null) {
                GrowthStagePickList(
                    vm = vm,
                    imagesByCode = stageImagesByCode,
                    searchText = stageSearch,
                    onSearchChange = { stageSearch = it },
                    onPick = { picked ->
                        val hasImage = stageImagesByCode[picked.code] != null ||
                            GrowthStageBundledImages.hasBundled(picked.code)
                        if (hasImage) {
                            stageToConfirm = picked
                        } else {
                            selection = ComposerTypeSelection.GrowthStageSel(picked)
                            validationMessage = null
                            showStagePicker = false
                            stageSearch = ""
                        }
                    },
                )
            } else {
                GrowthStageConfirm(
                    vm = vm,
                    stage = confirm,
                    image = stageImagesByCode[confirm.code],
                    onConfirm = {
                        selection = ComposerTypeSelection.GrowthStageSel(confirm)
                        validationMessage = null
                        showStagePicker = false
                        stageToConfirm = null
                        stageSearch = ""
                    },
                    onBack = { stageToConfirm = null },
                )
            }
        }
    }

    if (showAddCustom) {
        AddCustomItemDialog(
            existing = state.customPinTypes,
            onDismiss = { showAddCustom = false },
            onAdd = { name ->
                vm.addCustomPinType(name) { type, error ->
                    if (type != null) {
                        selection = ComposerTypeSelection.Custom(type)
                        showAddCustom = false
                    } else {
                        scope.launch { snackbarHostState.showSnackbar(error ?: "Couldn't add the custom item.") }
                    }
                }
            },
        )
    }

    // The photo question, shown after EVERY manual-composer save. Skip, a
    // swipe-dismiss and the 3s timeout are the same answer: keep the pin,
    // no photo, finish. The shared sheet owns the countdown so this flow and
    // the quick-pin flow can never drift apart.
    if (showAutoPhoto) {
        AutoPhotoPromptSheet(
            onSkip = {
                showAutoPhoto = false
                finish()
            },
            onTakePhoto = {
                showAutoPhoto = false
                photoPicker.launch(
                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                )
            },
        )
    }
}

/** What the user picked on the Repair / Growth / Custom tabs. */
private sealed interface ComposerTypeSelection {
    /** An existing Repair or Growth launcher button (same ids/labels/colours). */
    data class Standard(val name: String, val colorToken: String?, val mode: String) : ComposerTypeSelection

    /** The Growth Stage launcher: an exact E-L stage from the existing picker. */
    data class GrowthStageSel(val stage: GrowthStage) : ComposerTypeSelection

    /** A vineyard-shared custom item (mode stays ManualIssue internally). */
    data class Custom(val type: CustomPinType) : ComposerTypeSelection
}

// MARK: - Step 1: location method

@Composable
private fun MethodStep(selectedMethod: String?, onSelect: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 8.dp)) {
        MethodCard(
            title = UnifiedPinContract.METHOD_TITLES[0],
            subtitle = UnifiedPinContract.METHOD_SUBTITLES[0],
            icon = { Icon(Icons.Filled.AddLocationAlt, contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp)) },
            color = VineColors.Primary,
            selected = selectedMethod == UnifiedPinContract.SCOPE_POINT,
        ) { onSelect(UnifiedPinContract.SCOPE_POINT) }
        MethodCard(
            title = UnifiedPinContract.METHOD_TITLES[1],
            subtitle = UnifiedPinContract.METHOD_SUBTITLES[1],
            icon = { Icon(Icons.Filled.TableRows, contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp)) },
            color = VineColors.LeafGreen,
            selected = selectedMethod == UnifiedPinContract.SCOPE_ROW,
        ) { onSelect(UnifiedPinContract.SCOPE_ROW) }
        MethodCard(
            title = UnifiedPinContract.METHOD_TITLES[2],
            subtitle = UnifiedPinContract.METHOD_SUBTITLES[2],
            icon = { Icon(Icons.Filled.GridView, contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp)) },
            color = VineColors.EarthBrown,
            selected = selectedMethod == UnifiedPinContract.SCOPE_BLOCK,
        ) { onSelect(UnifiedPinContract.SCOPE_BLOCK) }
    }
}

/**
 * One enlarged location-choice control — full-width, min height
 * [UnifiedPinContract.METHOD_BUTTON_MIN_HEIGHT] (≈ double the original card),
 * with a clear blue selected state. Identical sizing on iOS.
 */
@Composable
private fun MethodCard(
    title: String,
    subtitle: String,
    icon: @Composable () -> Unit,
    color: Color,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = UnifiedPinContract.METHOD_BUTTON_MIN_HEIGHT.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(vine.cardBackground)
            .then(
                if (selected) {
                    Modifier.border(2.dp, VineColors.ActionBlue, RoundedCornerShape(16.dp))
                } else {
                    Modifier
                },
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(
            modifier = Modifier.size(48.dp).clip(RoundedCornerShape(12.dp)).background(color),
            contentAlignment = Alignment.Center,
        ) { icon() }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
            Text(subtitle, fontSize = 13.sp, color = vine.textSecondary)
        }
        if (selected) {
            Icon(Icons.Filled.CheckCircle, contentDescription = "Selected", tint = VineColors.ActionBlue, modifier = Modifier.size(24.dp))
        } else {
            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(20.dp))
        }
    }
}

// MARK: - Step 2: location

@Composable
private fun LocationStep(
    method: String,
    state: AppUiState,
    tapped: LatLng?,
    onTap: (LatLng) -> Unit,
    paddockId: String?,
    onPaddock: (String?) -> Unit,
    segments: Set<ManualIssueSegment>,
    // Row-first selection: (tapped block id, tapped segments). The block is
    // derived from the tapped row's geometry — never picked from a dropdown.
    onRowTap: (String, Set<ManualIssueSegment>) -> Unit,
    validationMessage: String?,
    onContinue: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val selectedPaddock = state.paddocks.firstOrNull { it.id == paddockId }
    var fullScreenMap by remember { mutableStateOf(false) }
    var rowFilter by remember { mutableStateOf("") }

    // The app's EXISTING location plumbing — the same tracker and permission
    // check every other VineTrack map uses. No second GPS source is created.
    val tracker = remember { LocationTracker(context) }
    var hasLocationPerm by remember { mutableStateOf(hasDeviceLocationPermission(context)) }
    var locationMessage by remember { mutableStateOf<String?>(null) }

    // Shared camera start for the inline and full-screen maps.
    val mapStart = tapped ?: state.paddocks.firstOrNull { !it.polygonPoints.isNullOrEmpty() }
        ?.polygonPoints?.let { pts ->
            ManualIssueContract.blockCentroid(pts.map { ManualIssueLatLng(it.latitude, it.longitude) })
                ?.let { LatLng(it.latitude, it.longitude) }
        }
    val camera = rememberCameraPositionState {
        position = CameraPosition.fromLatLngZoom(mapStart ?: LatLng(-34.9, 138.6), if (mapStart != null) 16f else 5f)
    }

    // Opening camera priority: an already-dropped pin, then the device's
    // current location, then the mapped block, then the wide fallback (the
    // last two are already applied above). This runs ONCE and then latches:
    // GPS movement never drags the camera back off what the operator is
    // looking at.
    var cameraFramed by remember { mutableStateOf(tapped != null) }
    LaunchedEffect(tapped != null) { if (tapped != null) cameraFramed = true }
    LaunchedEffect(Unit) {
        if (cameraFramed || !tracker.hasPermission) return@LaunchedEffect
        val fix = tracker.currentLocation()
        if (fix != null && !cameraFramed) {
            cameraFramed = true
            runCatching {
                camera.animate(CameraUpdateFactory.newLatLngZoom(LatLng(fix.latitude, fix.longitude), 17f))
            }
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Spacer(Modifier.height(2.dp))
        when (method) {
            UnifiedPinContract.SCOPE_POINT -> {
                // The map lives OUTSIDE any scrollable container so it owns
                // every pinch and drag — smooth continuous zoom/pan, exactly
                // like the main vineyard map.
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .clip(RoundedCornerShape(12.dp)),
                ) {
                    if (!fullScreenMap) {
                        GoogleMap(
                            cameraPositionState = camera,
                            // The normal blue current-location dot. Absent, not
                            // broken, when the operator has denied location —
                            // manual placement never depends on a fix.
                            properties = MapProperties(
                                mapType = MapType.HYBRID,
                                isMyLocationEnabled = hasLocationPerm,
                            ),
                            uiSettings = MapUiSettings(
                                zoomControlsEnabled = false,
                                // Our own control sits beside the expand button.
                                myLocationButtonEnabled = false,
                            ),
                            onMapClick = { onTap(it) },
                            modifier = Modifier.matchParentSize(),
                        ) {
                            tapped?.let { DraftPinMarker(position = it, onMove = onTap) }
                        }
                    }
                    Row(
                        modifier = Modifier.align(Alignment.TopEnd).padding(10.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        MapMyLocationButton(
                            camera = camera,
                            onMessage = { locationMessage = it },
                            contentDescription = "Centre on my location",
                            onPermissionGranted = { hasLocationPerm = true },
                        )
                        ComposerMapIconButton(
                            icon = Icons.Filled.Fullscreen,
                            contentDescription = "Full-screen map",
                            onClick = { fullScreenMap = true },
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
                // Canonical snapping preview — the same one-shot resolution the
                // save uses, so the label always matches what gets stored.
                PlacementPreviewLabel(state = state, tapped = tapped)
                locationMessage?.let {
                    Text(it, fontSize = 12.sp, color = vine.textSecondary)
                }
            }
            UnifiedPinContract.SCOPE_ROW -> {
                // Row-first: every mapped row in the vineyard is listed under
                // its block header (the existing row/quarter controls), so
                // "Row 41" is never ambiguous across blocks. The pin's block is
                // DERIVED from the tapped row — there is no block dropdown.
                val rowBlocks = state.paddocks
                    .map { block ->
                        block to block.rows.orEmpty()
                            .filter { it.startPoint != null && it.endPoint != null }
                            .sortedBy { it.number }
                    }
                    .filter { it.second.isNotEmpty() }
                    .sortedBy { it.first.name.lowercase() }
                // Filtering never touches the selection — selected rows stay
                // selected while the visible list narrows.
                val filteredRowBlocks = filterRowBlocks(rowBlocks, rowFilter)
                Column(
                    modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                if (rowBlocks.isEmpty()) {
                    Text(
                        "No mapped rows in this vineyard — use Select a block instead.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                } else {
                    RowSelectionFilterField(value = rowFilter, onValueChange = { rowFilter = it })
                }
                if (rowBlocks.isNotEmpty() && filteredRowBlocks.isEmpty()) {
                    Text(
                        "No blocks or rows match \u201c${rowFilter.trim()}\u201d.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                }
                if (segments.isNotEmpty() && selectedPaddock != null) {
                    Text(
                        ManualIssueContract.rowSelectionSummary(segments.toList()),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = VineColors.LeafGreen,
                    )
                    Text(
                        "Block: ${selectedPaddock.name} — detected from the selected row",
                        fontSize = 12.sp,
                        color = vine.textSecondary,
                    )
                }
                filteredRowBlocks.forEach { (block, rows) ->
                    val inBlock = block.id == paddockId
                    Text(
                        block.name,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        color = if (inBlock && segments.isNotEmpty()) VineColors.LeafGreen else vine.textPrimary,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                    rows.forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            val all = (1..4).map { ManualIssueSegment(row.number, it) }
                            val wholeSelected = inBlock && all.all { it in segments }
                            Box(
                                modifier = Modifier
                                    .width(38.dp)
                                    .heightIn(min = 28.dp)
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(if (wholeSelected) VineColors.LeafGreen else MaterialTheme.colorScheme.surfaceVariant)
                                    .clickable { onRowTap(block.id, all.toSet()) },
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
                                val selected = inBlock && segment in segments
                                Box(
                                    modifier = Modifier
                                        .weight(1f)
                                        .heightIn(min = 28.dp)
                                        .clip(RoundedCornerShape(5.dp))
                                        .background(if (selected) VineColors.LeafGreen else MaterialTheme.colorScheme.surfaceVariant)
                                        .clickable { onRowTap(block.id, setOf(segment)) },
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
                Spacer(Modifier.height(8.dp))
                }
            }
            else -> {
                Column(
                    modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Tap a block — the whole block will be flagged.",
                        fontSize = 13.sp,
                        color = vine.textSecondary,
                    )
                    Spacer(Modifier.height(2.dp))
                    ComposerBlockList(paddocks = state.paddocks, paddockId = paddockId, onSelect = onPaddock)
                    Spacer(Modifier.height(8.dp))
                }
            }
        }

        validationMessage?.let {
            Text(it, fontSize = 13.sp, color = VineColors.Destructive, modifier = Modifier.padding(top = 6.dp))
        }

        Button(
            onClick = onContinue,
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
        ) { Text("Continue") }
        Spacer(Modifier.height(16.dp))
    }

    // Edge-to-edge map for precise placement: tap to move the pin while the
    // placement label and Continue float on top, so the flow never leaves the
    // map.
    if (fullScreenMap) {
        FullScreenPinMap(
            state = state,
            tapped = tapped,
            onTap = onTap,
            initialPosition = camera.position,
            onSyncCamera = { camera.position = it },
            hasLocationPermission = hasLocationPerm,
            onPermissionGranted = { hasLocationPerm = true },
            validationMessage = validationMessage,
            onContinue = onContinue,
            onClose = { fullScreenMap = false },
        )
    }
}

/**
 * The draft pin: tap-placed, then DRAGGABLE.
 *
 * [position] is the composer's single shared coordinate, so the inline and
 * full-screen maps always show the pin in the same place. Drags are
 * published on every position change rather than only at drag-end, which is
 * what makes the block/row label re-resolve while the pin is still moving.
 */
@Composable
@GoogleMapComposable
private fun DraftPinMarker(position: LatLng, onMove: (LatLng) -> Unit) {
    val markerState = remember { MarkerState(position = position) }
    val latestOnMove by rememberUpdatedState(onMove)
    // A tap elsewhere (or the other map) moves the marker to match.
    LaunchedEffect(position) {
        if (markerState.position != position) markerState.position = position
    }
    // Continuous drag publication. `drop(1)` skips the value the marker was
    // created with, so composing the marker never re-reports a placement.
    LaunchedEffect(markerState) {
        snapshotFlow { markerState.position }
            .drop(1)
            .collect { latestOnMove(it) }
    }
    Marker(
        state = markerState,
        draggable = true,
        title = "Dropped pin",
        snippet = "Drag to move",
    )
}

/**
 * Full-width tappable block cards — generous touch area with a clear
 * checkmark on the selected block (replaces the old compact dropdown).
 */
@Composable
private fun ComposerBlockList(
    paddocks: List<Paddock>,
    paddockId: String?,
    onSelect: (String?) -> Unit,
) {
    val vine = LocalVineColors.current
    if (paddocks.isEmpty()) {
        Text("No blocks mapped in this vineyard yet.", fontSize = 13.sp, color = vine.textSecondary)
        return
    }
    paddocks.sortedBy { it.name.lowercase() }.forEach { paddock ->
        val selected = paddock.id == paddockId
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(vine.cardBackground)
                .then(
                    if (selected) {
                        Modifier.border(2.dp, VineColors.LeafGreen, RoundedCornerShape(12.dp))
                    } else {
                        Modifier
                    },
                )
                .clickable { onSelect(paddock.id) }
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                paddock.name,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textPrimary,
                modifier = Modifier.weight(1f),
            )
            if (selected) {
                Icon(Icons.Filled.CheckCircle, contentDescription = "Selected", tint = VineColors.LeafGreen, modifier = Modifier.size(22.dp))
            }
        }
    }
}

/**
 * Row-filter matching: a block-name substring match keeps the whole block;
 * otherwise only rows whose number starts with the query stay visible.
 * Filtering only narrows what is VISIBLE — the selection is untouched.
 */
private fun filterRowBlocks(
    rowBlocks: List<Pair<Paddock, List<PaddockRow>>>,
    filter: String,
): List<Pair<Paddock, List<PaddockRow>>> {
    val query = filter.trim()
    if (query.isEmpty()) return rowBlocks
    return rowBlocks.mapNotNull { (block, rows) ->
        if (block.name.contains(query, ignoreCase = true)) {
            block to rows
        } else {
            val matching = rows.filter { it.number.toString().startsWith(query) }
            if (matching.isNotEmpty()) block to matching else null
        }
    }
}

/** Compact one-line filter above the row selector (block name or row number). */
@Composable
private fun RowSelectionFilterField(value: String, onValueChange: (String) -> Unit) {
    val vine = LocalVineColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(vine.cardBackground)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Filled.Search, contentDescription = null, tint = vine.textSecondary, modifier = Modifier.size(16.dp))
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = TextStyle(fontSize = 14.sp, color = vine.textPrimary),
            cursorBrush = SolidColor(VineColors.Primary),
            modifier = Modifier.weight(1f).padding(vertical = 10.dp),
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty()) {
                        Text("Filter by block or row number", fontSize = 14.sp, color = vine.textSecondary)
                    }
                    inner()
                }
            },
        )
        if (value.isNotEmpty()) {
            Icon(
                Icons.Filled.Close,
                contentDescription = "Clear filter",
                tint = vine.textSecondary,
                modifier = Modifier
                    .size(18.dp)
                    .clickable { onValueChange("") },
            )
        }
    }
}

/** Small translucent icon button floated over a map. */
@Composable
private fun ComposerMapIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .size(40.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Color.Black.copy(alpha = 0.55f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = Color.White, modifier = Modifier.size(22.dp))
    }
}

/**
 * Canonical snapping preview — the same one-shot resolution the save uses,
 * so the label always matches what gets stored.
 */
@Composable
private fun PlacementPreviewLabel(state: AppUiState, tapped: LatLng?, onDark: Boolean = false) {
    val vine = LocalVineColors.current
    val color = if (onDark) Color.White.copy(alpha = 0.92f) else vine.textSecondary
    if (tapped == null) {
        Text("Tap the map to place the pin", fontSize = if (onDark) 13.sp else 12.sp, color = color)
        return
    }
    val placement = PinPlacement.resolve(
        paddocks = state.paddocks,
        selectedPaddockId = null,
        latitude = tapped.latitude,
        longitude = tapped.longitude,
        side = null,
    )
    val block = state.paddocks.firstOrNull { it.id == placement.paddockId }
    val label = when {
        placement.snappedToRow && block != null ->
            "${block.name} · on row ${formatRow(placement.pinRowNumber)}"
        block != null -> "${block.name} · not attached to a row"
        else -> "Pin placed outside mapped blocks"
    }
    Text(
        label,
        fontSize = if (onDark) 13.sp else 12.sp,
        fontWeight = if (onDark) FontWeight.Medium else FontWeight.Normal,
        color = color,
    )
}

/**
 * Edge-to-edge pin-drop map for precise placement. Zoom is uncapped (with
 * zoom controls for fine steps); the canonical placement label and the
 * Continue button float on top so the user can drop the pin and proceed
 * without leaving the map. Closing syncs the camera back to the inline map.
 */
@Composable
private fun FullScreenPinMap(
    state: AppUiState,
    tapped: LatLng?,
    onTap: (LatLng) -> Unit,
    initialPosition: CameraPosition,
    onSyncCamera: (CameraPosition) -> Unit,
    hasLocationPermission: Boolean,
    onPermissionGranted: () -> Unit,
    validationMessage: String?,
    onContinue: () -> Unit,
    onClose: () -> Unit,
) {
    // Opens on the inline map's camera, so the pin never jumps between the
    // two views — they share one coordinate and one starting frame.
    val fullCamera = remember { CameraPositionState(position = initialPosition) }
    var locationMessage by remember { mutableStateOf<String?>(null) }
    val close = {
        onSyncCamera(fullCamera.position)
        onClose()
    }
    Dialog(
        onDismissRequest = close,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
            GoogleMap(
                cameraPositionState = fullCamera,
                properties = MapProperties(
                    mapType = MapType.HYBRID,
                    isMyLocationEnabled = hasLocationPermission,
                ),
                uiSettings = MapUiSettings(
                    zoomControlsEnabled = true,
                    myLocationButtonEnabled = false,
                ),
                onMapClick = onTap,
                modifier = Modifier.fillMaxSize(),
            ) {
                tapped?.let { DraftPinMarker(position = it, onMove = onTap) }
            }
            Row(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .statusBarsPadding()
                    .padding(12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                MapMyLocationButton(
                    camera = fullCamera,
                    onMessage = { locationMessage = it },
                    contentDescription = "Centre on my location",
                    onPermissionGranted = onPermissionGranted,
                )
                ComposerMapIconButton(
                    icon = Icons.Filled.FullscreenExit,
                    contentDescription = "Exit full-screen map",
                    onClick = close,
                )
            }
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.Black.copy(alpha = 0.55f))
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    PlacementPreviewLabel(state = state, tapped = tapped, onDark = true)
                    validationMessage?.let {
                        Text(it, fontSize = 13.sp, color = Color(0xFFFF8A80))
                    }
                    locationMessage?.let {
                        Text(it, fontSize = 12.sp, color = Color.White.copy(alpha = 0.8f))
                    }
                }
                Button(
                    onClick = {
                        onSyncCamera(fullCamera.position)
                        onContinue()
                    },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
                ) { Text("Continue") }
            }
        }
    }
}

// MARK: - Step 3: Repair | Growth | Custom

@Composable
private fun TypeStep(
    state: AppUiState,
    selection: ComposerTypeSelection?,
    onSelect: (ComposerTypeSelection) -> Unit,
    onAddCustom: () -> Unit,
    onGrowthStage: () -> Unit,
    validationMessage: String?,
    saving: Boolean,
    onSave: () -> Unit,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()
    val pagerState = rememberPagerState(pageCount = { UnifiedPinContract.TABS.size })

    Column(modifier = Modifier.fillMaxSize()) {
        // Tappable + swipeable tabs, same ordering and wording as iOS.
        TabRow(
            selectedTabIndex = pagerState.currentPage,
            containerColor = vine.appBackground,
        ) {
            UnifiedPinContract.TABS.forEachIndexed { index, title ->
                Tab(
                    selected = pagerState.currentPage == index,
                    onClick = { scope.launch { pagerState.animateScrollToPage(index) } },
                    text = { Text(title, fontWeight = FontWeight.SemiBold) },
                )
            }
        }

        HorizontalPager(
            state = pagerState,
            modifier = Modifier.weight(1f),
        ) { page ->
            when (UnifiedPinContract.TABS[page]) {
                "Repair" -> StandardButtonsPage(
                    buttons = composerButtons(state, mode = "Repairs"),
                    mode = "Repairs",
                    selection = selection,
                    onSelect = onSelect,
                )
                "Growth" -> StandardButtonsPage(
                    buttons = composerButtons(state, mode = "Growth"),
                    mode = "Growth",
                    selection = selection,
                    onSelect = onSelect,
                    // Growth Stage renders exactly once, first, at the same
                    // tile size — it opens the existing E-L stage picker.
                    showGrowthStage = true,
                    onGrowthStage = onGrowthStage,
                )
                else -> CustomTypesPage(
                    types = state.customPinTypes.filter { it.isActive },
                    selection = selection,
                    onSelect = onSelect,
                    onAddCustom = onAddCustom,
                )
            }
        }

        validationMessage?.let {
            Text(it, fontSize = 13.sp, color = VineColors.Destructive, modifier = Modifier.padding(vertical = 4.dp))
        }
        Button(
            onClick = onSave,
            enabled = !saving && selection != null,
            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Primary),
        ) {
            if (saving) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
            } else {
                Text("Save Pin")
            }
        }
    }
}

/** A selectable Repair/Growth tile identified by name + colour token. */
private data class ComposerButton(val name: String, val colorToken: String?)

/**
 * The EXISTING vineyard button catalogue — same stored identifiers, labels
 * and colours as the Repairs/Growth launcher. Falls back to the built-in
 * defaults when the vineyard has no shared configuration yet. Growth Stage
 * buttons are excluded (they have their own authoring flow).
 */
private fun composerButtons(state: AppUiState, mode: String): List<ComposerButton> {
    val remote = (if (mode == "Growth") state.growthButtons else state.repairButtons)
        // Growth Stage never appears here — it has its own dedicated tile that
        // opens the existing stage picker (dedupe by flag AND by name).
        .filterNot {
            it.isGrowthStageButton ||
                it.name.trim().equals(UnifiedPinContract.GROWTH_STAGE_BUTTON, ignoreCase = true)
        }
        // Left/right launcher duplicates collapse to one tile each.
        .distinctBy { UnifiedPinContract.catalogueKey(it.name, it.color.ifBlank { null }) }
        .map { ComposerButton(it.name, it.color.ifBlank { null }) }
    if (remote.isNotEmpty()) return remote
    return if (mode == "Growth") {
        listOf(
            ComposerButton("Powdery", "gray"),
            ComposerButton("Downy", "yellow"),
            ComposerButton("Blackberries", "red"),
        )
    } else {
        listOf(
            ComposerButton("Irrigation", "blue"),
            ComposerButton("Broken Post", "brown"),
            ComposerButton("Vine Issue", "green"),
            ComposerButton("Other", "red"),
        )
    }
}

@Composable
private fun StandardButtonsPage(
    buttons: List<ComposerButton>,
    mode: String,
    selection: ComposerTypeSelection?,
    onSelect: (ComposerTypeSelection) -> Unit,
    showGrowthStage: Boolean = false,
    onGrowthStage: () -> Unit = {},
) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(2),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxSize().padding(top = 12.dp),
    ) {
        if (showGrowthStage) {
            item {
                val stageSelection = selection as? ComposerTypeSelection.GrowthStageSel
                Column(
                    modifier = Modifier
                        .heightIn(min = UnifiedPinContract.TYPE_BUTTON_MIN_HEIGHT.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .background(launcherColor(UnifiedPinContract.GROWTH_STAGE_PIN_COLOR))
                        .clickable(onClick = onGrowthStage)
                        .padding(12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    if (stageSelection != null) {
                        Icon(Icons.Filled.CheckCircle, contentDescription = "Selected", tint = Color.White, modifier = Modifier.size(22.dp))
                    } else {
                        Icon(Icons.Filled.LocationOn, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        UnifiedPinContract.GROWTH_STAGE_BUTTON,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.Black,
                        color = Color.White,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        maxLines = 2,
                    )
                    Text(
                        stageSelection?.stage?.let { "EL ${it.code}" } ?: "Pick the E-L stage",
                        fontSize = 11.sp,
                        color = Color.White.copy(alpha = 0.9f),
                    )
                }
            }
        }
        items(buttons) { button ->
            val isSelected = (selection as? ComposerTypeSelection.Standard)
                ?.let { it.name == button.name && it.mode == mode } == true
            val tileColor = launcherColor(button.colorToken ?: "")
            Column(
                modifier = Modifier
                    .heightIn(min = UnifiedPinContract.TYPE_BUTTON_MIN_HEIGHT.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(tileColor)
                    .clickable { onSelect(ComposerTypeSelection.Standard(button.name, button.colorToken, mode)) }
                    .padding(12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                if (isSelected) {
                    Icon(Icons.Filled.CheckCircle, contentDescription = "Selected", tint = Color.White, modifier = Modifier.size(22.dp))
                } else {
                    Icon(Icons.Filled.LocationOn, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    button.name,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Black,
                    color = Color.White,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    maxLines = 2,
                )
            }
        }
    }
}

@Composable
private fun CustomTypesPage(
    types: List<CustomPinType>,
    selection: ComposerTypeSelection?,
    onSelect: (ComposerTypeSelection) -> Unit,
    onAddCustom: () -> Unit,
) {
    val vine = LocalVineColors.current
    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (types.isEmpty()) {
            Text(
                "No custom items yet — add one for actions the Repair and Growth buttons don't cover (e.g. Broken Wire, Large Divot, Check Irrigation).",
                fontSize = 13.sp,
                color = vine.textSecondary,
            )
        }
        types.forEach { type ->
            val isSelected = (selection as? ComposerTypeSelection.Custom)?.type?.id == type.id
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(if (isSelected) VineColors.Orange else vine.cardBackground)
                    .clickable { onSelect(ComposerTypeSelection.Custom(type)) }
                    .padding(horizontal = 14.dp, vertical = 13.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    type.name,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (isSelected) Color.White else vine.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                if (isSelected) {
                    Icon(Icons.Filled.Check, contentDescription = "Selected", tint = Color.White, modifier = Modifier.size(16.dp))
                }
            }
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .clickable(onClick = onAddCustom)
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Filled.Add, contentDescription = null, tint = VineColors.Primary, modifier = Modifier.size(18.dp))
            Text("Add custom item", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = VineColors.Primary)
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun AddCustomItemDialog(
    existing: List<CustomPinType>,
    onDismiss: () -> Unit,
    onAdd: (String) -> Unit,
) {
    var name by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add custom item") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it; error = null },
                    label = { Text("Custom item name") },
                    placeholder = { Text("e.g. Broken Wire") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(
                    "Shared with everyone in this vineyard.",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                error?.let { Text(it, fontSize = 12.sp, color = VineColors.Destructive) }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val trimmed = UnifiedPinContract.normalizeCustomTypeName(name)
                when {
                    trimmed == null -> error = "A name is required."
                    UnifiedPinContract.isDuplicateCustomTypeName(trimmed, existing) ->
                        error = "That item already exists."
                    else -> onAdd(trimmed)
                }
            }) { Text("Add") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

private fun formatRow(row: Double?): String {
    if (row == null) return "?"
    return if (row % 1.0 == 0.0) row.toInt().toString() else row.toString()
}
