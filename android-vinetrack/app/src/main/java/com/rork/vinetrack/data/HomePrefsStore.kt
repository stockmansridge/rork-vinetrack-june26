package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit

/**
 * Lightweight on-device preferences for the Home dashboard. Currently tracks
 * whether the user has dismissed the "Repairs & Growth" info notification, so
 * it stays hidden once closed. Device-local only — never written to the backend.
 */
class HomePrefsStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_home", Context.MODE_PRIVATE)

    fun isInfoCardDismissed(): Boolean = prefs.getBoolean(KEY_INFO_DISMISSED, false)

    fun setInfoCardDismissed(dismissed: Boolean) {
        prefs.edit { putBoolean(KEY_INFO_DISMISSED, dismissed) }
    }

    /** Per-device dismissed app-notice ids, mirroring iOS `AppNoticeService`. */
    fun dismissedNoticeIds(): Set<String> =
        prefs.getStringSet(KEY_DISMISSED_NOTICES, emptySet())?.toSet() ?: emptySet()

    fun addDismissedNoticeId(id: String) {
        val next = dismissedNoticeIds().toMutableSet().apply { add(id) }
        prefs.edit { putStringSet(KEY_DISMISSED_NOTICES, next) }
    }

    private companion object {
        const val KEY_INFO_DISMISSED = "info_card_dismissed"
        const val KEY_DISMISSED_NOTICES = "dismissed_notice_ids_v1"
    }
}
