package com.rork.vinetrack.ui.components

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

/**
 * True when the app holds a foreground location permission (fine or coarse).
 * Used to gate Google Map `isMyLocationEnabled`, which throws a
 * SecurityException when enabled without a granted permission.
 */
fun hasDeviceLocationPermission(context: Context): Boolean =
    ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.ACCESS_FINE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
