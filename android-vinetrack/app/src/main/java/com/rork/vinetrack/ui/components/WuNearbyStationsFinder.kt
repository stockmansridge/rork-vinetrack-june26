package com.rork.vinetrack.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocationSearching
import androidx.compose.material.icons.filled.SignalWifiOff
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rork.vinetrack.data.NearbyWuStation
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlinx.coroutines.launch

/**
 * "Find nearby WU stations" — Android counterpart of the iOS
 * `WundergroundStationPickerSheet`. Renders the search button, the
 * coordinates-required warning, loading/error/empty states, and the 10
 * closest Weather Underground PWS results (name, station ID, distance).
 * Tapping a result invokes [onSelect]; the row shows a saving spinner
 * until the parent confirms via reload.
 *
 * The search location is resolved by the caller with the iOS priority:
 * vineyard latitude/longitude → block/paddock centroid.
 */
@Composable
fun WuNearbyStationsFinder(
    coordinates: Pair<Double, Double>?,
    enabled: Boolean,
    onSearch: suspend (lat: Double, lon: Double) -> List<NearbyWuStation>,
    onSelect: suspend (NearbyWuStation) -> Unit,
    modifier: Modifier = Modifier,
) {
    val vine = LocalVineColors.current
    val scope = rememberCoroutineScope()

    var stations by remember { mutableStateOf<List<NearbyWuStation>>(emptyList()) }
    var isSearching by remember { mutableStateOf(false) }
    var hasSearched by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var savingStationId by remember { mutableStateOf<String?>(null) }
    var saveError by remember { mutableStateOf<String?>(null) }

    fun runSearch() {
        val coords = coordinates ?: return
        if (isSearching) return
        isSearching = true
        errorMessage = null
        saveError = null
        scope.launch {
            try {
                stations = onSearch(coords.first, coords.second)
                hasSearched = true
            } catch (e: Exception) {
                stations = emptyList()
                errorMessage = e.message ?: "Could not find nearby stations. Check your connection and try again."
            } finally {
                isSearching = false
            }
        }
    }

    fun select(station: NearbyWuStation) {
        if (savingStationId != null) return
        savingStationId = station.stationId
        saveError = null
        scope.launch {
            try {
                onSelect(station)
                stations = emptyList()
                hasSearched = false
            } catch (e: Exception) {
                saveError = e.message ?: "Could not save station."
            } finally {
                savingStationId = null
            }
        }
    }

    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(
            onClick = { runSearch() },
            enabled = enabled && coordinates != null && !isSearching,
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (isSearching) {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            } else {
                Icon(Icons.Filled.LocationSearching, contentDescription = null, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(6.dp))
            Text(
                when {
                    isSearching -> "Searching…"
                    hasSearched && stations.isNotEmpty() -> "Search again"
                    else -> "Find nearby WU stations"
                }
            )
        }

        if (coordinates == null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(
                    Icons.Filled.WarningAmber,
                    contentDescription = null,
                    tint = VineColors.Orange,
                    modifier = Modifier.size(14.dp),
                )
                Text(
                    "Vineyard coordinates are required to find nearby Weather Underground stations.",
                    fontSize = 12.sp,
                    color = VineColors.Orange,
                )
            }
        }

        errorMessage?.let {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(
                    Icons.Filled.WarningAmber,
                    contentDescription = null,
                    tint = VineColors.Orange,
                    modifier = Modifier.size(14.dp),
                )
                Text(it, fontSize = 12.sp, color = VineColors.Orange, modifier = Modifier.weight(1f))
            }
        }

        if (hasSearched && !isSearching && stations.isEmpty() && errorMessage == null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(
                    Icons.Filled.SignalWifiOff,
                    contentDescription = null,
                    tint = vine.textSecondary,
                    modifier = Modifier.size(14.dp),
                )
                Text("No nearby Weather Underground stations found.", fontSize = 12.sp, color = vine.textSecondary)
            }
        }

        if (stations.isNotEmpty()) {
            Text(
                "${stations.size} closest station${if (stations.size == 1) "" else "s"} — tap to select",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = vine.textSecondary,
            )
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(vine.appBackground),
            ) {
                stations.forEachIndexed { index, station ->
                    if (index > 0) HorizontalDivider(color = vine.cardBorder, modifier = Modifier.padding(start = 12.dp))
                    NearbyStationRow(
                        station = station,
                        isSaving = savingStationId == station.stationId,
                        enabled = enabled && savingStationId == null,
                        onClick = { select(station) },
                    )
                }
            }
        }

        saveError?.let {
            Text(it, fontSize = 12.sp, color = VineColors.Destructive)
        }
    }
}

@Composable
private fun NearbyStationRow(
    station: NearbyWuStation,
    isSaving: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val vine = LocalVineColors.current
    val trimmedName = station.name?.trim().orEmpty()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (enabled) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (trimmedName.isNotEmpty()) {
                Text(trimmedName, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, maxLines = 2)
                Text(station.stationId, fontSize = 12.sp, color = vine.textSecondary, fontFamily = FontFamily.Monospace)
            } else {
                Text(station.stationId, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = vine.textPrimary, fontFamily = FontFamily.Monospace)
                Text("Unnamed station", fontSize = 12.sp, color = vine.textSecondary)
            }
        }
        station.distanceKm?.let {
            Text("%.1f km".format(it), fontSize = 12.sp, color = vine.textSecondary)
        }
        if (isSaving) {
            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
        }
    }
}
