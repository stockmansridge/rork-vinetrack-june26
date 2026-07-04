package com.rork.vinetrack.ui.components

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.WindowManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rork.vinetrack.data.AppPreferencesStore

/**
 * Keeps the device screen awake while [enabled] is true, mirroring the iOS
 * `ScreenAwakeManager` (`UIApplication.isIdleTimerDisabled`). The window flag
 * is only applied while this composable is in composition AND the user's
 * "Keep screen awake during trips" preference allows it, and it is always
 * cleared on dispose so the flag can never be left stuck on after a trip
 * ends or the user leaves the screen.
 *
 * Preference changes apply live via [AppPreferencesStore.keepScreenAwakeFlow],
 * matching the iOS `preferenceDidChange()` behaviour when the toggle is
 * flipped mid-trip.
 */
@Composable
fun KeepScreenAwake(enabled: Boolean) {
    val context = LocalContext.current
    val preferenceEnabled by AppPreferencesStore.keepScreenAwakeFlow.collectAsStateWithLifecycle()
    val shouldKeepAwake = enabled && preferenceEnabled

    DisposableEffect(context, shouldKeepAwake) {
        val window = context.findActivityOrNull()?.window
        if (window != null && shouldKeepAwake) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        onDispose {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
}

/** Walks the [ContextWrapper] chain to find the hosting [Activity], if any. */
private fun Context.findActivityOrNull(): Activity? {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}
