package com.rork.vinetrack.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Navigation
import androidx.compose.material.icons.filled.PushPin
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.google.android.gms.maps.model.Dash
import com.google.android.gms.maps.model.Gap
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.MapsComposeExperimentalApi
import com.google.maps.android.compose.MarkerComposable
import com.google.maps.android.compose.MarkerState
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.ui.components.estimatedCameraPosition
import com.rork.vinetrack.ui.components.fitToContent
import com.rork.vinetrack.ui.components.hasDeviceLocationPermission
import com.rork.vinetrack.ui.components.isValidMapCoordinate
import com.rork.vinetrack.ui.theme.LocalVineColors
import com.rork.vinetrack.ui.theme.VineColors
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/** Dashed guide-line colour matching the iOS `.blue` polyline. */
private val DirectLineBlue = Color(0xFF2E7CF6)

/**
 * In-app directions view for a pin (iOS `PinDirectionsSheet` parity): a
 * full-screen satellite map showing the user's location dot, the pin, and a
 * dashed straight line between them. Vineyard driving is off-road, so this
 * intentionally ignores the road network — no turn-by-turn, just the direct
 * line, live distance and a bearing arrow.
 */
@OptIn(ExperimentalMaterial3Api::class, MapsComposeExperimentalApi::class)
@Composable
internal fun PinDirectionsDialog(
    pin: Pin,
    color: Color,
    userLocation: Pair<Double, Double>?,
    onDismiss: () -> Unit,
) {
    val vine = LocalVineColors.current
    val context = LocalContext.current
    val hasLocationPermission = remember { hasDeviceLocationPermission(context) }

    val pinLatLng = remember(pin.latitude, pin.longitude) {
        val lat = pin.latitude
        val lon = pin.longitude
        if (isValidMapCoordinate(lat, lon)) LatLng(lat ?: 0.0, lon ?: 0.0) else null
    }
    val userLatLng = userLocation
        ?.takeIf { isValidMapCoordinate(it.first, it.second) }
        ?.let { LatLng(it.first, it.second) }

    // Seed the camera on whatever is known immediately so the map never opens
    // at the world-default position while tiles load.
    val cameraPositionState = rememberCameraPositionState {
        estimatedCameraPosition(listOfNotNull(pinLatLng, userLatLng))?.let { position = it }
    }
    var mapLoaded by remember { mutableStateOf(false) }
    // Frame user + pin together once both are known; never re-frame after that
    // so the 10s location refresh doesn't fight a manual pan/zoom.
    var framedWithUser by remember { mutableStateOf(false) }
    LaunchedEffect(mapLoaded, userLatLng != null) {
        if (!mapLoaded || framedWithUser) return@LaunchedEffect
        val points = listOfNotNull(pinLatLng, userLatLng)
        if (points.isEmpty()) return@LaunchedEffect
        cameraPositionState.fitToContent(
            points = points,
            paddingPx = 160,
            singlePointZoom = 17f,
            animate = true,
        )
        if (userLatLng != null) framedWithUser = true
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Scaffold(
            containerColor = vine.appBackground,
            topBar = {
                TopAppBar(
                    title = { Text("Directions") },
                    actions = { TextButton(onClick = onDismiss) { Text("Done") } },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = vine.appBackground),
                )
            },
        ) { padding ->
            Column(modifier = Modifier.fillMaxSize().padding(padding)) {
                Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
                    GoogleMap(
                        modifier = Modifier.fillMaxSize(),
                        cameraPositionState = cameraPositionState,
                        properties = MapProperties(
                            // Satellite imagery by default (iOS `.hybrid` parity)
                            // — directions here are cross-country, not on roads.
                            mapType = MapType.HYBRID,
                            isMyLocationEnabled = hasLocationPermission,
                        ),
                        uiSettings = MapUiSettings(
                            zoomControlsEnabled = false,
                            mapToolbarEnabled = false,
                            myLocationButtonEnabled = false,
                        ),
                        onMapLoaded = { mapLoaded = true },
                    ) {
                        // Straight guide line from the current fix to the pin,
                        // dashed like the iOS MapPolyline (ignores roads).
                        if (userLatLng != null && pinLatLng != null) {
                            Polyline(
                                points = listOf(userLatLng, pinLatLng),
                                color = DirectLineBlue,
                                width = 9f,
                                pattern = listOf(Dash(26f), Gap(14f)),
                                zIndex = 1f,
                            )
                        }
                        if (pinLatLng != null) {
                            val markerState = remember(pinLatLng) { MarkerState(position = pinLatLng) }
                            MarkerComposable(
                                keys = arrayOf(pin.id, color.value.toString()),
                                state = markerState,
                                title = pin.displayTitle,
                                anchor = Offset(0.5f, 0.5f),
                                zIndex = 2f,
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(36.dp)
                                        .clip(CircleShape)
                                        .background(
                                            Brush.verticalGradient(
                                                listOf(color, lerp(color, Color.Black, 0.16f)),
                                            ),
                                        ),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(
                                        Icons.Filled.PushPin,
                                        contentDescription = null,
                                        tint = Color.White,
                                        modifier = Modifier.size(17.dp),
                                    )
                                }
                            }
                        }
                    }
                }

                // Bottom info bar: name + live distance + bearing arrow
                // (iOS PinDirectionsSheet footer parity).
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(vine.cardBackground)
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Text(
                            pin.displayTitle,
                            fontSize = 17.sp,
                            fontWeight = FontWeight.Bold,
                            color = vine.textPrimary,
                        )
                        Text(
                            directionsDistanceText(pinLatLng, userLatLng),
                            fontSize = 14.sp,
                            color = vine.textSecondary,
                        )
                        Text(
                            "Direct line \u2014 ignores roads",
                            fontSize = 12.sp,
                            color = vine.textSecondary,
                        )
                    }
                    if (userLatLng != null && pinLatLng != null) {
                        Icon(
                            Icons.Filled.Navigation,
                            contentDescription = "Bearing to pin",
                            tint = VineColors.Primary,
                            modifier = Modifier
                                .size(30.dp)
                                .rotate(bearingDegrees(userLatLng, pinLatLng).toFloat()),
                        )
                    }
                }
            }
        }
    }
}

/** "123m away" using the shared locale-aware short-distance format. */
private fun directionsDistanceText(pinLatLng: LatLng?, userLatLng: LatLng?): String {
    if (pinLatLng == null) return "This pin has no saved location"
    if (userLatLng == null) return "Waiting for a GPS fix\u2026"
    val metres = haversineMetres(
        userLatLng.latitude,
        userLatLng.longitude,
        pinLatLng.latitude,
        pinLatLng.longitude,
    )
    return "${formatShortDistance(metres)} away"
}

/** Initial great-circle bearing from [from] to [to] in degrees (iOS parity). */
private fun bearingDegrees(from: LatLng, to: LatLng): Double {
    val lat1 = Math.toRadians(from.latitude)
    val lat2 = Math.toRadians(to.latitude)
    val dLon = Math.toRadians(to.longitude - from.longitude)
    val y = sin(dLon) * cos(lat2)
    val x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    return Math.toDegrees(atan2(y, x))
}
