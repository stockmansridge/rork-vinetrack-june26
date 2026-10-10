package com.rork.vinetrack.data.isolation

import android.content.Context
import java.io.File

/** Resolves only OS-supplied app roots; individual business files still undergo strict symlink checks. Unwired. */
internal class AndroidFieldStorageRoots(context: Context) {
    val files: File = context.applicationContext.filesDir.canonicalFile
    val preferences: File = File(File(context.applicationContext.applicationInfo.dataDir).canonicalFile, "shared_prefs")
    val cache: File = context.applicationContext.cacheDir.canonicalFile
    val protected: File = File(files, "field-isolation-v2")

    fun inventory(): List<RawEvidenceSource> = ReviewedBusinessInventory.sources(preferences, files, cache, setOf(protected))
}
