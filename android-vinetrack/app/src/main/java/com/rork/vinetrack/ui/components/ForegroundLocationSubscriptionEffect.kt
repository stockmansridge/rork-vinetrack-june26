package com.rork.vinetrack.ui.components

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.rork.vinetrack.data.ForegroundLocationSubscriptionController
import com.rork.vinetrack.data.LocationTracker

/** Owns location warming across composition, foreground, service, and permission transitions. */
@Composable
fun ForegroundLocationSubscriptionEffect(tracker: LocationTracker) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val controller = remember(tracker) {
        ForegroundLocationSubscriptionController(
            start = { tracker.startPinFixUpdates() },
            stop = { tracker.stopPinFixUpdates() },
        )
    }
    DisposableEffect(context, lifecycleOwner, controller) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START, Lifecycle.Event.ON_RESUME -> controller.onForegroundChanged(true)
                Lifecycle.Event.ON_STOP -> controller.onForegroundChanged(false)
                else -> Unit
            }
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                controller.onEnvironmentChanged()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        ContextCompat.registerReceiver(
            context,
            receiver,
            IntentFilter(LocationManager.PROVIDERS_CHANGED_ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        controller.onForegroundChanged(lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            context.unregisterReceiver(receiver)
            controller.dispose()
        }
    }
}
