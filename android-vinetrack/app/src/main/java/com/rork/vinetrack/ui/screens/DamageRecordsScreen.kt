package com.rork.vinetrack.ui.screens

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.CalendarToday
import androidx.compose.material.icons.filled.Coronavirus
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Grain
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Undo
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.RegionFormatter
import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.DamageRecord
import com.rork.vinetrack.data.model.DamageType
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.damageFactor
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
import kotlin.math.abs
import kotlin.math.cos

/**
 * Record Damage surface — mirrors the iOS `DamageRecordsListView` +
 * `RecordDamageView`. Lists block-damage events with an overview + per-block
 * yield-impact summary, and lets members draw a damage-zone polygon on the
 * block map, set the type/percent/date, and save. Backed by the
 * `damage_records` table via [AppViewModel.saveDamageRecord]/[deleteDamageRecord].
 */
private sealed interface DamageDestination {
    data object List : DamageDestination
    data class Edit(val paddock: Paddock, val record: DamageRecord?) : DamageDestination
}

@Composable
fun DamageRecordsScreen(
    vm: AppViewModel,
    state: AppUiState,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
) {
    var destination by remember { mutableStateOf<DamageDestination>(DamageDestination.List) }

    AnimatedContent(
        targetState = destination,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "damage-nav",
        modifier = modifier,
    ) { dest ->
        when (dest) {
            is DamageDestination.List -> DamageListView(
                state = state,
                onBack = onBack,
                onReport = { paddock -> destination = DamageDestination.Edit(paddock, null) },
                onOpen = { record ->
                    val paddock = state.paddocks.firstOrNull { it.id == record.paddockId }
                    if (paddock != null) destination = DamageDestination.Edit(paddock, record)
                },
                onDelete = { vm.deleteDamageRecord(it.id) {} },
            )
            is DamageDestination.Edit -> RecordDamageView(
                vm = vm,
                state = state,
                paddock = dest.paddock,
                editing = dest.record,
                onBack = { destination = DamageDestination.List },
                onSaved = { destination = DamageDestination.List },
                onDeleted = { destination = DamageDestination.List },
            )
        }
    }
}

// MARK: - List

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DamageListView(
    state: AppUiState,
    onBack: (() -> Unit)?,
    onReport: (Paddock) -> Unit,
    onOpen: (DamageRecord) -> Unit,
    onDelete: (DamageRecord) -> Unit,
) {
    val vine = LocalVineColors.current
    val fmt = state.regionFormatter
    val mappablePaddocks = remember(state.paddocks) { state.paddocks.filter { it.hasGeometry } }
    val records = remember(state.damageRecords) {
        state.damageRecords.sortedByDescending { it.date ?: "" }
    }
    var showPicker by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf<DamageRecord?>(null) }

    val totalAffectedHa = records.sumOf { it.areaHectares }
    val effectiveLossHa = records.sumOf { it.areaHectares * (it.damagePercent.coerceIn(0.0, 100.0) / 100.0) }
    val blockArea = mappablePaddocks.sumOf { it.areaHectares }
    val impactPct = if (blockArea > 0) (effectiveLossHa / blockArea * 100).coerceAtMost(100.0) else 0.0
    val affected = remember(records, mappablePaddocks) {
        mappablePaddocks.filter { p -> records.any { it.paddockId == p.id } }
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text("Damage Reports") },
                navigationIcon = { if (onBack != null) BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(0.dp))

            // Overview.
            SectionHeader("Damage Overview", onLight = true)
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        DamageStat("Records", records.size.toString(), Icons.Filled.Warning, VineColors.Orange, Modifier.weight(1f))
                        DamageStat("Blocks Affected", records.map { it.paddockId }.distinct().size.toString(), Icons.Filled.Map, VineColors.Destructive, Modifier.weight(1f))
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        DamageStat("Effective Loss", fmt.formatArea(effectiveLossHa), Icons.Filled.Grain, VineColors.EarthBrown, Modifier.weight(1f))
                        DamageStat("Yield Impact", String.format(Locale.getDefault(), "%.1f%%", impactPct), Icons.Filled.Warning, VineColors.Pink, Modifier.weight(1f))
                    }
                }
            }

            Button(
                onClick = { showPicker = true },
                enabled = mappablePaddocks.isNotEmpty(),
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Orange),
            ) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Report Damage")
            }

            // Yield impact (per-block viability).
            if (affected.isNotEmpty()) {
                SectionHeader("Yield Impact", onLight = true)
                VineyardCard {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        affected.forEach { paddock ->
                            val count = records.count { it.paddockId == paddock.id }
                            val factor = records.damageFactor(paddock.id)
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(paddock.name, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                                    Text("$count record${if (count == 1) "" else "s"}", color = vine.textSecondary, fontSize = 12.sp)
                                }
                                Text(
                                    String.format(Locale.getDefault(), "%.0f%% viable", factor * 100),
                                    color = if (factor >= 0.8) VineColors.LeafGreen else if (factor >= 0.5) VineColors.Orange else VineColors.Destructive,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold,
                                )
                            }
                        }
                    }
                }
            }

            // Reports list.
            SectionHeader("Damage Reports", onLight = true)
            state.damageError?.let { Text(it, color = VineColors.Destructive, fontSize = 13.sp) }
            if (records.isEmpty()) {
                EmptyState(
                    icon = Icons.Filled.Warning,
                    title = "No Damage Recorded",
                    message = "Tap Report Damage to log frost, hail, wind, or other damage events.",
                )
            } else {
                records.forEach { record ->
                    val paddock = state.paddocks.firstOrNull { it.id == record.paddockId }
                    DamageRecordCard(
                        record = record,
                        fmt = fmt,
                        paddockName = paddock?.name ?: "Unknown Block",
                        onClick = { onOpen(record) },
                        onDelete = { confirmDelete = record },
                    )
                }
            }
        }
    }

    if (showPicker) {
        BlockPickerDialog(
            paddocks = mappablePaddocks,
            fmt = fmt,
            existingCount = { id -> state.damageRecords.count { it.paddockId == id } },
            onDismiss = { showPicker = false },
            onPick = { showPicker = false; onReport(it) },
        )
    }

    confirmDelete?.let { rec ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("Delete damage record?") },
            text = { Text("This permanently removes the damage record for everyone. This can't be undone.") },
            confirmButton = {
                TextButton(onClick = { confirmDelete = null; onDelete(rec) }) {
                    Text("Delete", color = VineColors.Destructive)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun DamageStat(label: String, value: String, icon: ImageVector, tint: Color, modifier: Modifier = Modifier) {
    val vine = LocalVineColors.current
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(tint.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) { Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp)) }
        Column {
            Text(value, color = vine.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1)
            Text(label, color = vine.textSecondary, fontSize = 11.sp, maxLines = 1)
        }
    }
}

@Composable
private fun DamageRecordCard(
    record: DamageRecord,
    fmt: RegionFormatter,
    paddockName: String,
    onClick: () -> Unit,
    onDelete: () -> Unit,
) {
    val vine = LocalVineColors.current
    VineyardCard(modifier = Modifier.clickable { onClick() }) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                modifier = Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(VineColors.Orange.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) { Icon(damageIcon(record.type), contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(22.dp)) }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(record.type.label, color = vine.textPrimary, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f, fill = false))
                    Text(String.format(Locale.getDefault(), "%.0f%%", record.damagePercent), color = VineColors.Destructive, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                }
                val parts = buildList {
                    add(paddockName)
                    formatDamageDate(record.date)?.let { add(it) }
                    if (record.areaHectares > 0) add(fmt.formatArea(record.areaHectares))
                }
                Text(parts.joinToString(" · "), color = vine.textSecondary, fontSize = 12.sp, maxLines = 1)
                record.notes.takeIf { it.isNotBlank() }?.let {
                    Text(it, color = vine.textSecondary, fontSize = 12.sp, maxLines = 2)
                }
            }
            Icon(
                Icons.Filled.Delete,
                contentDescription = "Delete",
                tint = vine.textSecondary,
                modifier = Modifier.size(20.dp).clickable { onDelete() },
            )
        }
    }
}

@Composable
private fun BlockPickerDialog(
    paddocks: List<Paddock>,
    fmt: RegionFormatter,
    existingCount: (String) -> Int,
    onDismiss: () -> Unit,
    onPick: (Paddock) -> Unit,
) {
    val vine = LocalVineColors.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Report Damage") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Select the block where damage occurred.", color = vine.textSecondary, fontSize = 13.sp)
                paddocks.forEach { paddock ->
                    val count = existingCount(paddock.id)
                    Row(
                        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))
                            .clickable { onPick(paddock) }.padding(vertical = 10.dp, horizontal = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(Icons.Filled.Warning, contentDescription = null, tint = VineColors.Orange, modifier = Modifier.size(20.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(paddock.name, color = vine.textPrimary, fontSize = 15.sp)
                            Text(
                                if (count > 0) "$count existing" else fmt.formatArea(paddock.areaHectares),
                                color = if (count > 0) VineColors.Orange else vine.textSecondary,
                                fontSize = 12.sp,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// MARK: - Record / Edit

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun RecordDamageView(
    vm: AppViewModel,
    state: AppUiState,
    paddock: Paddock,
    editing: DamageRecord?,
    onBack: () -> Unit,
    onSaved: () -> Unit,
    onDeleted: () -> Unit,
) {
    val vine = LocalVineColors.current
    val fmt = state.regionFormatter
    val isNew = editing == null
    val canDelete = state.currentRole in setOf("owner", "manager", "supervisor")

    // Polygon vertices as draggable marker states (live position drives the overlay).
    val verts: SnapshotStateList<MarkerState> = remember(editing?.id) {
        (editing?.polygonPoints ?: emptyList()).map { MarkerState(position = LatLng(it.latitude, it.longitude)) }
            .toMutableStateList()
    }
    var damageType by remember(editing?.id) { mutableStateOf(editing?.type ?: DamageType.Frost) }
    var percentText by remember(editing?.id) { mutableStateOf(((editing?.damagePercent ?: 20.0)).toInt().toString()) }
    var notes by remember(editing?.id) { mutableStateOf(editing?.notes ?: "") }
    var dateMs by remember(editing?.id) {
        mutableStateOf(parseDateMs(editing?.date) ?: System.currentTimeMillis())
    }
    var showDatePicker by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    val percent = percentText.toDoubleOrNull() ?: 0.0
    val livePoints by remember { derivedStateOf { verts.map { it.position } } }
    val damageAreaHa = polygonAreaHa(livePoints)
    val pctOfBlock = if (paddock.areaHectares > 0) damageAreaHa / paddock.areaHectares * 100 else 0.0
    val isValid = livePoints.size >= 3 && percent > 0 && percent <= 100

    val blockPoly = remember(paddock.id) { paddock.polygonPoints?.map { LatLng(it.latitude, it.longitude) } ?: emptyList() }
    val cameraPositionState = rememberCameraPositionState()

    LaunchedEffect(paddock.id) {
        val pts = blockPoly.ifEmpty { livePoints }
        if (pts.isNotEmpty()) {
            val b = LatLngBounds.builder().apply { pts.forEach { include(it) } }.build()
            runCatching { cameraPositionState.move(CameraUpdateFactory.newLatLngBounds(b, 140)) }
        }
    }

    Scaffold(
        containerColor = vine.appBackground,
        topBar = {
            TopAppBar(
                title = { Text(if (isNew) "Record Damage" else "Edit Damage") },
                navigationIcon = { BackNavIcon(onBack) },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Spacer(Modifier.height(0.dp))

            // Map with block boundary + editable damage polygon.
            Box(
                modifier = Modifier.fillMaxWidth().height(320.dp).clip(RoundedCornerShape(14.dp)),
            ) {
                GoogleMap(
                    modifier = Modifier.fillMaxSize(),
                    cameraPositionState = cameraPositionState,
                    properties = MapProperties(mapType = MapType.HYBRID),
                    uiSettings = MapUiSettings(zoomControlsEnabled = false, mapToolbarEnabled = false),
                    onMapClick = { latLng -> verts.add(MarkerState(position = latLng)) },
                ) {
                    if (blockPoly.size >= 3) {
                        Polygon(
                            points = blockPoly,
                            fillColor = VineColors.Info.copy(alpha = 0.08f),
                            strokeColor = VineColors.Info.copy(alpha = 0.6f),
                            strokeWidth = 4f,
                            zIndex = 0f,
                        )
                    }
                    // Existing damage polygons on this block (read-only context).
                    state.damageRecords.filter { it.paddockId == paddock.id && it.id != editing?.id }.forEach { rec ->
                        val pts = rec.polygonPoints?.map { LatLng(it.latitude, it.longitude) } ?: emptyList()
                        if (pts.size >= 3) {
                            Polygon(
                                points = pts,
                                fillColor = VineColors.Destructive.copy(alpha = 0.18f),
                                strokeColor = VineColors.Destructive.copy(alpha = 0.6f),
                                strokeWidth = 2f,
                                zIndex = 1f,
                            )
                        }
                    }
                    // The polygon being edited.
                    if (livePoints.size >= 3) {
                        Polygon(
                            points = livePoints,
                            fillColor = VineColors.Orange.copy(alpha = 0.25f),
                            strokeColor = VineColors.Orange,
                            strokeWidth = 5f,
                            zIndex = 2f,
                        )
                    } else if (livePoints.size == 2) {
                        Polyline(points = livePoints, color = VineColors.Orange, width = 5f, zIndex = 2f)
                    }
                    verts.forEach { ms ->
                        Marker(
                            state = ms,
                            draggable = true,
                            icon = BitmapDescriptorFactory.defaultMarker(BitmapDescriptorFactory.HUE_ORANGE),
                            zIndex = 3f,
                        )
                    }
                }
            }

            Text(
                if (livePoints.isEmpty()) "Tap the map to drop the damage-zone corners. Drag a pin to fine-tune."
                else "${livePoints.size} point${if (livePoints.size == 1) "" else "s"} — tap to add more, drag pins to adjust.",
                color = vine.textSecondary, fontSize = 12.sp,
            )

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(
                    onClick = { if (verts.isNotEmpty()) verts.removeAt(verts.lastIndex) },
                    enabled = verts.isNotEmpty(),
                ) {
                    Icon(Icons.Filled.Undo, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp)); Text("Undo")
                }
                OutlinedButton(onClick = { verts.clear() }, enabled = verts.isNotEmpty()) {
                    Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp)); Text("Clear")
                }
                OutlinedButton(onClick = {
                    val c = cameraPositionState.position.target
                    verts.add(MarkerState(position = c))
                }) {
                    Icon(Icons.Filled.Place, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp)); Text("Center")
                }
            }

            // Area info.
            if (livePoints.size >= 3) {
                VineyardCard {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        DamageStat("Damage Zone", fmt.formatArea(damageAreaHa, fractionDigits = 4), Icons.Filled.Warning, VineColors.Orange, Modifier.weight(1f))
                        DamageStat("Block Area", fmt.formatArea(paddock.areaHectares), Icons.Filled.Map, VineColors.Info, Modifier.weight(1f))
                    }
                    Spacer(Modifier.height(10.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("% of Block", color = vine.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        Text(String.format(Locale.getDefault(), "%.1f%%", pctOfBlock), color = VineColors.Destructive, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }

            // Damage details.
            SectionHeader("Damage Details", onLight = true)
            VineyardCard {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    // Date.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Date", color = vine.textPrimary, fontSize = 14.sp, modifier = Modifier.weight(1f))
                        OutlinedButton(onClick = { showDatePicker = true }) {
                            Icon(Icons.Filled.CalendarToday, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(displayDate(dateMs))
                        }
                    }

                    // Type grid.
                    Text("Type of Damage", color = vine.textSecondary, fontSize = 12.sp)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        DamageType.entries.forEach { type ->
                            val selected = type == damageType
                            Row(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(if (selected) VineColors.Orange.copy(alpha = 0.15f) else vine.appBackground)
                                    .border(
                                        androidx.compose.foundation.BorderStroke(1.5.dp, if (selected) VineColors.Orange else Color.Transparent),
                                        RoundedCornerShape(8.dp),
                                    )
                                    .clickable { damageType = type }
                                    .padding(horizontal = 12.dp, vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(5.dp),
                            ) {
                                Icon(damageIcon(type), contentDescription = null, tint = if (selected) VineColors.Orange else vine.textSecondary, modifier = Modifier.size(15.dp))
                                Text(type.label, color = if (selected) VineColors.Orange else vine.textPrimary, fontSize = 13.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
                            }
                        }
                    }

                    // Percent.
                    Text("Damage Amount (%)", color = vine.textSecondary, fontSize = 12.sp)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        OutlinedTextField(
                            value = percentText,
                            onValueChange = { v -> percentText = v.filter { it.isDigit() }.take(3) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            modifier = Modifier.width(90.dp),
                        )
                        Slider(
                            value = percent.toFloat().coerceIn(1f, 100f),
                            onValueChange = { percentText = it.toInt().toString() },
                            valueRange = 1f..100f,
                            modifier = Modifier.weight(1f),
                            colors = androidx.compose.material3.SliderDefaults.colors(thumbColor = VineColors.Orange, activeTrackColor = VineColors.Orange),
                        )
                        Text("${percent.toInt()}%", color = VineColors.Orange, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                    }

                    // Notes.
                    OutlinedTextField(
                        value = notes,
                        onValueChange = { notes = it },
                        label = { Text("Notes (optional)") },
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 2,
                    )
                }
            }

            state.damageError?.let { Text(it, color = VineColors.Destructive, fontSize = 13.sp) }

            Button(
                onClick = {
                    val record = buildRecord(editing, paddock, livePoints, dateMs, damageType, percent, notes)
                    vm.saveDamageRecord(record, isNew = isNew) { ok -> if (ok) onSaved() }
                },
                enabled = isValid && !state.damageBusy,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = VineColors.Orange),
            ) {
                Text(if (isNew) "Save Damage Record" else "Update Damage Record")
            }

            if (!isNew && canDelete) {
                OutlinedButton(
                    onClick = { confirmDelete = true },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = VineColors.Destructive),
                ) {
                    Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Delete Damage Record")
                }
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

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete damage record?") },
            text = { Text("This permanently removes the damage record for everyone. This can't be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmDelete = false
                    editing?.let { rec -> vm.deleteDamageRecord(rec.id) { ok -> if (ok) onDeleted() } }
                }) { Text("Delete", color = VineColors.Destructive) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

// MARK: - Helpers

private fun buildRecord(
    editing: DamageRecord?,
    paddock: Paddock,
    points: List<LatLng>,
    dateMs: Long,
    type: DamageType,
    percent: Double,
    notes: String,
): DamageRecord {
    val poly = points.map { CoordinatePoint(latitude = it.latitude, longitude = it.longitude) }
    val iso = Instant.ofEpochMilli(dateMs).toString()
    return (editing ?: DamageRecord(
        id = UUID.randomUUID().toString(),
        vineyardId = paddock.vineyardId,
        paddockId = paddock.id,
    )).copy(
        paddockId = paddock.id,
        polygonPoints = poly,
        date = iso,
        damageType = type.label,
        damagePercent = percent,
        notes = notes.trim(),
    )
}

private fun damageIcon(type: DamageType): ImageVector = when (type) {
    DamageType.Frost -> Icons.Filled.AcUnit
    DamageType.Hail -> Icons.Filled.Grain
    DamageType.Wind -> Icons.Filled.Air
    DamageType.Heat -> Icons.Filled.WbSunny
    DamageType.Disease -> Icons.Filled.Coronavirus
    DamageType.Pest -> Icons.Filled.BugReport
    DamageType.Other -> Icons.Filled.Warning
}

private fun polygonAreaHa(points: List<LatLng>): Double {
    if (points.size < 3) return 0.0
    val centroidLat = points.map { it.latitude }.average()
    val mPerDegLat = 111_320.0
    val mPerDegLon = 111_320.0 * cos(centroidLat * Math.PI / 180.0)
    var area = 0.0
    val n = points.size
    for (i in 0 until n) {
        val j = (i + 1) % n
        area += (points[i].longitude * mPerDegLon) * (points[j].latitude * mPerDegLat) -
            (points[j].longitude * mPerDegLon) * (points[i].latitude * mPerDegLat)
    }
    return abs(area) / 2.0 / 10_000.0
}

private fun formatHaD(value: Double): String =
    if (value >= 10) value.toInt().toString()
    else if (value >= 1) String.format(Locale.getDefault(), "%.1f", value)
    else String.format(Locale.getDefault(), "%.3f", value)

private val isoParsers = listOf("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", "yyyy-MM-dd'T'HH:mm:ssXXX", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd")

private fun parseDateMs(iso: String?): Long? {
    if (iso.isNullOrBlank()) return null
    for (p in isoParsers) {
        runCatching {
            val f = SimpleDateFormat(p, Locale.US)
            return f.parse(iso)?.time
        }
    }
    return null
}

private fun formatDamageDate(iso: String?): String? {
    val ms = parseDateMs(iso) ?: return null
    return displayDate(ms)
}

private fun displayDate(ms: Long): String =
    SimpleDateFormat("d MMM yyyy", Locale.getDefault()).format(Date(ms))
