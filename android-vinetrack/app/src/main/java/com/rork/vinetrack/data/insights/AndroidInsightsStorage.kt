package com.rork.vinetrack.data.insights

import android.content.SharedPreferences
import android.util.Log

/**
 * Android-backed implementations of the Vineyard Insights storage seams.
 *
 * Held apart from [InsightsKeyValueStore] so that interface — and everything
 * built on it — stays free of `android.*` imports and can be compiled into an
 * ordinary JVM test. This file is the only place in the Insights storage path
 * that touches the framework.
 *
 * Uses `commit()` rather than `apply()` deliberately. These writes report their
 * own success and the caller spends that Boolean on telling an operator their
 * field capture is safe. `apply()` returns Unit and schedules the disk write
 * for later, so it could only ever be reported as "true, probably" — a hopeful
 * true about a vineyard walk that is not yet on disk. Autosave here is a
 * handful of small writes at human pace, so the synchronous cost is irrelevant
 * next to the honesty.
 */
class SharedPreferencesKeyValueStore(
    private val prefs: SharedPreferences,
) : InsightsKeyValueStore {

    override fun read(key: String): String? =
        runCatching { prefs.getString(key, null) }
            .onFailure { Log.w(TAG, "Reading $key failed: ${it.javaClass.simpleName}") }
            .getOrNull()

    override fun write(key: String, value: String): Boolean =
        commit(key) { it.putString(key, value) }

    override fun remove(key: String): Boolean = commit(key) { it.remove(key) }

    private fun commit(key: String, change: (SharedPreferences.Editor) -> Unit): Boolean =
        runCatching {
            val editor = prefs.edit()
            change(editor)
            val committed = editor.commit()
            if (!committed) Log.w(TAG, "Commit for $key returned false")
            committed
        }.onFailure { Log.w(TAG, "Commit for $key threw: ${it.javaClass.simpleName}") }
            .getOrDefault(false)

    private companion object {
        const val TAG = "VineyardInsights"
    }
}

/** Routes storage diagnostics to logcat in production. */
class AndroidInsightsLogger(private val tag: String = "VineyardInsights") : InsightsLogger {
    override fun warn(message: String) {
        Log.w(tag, message)
    }
}
