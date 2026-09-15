package com.rork.vinetrack.data

import android.content.Context
import android.content.SharedPreferences
import java.util.UUID

/**
 * VineTrack's opaque per-installation identifier for this Android app instance.
 *
 * This is the identifier introduced for client telemetry (SQL 154) and is now
 * shared, because more than one feature needs to say "this particular Android
 * installation" without implying anything about the device or the person.
 *
 * ## What it is
 *
 * A random [UUID] generated once on first use and stored in SharedPreferences.
 * It survives sign-out and app restarts, and is reset only by reinstalling or
 * clearing app data — which is the correct behaviour: a reinstall genuinely is
 * a new installation with its own local state.
 *
 * ## What it deliberately is NOT
 *
 * Never a hardware identity. It is not IMEI, not the hardware serial, not
 * `Settings.Secure.ANDROID_ID`, not the Android advertising ID, not a MAC
 * address, not an email address, and it is not the signed-in user ID standing
 * in for device identity. A single installation may be used by several accounts
 * and one account may use several installations; those are separate concepts.
 *
 * The value and storage key are unchanged from the telemetry implementation, so
 * existing installations keep the identifier they already have — this is an
 * extraction for reuse, not a new identity.
 */
object AndroidInstallationIdentity {

    private const val PREFS_NAME = "vinetrack_telemetry"
    private const val KEY_CLIENT_INSTANCE_ID = "telemetry_client_instance_id"

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /**
     * The stable identifier for this installation, creating it on first call.
     *
     * Synchronized so two concurrent first-callers cannot each mint a different
     * UUID and leave the installation with an unstable identity.
     */
    @Synchronized
    fun current(context: Context): String {
        val store = prefs(context)
        store.getString(KEY_CLIENT_INSTANCE_ID, null)?.let { return it }
        val generated = UUID.randomUUID().toString()
        store.edit().putString(KEY_CLIENT_INSTANCE_ID, generated).apply()
        return generated
    }
}
