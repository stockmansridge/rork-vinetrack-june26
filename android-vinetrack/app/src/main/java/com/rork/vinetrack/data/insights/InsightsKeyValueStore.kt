package com.rork.vinetrack.data.insights

import android.content.SharedPreferences
import android.util.Log

/**
 * The narrow persistence boundary under [VineyardInsightsStore].
 *
 * Exists so the durability rules — encode before write, a failed write is never
 * a deletion, a real commit result — can be exercised in a plain JVM test.
 * `SharedPreferences` cannot be instantiated off-device, so without this seam
 * the only way to "test" those rules would be to read the code and hope.
 *
 * Note the shape: [write] takes a NON-NULL value and [remove] is a separate
 * operation. A single `write(key, value?)` where null meant "delete" would make
 * a failed encode indistinguishable from a deliberate deletion — which is
 * exactly how a failed save becomes data loss.
 */
interface InsightsKeyValueStore {
    fun read(key: String): String?

    /** Returns whether the value genuinely reached storage. */
    fun write(key: String, value: String): Boolean

    /** Returns whether the key was genuinely removed. */
    fun remove(key: String): Boolean
}

/**
 * Production implementation.
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
