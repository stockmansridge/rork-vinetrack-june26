package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationOff
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import android.widget.Toast
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.ScoutReportPdfExporter
import com.rork.vinetrack.data.insights.ScoutReportPresentation
import com.rork.vinetrack.data.model.GrowthStageRecord
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.rork.vinetrack.data.insights.ScoutItem
import com.rork.vinetrack.data.insights.ScoutStatus
import com.rork.vinetrack.data.insights.ScoutVisit
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.components.BackNavIcon
import com.rork.vinetrack.ui.components.VineyardCard
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors

private data class ScoutMapMarker(val id: String, val title: String, val subtitle: String, val point: LatLng, val photoId: String? = null, val source: String, val reference: String)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScoutReportScreen(vm: AppViewModel, state: AppUiState, visit: ScoutVisit, onBack: () -> Unit) {
    val context = LocalContext.current
    val vine = LocalVineColors.current
    val liveState by vm.ui.collectAsStateWithLifecycle()
    val syncError by vm.vineyardInsights.lastSyncError.collectAsStateWithLifecycle()
    val vineyard = liveState.vineyards.firstOrNull { it.id == visit.vineyardId }
    val logo = liveState.selectedVineyardLogo.takeIf { liveState.selectedVineyardId == visit.vineyardId }
    val blocks = visit.assessments.mapNotNull { assessment -> state.paddocks.firstOrNull { it.id == assessment.paddockId } }
    val locations = ScoutReportPresentation.locations(visit, liveState.paddocks, liveState.growthRecords, liveState.pins)
    val markers = reportMarkers(locations)
    var selected by remember { mutableStateOf<ScoutMapMarker?>(null) }

    Scaffold(topBar = { TopAppBar(title = { Text("Scout report") }, navigationIcon = { BackNavIcon(onBack) }) }) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item {
                VineyardCard {
                    logo?.let { logo ->
                        androidx.compose.foundation.Image(bitmap = logo.asImageBitmap(), contentDescription = "Vineyard logo", modifier = Modifier.size(64.dp), contentScale = ContentScale.Fit)
                    }
                    Text(vineyard?.name ?: "Vineyard", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                    Text(if (visit.status == ScoutStatus.DRAFT) "DRAFT SCOUT REPORT" else "SCOUT REPORT",
                        color = if (visit.status == ScoutStatus.DRAFT) VineColors.Warning else VineColors.LeafGreen,
                        fontWeight = FontWeight.Bold)
                    Text("${visit.scoutDateIso} • Vintage ${VintageYearText.format(visit.vintageYear)}")
                    Text("Observer: ${visit.scoutNameSnapshot ?: "Unavailable"} • ${visit.status.label}")
                    if (vm.vineyardInsights.deletionPending(visit.id)) {
                        Text(vm.vineyardInsights.syncStatus(visit), color = VineColors.Warning)
                        syncError?.let { Text(it, fontSize = 12.sp, color = VineColors.Warning) }
                    }
                }
            }
            item { WeatherReportCard(visit) }
            item { ScoutVisitMap(blocks, markers) { selected = it } }
            item { Text(ScoutReportPresentation.LEGEND, fontSize = 12.sp) }
            items(locations.boundaryUnavailable) { Text(it, fontSize = 12.sp) }
            items(markers, key = { it.id }) { marker ->
                androidx.compose.material3.TextButton(onClick = { selected = marker }) { Text("${marker.title} • ${marker.subtitle}", fontSize = 12.sp) }
            }
            if (locations.unavailable.isNotEmpty()) {
                item { Row { Icon(Icons.Filled.LocationOff, null); Spacer(Modifier.size(8.dp)); Text("Location unavailable", fontWeight = FontWeight.Bold) } }
                items(locations.unavailable) { Text(it, fontSize = 12.sp, color = vine.textSecondary) }
            }
            items(visit.assessments, key = { it.id }) { assessment ->
                val block = blocks.firstOrNull { it.id == assessment.paddockId }
                VineyardCard {
                    Text(block?.name ?: "Block ${assessment.paddockId}", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    val varieties = block?.varietyAllocations.orEmpty().mapNotNull { it.displayName }.distinct()
                    Text(if (varieties.isEmpty()) "Variety details unavailable" else varieties.joinToString(", "), fontSize = 12.sp, color = vine.textSecondary)
                    ScoutItem.entries.forEach { item ->
                        val observation = assessment.observation(item)
                        Text(item.label, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 10.dp))
                        val value = when {
                            item == ScoutItem.GROWTH_STAGE -> ScoutReportPresentation.growthValue(observation, visit.vineyardId, liveState.growthRecords)
                            item.isFreeText -> observation?.notes
                            else -> observation?.valueLabel
                        }
                        Text(value?.takeIf { it.isNotBlank() } ?: "Not assessed")
                        if (!item.isFreeText && !observation?.notes.isNullOrBlank()) Text(observation?.notes.orEmpty(), fontSize = 13.sp)
                        if (!observation?.photos.isNullOrEmpty()) LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(observation?.photos.orEmpty(), key = { it.id }) { photo ->
                                Column {
                                    val bytes = vm.vineyardInsights.photoBytes(photo)
                                    if (bytes != null) AsyncImage(model = bytes, contentDescription = item.label, contentScale = ContentScale.Crop, modifier = Modifier.size(110.dp, 82.dp))
                                    else Column(Modifier.size(110.dp, 82.dp)) { Icon(Icons.Filled.PhotoCamera, null); Text("Not downloaded", fontSize = 10.sp) }
                                    Text(locations.photoReferences[photo.id] ?: "Photograph", fontSize = 10.sp)
                                }
                            }
                        }
                    }
                }
            }
            item { VineyardCard { Text("Visit summary", fontWeight = FontWeight.Bold); Text(visit.visitSummary ?: "Not assessed") } }
            item {
                Button(onClick = {
                    val shared = ScoutReportPdfExporter.exportAndShare(
                        context, visit, vineyard, blocks,
                        photoBytes = { id -> visit.assessments.flatMap { it.observations }.flatMap { it.photos }.firstOrNull { it.id == id }?.let(vm.vineyardInsights::photoBytes) },
                        logo = logo,
                        growthRecords = liveState.growthRecords,
                        pins = liveState.pins,
                        locationBlocks = liveState.paddocks,
                        deletionStatus = if (vm.vineyardInsights.deletionPending(visit.id)) vm.vineyardInsights.syncStatus(visit) else null,
                    )
                    if (!shared) Toast.makeText(context, "The Scout PDF could not be created or shared. Check device storage and try again.", Toast.LENGTH_LONG).show()
                }, modifier = Modifier.fillMaxWidth()) { Text("Export PDF / Share") }
            }
        }
    }
    selected?.let { marker ->
        androidx.compose.material3.AlertDialog(onDismissRequest = { selected = null }, title = { Text(marker.title) },
            text = { Column { Text(marker.subtitle); marker.photoId?.let { id -> val photo = visit.assessments.flatMap { it.observations }.flatMap { it.photos }.firstOrNull { it.id == id }; val bytes = photo?.let(vm.vineyardInsights::photoBytes); if (bytes != null) AsyncImage(model = bytes, contentDescription = marker.title, modifier = Modifier.fillMaxWidth().height(180.dp), contentScale = ContentScale.Fit) else Text("Saved photograph unavailable on this device") } ?: Text(marker.source) } },
            confirmButton = { androidx.compose.material3.TextButton(onClick = { selected = null }) { Text("Done") } })
    }
}

@Composable
private fun WeatherReportCard(visit: ScoutVisit) {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("Weather", fontWeight = FontWeight.Bold)
        val weather = visit.weather
        Text("Temp: ${weather?.temperatureCelsius?.let { "%.1f °C".format(it) } ?: "Unavailable"}")
        Text("Humidity: ${weather?.humidityPercent?.let { "${it.toInt()}%" } ?: "Unavailable"}")
        Text("Wind: ${weather?.windSpeedKph?.let { "${it.toInt()} km/h" } ?: "Unavailable"}")
        Text("Source: ${weather?.source ?: "Unavailable"}")
        Text(weather?.observedAtIso?.let { "Observed $it" } ?: "Observation time unavailable", fontSize = 12.sp, color = vine.textSecondary)
        if (weather?.isUnavailable == true) Text("Unavailable at observation time", fontSize = 12.sp, color = VineColors.Warning)
        if (weather?.isStale == true) Text("Stale weather reading", fontSize = 12.sp, color = VineColors.Warning)
    }
}

@Composable
fun ScoutWorkspaceMap(visit: ScoutVisit, blocks: List<Paddock>, pins: List<Pin>, photoBytes: (String) -> ByteArray?, growthRecords: List<GrowthStageRecord>, locationBlocks: List<Paddock>) {
    var selected by remember { mutableStateOf<ScoutMapMarker?>(null) }
    val locations = ScoutReportPresentation.locations(visit, locationBlocks, growthRecords, pins)
    val markers = reportMarkers(locations)
    Column {
        ScoutVisitMap(blocks, markers) { selected = it }
        LocationReferences(markers) { selected = it }
        locations.boundaryUnavailable.forEach { Text(it, fontSize = 12.sp) }
        if (locations.unavailable.isNotEmpty()) {
            Text("Location unavailable", fontWeight = FontWeight.Bold)
            locations.unavailable.forEach { Text(it, fontSize = 12.sp) }
        }
    }
    selected?.let { marker ->
        androidx.compose.material3.AlertDialog(onDismissRequest = { selected = null }, title = { Text(marker.title) },
            text = { Column { Text(marker.subtitle); marker.photoId?.let { id -> val bytes = photoBytes(id); if (bytes != null) AsyncImage(model = bytes, contentDescription = marker.title, modifier = Modifier.fillMaxWidth().height(180.dp), contentScale = ContentScale.Fit) else Text("Saved photograph unavailable on this device") } ?: Text(marker.source) } },
            confirmButton = { androidx.compose.material3.TextButton(onClick = { selected = null }) { Text("Done") } })
    }
}

@Composable
private fun ScoutVisitMap(blocks: List<Paddock>, markers: List<ScoutMapMarker>, onMarker: (ScoutMapMarker) -> Unit) {
    val camera = rememberCameraPositionState()
    val points = blocks.flatMap { block -> block.polygonPoints.orEmpty().filter { ScoutReportPresentation.valid(it.latitude, it.longitude) }.map { LatLng(it.latitude, it.longitude) } } + markers.map { it.point }
    var mapSize by remember { mutableStateOf(IntSize.Zero) }
    androidx.compose.runtime.LaunchedEffect(points, mapSize) {
        if (mapSize.width > 0 && mapSize.height > 0 && points.isNotEmpty()) {
            val builder = LatLngBounds.builder(); points.forEach(builder::include)
            runCatching {
                val bounds = builder.build()
                if (points.distinct().size == 1) camera.animate(CameraUpdateFactory.newLatLngZoom(points.first(), 17f))
                else camera.animate(CameraUpdateFactory.newLatLngBounds(bounds, mapSize.width, mapSize.height, minOf(60, minOf(mapSize.width, mapSize.height) / 4)))
            }
        }
    }
    GoogleMap(modifier = Modifier.fillMaxWidth().height(280.dp).onSizeChanged { mapSize = it }, cameraPositionState = camera, properties = MapProperties(mapType = MapType.HYBRID)) {
        blocks.forEach { block -> val polygon = block.polygonPoints.orEmpty().filter { ScoutReportPresentation.valid(it.latitude, it.longitude) }.map { LatLng(it.latitude, it.longitude) }; if (polygon.size >= 3 && polygon.size == block.polygonPoints.orEmpty().size) Polygon(points = polygon, fillColor = VineColors.LeafGreen.copy(alpha = 0.18f), strokeColor = VineColors.LeafGreen) }
        markers.forEach { marker ->
            androidx.compose.runtime.key(marker.id) {
                Marker(state = MarkerState(marker.point), title = marker.title, snippet = marker.subtitle,
                    icon = BitmapDescriptorFactory.defaultMarker(if (marker.photoId != null) BitmapDescriptorFactory.HUE_ORANGE else if (marker.reference.startsWith("E")) BitmapDescriptorFactory.HUE_GREEN else BitmapDescriptorFactory.HUE_AZURE),
                    onClick = { onMarker(marker); true })
            }
        }
    }
}

private fun reportMarkers(locations: ScoutReportPresentation.Locations): List<ScoutMapMarker> = locations.markers.map {
    ScoutMapMarker("${it.observationId}:${it.reference}", "${it.reference} • ${it.item}", "${it.block} • ${it.item} • ${it.source}", LatLng(it.latitude, it.longitude), it.photoId, it.source, it.reference)
}

@Composable
private fun LocationReferences(markers: List<ScoutMapMarker>, onMarker: (ScoutMapMarker) -> Unit) {
    Column {
        Text(ScoutReportPresentation.LEGEND, fontSize = 12.sp)
        markers.forEach { marker ->
            androidx.compose.material3.TextButton(onClick = { onMarker(marker) }) { Text("${marker.title} • ${marker.subtitle}", fontSize = 12.sp) }
        }
    }
}
