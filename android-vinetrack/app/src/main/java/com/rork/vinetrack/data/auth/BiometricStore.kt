package com.rork.vinetrack.data.auth

import android.content.Context
import androidx.core.content.edit

/**
 * Persists the user's biometric-login preference and the email shown on the
 * lock screen. Mirrors the iOS `BiometricKeychain`: only a preference flag and
 * the account email are stored — never the password. The already-restored
 * Supabase session is what biometrics gate access to.
 */
class BiometricStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_biometric", Context.MODE_PRIVATE)

    var isEnabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, false)
        set(value) = prefs.edit { putBoolean(KEY_ENABLED, value) }

    var savedEmail: String?
        get() = prefs.getString(KEY_EMAIL, null)
        set(value) = prefs.edit { putString(KEY_EMAIL, value) }

    /** Whether the one-time enrollment offer has already been shown. */
    var hasShownEnrollmentPrompt: Boolean
        get() = prefs.getBoolean(KEY_PROMPT_SHOWN, false)
        set(value) = prefs.edit { putBoolean(KEY_PROMPT_SHOWN, value) }

    fun clearAll() {
        prefs.edit {
            remove(KEY_ENABLED)
            remove(KEY_EMAIL)
        }
    }

    private companion object {
        const val KEY_ENABLED = "biometric_enabled"
        const val KEY_EMAIL = "biometric_saved_email"
        const val KEY_PROMPT_SHOWN = "biometric_prompt_shown"
    }
}
