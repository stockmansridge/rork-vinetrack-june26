package com.rork.vinetrack.ui.components

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.model.LatLng
import com.google.maps.android.compose.CameraPositionState
import com.rork.vinetrack.data.LocationTracker
import kotlinx.coroutines.launch

/**
 * Floating "go to current location" map control shared across VineTrack maps.
 *
 * Handles the full flow: requests location permission when missing, fetches a
 * one-shot fix via [LocationTracker.currentLocation] (cached fix first, then a
 * fresh high-accuracy fix with timeout), and animates the camera to the user's
 * position. Callers can provide [targetZoom] when their renderer requires a
 * specific one-time zoom; otherwise the current sensible vineyard zoom is
 * preserved. Failure states are surfaced through [onMessage] instead of failing
 * silently, and a spinner replaces the icon while a fix is being acquired.
 */
@Composable
fun MapMyLocationButton(
    camera: CameraPositionState,
    onMessage: (String) -> Unit,
    modifier: Modifier = Modifier,
    containerColor: Color = Color(0xCC1C1C1E),
    contentColor: Color = Color.White,
    contentDescription: String = "Go to current location",
    targetZoom: Float? = null,
    onPermissionGranted: () -> Unit = {},
    onRequestStateChanged: (Boolean) -> Unit = {},
    onCentred: () -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val tracker = remember { LocationTracker(context) }
    var isLocating by remember { mutableStateOf(false) }

    fun goToCurrentLocation() {
        if (isLocating) return
        scope.launch {
            isLocating = true
            onRequestStateChanged(true)
            try {
                val fix = tracker.currentLocation()
                if (fix == null) {
                    onMessage("Current location unavailable. Try again when GPS has a fix.")
                    return@launch
                }
                val currentZoom = camera.position.zoom
                val requestedZoom = targetZoom ?: if (currentZoom in 16f..21f) currentZoom else 18f
                runCatching {
                    camera.animate(
                        CameraUpdateFactory.newLatLngZoom(LatLng(fix.latitude, fix.longitude), requestedZoom),
                    )
                }.onSuccess {
                    onCentred()
                }
            } finally {
                isLocating = false
                onRequestStateChanged(false)
            }
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { grants ->
        isLocating = false
        if (grants.values.any { it }) {
            onPermissionGranted()
            goToCurrentLocation()
        } else {
            onRequestStateChanged(false)
            onMessage("Location permission is needed to centre the map on your current position.")
        }
    }

    Box(
        modifier = modifier
            .size(40.dp)
            .clip(CircleShape)
            .background(containerColor)
            .clickable(enabled = !isLocating) {
                if (tracker.hasPermission) {
                    goToCurrentLocation()
                } else {
                    isLocating = true
                    onRequestStateChanged(true)
                    permissionLauncher.launch(
                        arrayOf(
                            android.Manifest.permission.ACCESS_FINE_LOCATION,
                            android.Manifest.permission.ACCESS_COARSE_LOCATION,
                        ),
                    )
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        if (isLocating) {
            CircularProgressIndicator(
                modifier = Modifier.size(18.dp),
                strokeWidth = 2.dp,
                color = contentColor,
            )
        } else {
            Icon(
                Icons.Filled.MyLocation,
                contentDescription = contentDescription,
                tint = contentColor,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}
