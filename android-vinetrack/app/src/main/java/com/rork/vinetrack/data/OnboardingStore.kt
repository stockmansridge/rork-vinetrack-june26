package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/**
 * Device-local flag for whether the first-launch welcome/onboarding flow has
 * been completed, mirroring the iOS `OnboardingState`
 * (`vinetrack_onboarding_completed_v1` in UserDefaults). Never written to the
 * backend — it only gates the intro carousel shown once after sign-in.
 */
class OnboardingStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_onboarding", Context.MODE_PRIVATE)

    val isCompleted: Boolean
        get() = prefs.getBoolean(KEY_COMPLETED, false)

    fun markCompleted() {
        prefs.edit { putBoolean(KEY_COMPLETED, true) }
    }

    fun reset() {
        prefs.edit { remove(KEY_COMPLETED) }
    }

    private companion object {
        const val KEY_COMPLETED = "onboarding_completed_v1"
    }
}
