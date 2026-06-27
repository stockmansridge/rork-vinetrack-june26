package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/**
 * Device-local preference for the Home Setup Wizard, mirroring the iOS
 * `@AppStorage("setupWizardEnabled")` flag. When disabled, the Home wizard
 * card is hidden even if setup is incomplete. Never written to the backend.
 */
class SetupWizardStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_setup_wizard", Context.MODE_PRIVATE)

    fun isEnabled(): Boolean = prefs.getBoolean(KEY_ENABLED, true)

    fun setEnabled(enabled: Boolean) {
        prefs.edit { putBoolean(KEY_ENABLED, enabled) }
    }

    private companion object {
        const val KEY_ENABLED = "setup_wizard_enabled"
    }
}
