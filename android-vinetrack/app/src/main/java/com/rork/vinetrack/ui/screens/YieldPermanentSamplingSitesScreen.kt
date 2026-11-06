package com.rork.vinetrack.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.Manifest
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.PinLocationResult
import com.rork.vinetrack.data.RowAttachment
import com.rork.vinetrack.data.YieldFixedSite
import com.rork.vinetrack.data.YieldSamplingSiteRepository
import com.rork.vinetrack.data.YieldSiteSet
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.components.MapMyLocationButton
import com.rork.vinetrack.ui.components.hasDeviceLocationPermission
import com.rork.vinetrack.ui.components.mapGestureOwnership
import com.rork.vinetrack.ui.components.ForegroundLocationSubscriptionEffect
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Issue #54 native fixed yield locations. Confirmed revisions are immutable,
 * shared per vineyard/block and never mutated through the Trip outbox.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun YieldPermanentSamplingSitesScreen(state: AppUiState, onBack: () -> Unit) {
    val vineyardId = state.selectedVineyardId ?: ""
    val user = state.currentUserId
    val canEditSites = state.currentRole in setOf("owner", "manager", "supervisor", "operator")
    val canDeleteConfirmed = state.currentRole in setOf("owner", "manager", "supervisor")
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }
    val context = LocalContext.current
    val repo = remember(context) { YieldSamplingSiteRepository(SessionStore(context)) }
    val tracker = remember(context) { LocationTracker(context) }
    ForegroundLocationSubscriptionEffect(tracker)
    val scope = rememberCoroutineScope()
    val vine = LocalVineColors.current

    var selectedBlockId by rememberSaveable(vineyardId, user) { mutableStateOf("") }
    // No default: the map shows every block until one is chosen from the dropdown.
    val block = blocks.firstOrNull { it.id.equals(selectedBlockId, true) }
    var blockMenu by remember { mutableStateOf(false) }
    var sets by remember { mutableStateOf<List<YieldSiteSet>>(emptyList()) }
    var draftSites by remember { mutableStateOf<List<YieldFixedSite>>(emptyList()) }
    var confirmedSites by remember { mutableStateOf<List<YieldFixedSite>>(emptyList()) }
    val draft = sets.firstOrNull { it.status == "draft" }
    val confirmed = sets.firstOrNull { it.isConfirmed }
    val displaySites = if (draft != null) draftSites else confirmedSites
    var revision by remember { mutableStateOf(0) }
    var busy by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var showConfirm by remember { mutableStateOf(false) }
    var deleteTarget by remember(vineyardId, user, block?.id) { mutableStateOf<Pair<YieldSiteSet, YieldFixedSite>?>(null) }
    val currentScope by rememberUpdatedState(Triple(vineyardId, user, block?.id))
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) revision++
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    var mapGestureActive by remember { mutableStateOf(false) }
    var hasLocationPerm by remember { mutableStateOf(hasDeviceLocationPermission(context)) }
    var locatingField by remember { mutableStateOf(false) }
    var fieldLocationFeedback by remember { mutableStateOf<String?>(null) }

    var editorSite by remember { mutableStateOf<YieldFixedSite?>(null) }
    var pendingCoordinate by remember { mutableStateOf<LatLng?>(null) }
    var showEditor by remember { mutableStateOf(false) }
    var nameText by remember { mutableStateOf("") }
    var rowText by remember { mutableStateOf("") }
    var panelText by remember { mutableStateOf("") }
    var notesText by remember { mutableStateOf("") }

    fun showSiteEditor(position: LatLng, existing: YieldFixedSite? = null) {
        if (draft == null || busy || block == null) return
        if (!RowAttachment.containsPoint(block, position.latitude, position.longitude)) {
            errorText = "This position must be inside the selected block boundary."
            return
        }
        editorSite = existing
        pendingCoordinate = position
        val next = (draftSites.maxOfOrNull { it.siteNumber } ?: 0) + 1
        nameText = existing?.name ?: ""
        rowText = existing?.rowNumber ?: ""
        panelText = existing?.panelNumber ?: ""
        notesText = existing?.notes ?: ""
        errorText = null
        showEditor = true
    }

    fun captureFieldLocation() {
        val chosenBlock = block ?: run {
            fieldLocationFeedback = "Select a mapped block first."
            return
        }
        if (draft == null) {
            fieldLocationFeedback = "Create a draft for this block before recording locations."
            return
        }
        if (locatingField) return
        scope.launch {
            locatingField = true
            fieldLocationFeedback = "Getting a fresh, precise GPS fix…"
            try {
                val fix = tracker.currentPinLocation(timeoutMs = 12000L)
                if (fix !is PinLocationResult.Success) {
                    fieldLocationFeedback = fix.operatorMessage() +
                        " Check Location permissions and GPS, then try again."
                    return@launch
                }
                val matches = blocks.filter {
                    RowAttachment.containsPoint(it, fix.fix.latitude, fix.fix.longitude)
                }
                when {
                    matches.size != 1 -> fieldLocationFeedback =
                        "The location does not match exactly one mapped block. Move into the block or place the pin on the map."
                    matches.single().id != chosenBlock.id -> {
                        selectedBlockId = matches.single().id
                        fieldLocationFeedback = "GPS matched ${matches.single().name}. Open its draft, then press Place Pin Here again."
                    }
                    else -> {
                        fieldLocationFeedback = null
                        showSiteEditor(LatLng(fix.fix.latitude, fix.fix.longitude))
                    }
                }
            } catch (e: Exception) {
                fieldLocationFeedback = "GPS capture failed: ${e.message ?: "Try again."}"
            } finally {
                locatingField = false
            }
        }
    }

    val fieldPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { grants ->
        hasLocationPerm = hasDeviceLocationPermission(context)
        if (tracker.hasFinePermission) captureFieldLocation()
        else fieldLocationFeedback =
            "Precise location permission is required to place a field pin. Enable precise location in Android Settings or use the map."
    }

    LaunchedEffect(vineyardId, user, block?.id, revision) {
        val currentBlock = block ?: run {
            sets = emptyList(); draftSites = emptyList(); confirmedSites = emptyList()
            return@LaunchedEffect
        }
        if (vineyardId.isBlank() || user.isNullOrBlank()) return@LaunchedEffect
        busy = true
        sets = emptyList(); draftSites = emptyList(); confirmedSites = emptyList()
        try {
            val rows = repo.listSets(vineyardId, currentBlock.id)
            val draftRow = rows.firstOrNull { it.status == "draft" }
            val confirmedRow = rows.firstOrNull { it.isConfirmed }
            val pending = draftRow?.let { repo.listSites(it) }.orEmpty()
            val ready = confirmedRow?.let { repo.listSites(it) }.orEmpty()
            currentCoroutineContext().ensureActive()
            sets = rows; draftSites = pending; confirmedSites = ready
            errorText = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            errorText = "Could not read sites from server: ${e.message ?: "Check connection and permissions."}"
        } finally {
            busy = false
        }
    }

    val camera = rememberCameraPositionState()
    var mapLoaded by remember { mutableStateOf(false) }
    val bounds = block?.polygonPoints?.map { LatLng(it.latitude, it.longitude) }.orEmpty()
    val allBlockPoints = remember(blocks) {
        blocks.flatMap { b -> b.polygonPoints.orEmpty().map { LatLng(it.latitude, it.longitude) } }
    }
    LaunchedEffect(mapLoaded, block?.id) {
        if (!mapLoaded) return@LaunchedEffect
        val target = if (block != null) bounds else allBlockPoints
        if (target.isNotEmpty()) camera.fitToContent(points = target, paddingPx = 100)
    }

    fun createDraft() {
        val currentBlock = block ?: return
        scope.launch {
            busy = true
            try {
                repo.beginDraft(vineyardId, currentBlock.id)
                message = "Draft created. Tap inside the purple block to add sampling sites."
                errorText = null
                revision++
            } catch (e: Exception) {
                errorText = "Could not create draft: ${e.message}"
            } finally { busy = false }
        }
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Permanent Yield Locations") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState(), enabled = !mapGestureActive)
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Select a mapped block and save fixed sampling locations. They are separate from Permanent Items and can be revisited in future vintages.",
                color = vine.textSecondary)
            Box {
                OutlinedButton(onClick = { blockMenu = true }, modifier = Modifier.fillMaxWidth()) {
                    Text("Block: ${block?.name ?: "Select a block"}")
                }
                DropdownMenu(expanded = blockMenu, onDismissRequest = { blockMenu = false }) {
                    if (block != null) DropdownMenuItem(text = { Text("All blocks (none selected)") }, onClick = {
                        selectedBlockId = ""
                        blockMenu = false
                        message = null
                    })
                    blocks.forEach { option ->
                        DropdownMenuItem(text = { Text(option.name) }, onClick = {
                            selectedBlockId = option.id
                            blockMenu = false
                            message = null
                        })
                    }
                }
            }
            // Step 1 comes first: a draft must exist before the map accepts pins.
            if (block != null && draft == null && !busy) {
                Button(
                    modifier = Modifier.fillMaxWidth(),
                    enabled = user != null && vineyardId.isNotEmpty() && canEditSites,
                    onClick = { createDraft() },
                    colors = ButtonDefaults.buttonColors(containerColor = VineColors.Purple),
                ) { Icon(Icons.Filled.Add, contentDescription = null); Spacer(Modifier.width(6.dp))
                    Text(if (confirmed == null) "Create Draft Locations" else "Revise Confirmed Locations") }
                Text("Create a draft first, then tap inside the block on the map to drop sampling pins.",
                    color = vine.textSecondary)
            }
            OutlinedButton(onClick = { revision++ }, enabled = !busy && block != null) { Text("Refresh from Server") }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (blocks.isNotEmpty()) {
                Box(Modifier.fillMaxWidth().height(350.dp).mapGestureOwnership { mapGestureActive = it }) {
                    GoogleMap(
                        modifier = Modifier.fillMaxSize(),
                        cameraPositionState = camera,
                        properties = MapProperties(
                            mapType = MapType.HYBRID,
                            isMyLocationEnabled = hasLocationPerm,
                        ),
                        uiSettings = MapUiSettings(
                            zoomControlsEnabled = true,
                            scrollGesturesEnabled = true,
                            zoomGesturesEnabled = true,
                            mapToolbarEnabled = false,
                            myLocationButtonEnabled = false,
                        ),
                        onMapLoaded = { mapLoaded = true },
                        onMapClick = { position ->
                            when {
                                block == null -> {
                                    // Tapping a block on the overview selects it.
                                    blocks.firstOrNull {
                                        RowAttachment.containsPoint(it, position.latitude, position.longitude)
                                    }?.let { selectedBlockId = it.id; message = null }
                                        ?: run { message = "Select a block from the dropdown first." }
                                }
                                draft == null -> message =
                                    "Press ${if (confirmed == null) "Create Draft Locations" else "Revise Confirmed Locations"} at the top first."
                                else -> showSiteEditor(position)
                            }
                        },
                    ) {
                        blocks.forEach { b ->
                            val pts = b.polygonPoints.orEmpty().map { LatLng(it.latitude, it.longitude) }
                            val selected = b.id.equals(block?.id, true)
                            if (pts.size >= 3) Polygon(
                                points = pts,
                                strokeColor = if (selected) VineColors.Purple else Color(0xFFF5D45B),
                                strokeWidth = if (selected) 4f else 2f,
                                fillColor = if (selected) VineColors.Purple.copy(alpha = 0.16f)
                                    else Color.Yellow.copy(alpha = 0.08f),
                                zIndex = if (selected) 1f else 0f,
                            )
                        }
                        displaySites.forEach { site ->
                            Marker(
                                state = MarkerState(position = LatLng(site.latitude, site.longitude)),
                                title = "${site.siteNumber}. ${site.name}",
                                snippet = "Row ${site.rowNumber ?: "—"} · Panel ${site.panelNumber ?: "—"}",
                                onClick = {
                                    if (draft != null) showSiteEditor(LatLng(site.latitude, site.longitude), site)
                                    true
                                },
                            )
                        }
                    }
                    MapMyLocationButton(
                        camera = camera,
                        modifier = Modifier.align(Alignment.TopEnd).padding(12.dp),
                        onMessage = { fieldLocationFeedback = it },
                        onPermissionGranted = {
                            hasLocationPerm = hasDeviceLocationPermission(context)
                        },
                        contentDescription = "Show my current location",
                        targetZoom = 18f,
                        locationTracker = tracker,
                    )
                }
                Text(
                    when {
                        block == null -> "Select a block from the dropdown (or tap one on the map) to manage its sampling sites."
                        draft != null -> "Tap within the purple block to add a site, or tap a draft marker to edit."
                        confirmed != null -> "Confirmed locations are locked. Press Revise Confirmed Locations to make changes."
                        else -> "Press Create Draft Locations at the top, then tap inside the block."
                    },
                    color = vine.textSecondary,
                )
            }
            if (block != null) VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (confirmed != null) Text(
                        "Confirmed version ${confirmed.version} · ${confirmedSites.size} sites",
                        color = VineColors.LeafGreen, fontWeight = FontWeight.SemiBold,
                    ) else Text("No confirmed sites for this block", color = vine.textSecondary)
                    if (draft != null) Text(
                        "Draft version ${draft.version} · ${draftSites.size} sites (not yet confirmed)",
                        color = VineColors.Purple, fontWeight = FontWeight.SemiBold,
                    )
                    if (draft != null) {
                        OutlinedButton(
                            modifier = Modifier.fillMaxWidth().testTag("yield.sites.placeGPS"),
                            enabled = !busy && !locatingField,
                            onClick = {
                                fieldLocationFeedback = null
                                if (!tracker.hasFinePermission) {
                                    fieldPermissionLauncher.launch(arrayOf(
                                        Manifest.permission.ACCESS_FINE_LOCATION,
                                        Manifest.permission.ACCESS_COARSE_LOCATION,
                                    ))
                                } else captureFieldLocation()
                            },
                        ) {
                            Icon(Icons.Filled.MyLocation, contentDescription = null)
                            Spacer(Modifier.width(6.dp))
                            Text(if (locatingField) "Locating…" else "Set Location in Field — Place Pin Here")
                        }
                        fieldLocationFeedback?.let {
                            Text(it, color = if (locatingField) vine.textSecondary else VineColors.Destructive)
                        }
                        draftSites.sortedBy { it.siteNumber }.forEach { site ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f).clickable {
                                    showSiteEditor(LatLng(site.latitude, site.longitude), site)
                                }) {
                                    Text("${site.siteNumber}. ${site.name}", color = vine.textPrimary)
                                    Text("Row ${site.rowNumber ?: "—"} · Panel ${site.panelNumber ?: "—"}",
                                        color = vine.textSecondary)
                                }
                                if (canEditSites) IconButton(onClick = {
                                    deleteTarget = draft to site
                                }, enabled = !busy) {
                                    Icon(Icons.Filled.Delete, contentDescription = "Hard Delete Draft ${site.name}", tint = VineColors.Destructive)
                                }
                            }
                        }
                        Button(
                            onClick = { showConfirm = true },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !busy && draftSites.isNotEmpty() && canDeleteConfirmed,
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Info),
                        ) { Icon(Icons.Filled.CheckCircle, contentDescription = null)
                            Spacer(Modifier.width(6.dp)); Text("Review & Confirm Block Locations") }
                    }
                    if (confirmed != null) {
                        Text("Confirmed locations", fontWeight = FontWeight.SemiBold, color = vine.textPrimary)
                        confirmedSites.sortedBy { it.siteNumber }.forEach { site ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("${site.siteNumber}. ${site.name} · Row ${site.rowNumber ?: "—"}",
                                    color = vine.textPrimary, modifier = Modifier.weight(1f))
                                if (canDeleteConfirmed) IconButton(onClick = {
                                    deleteTarget = confirmed to site
                                }, enabled = !busy) {
                                    Icon(Icons.Filled.Delete, contentDescription = "Hard Delete Confirmed ${site.name}", tint = VineColors.Destructive)
                                }
                            }
                        }
                    }
                }
            }
            if (message != null) Text(message!!, color = vine.textSecondary)
            if (errorText != null) Text(errorText!!, color = VineColors.Destructive)
            Spacer(Modifier.height(24.dp))
        }
    }

    deleteTarget?.let { (targetSet, targetSite) ->
        AlertDialog(
            onDismissRequest = { if (!busy) deleteTarget = null },
            title = { Text("Hard Delete Sampling Location?") },
            text = { Text("Permanently remove ${targetSite.name} for everyone in this block? Confirmed deletion also removes draft copies. Historical count observations keep their recorded GPS, row and panel. This cannot be undone.") },
            confirmButton = {
                TextButton(enabled = !busy, onClick = {
                    val operationScope = currentScope
                    scope.launch {
                        busy = true
                        try {
                            check(if (targetSet.isConfirmed) canDeleteConfirmed else canEditSites)
                            repo.hardDeleteSite(targetSet, targetSite)
                            if (currentScope == operationScope) {
                                message = "Hard Delete verified by server receipt and absence. Historical observations are unchanged."
                                errorText = null
                                revision++
                            }
                        } catch (e: CancellationException) { throw e }
                        catch (e: Exception) {
                            if (currentScope == operationScope) errorText = "Hard Delete not confirmed. Refresh and retry: ${e.message}"
                        } finally { busy = false; deleteTarget = null }
                    }
                }) { Text("Hard Delete", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(enabled = !busy, onClick = { deleteTarget = null }) { Text("Cancel") } },
        )
    }

    if (showEditor && block != null && draft != null && pendingCoordinate != null) {
        val currentBlock = block
        val currentSet = draft
        val coord = pendingCoordinate!!
        AlertDialog(
            onDismissRequest = { showEditor = false },
            title = { Text(if (editorSite == null) "Add Yield Site" else "Edit Draft Yield Site") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Lat ${"%.7f".format(coord.latitude)} · Long ${"%.7f".format(coord.longitude)}",
                        color = vine.textSecondary)
                    val defaultName = editorSite?.name ?: "Sample ${(draftSites.maxOfOrNull { it.siteNumber } ?: 0) + 1}"
                    OutlinedTextField(nameText, { nameText = it }, label = { Text("Site name (optional)") },
                        placeholder = { Text(defaultName) }, singleLine = true)
                    OutlinedTextField(rowText, { rowText = it }, label = { Text("Row (optional)") }, singleLine = true)
                    OutlinedTextField(panelText, { panelText = it }, label = { Text("Panel (optional)") }, singleLine = true)
                    OutlinedTextField(notesText, { notesText = it }, label = { Text("Notes (optional)") })
                }
            },
            confirmButton = {
                TextButton(enabled = !busy, onClick = {
                    val existing = editorSite
                    val nextNumber = existing?.siteNumber ?: ((draftSites.maxOfOrNull { it.siteNumber } ?: 0) + 1)
                    val site = YieldFixedSite(
                        id = existing?.id ?: UUID.randomUUID().toString(),
                        siteSetId = currentSet.id, vineyardId = vineyardId, paddockId = currentBlock.id,
                        siteId = existing?.siteId ?: UUID.randomUUID().toString(),
                        siteNumber = nextNumber,
                        name = nameText.trim().ifEmpty { existing?.name ?: "Sample $nextNumber" },
                        rowNumber = rowText.trim().ifEmpty { null },
                        panelNumber = panelText.trim().ifEmpty { null },
                        latitude = coord.latitude, longitude = coord.longitude,
                        notes = notesText.trim().ifEmpty { null },
                    )
                    scope.launch {
                        busy = true
                        try {
                            require(RowAttachment.containsPoint(currentBlock, coord.latitude, coord.longitude))
                            repo.saveSite(currentSet, site)
                            showEditor = false
                            errorText = null
                            message = "Draft site saved on server. Block confirmation is still required."
                            revision++
                        } catch (e: Exception) {
                            errorText = "Site was not confirmed saved: ${e.message}"
                            revision++ // Re-read so a save that did land is shown, not duplicated.
                        } finally { busy = false }
                    }
                }) { Text("Save Site") }
            },
            dismissButton = { TextButton(onClick = { showEditor = false }) { Text("Cancel") } },
        )
    }
    if (showConfirm && draft != null && block != null) {
        val currentSet = draft
        val currentBlock = block
        AlertDialog(
            onDismissRequest = { showConfirm = false },
            title = { Text("Confirm permanent sampling locations?") },
            text = { Text("Confirm ${draftSites.size} sites for ${currentBlock.name}? Confirmed coordinates are immutable and shared with other vineyard devices. Revisions retain the previous history.") },
            confirmButton = {
                TextButton(onClick = {
                    showConfirm = false
                    scope.launch {
                        busy = true
                        try {
                            check(draftSites.isNotEmpty() && draftSites.all {
                                RowAttachment.containsPoint(currentBlock, it.latitude, it.longitude)
                            }) { "All locations must be inside the selected block." }
                            val verified = repo.confirm(currentSet)
                            message = "Confirmed version ${verified.set.version} (${verified.sites.size} sites). Server readback verified."
                            errorText = null
                            revision++
                        } catch (e: Exception) {
                            errorText = "Confirmation or readback failed. Reload and verify before retrying: ${e.message}"
                        } finally { busy = false }
                    }
                }, enabled = !busy) { Text("Confirm") }
            },
            dismissButton = { TextButton(onClick = { showConfirm = false }) { Text("Cancel") } },
        )
    }
}
