package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

internal interface ActiveTripSnapshotStorage {
    fun read(): String?
    fun write(value: String)
    fun writeDurably(value: String): Boolean {
        write(value)
        return true
    }
    fun remove()
}

internal class SharedPreferencesActiveTripSnapshotStorage(
    context: Context,
) : ActiveTripSnapshotStorage {
    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_active_trip", Context.MODE_PRIVATE)

    override fun read(): String? = prefs.getString(KEY_SNAPSHOT, null)

    override fun write(value: String) {
        prefs.edit { putString(KEY_SNAPSHOT, value) }
    }

    override fun writeDurably(value: String): Boolean =
        prefs.edit().putString(KEY_SNAPSHOT, value).commit()

    override fun remove() {
        prefs.edit { remove(KEY_SNAPSHOT) }
    }

    private companion object {
        const val KEY_SNAPSHOT = "active_trip_snapshot_json"
    }
}
