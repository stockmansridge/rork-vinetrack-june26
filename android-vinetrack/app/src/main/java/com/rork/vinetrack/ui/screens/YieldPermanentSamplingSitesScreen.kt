package com.rork.vinetrack.ui.screens

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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
    val blocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }
    val context = LocalContext.current
    val repo = remember(context) { YieldSamplingSiteRepository(SessionStore(context)) }
    val tracker = remember(context) { LocationTracker(context) }
    val scope = rememberCoroutineScope()
    val vine = LocalVineColors.current

    var selectedBlockId by rememberSaveable(vineyardId, user) { mutableStateOf("") }
    val block = blocks.firstOrNull { it.id.equals(selectedBlockId, true) } ?: blocks.firstOrNull()
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
        nameText = existing?.name ?: "Sample $next"
        rowText = existing?.rowNumber ?: ""
        panelText = existing?.panelNumber ?: ""
        notesText = existing?.notes ?: ""
        errorText = null
        showEditor = true
    }

    LaunchedEffect(vineyardId, user, block?.id, revision) {
        val currentBlock = block ?: return@LaunchedEffect
        if (vineyardId.isBlank() || user.isNullOrBlank()) return@LaunchedEffect
        busy = true
        sets = emptyList(); draftSites = emptyList(); confirmedSites = emptyList()
        try {
            val rows = repo.listSets(vineyardId, currentBlock.id)
            val draftRow = rows.firstOrNull { it.status == "draft" }
            val confirmedRow = rows.firstOrNull { it.isConfirmed }
            val pending = draftRow?.let { repo.listSites(it) }.orEmpty()
            val ready = confirmedRow?.let { repo.listSites(it) }.orEmpty()
            sets = rows; draftSites = pending; confirmedSites = ready
            errorText = null
        } catch (e: Exception) {
            errorText = "Could not read sites from server: ${e.message ?: "Check connection and permissions."}"
        } finally {
            busy = false
        }
    }

    val camera = rememberCameraPositionState()
    var mapLoaded by remember { mutableStateOf(false) }
    val bounds = block?.polygonPoints?.map { LatLng(it.latitude, it.longitude) }.orEmpty()
    LaunchedEffect(mapLoaded, block?.id) {
        if (mapLoaded && bounds.isNotEmpty()) camera.fitToContent(points = bounds, paddingPx = 100)
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
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Select a mapped block and save fixed sampling locations. They are separate from Permanent Items and can be revisited in future vintages.",
                color = vine.textSecondary)
            Box {
                OutlinedButton(onClick = { blockMenu = true }, modifier = Modifier.fillMaxWidth()) {
                    Text("Block: ${block?.name ?: "Choose block"}")
                }
                DropdownMenu(expanded = blockMenu, onDismissRequest = { blockMenu = false }) {
                    blocks.forEach { option ->
                        DropdownMenuItem(text = { Text(option.name) }, onClick = {
                            selectedBlockId = option.id
                            blockMenu = false
                            message = null
                        })
                    }
                }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (block != null) {
                Box(Modifier.fillMaxWidth().height(330.dp)) {
                    GoogleMap(
                        modifier = Modifier.fillMaxSize(),
                        cameraPositionState = camera,
                        properties = MapProperties(mapType = MapType.HYBRID),
                        uiSettings = MapUiSettings(zoomControlsEnabled = false, mapToolbarEnabled = false),
                        onMapLoaded = { mapLoaded = true },
                        onMapClick = { position ->
                            if (draft != null) showSiteEditor(position)
                        },
                    ) {
                        if (bounds.size >= 3) Polygon(
                            points = bounds,
                            strokeColor = VineColors.Purple,
                            strokeWidth = 3f,
                            fillColor = VineColors.Purple.copy(alpha = 0.16f),
                        )
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
                }
                Text(
                    if (draft != null) "Tap within the purple block to add a site, or tap a draft marker to edit."
                    else "Confirmed locations are locked. Create a draft revision to make changes.",
                    color = vine.textSecondary,
                )
            }
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (confirmed != null) Text(
                        "Confirmed version ${confirmed.version} · ${confirmedSites.size} sites",
                        color = VineColors.LeafGreen, fontWeight = FontWeight.SemiBold,
                    ) else Text("No confirmed sites for this block", color = vine.textSecondary)
                    if (draft != null) Text(
                        "Draft version ${draft.version} · ${draftSites.size} sites (not yet confirmed)",
                        color = VineColors.Purple, fontWeight = FontWeight.SemiBold,
                    )
                    if (draft == null) {
                        OutlinedButton(
                            modifier = Modifier.fillMaxWidth(),
                            enabled = block != null && !busy && user != null && vineyardId.isNotEmpty(),
                            onClick = {
                                val currentBlock = block ?: return@OutlinedButton
                                scope.launch {
                                    busy = true
                                    try {
                                        repo.beginDraft(vineyardId, currentBlock.id)
                                        message = "Draft saved on server. Review and confirm the locations."
                                        revision++
                                    } catch (e: Exception) {
                                        errorText = "Could not create draft: ${e.message}"
                                    } finally { busy = false }
                                }
                            },
                        ) { Icon(Icons.Filled.Add, contentDescription = null); Spacer(Modifier.width(6.dp))
                            Text(if (confirmed == null) "Create Draft Locations" else "Revise Confirmed Locations") }
                    } else {
                        OutlinedButton(
                            modifier = Modifier.fillMaxWidth().testTag("yield.sites.placeGPS"),
                            enabled = !busy,
                            onClick = {
                                scope.launch {
                                    val fix = tracker.currentPinLocation()
                                    if (fix !is PinLocationResult.Success) {
                                        errorText = fix.operatorMessage()
                                        return@launch
                                    }
                                    val matched = blocks.filter {
                                        RowAttachment.containsPoint(it, fix.fix.latitude, fix.fix.longitude)
                                    }
                                    if (matched.size != 1) {
                                        errorText = "Location must match exactly one mapped block. Check boundary or select the block manually."
                                    } else if (matched[0].id != block.id) {
                                        selectedBlockId = matched[0].id
                                        message = "Switched to ${matched[0].name}. Open that block's draft and place the pin again."
                                    } else {
                                        showSiteEditor(LatLng(fix.fix.latitude, fix.fix.longitude))
                                    }
                                }
                            },
                        ) {
                            Icon(Icons.Filled.MyLocation, contentDescription = null)
                            Spacer(Modifier.width(6.dp))
                            Text("Set Location in Field — Place Pin Here")
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
                                IconButton(onClick = {
                                    scope.launch {
                                        busy = true
                                        try {
                                            repo.deleteDraftSite(draft, site)
                                            message = "Draft site removed. Confirmed history is unchanged."
                                            revision++
                                        } catch (e: Exception) { errorText = "Could not remove draft site: ${e.message}" }
                                        finally { busy = false }
                                    }
                                }, enabled = !busy) {
                                    Icon(Icons.Filled.Delete, contentDescription = "Delete draft site", tint = VineColors.Destructive)
                                }
                            }
                        }
                        Button(
                            onClick = { showConfirm = true },
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !busy && draftSites.isNotEmpty(),
                            colors = ButtonDefaults.buttonColors(containerColor = VineColors.Info),
                        ) { Icon(Icons.Filled.CheckCircle, contentDescription = null)
                            Spacer(Modifier.width(6.dp)); Text("Review & Confirm Block Locations") }
                    }
                    if (draft == null) {
                        confirmedSites.sortedBy { it.siteNumber }.forEach { site ->
                            Text("${site.siteNumber}. ${site.name} · Row ${site.rowNumber ?: "—"}",
                                color = vine.textPrimary)
                        }
                    }
                }
            }
            if (message != null) Text(message!!, color = vine.textSecondary)
            if (errorText != null) Text(errorText!!, color = VineColors.Destructive)
            Spacer(Modifier.height(24.dp))
        }
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
                    OutlinedTextField(nameText, { nameText = it }, label = { Text("Site name") }, singleLine = true)
                    OutlinedTextField(rowText, { rowText = it }, label = { Text("Row (optional)") }, singleLine = true)
                    OutlinedTextField(panelText, { panelText = it }, label = { Text("Panel (optional)") }, singleLine = true)
                    OutlinedTextField(notesText, { notesText = it }, label = { Text("Notes (optional)") })
                }
            },
            confirmButton = {
                TextButton(enabled = !busy && nameText.isNotBlank(), onClick = {
                    val existing = editorSite
                    val site = YieldFixedSite(
                        id = existing?.id ?: UUID.randomUUID().toString(),
                        siteSetId = currentSet.id, vineyardId = vineyardId, paddockId = currentBlock.id,
                        siteId = existing?.siteId ?: UUID.randomUUID().toString(),
                        siteNumber = existing?.siteNumber ?: ((draftSites.maxOfOrNull { it.siteNumber } ?: 0) + 1),
                        name = nameText.trim(),
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
