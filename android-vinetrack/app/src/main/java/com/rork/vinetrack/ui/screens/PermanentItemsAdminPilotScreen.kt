package com.rork.vinetrack.ui.screens

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AddLocationAlt
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.LocationTracker
import com.rork.vinetrack.data.PermanentItemPilotPolicy
import com.rork.vinetrack.data.PermanentItemPilotRow
import com.rork.vinetrack.data.PermanentItemsPilotRepository
import com.rork.vinetrack.ui.AppUiState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** An independent System Admin pilot surface, never joined to the normal Pins map/outbox. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PermanentItemsAdminPilotScreen(
    state: AppUiState,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val repository = remember { PermanentItemsPilotRepository(context) }
    val location = remember { LocationTracker(context) }
    val scope = rememberCoroutineScope()
    val user = state.currentUserId
    val vineyard = state.selectedVineyardId
    var allowed by remember(user, vineyard) { mutableStateOf(false) }
    var loading by remember(user, vineyard) { mutableStateOf(true) }
    var busy by remember(user, vineyard) { mutableStateOf(false) }
    var rows by remember(user, vineyard) { mutableStateOf<List<PermanentItemPilotRow>>(emptyList()) }
    var pending by remember(user, vineyard) { mutableStateOf(false) }
    var error by remember(user, vineyard) { mutableStateOf<String?>(null) }
    var notice by remember(user, vineyard) { mutableStateOf<String?>(null) }
    var mapMode by remember(user, vineyard) { mutableStateOf(false) }
    var mapLayer by remember(user, vineyard) { mutableStateOf(true) }
    var search by remember(user, vineyard) { mutableStateOf("") }
    var category by remember(user, vineyard) { mutableStateOf("all") }
    var editing by remember(user, vineyard) { mutableStateOf(false) }
    var selected by remember(user, vineyard) { mutableStateOf<PermanentItemPilotRow?>(null) }
    var archiveTarget by remember(user, vineyard) { mutableStateOf<PermanentItemPilotRow?>(null) }
    var name by remember(user, vineyard) { mutableStateOf("") }
    var type by remember(user, vineyard) { mutableStateOf("irrigation_valve") }
    var blockId by remember(user, vineyard) { mutableStateOf<String?>(null) }
    var lat by remember(user, vineyard) { mutableStateOf("") }
    var lon by remember(user, vineyard) { mutableStateOf("") }
    var notes by remember(user, vineyard) { mutableStateOf("") }
    var photo by remember(user, vineyard) { mutableStateOf<ByteArray?>(null) }
    var typeExpanded by remember { mutableStateOf(false) }
    var blockExpanded by remember { mutableStateOf(false) }
    val locked = !PermanentItemPilotPolicy.allowed(
        state.isSystemAdmin, allowed, user, vineyard, state.currentRole
    )

    fun startEditor(item: PermanentItemPilotRow?) {
        selected = item
        name = item?.name ?: ""
        type = item?.itemType ?: "irrigation_valve"
        blockId = item?.paddockId
        lat = item?.latitude?.toString() ?: ""
        lon = item?.longitude?.toString() ?: ""
        notes = item?.notes ?: ""
        photo = null
        error = null
        editing = true
    }
    fun refresh() {
        val target = vineyard ?: return
        scope.launch {
            try {
                val listed = repository.list(target)
                if (state.selectedVineyardId == target && state.currentUserId == user) {
                    rows = listed
                    pending = repository.pending(target) != null
                }
            } catch (e: Exception) {
                error = "Couldn't load Permanent Items: " + (e.message ?: "Network error")
            }
        }
    }
    fun save(action: String, item: PermanentItemPilotRow? = selected) {
        val target = vineyard ?: return
        if (locked || busy) return
        if (pending) { error = "Retry the outstanding save before making another change."; return }
        val latitude = lat.toDoubleOrNull() ?: Double.NaN
        val longitude = lon.toDoubleOrNull() ?: Double.NaN
        if (action != "archive" && !PermanentItemPilotPolicy.valid(name, type, latitude, longitude)) {
            error = "Enter name, type, and valid coordinates. Tap map or use current GPS."
            return
        }
        val submittedPhoto = if (action == "archive") null else photo
        busy = true; error = null
        scope.launch {
            try {
                val op = repository.operation(target, action, item, name, type,
                    latitude, longitude, blockId, notes)
                var saved = repository.commit(op)
                // The row must already exist before a private photo may be uploaded.
                if (submittedPhoto != null) {
                    val path = repository.uploadJpeg(target, saved.id, submittedPhoto)
                    val photoOp = repository.operation(target, "update", saved, saved.name,
                        saved.itemType, saved.latitude, saved.longitude, saved.paddockId,
                        saved.notes, photo = path)
                    saved = repository.commit(photoOp)
                }
                if (state.selectedVineyardId == target && state.currentUserId == user) {
                    rows = repository.list(target)
                    pending = false
                    selected = saved
                    editing = false
                    notice = "Synced · revision " + saved.serverRevision
                }
            } catch (e: Exception) {
                if (state.selectedVineyardId == target && state.currentUserId == user) {
                    error = (e.message ?: "Unable to verify save") +
                        ". Any unconfirmed operation is retained for retry."
                    pending = repository.pending(target) != null
                }
            } finally { busy = false }
        }
    }
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) scope.launch {
            try {
                photo = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { stream ->
                        stream.readBytes()
                    } ?: throw IllegalStateException("Unable to open photo.")
                }
                notice = "One photo selected. It will upload after the item is saved."
            } catch (e: Exception) { error = e.message ?: "Couldn't open photo." }
        }
    }

    LaunchedEffect(user, vineyard, state.isSystemAdmin, state.currentRole) {
        allowed = false; rows = emptyList(); editing = false; pending = false; loading = true
        val target = vineyard
        if (target != null && PermanentItemPilotPolicy.allowed(
            state.isSystemAdmin, true, user, target, state.currentRole
        )) {
            try {
                allowed = repository.pilotEnabled(target)
                if (allowed) {
                    rows = repository.list(target)
                    pending = repository.pending(target) != null
                }
            } catch (e: Exception) {
                allowed = false
                error = e.message ?: "Pilot authorization unavailable"
            }
        }
        loading = false
    }
    BackHandler {
        if (editing) editing = false else onBack()
    }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text("Permanent Items · Admin Pilot") },
                navigationIcon = {
                    IconButton(onClick = { if (editing) editing = false else onBack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    if (!locked && !editing) IconButton(onClick = ::refresh) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
                    }
                }
            )
        }
    ) { padding ->
        if (loading) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        } else if (locked) {
            Column(Modifier.fillMaxSize().padding(padding).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("System Admin pilot unavailable", style = MaterialTheme.typography.titleMedium)
                Text("Requires an active System Admin account, selected-vineyard membership and the Permanent Items preview switch.")
                if (error != null) Text(error ?: "", color = MaterialTheme.colorScheme.error)
            }
        } else if (editing) {
            Column(
                Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text(if (selected == null) "New Permanent Item" else "Edit / Move Permanent Item",
                    style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(value = name, onValueChange = { name = it.take(100) },
                    label = { Text("Name (required)") }, modifier = Modifier.fillMaxWidth())
                Box {
                    OutlinedButton(onClick = { typeExpanded = true }) {
                        Text("Type: " + (PermanentItemPilotPolicy.TYPES[type] ?: type))
                    }
                    DropdownMenu(expanded = typeExpanded, onDismissRequest = { typeExpanded = false }) {
                        PermanentItemPilotPolicy.TYPES.forEach { (key, label) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = {
                                type = key; typeExpanded = false
                            })
                        }
                    }
                }
                Box {
                    OutlinedButton(onClick = { blockExpanded = true }) {
                        Text("Block: " + (state.paddocks.firstOrNull { it.id == blockId }?.name ?: "None / outside blocks"))
                    }
                    DropdownMenu(expanded = blockExpanded, onDismissRequest = { blockExpanded = false }) {
                        DropdownMenuItem(text = { Text("None / outside blocks") },
                            onClick = { blockId = null; blockExpanded = false })
                        state.paddocks.forEach { block ->
                            DropdownMenuItem(text = { Text(block.name) }, onClick = {
                                blockId = block.id; blockExpanded = false
                            })
                        }
                    }
                }
                OutlinedTextField(value = notes, onValueChange = { notes = it.take(2000) },
                    label = { Text("Notes (optional)") }, modifier = Modifier.fillMaxWidth(),
                    minLines = 2, maxLines = 4)
                Button(onClick = {
                    scope.launch {
                        val fix = location.currentLocation()
                        if (fix == null) error = "No recent accurate GPS fix. Enable precise location or tap map."
                        else {
                            lat = fix.latitude.toString()
                            lon = fix.longitude.toString()
                            error = null
                        }
                    }
                }) {
                    Icon(Icons.Filled.AddLocationAlt, contentDescription = null)
                    Text(" Use Current GPS")
                }
                val currentLat = lat.toDoubleOrNull()
                val currentLon = lon.toDoubleOrNull()
                val picked = if (currentLat != null && currentLon != null &&
                    currentLat in -90.0..90.0 && currentLon in -180.0..180.0)
                    LatLng(currentLat, currentLon) else null
                val focus = picked ?: rows.firstOrNull()?.let { LatLng(it.latitude, it.longitude) }
                    ?: LatLng(-34.0, 138.0)
                val camera = rememberCameraPositionState {
                    position = CameraPosition.fromLatLngZoom(focus, if (picked != null) 17f else 9f)
                }
                GoogleMap(
                    modifier = Modifier.fillMaxWidth().height(270.dp),
                    cameraPositionState = camera,
                    properties = MapProperties(mapType = MapType.HYBRID),
                    uiSettings = MapUiSettings(zoomControlsEnabled = true),
                    onMapClick = { point ->
                        lat = point.latitude.toString()
                        lon = point.longitude.toString()
                        error = null
                    }
                ) {
                    if (picked != null) Marker(state = MarkerState(position = picked),
                        title = "Permanent Item placement")
                }
                Text("Tap the map to set or move the marker. Coordinates can also be entered below.")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(value = lat, onValueChange = { lat = it },
                        label = { Text("Latitude") }, modifier = Modifier.weight(1f),
                        singleLine = true)
                    OutlinedTextField(value = lon, onValueChange = { lon = it },
                        label = { Text("Longitude") }, modifier = Modifier.weight(1f),
                        singleLine = true)
                }
                OutlinedButton(onClick = { photoPicker.launch("image/*") }) {
                    Text(if (photo == null) "Add photo (optional)" else "Replace selected photo")
                }
                if (selected?.photoPath != null) Text("This item already has a private photo reference.")
                if (notice != null) Text(notice ?: "", style = MaterialTheme.typography.bodySmall)
                if (error != null) Text(error ?: "", color = MaterialTheme.colorScheme.error)
                Button(onClick = { save(if (selected == null) "create" else "update") },
                    enabled = !busy && !pending,
                    modifier = Modifier.fillMaxWidth()) {
                    Text(if (busy) "Verifying with server…" else "Save Permanent Item")
                }
                if (pending) Text("An unconfirmed save is held. Return to list and retry the same operation.")
            }
        } else {
            Column(
                Modifier.fillMaxSize().padding(padding).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Text("Fixed fixtures, independent of Repairs and Observations.",
                    style = MaterialTheme.typography.bodySmall)
                if (pending) {
                    Text("Saved on device — pending server confirmation.",
                        color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.SemiBold)
                    Button(onClick = {
                        val target = vineyard ?: return@Button
                        if (busy) return@Button
                        busy = true
                        scope.launch {
                            try {
                                val row = repository.retry(target)
                                notice = "Synced · revision " + row.serverRevision
                                error = null
                                rows = repository.list(target)
                            } catch (e: Exception) {
                                error = e.message ?: "Still pending"
                            } finally {
                                pending = repository.pending(target) != null
                                busy = false
                            }
                        }
                    }, enabled = !busy) { Text("Retry same operation") }
                }
                if (notice != null) Text(notice ?: "", style = MaterialTheme.typography.bodySmall)
                if (error != null) Text(error ?: "", color = MaterialTheme.colorScheme.error)
                Button(onClick = { startEditor(null) },
                    enabled = !busy && !pending,
                    modifier = Modifier.fillMaxWidth()) {
                    Text("New Permanent Item")
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Show Map")
                    Switch(checked = mapMode, onCheckedChange = { mapMode = it })
                    if (mapMode) {
                        Spacer(Modifier.weight(1f))
                        Text("Fixtures")
                        Switch(checked = mapLayer, onCheckedChange = { mapLayer = it })
                    }
                }
                OutlinedTextField(value = search, onValueChange = { search = it },
                    label = { Text("Search name or type") }, modifier = Modifier.fillMaxWidth(),
                    singleLine = true)
                val visible = rows.filter { it.archivedAt == null &&
                    (category == "all" || it.itemType == category) &&
                    (search.isBlank() || it.name.contains(search, true) ||
                        (PermanentItemPilotPolicy.TYPES[it.itemType] ?: "").contains(search, true))
                }
                if (mapMode) {
                    val center = visible.firstOrNull()?.let { LatLng(it.latitude, it.longitude) }
                        ?: LatLng(-34.0, 138.0)
                    val mapCamera = rememberCameraPositionState {
                        position = CameraPosition.fromLatLngZoom(center, 14f)
                    }
                    GoogleMap(
                        modifier = Modifier.fillMaxWidth().height(300.dp),
                        cameraPositionState = mapCamera,
                        properties = MapProperties(mapType = MapType.HYBRID),
                    ) {
                        if (mapLayer) visible.forEach { item ->
                            Marker(
                                state = MarkerState(position = LatLng(item.latitude, item.longitude)),
                                title = item.name, snippet = "Permanent Item",
                                onClick = { startEditor(item); true }
                            )
                        }
                    }
                }
                Box {
                    var categoryExpanded by remember { mutableStateOf(false) }
                    OutlinedButton(onClick = { categoryExpanded = true }) {
                        Text("Filter: " + (PermanentItemPilotPolicy.TYPES[category] ?: "All types"))
                    }
                    DropdownMenu(expanded = categoryExpanded, onDismissRequest = { categoryExpanded = false }) {
                        DropdownMenuItem(text = { Text("All types") }, onClick = {
                            category = "all"; categoryExpanded = false
                        })
                        PermanentItemPilotPolicy.TYPES.forEach { (key, label) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = {
                                category = key; categoryExpanded = false
                            })
                        }
                    }
                }
                Column(
                    Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    visible.sortedBy { it.name }.forEach { item ->
                        Column(
                            Modifier.fillMaxWidth().clickable { startEditor(item) }.padding(vertical = 8.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Text(item.name, fontWeight = FontWeight.SemiBold)
                            Text((PermanentItemPilotPolicy.TYPES[item.itemType] ?: item.itemType) +
                                " · revision " + item.serverRevision,
                                style = MaterialTheme.typography.bodySmall)
                            Text("%.6f, %.6f".format(item.latitude, item.longitude),
                                style = MaterialTheme.typography.bodySmall)
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                OutlinedButton(onClick = { startEditor(item) }, enabled = !busy && !pending) {
                                    Text("Edit / Move")
                                }
                                OutlinedButton(onClick = { archiveTarget = item },
                                    enabled = !busy && !pending) {
                                    Text("Archive")
                                }
                            }
                        }
                    }
                    if (visible.isEmpty()) Text("No Permanent Items in this filter.")
                }
            }
        }
    }

    if (archiveTarget != null) {
        AlertDialog(
            onDismissRequest = { archiveTarget = null },
            title = { Text("Archive Permanent Item?") },
            text = { Text("This fixture will leave the active map, but remain in history.") },
            confirmButton = {
                TextButton(onClick = {
                    val item = archiveTarget ?: return@TextButton
                    archiveTarget = null
                    selected = item
                    name = item.name; type = item.itemType; lat = item.latitude.toString()
                    lon = item.longitude.toString(); notes = item.notes ?: ""; blockId = item.paddockId
                    save("archive", item)
                }) { Text("Archive") }
            },
            dismissButton = { TextButton(onClick = { archiveTarget = null }) { Text("Cancel") } }
        )
    }
}
