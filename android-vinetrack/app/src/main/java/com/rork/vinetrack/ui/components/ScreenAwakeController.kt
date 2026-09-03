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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Single source of truth for whether the display must stay on.
 *
 * Every screen that needs keep-awake REGISTERS A REASON here instead of
 * touching `FLAG_KEEP_SCREEN_ON` itself. Exactly one effect
 * ([ScreenAwakeHost], mounted once at the root) reads the combined condition
 * and applies or clears the window flag. That ordering matters: with one
 * flag-owner, a screen leaving composition can never clear keep-awake while
 * another workflow still requires it.
 *
 * Two independent classes of reason are tracked:
 *
 * - **Preference-gated** ([requestPreferenceScope]) — the historical
 *   behaviour. Honoured only while the user's "Keep screen awake" preference
 *   is ON (live trips, the pin launcher when opened mid-trip, …).
 * - **Forced** ([requestForcedScope]) — Repairs / Growth pin dropping. The
 *   operator is walking rows with the phone in hand and cannot afford the
 *   screen dimming mid-workflow, so this IGNORES the preference entirely.
 *
 * Effective condition:
 * `keepScreenAwakePreference && preferenceScopes.isNotEmpty() || forcedScopes.isNotEmpty()`
 *
 * Only `FLAG_KEEP_SCREEN_ON` is used — never a CPU WakeLock.
 */
object ScreenAwakeController {

    /** Named reasons so overlapping holders are idempotent and debuggable. */
    enum class Reason {
        /** A trip is recording — historical preference-gated hold. */
        ActiveTrip,

        /** The Repairs / Growth quick-action launcher is open (preference-gated). */
        PinLauncherOpen,

        /** Actively dropping Repairs pins — forced, ignores the preference. */
        RepairPinDrop,

        /** Actively dropping Growth Stage pins — forced, ignores the preference. */
        GrowthPinDrop,
    }

    private val _preferenceScopes = MutableStateFlow<Set<Reason>>(emptySet())
    private val _forcedScopes = MutableStateFlow<Set<Reason>>(emptySet())

    /** Reasons currently held that respect the user's keep-awake preference. */
    val preferenceScopes: StateFlow<Set<Reason>> = _preferenceScopes.asStateFlow()

    /** Reasons currently held that override the user's keep-awake preference. */
    val forcedScopes: StateFlow<Set<Reason>> = _forcedScopes.asStateFlow()

    fun addPreferenceScope(reason: Reason) {
        _preferenceScopes.value = _preferenceScopes.value + reason
    }

    fun removePreferenceScope(reason: Reason) {
        _preferenceScopes.value = _preferenceScopes.value - reason
    }

    fun addForcedScope(reason: Reason) {
        _forcedScopes.value = _forcedScopes.value + reason
    }

    fun removeForcedScope(reason: Reason) {
        _forcedScopes.value = _forcedScopes.value - reason
    }

    /**
     * The one effective condition. [preferenceEnabled] is the user's global
     * "Keep screen awake" setting; forced scopes deliberately bypass it.
     */
    fun shouldKeepScreenAwake(
        preferenceEnabled: Boolean,
        preferenceScopes: Set<Reason>,
        forcedScopes: Set<Reason>,
    ): Boolean = (preferenceEnabled && preferenceScopes.isNotEmpty()) || forcedScopes.isNotEmpty()

    /** Test/sign-out hook — drops every hold. */
    fun reset() {
        _preferenceScopes.value = emptySet()
        _forcedScopes.value = emptySet()
    }
}

/**
 * THE single owner of `FLAG_KEEP_SCREEN_ON`. Mount once, at the root of the
 * Activity content, above every screen. No other composable may add or clear
 * the flag.
 */
@Composable
fun ScreenAwakeHost() {
    val context = LocalContext.current
    val preferenceEnabled by AppPreferencesStore.keepScreenAwakeFlow.collectAsStateWithLifecycle()
    val preferenceScopes by ScreenAwakeController.preferenceScopes.collectAsStateWithLifecycle()
    val forcedScopes by ScreenAwakeController.forcedScopes.collectAsStateWithLifecycle()

    val shouldKeepAwake = ScreenAwakeController.shouldKeepScreenAwake(
        preferenceEnabled = preferenceEnabled,
        preferenceScopes = preferenceScopes,
        forcedScopes = forcedScopes,
    )

    DisposableEffect(context, shouldKeepAwake) {
        val window = context.findActivityOrNull()?.window
        if (shouldKeepAwake) {
            window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        onDispose {
            // The host only leaves composition when the Activity content is
            // torn down, at which point the window goes with it.
            window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
}

/**
 * Hold a preference-gated keep-awake reason while [enabled] and this
 * composable are live. Registers with [ScreenAwakeController]; never touches
 * the window flag directly.
 */
@Composable
fun KeepScreenAwake(enabled: Boolean, reason: ScreenAwakeController.Reason) {
    DisposableEffect(enabled, reason) {
        if (enabled) ScreenAwakeController.addPreferenceScope(reason)
        onDispose { ScreenAwakeController.removePreferenceScope(reason) }
    }
}

/**
 * Hold a FORCED keep-awake reason while [enabled] and this composable are
 * live — used by Repairs / Growth pin dropping, which must keep the display on
 * regardless of the user's preference.
 */
@Composable
fun ForceScreenAwake(enabled: Boolean, reason: ScreenAwakeController.Reason) {
    DisposableEffect(enabled, reason) {
        if (enabled) ScreenAwakeController.addForcedScope(reason)
        onDispose { ScreenAwakeController.removeForcedScope(reason) }
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
