package com.rork.vinetrack.data

import android.content.Context

/** Local 24-hour Later choice for the same release, not a server preference. */
class ReleaseReminderStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("release_reminders", Context.MODE_PRIVATE)

    fun isSnoozed(build: Long, now: Long): Boolean =
        preferences.getLong("android_build", -1L) == build &&
            now - preferences.getLong("android_later_at", 0L) in 0 until 24L * 60 * 60 * 1000

    fun later(build: Long, now: Long) {
        preferences.edit().putLong("android_build", build).putLong("android_later_at", now).apply()
    }
}
