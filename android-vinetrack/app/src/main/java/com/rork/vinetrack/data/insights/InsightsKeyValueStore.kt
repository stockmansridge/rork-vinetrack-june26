package com.rork.vinetrack.data.insights

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
 *
 * The Android implementation lives in `AndroidInsightsStorage.kt`, deliberately
 * in a different file so this one stays free of framework imports and can be
 * compiled into an ordinary JVM test.
 */
interface InsightsKeyValueStore {
    fun read(key: String): String?

    /** Returns whether the value genuinely reached storage. */
    fun write(key: String, value: String): Boolean

    /** Returns whether the key was genuinely removed. */
    fun remove(key: String): Boolean
}

/**
 * Diagnostic sink for the storage layer.
 *
 * A seam rather than a direct `android.util.Log` call so [VineyardInsightsStore]
 * carries no framework import. [Silent] is the default, so a JVM test neither
 * needs a logger nor trips over one.
 */
fun interface InsightsLogger {
    fun warn(message: String)

    companion object {
        val Silent: InsightsLogger = InsightsLogger { }
    }
}
