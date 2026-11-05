package com.rork.vinetrack.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.CameraPosition
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
import com.rork.vinetrack.data.PermanentItemPilotPolicy
import com.rork.vinetrack.data.PermanentItemHardDeleteIntent
import com.rork.vinetrack.data.PermanentItemPilotRow
import com.rork.vinetrack.data.PermanentItemPilotType
import com.rork.vinetrack.data.PermanentItemsPilotRepository
import com.rork.vinetrack.ui.AppUiState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

private fun permanentItemMarkerHue(type: String, custom: List<PermanentItemPilotType>): Float {
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(
        android.graphics.Color.parseColor(PermanentItemPilotPolicy.hex(type, custom)), hsv)
    return hsv[0]
}

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
    var canManage by remember(user, vineyard) { mutableStateOf(false) }
    var canHardDelete by remember(user, vineyard) { mutableStateOf(false) }
    var loading by remember(user, vineyard) { mutableStateOf(true) }
    var busy by remember(user, vineyard) { mutableStateOf(false) }
    var rows by remember(user, vineyard) { mutableStateOf<List<PermanentItemPilotRow>>(emptyList()) }
    var customTypes by remember(user, vineyard) { mutableStateOf<List<PermanentItemPilotType>>(emptyList()) }
    var pending by remember(user, vineyard) { mutableStateOf(false) }
    var pendingDelete by remember(user, vineyard) {
        mutableStateOf<PermanentItemHardDeleteIntent?>(null)
    }
    var error by remember(user, vineyard) { mutableStateOf<String?>(null) }
    var notice by remember(user, vineyard) { mutableStateOf<String?>(null) }
    var search by remember(user, vineyard) { mutableStateOf("") }
    var editing by remember(user, vineyard) { mutableStateOf(false) }
    var selected by remember(user, vineyard) { mutableStateOf<PermanentItemPilotRow?>(null) }
    var archiveTarget by remember(user, vineyard) { mutableStateOf<PermanentItemPilotRow?>(null) }
    var deleteTarget by remember(user, vineyard) { mutableStateOf<PermanentItemPilotRow?>(null) }
    var name by remember(user, vineyard) { mutableStateOf("") }
    var type by remember(user, vineyard) { mutableStateOf("irrigation_valve") }
    var blockId by remember(user, vineyard) { mutableStateOf<String?>(null) }
    var lat by remember(user, vineyard) { mutableStateOf("") }
    var lon by remember(user, vineyard) { mutableStateOf("") }
    var notes by remember(user, vineyard) { mutableStateOf("") }
    var photo by remember(user, vineyard) { mutableStateOf<ByteArray?>(null) }
    var typeExpanded by remember { mutableStateOf(false) }
    var blockExpanded by remember { mutableStateOf(false) }
    var showNewType by remember { mutableStateOf(false) }
    var newTypeName by remember { mutableStateOf("") }
    var newTypeHex by remember { mutableStateOf("#7856D8") }
    var savingNewType by remember { mutableStateOf(false) }
    var newTypeError by remember { mutableStateOf<String?>(null) }
    var showPhotoOptions by remember { mutableStateOf(false) }
    val locked = !PermanentItemPilotPolicy.allowed(
        state.isSystemAdmin, allowed, user, vineyard, state.currentRole
    )

    fun startEditor(item: PermanentItemPilotRow?) {
        if (locked) return
        if (!canManage) {
            if (canHardDelete && item != null) deleteTarget = item
            return
        }
        if (item?.archivedAt != null) return
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
                    customTypes = repository.listTypes(target)
                    pending = repository.pending(target) != null
                    pendingDelete = repository.pendingHardDelete(target)
                }
            } catch (e: Exception) {
                error = "Couldn't load Permanent Items: " + (e.message ?: "Network error")
            }
        }
    }
    fun save(action: String, item: PermanentItemPilotRow? = selected) {
        val target = vineyard ?: return
        if (locked || !canManage || busy || pendingDelete != null) return
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
                // The fixture is already committed even if the optional photo upload fails.
                // Retain its server ID+revision so an operator retry is an UPDATE, never
                // an accidental second CREATE.
                if (state.selectedVineyardId == target && state.currentUserId == user) {
                    selected = saved
                }
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
                    pending = repository.pending(target) != null
                    error = (e.message ?: "Unable to verify save") +
                        (if (pending) " Retry the saved operation ID." else
                            " The fixture may already be saved; review it before retrying the photo.")
                }
            } finally { busy = false }
        }
    }
    fun hardDelete(item: PermanentItemPilotRow? = null) {
        val target = vineyard ?: return
        if (locked || !canHardDelete || busy || pending) return
        val already = pendingDelete
        if (already != null && item != null && already.itemId != item.id) {
            error = "Finish the pending hard delete before deleting another item."
            return
        }
        val intent = already ?: item?.let { repository.hardDeleteIntent(it) } ?: return
        busy = true
        error = null
        scope.launch {
            try {
                repository.hardDelete(intent)
                if (state.selectedVineyardId == target && state.currentUserId == user) {
                    pendingDelete = null
                    rows = repository.list(target)
                    notice = "Permanently deleted. All attached photos removed."
                    deleteTarget = null
                    selected = null
                }
            } catch (e: Exception) {
                if (state.selectedVineyardId == target && state.currentUserId == user) {
                    pendingDelete = repository.pendingHardDelete(target)
                    error = "Delete or photo cleanup not fully confirmed. " +
                        "Retry the same operation: " + (e.message ?: "Network unavailable.")
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

    val cameraPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.TakePicturePreview()
    ) { bitmap ->
        if (bitmap != null) {
            val stream = ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, stream)
            photo = stream.toByteArray()
            notice = "Camera photo selected. It will attach after the item is saved."
        }
    }
    val cameraPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) cameraPicker.launch(null)
        else error = "Allow Camera permission to take a photo, or choose one from your library."
    }

    LaunchedEffect(user, vineyard, state.isSystemAdmin, state.currentRole) {
        allowed = false; canManage = false; canHardDelete = false
        rows = emptyList(); customTypes = emptyList()
        editing = false; pending = false; pendingDelete = null; deleteTarget = null; loading = true
        val target = vineyard
        if (target != null && PermanentItemPilotPolicy.allowed(
            state.isSystemAdmin, true, user, target, state.currentRole
        )) {
            try {
                val grant = repository.permissions(target)
                if (state.selectedVineyardId == target && state.currentUserId == user) {
                    allowed = grant.canRead
                    canManage = grant.canManage
                    canHardDelete = grant.canHardDelete
                    if (allowed) {
                        rows = repository.list(target)
                        customTypes = repository.listTypes(target)
                        pending = repository.pending(target) != null
                        pendingDelete = repository.pendingHardDelete(target)
                    }
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
                title = { Text("Permanent Items") },
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
                Text("Permanent Items unavailable", style = MaterialTheme.typography.titleMedium)
                Text("Requires System Admin pilot access or an Owner/Manager role in the selected vineyard.")
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
                        Text("Type: " + PermanentItemPilotPolicy.label(type, customTypes))
                        Icon(Icons.Filled.Add, contentDescription = "Add custom type")
                    }
                    DropdownMenu(expanded = typeExpanded, onDismissRequest = { typeExpanded = false }) {
                        PermanentItemPilotPolicy.TYPES.forEach { (key, label) ->
                            DropdownMenuItem(
                                text = { Text(label) },
                                leadingIcon = {
                                    Box(Modifier.size(16.dp)
                                        .background(Color(android.graphics.Color.parseColor(
                                            PermanentItemPilotPolicy.hex(key, customTypes))), CircleShape))
                                },
                                onClick = { type = key; typeExpanded = false }
                            )
                        }
                        customTypes.forEach { custom ->
                            DropdownMenuItem(
                                text = { Text(custom.name) },
                                onClick = { type = custom.typeKey; typeExpanded = false }
                            )
                        }
                        DropdownMenuItem(
                            text = { Text("+ Add Vineyard Type") },
                            leadingIcon = { Icon(Icons.Filled.Add, contentDescription = null) },
                            onClick = { typeExpanded = false; showNewType = true }
                        )
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
                    Text(" Drop Permanent Pin Here")
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
                    state.paddocks.forEach { block ->
                        val points = block.polygonPoints.orEmpty()
                            .map { LatLng(it.latitude, it.longitude) }
                        if (points.size >= 3) Polygon(
                            points = points,
                            fillColor = Color.Yellow.copy(alpha = 0.10f),
                            strokeColor = Color(0xFFF5D45B),
                            strokeWidth = 3f
                        )
                    }
                    if (picked != null) Marker(
                        state = MarkerState(position = picked),
                        title = "Permanent Item placement",
                        icon = BitmapDescriptorFactory.defaultMarker(
                            permanentItemMarkerHue(type, customTypes))
                    )
                }
                OutlinedButton(onClick = {
                    lat = ""; lon = ""; error = null
                }, enabled = picked != null) { Text("Clear Pin") }
                Text("Tap the map to set or move the marker. Clear Pin starts the placement again.")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(value = lat, onValueChange = { lat = it },
                        label = { Text("Latitude") }, modifier = Modifier.weight(1f),
                        singleLine = true)
                    OutlinedTextField(value = lon, onValueChange = { lon = it },
                        label = { Text("Longitude") }, modifier = Modifier.weight(1f),
                        singleLine = true)
                }
                OutlinedButton(onClick = { showPhotoOptions = true }) {
                    Text(if (photo == null) "Add Photo" else "Change Photo")
                }
                if (photo != null) Text("Photo ready to attach", color = MaterialTheme.colorScheme.primary)
                if (selected?.photoPath != null) Text("This item already has a private photo reference.")
                if (notice != null) Text(notice ?: "", style = MaterialTheme.typography.bodySmall)
                if (error != null) Text(error ?: "", color = MaterialTheme.colorScheme.error)
                Button(onClick = { save(if (selected == null) "create" else "update") },
                    enabled = canManage && !busy && !pending && pendingDelete == null,
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
                if (pendingDelete != null && canHardDelete) {
                    Text("Permanent delete or private photo cleanup pending.",
                        color = MaterialTheme.colorScheme.error,
                        fontWeight = FontWeight.SemiBold)
                    Button(onClick = { hardDelete() }, enabled = !busy) {
                        Text("Retry same permanent delete")
                    }
                }
                if (pending && canManage) {
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
                if (canManage) {
                    Button(onClick = { startEditor(null) },
                        enabled = !busy && !pending && pendingDelete == null,
                        modifier = Modifier.fillMaxWidth()) {
                        Text("New Permanent Item")
                    }
                }
                OutlinedTextField(
                    value = search, onValueChange = { search = it },
                    label = { Text("Search permanent items") },
                    modifier = Modifier.fillMaxWidth(), singleLine = true,
                    trailingIcon = {
                        if (search.isNotEmpty()) TextButton(onClick = { search = "" }) {
                            Text("Clear")
                        }
                    }
                )
                val visible = rows.filter { (canHardDelete || it.archivedAt == null) &&
                    (search.isBlank() || it.name.contains(search, true) ||
                        PermanentItemPilotPolicy.label(it.itemType, customTypes).contains(search, true))
                }
                val allMarkers = rows.filter { it.archivedAt == null }
                // Overview always renders every pin and vineyard block boundary.
                // Search filters the list only; future type/layer filters are deliberately omitted.
                val fallback = state.paddocks.firstNotNullOfOrNull { block ->
                    block.polygonPoints?.firstOrNull()?.let { LatLng(it.latitude, it.longitude) }
                } ?: LatLng(-34.0, 138.0)
                val center = allMarkers.firstOrNull()?.let { LatLng(it.latitude, it.longitude) }
                    ?: fallback
                val mapCamera = rememberCameraPositionState {
                    position = CameraPosition.fromLatLngZoom(center, 14f)
                }
                GoogleMap(
                    modifier = Modifier.fillMaxWidth().height(300.dp),
                    cameraPositionState = mapCamera,
                    properties = MapProperties(mapType = MapType.HYBRID),
                ) {
                    state.paddocks.forEach { block ->
                        val points = block.polygonPoints.orEmpty()
                            .map { LatLng(it.latitude, it.longitude) }
                        if (points.size >= 3) Polygon(
                            points = points,
                            fillColor = Color.Yellow.copy(alpha = 0.10f),
                            strokeColor = Color(0xFFF5D45B),
                            strokeWidth = 3f
                        )
                    }
                    allMarkers.forEach { item ->
                        Marker(
                            state = MarkerState(position = LatLng(item.latitude, item.longitude)),
                            title = item.name,
                            snippet = PermanentItemPilotPolicy.label(item.itemType, customTypes),
                            icon = BitmapDescriptorFactory.defaultMarker(
                                permanentItemMarkerHue(item.itemType, customTypes)),
                            onClick = { startEditor(item); true }
                        )
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
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(item.name, fontWeight = FontWeight.SemiBold)
                                if (item.archivedAt != null) Text(" · Archived",
                                    style = MaterialTheme.typography.labelSmall)
                            }
                            Row(verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Box(Modifier.size(14.dp).background(
                                    Color(android.graphics.Color.parseColor(
                                        PermanentItemPilotPolicy.hex(item.itemType, customTypes))),
                                    CircleShape))
                                Text(PermanentItemPilotPolicy.label(item.itemType, customTypes) +
                                    " · revision " + item.serverRevision,
                                    style = MaterialTheme.typography.bodySmall)
                            }
                            Text("%.6f, %.6f".format(item.latitude, item.longitude),
                                style = MaterialTheme.typography.bodySmall)
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                if (canManage && item.archivedAt == null) {
                                    OutlinedButton(onClick = { startEditor(item) },
                                        enabled = !busy && !pending && pendingDelete == null) {
                                        Text("Edit / Move")
                                    }
                                    OutlinedButton(onClick = { archiveTarget = item },
                                        enabled = !busy && !pending && pendingDelete == null) {
                                        Text("Archive")
                                    }
                                }
                                if (canHardDelete) {
                                    OutlinedButton(onClick = { deleteTarget = item },
                                        enabled = !busy && !pending && pendingDelete == null) {
                                        Text("Hard Delete", color = MaterialTheme.colorScheme.error)
                                    }
                                }
                            }
                        }
                    }
                    if (visible.isEmpty()) Text("No Permanent Items in this filter.")
                }
            }
        }
    }

    if (showPhotoOptions) {
        AlertDialog(
            onDismissRequest = { showPhotoOptions = false },
            title = { Text("Attach a photo") },
            text = { Text("Take a photo with the camera, or upload one from your library.") },
            confirmButton = {
                TextButton(onClick = {
                    showPhotoOptions = false
                    if (ContextCompat.checkSelfPermission(
                            context, Manifest.permission.CAMERA
                        ) == PackageManager.PERMISSION_GRANTED
                    ) {
                        cameraPicker.launch(null)
                    } else {
                        cameraPermission.launch(Manifest.permission.CAMERA)
                    }
                }) { Text("Take Photo") }
            },
            dismissButton = {
                TextButton(onClick = {
                    showPhotoOptions = false
                    photoPicker.launch("image/*")
                }) { Text("Choose from Library") }
            }
        )
    }

    if (showNewType) {
        AlertDialog(
            onDismissRequest = { if (!savingNewType) showNewType = false },
            title = { Text("Add Vineyard Type") },
            text = {
                Column(modifier = Modifier.height(350.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = newTypeName, onValueChange = { newTypeName = it.take(60) },
                        label = { Text("Type name") }, singleLine = true
                    )
                    Text("Choose a colour shared across the vineyard:")
                    PermanentItemPilotPolicy.CUSTOM_PALETTE.entries.toList()
                        .chunked(2).forEach { pair ->
                            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                pair.forEach { (label, hex) ->
                                    OutlinedButton(onClick = { newTypeHex = hex },
                                        modifier = Modifier.weight(1f)) {
                                        Box(Modifier.size(12.dp).background(
                                            Color(android.graphics.Color.parseColor(hex)),
                                            CircleShape))
                                        Text(if (newTypeHex == hex) "✓$label" else label,
                                            style = MaterialTheme.typography.labelSmall)
                                    }
                                }
                            }
                        }
                    if (newTypeError != null) {
                        Text(newTypeError ?: "", color = MaterialTheme.colorScheme.error)
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val target = vineyard ?: return@TextButton
                    if (locked || savingNewType) return@TextButton
                    savingNewType = true
                    newTypeError = null
                    scope.launch {
                        try {
                            val added = repository.createType(target, newTypeName, newTypeHex)
                            if (state.currentUserId == user && state.selectedVineyardId == target) {
                                customTypes = customTypes + added
                                type = added.typeKey
                                showNewType = false
                                newTypeName = ""
                            }
                        } catch (e: Exception) {
                            newTypeError = e.message ?: "Unable to add vineyard type."
                        } finally { savingNewType = false }
                    }
                }, enabled = !savingNewType && newTypeName.trim().isNotEmpty()) {
                    Text(if (savingNewType) "Saving…" else "Add Type")
                }
            },
            dismissButton = {
                TextButton(onClick = { showNewType = false }, enabled = !savingNewType) {
                    Text("Cancel")
                }
            }
        )
    }

    if (deleteTarget != null) {
        val current = deleteTarget
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Permanently delete " + (current?.name ?: "this item") + "?") },
            text = {
                Text("This cannot be undone. The Permanent Item, its history entries " +
                    "and all attached photos will be permanently removed from iOS, Android and Portal.")
            },
            confirmButton = {
                TextButton(onClick = {
                    val item = deleteTarget ?: return@TextButton
                    deleteTarget = null
                    hardDelete(item)
                }, enabled = canHardDelete && !busy && !pending && pendingDelete == null) {
                    Text("Delete Permanently", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) { Text("Cancel") }
            }
        )
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
