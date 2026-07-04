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
 * position. The current zoom is preserved when it is already at a sensible
 * vineyard working level (16–21); otherwise it snaps to a default setup zoom
 * of 18. Failure states are surfaced through [onMessage] instead of failing
 * silently, and a spinner replaces the icon while a fix is being acquired.
 */
@Composable
fun MapMyLocationButton(
    camera: CameraPositionState,
    onMessage: (String) -> Unit,
    modifier: Modifier = Modifier,
    containerColor: Color = Color(0xCC1C1C1E),
    contentColor: Color = Color.White,
    onPermissionGranted: () -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val tracker = remember { LocationTracker(context) }
    var isLocating by remember { mutableStateOf(false) }

    fun goToCurrentLocation() {
        if (isLocating) return
        scope.launch {
            isLocating = true
            val fix = tracker.currentLocation()
            isLocating = false
            if (fix == null) {
                onMessage("Current location unavailable. Try again when GPS has a fix.")
                return@launch
            }
            val currentZoom = camera.position.zoom
            val targetZoom = if (currentZoom in 16f..21f) currentZoom else 18f
            runCatching {
                camera.animate(
                    CameraUpdateFactory.newLatLngZoom(LatLng(fix.latitude, fix.longitude), targetZoom),
                )
            }
        }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { grants ->
        if (grants.values.any { it }) {
            onPermissionGranted()
            goToCurrentLocation()
        } else {
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
                contentDescription = "Go to current location",
                tint = contentColor,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}
