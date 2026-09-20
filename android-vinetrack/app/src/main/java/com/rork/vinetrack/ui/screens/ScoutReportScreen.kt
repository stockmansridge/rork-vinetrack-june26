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
import androidx.compose.ui.layout.ContentScale
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
import com.rork.vinetrack.data.VintageYearText
import com.rork.vinetrack.data.insights.PhotoLocationStatus
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

private data class ScoutMapMarker(val id: String, val title: String, val subtitle: String, val point: LatLng)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScoutReportScreen(vm: AppViewModel, state: AppUiState, visit: ScoutVisit, onBack: () -> Unit) {
    val context = LocalContext.current
    val vine = LocalVineColors.current
    val liveState by vm.ui.collectAsStateWithLifecycle()
    val vineyard = state.vineyards.firstOrNull { it.id == visit.vineyardId }
    val blocks = visit.assessments.mapNotNull { assessment -> state.paddocks.firstOrNull { it.id == assessment.paddockId } }
    val markers = reportMarkers(visit, blocks, state.pins)
    var selected by remember { mutableStateOf<ScoutMapMarker?>(null) }

    Scaffold(topBar = { TopAppBar(title = { Text("Scout report") }, navigationIcon = { BackNavIcon(onBack) }) }) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item {
                VineyardCard {
                    Text(vineyard?.name ?: "Vineyard", fontSize = 22.sp, fontWeight = FontWeight.Bold, color = vine.textPrimary)
                    Text(if (visit.status == ScoutStatus.DRAFT) "DRAFT SCOUT REPORT" else "SCOUT REPORT",
                        color = if (visit.status == ScoutStatus.DRAFT) VineColors.Warning else VineColors.LeafGreen,
                        fontWeight = FontWeight.Bold)
                    Text("${visit.scoutDateIso} • Vintage ${VintageYearText.format(visit.vintageYear)}")
                    Text("Observer: ${visit.scoutNameSnapshot ?: "Unavailable"} • ${visit.status.label}")
                }
            }
            item { WeatherReportCard(visit) }
            item { ScoutVisitMap(blocks, markers) { selected = it } }
            item {
                val unavailable = visit.assessments.flatMap { assessment ->
                    val name = blocks.firstOrNull { it.id == assessment.paddockId }?.name ?: "Block"
                    assessment.observations.filter { observation ->
                        observation.photos.any { it.locationStatus == PhotoLocationStatus.UNAVAILABLE } ||
                            (observation.item == ScoutItem.GROWTH_STAGE && observation.linkedGrowthStageRecordId != null && observation.linkedPinId == null)
                    }.map { "${it.item.label} — $name" }
                }
                if (unavailable.isNotEmpty()) VineyardCard {
                    Row { Icon(Icons.Filled.LocationOff, null); Spacer(Modifier.size(8.dp)); Text("Location unavailable", fontWeight = FontWeight.Bold) }
                    unavailable.forEach { Text(it, fontSize = 12.sp, color = vine.textSecondary) }
                }
            }
            items(visit.assessments, key = { it.id }) { assessment ->
                val block = blocks.firstOrNull { it.id == assessment.paddockId }
                VineyardCard {
                    Text(block?.name ?: "Block", fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    val varieties = block?.varietyAllocations.orEmpty().mapNotNull { it.displayName }.distinct()
                    Text(if (varieties.isEmpty()) "Variety details unavailable" else varieties.joinToString(", "), fontSize = 12.sp, color = vine.textSecondary)
                    ScoutItem.entries.forEach { item ->
                        val observation = assessment.observation(item)
                        Text(item.label, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 10.dp))
                        val canonical = if (item == ScoutItem.GROWTH_STAGE) observation?.linkedGrowthStageRecordId?.let { id ->
                            liveState.growthRecords.firstOrNull { it.id == id }?.let { record ->
                                com.rork.vinetrack.data.model.GrowthStage.byCode(record.stageCode)?.displayName ?: record.stageLabel
                            }
                        } else null
                        val value = when {
                            canonical != null -> canonical
                            item == ScoutItem.GROWTH_STAGE -> observation?.valueLabel
                            item.isFreeText -> observation?.notes
                            else -> observation?.valueLabel
                        }
                        Text(value?.takeIf { it.isNotBlank() } ?: "Not assessed")
                        if (!item.isFreeText && !observation?.notes.isNullOrBlank()) Text(observation?.notes.orEmpty(), fontSize = 13.sp)
                        if (!observation?.photos.isNullOrEmpty()) LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(observation?.photos.orEmpty(), key = { it.id }) { photo ->
                                val bytes = vm.vineyardInsights.photoBytes(photo)
                                if (bytes != null) AsyncImage(model = bytes, contentDescription = item.label, contentScale = ContentScale.Crop, modifier = Modifier.size(110.dp, 82.dp))
                                else Column(Modifier.size(110.dp, 82.dp)) { Icon(Icons.Filled.PhotoCamera, null); Text("Not downloaded", fontSize = 10.sp) }
                            }
                        }
                    }
                }
            }
            item { VineyardCard { Text("Visit summary", fontWeight = FontWeight.Bold); Text(visit.visitSummary ?: "Not assessed") } }
            item {
                Button(onClick = {
                    ScoutReportPdfExporter.exportAndShare(
                        context, visit, vineyard, blocks,
                        photoBytes = { id -> visit.assessments.flatMap { it.observations }.flatMap { it.photos }.firstOrNull { it.id == id }?.let(vm.vineyardInsights::photoBytes) },
                        logo = state.selectedVineyardLogo,
                    )
                }, modifier = Modifier.fillMaxWidth()) { Text("Export PDF / Share") }
            }
        }
    }
    selected?.let { marker ->
        androidx.compose.material3.AlertDialog(onDismissRequest = { selected = null }, title = { Text(marker.title) },
            text = { Text(marker.subtitle) }, confirmButton = { androidx.compose.material3.TextButton(onClick = { selected = null }) { Text("Done") } })
    }
}

@Composable
private fun WeatherReportCard(visit: ScoutVisit) {
    val vine = LocalVineColors.current
    VineyardCard {
        Text("Weather", fontWeight = FontWeight.Bold)
        val weather = visit.weather
        when {
            weather == null -> Text("Not captured", color = vine.textSecondary)
            weather.isUnavailable -> Text("Unavailable at observation time • ${weather.source ?: "source unavailable"}", color = VineColors.Warning)
            else -> {
                Text(listOfNotNull(weather.temperatureCelsius?.let { "${it.toInt()}°C" }, weather.humidityPercent?.let { "${it.toInt()}% RH" }, weather.windSpeedKph?.let { "wind ${it.toInt()} km/h" }).joinToString(" • "))
                Text("${weather.source ?: "Source unavailable"} • ${weather.observedAtIso?.let { "observed $it" } ?: "observation time unavailable"}", fontSize = 12.sp, color = if (weather.isStale) VineColors.Warning else vine.textSecondary)
            }
        }
    }
}

@Composable
fun ScoutWorkspaceMap(visit: ScoutVisit, blocks: List<Paddock>, pins: List<Pin>) {
    var selected by remember { mutableStateOf<ScoutMapMarker?>(null) }
    ScoutVisitMap(blocks, reportMarkers(visit, blocks, pins)) { selected = it }
    selected?.let { marker ->
        androidx.compose.material3.AlertDialog(onDismissRequest = { selected = null }, title = { Text(marker.title) },
            text = { Text(marker.subtitle) }, confirmButton = { androidx.compose.material3.TextButton(onClick = { selected = null }) { Text("Done") } })
    }
}

@Composable
private fun ScoutVisitMap(blocks: List<Paddock>, markers: List<ScoutMapMarker>, onMarker: (ScoutMapMarker) -> Unit) {
    val camera = rememberCameraPositionState()
    val points = blocks.flatMap { block -> block.polygonPoints.orEmpty().map { LatLng(it.latitude, it.longitude) } } + markers.map { it.point }
    androidx.compose.runtime.LaunchedEffect(points) {
        if (points.isNotEmpty()) {
            val builder = LatLngBounds.builder(); points.forEach(builder::include)
            runCatching { camera.animate(CameraUpdateFactory.newLatLngBounds(builder.build(), 60)) }
        }
    }
    GoogleMap(modifier = Modifier.fillMaxWidth().height(280.dp), cameraPositionState = camera, properties = MapProperties(mapType = MapType.HYBRID)) {
        blocks.forEach { block -> val polygon = block.polygonPoints.orEmpty().map { LatLng(it.latitude, it.longitude) }; if (polygon.size >= 3) Polygon(points = polygon, fillColor = VineColors.LeafGreen.copy(alpha = 0.18f), strokeColor = VineColors.LeafGreen) }
        markers.forEach { marker -> Marker(state = MarkerState(marker.point), title = marker.title, snippet = marker.subtitle, onClick = { onMarker(marker); true }) }
    }
}

private fun reportMarkers(visit: ScoutVisit, blocks: List<Paddock>, pins: List<Pin>): List<ScoutMapMarker> = visit.assessments.flatMap { assessment ->
    val blockName = blocks.firstOrNull { it.id == assessment.paddockId }?.name ?: "Block"
    assessment.observations.flatMap { observation ->
        val photos = observation.photos.mapNotNull { photo ->
            if (photo.locationStatus == PhotoLocationStatus.GPS_CONFIRMED && photo.latitude != null && photo.longitude != null)
                ScoutMapMarker(photo.id, observation.item.label, blockName, LatLng(photo.latitude, photo.longitude)) else null
        }.toMutableList()
        if (observation.item == ScoutItem.GROWTH_STAGE) observation.linkedPinId?.let { id -> pins.firstOrNull { it.id == id } }?.let { pin ->
            if (pin.latitude != null && pin.longitude != null) photos += ScoutMapMarker(observation.id, observation.valueLabel ?: "E-L observation", blockName, LatLng(pin.latitude, pin.longitude))
        }
        photos
    }
}
