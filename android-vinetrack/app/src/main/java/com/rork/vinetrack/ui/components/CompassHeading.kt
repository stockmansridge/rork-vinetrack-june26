package com.rork.vinetrack.ui.components

import android.content.Context
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.view.Surface
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

/**
 * Live magnetometer compass heading (degrees 0–360, magnetic north) from the
 * rotation-vector sensor, or null until the first reading / when the device
 * has no compass. Unlike the GPS fix bearing (course over ground, only present
 * while moving), this reports the direction the phone is *facing* even when
 * standing still — matching how iOS records a pin's "facing" direction via
 * `CLLocationManager` heading updates.
 *
 * The listener is registered only while the calling composable is in
 * composition and is always unregistered on dispose.
 */
@Composable
fun rememberCompassHeading(): State<Double?> {
    val context = LocalContext.current
    val heading = remember { mutableStateOf<Double?>(null) }

    DisposableEffect(context) {
        val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        val sensor = sensorManager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        val listener = object : SensorEventListener {
            private val rotationMatrix = FloatArray(9)
            private val remapped = FloatArray(9)
            private val orientation = FloatArray(3)

            override fun onSensorChanged(event: SensorEvent) {
                SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
                // Remap axes for the current screen rotation so the azimuth
                // tracks the top of the screen (what the operator points at).
                val (axisX, axisY) = when (displayRotation(context)) {
                    Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
                    Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
                    Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
                    else -> SensorManager.AXIS_X to SensorManager.AXIS_Y
                }
                SensorManager.remapCoordinateSystem(rotationMatrix, axisX, axisY, remapped)
                SensorManager.getOrientation(remapped, orientation)
                val azimuth = Math.toDegrees(orientation[0].toDouble())
                heading.value = ((azimuth % 360.0) + 360.0) % 360.0
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        if (sensor != null) {
            sensorManager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_UI)
        }
        onDispose { sensorManager?.unregisterListener(listener) }
    }
    return heading
}

/**
 * Convert a magnetic compass azimuth to true-north degrees at a location by
 * applying the local magnetic declination — parity with iOS `trueHeading`.
 */
fun compassTrueHeading(magneticDegrees: Double, latitude: Double, longitude: Double): Double {
    val declination = GeomagneticField(
        latitude.toFloat(),
        longitude.toFloat(),
        0f,
        System.currentTimeMillis(),
    ).declination.toDouble()
    return ((magneticDegrees + declination) % 360.0 + 360.0) % 360.0
}

/** Current display rotation for compass axis remapping. */
private fun displayRotation(context: Context): Int =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        runCatching { context.display?.rotation }.getOrNull() ?: Surface.ROTATION_0
    } else {
        @Suppress("DEPRECATION")
        (context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager)
            ?.defaultDisplay?.rotation ?: Surface.ROTATION_0
    }
