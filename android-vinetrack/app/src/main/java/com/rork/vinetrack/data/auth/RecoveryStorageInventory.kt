package com.rork.vinetrack.data.auth

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import com.rork.vinetrack.BuildConfig
import java.io.File

/**
 * Read-only support metadata, deliberately separate from AccountTransitionEvidence.
 * Does not open any file, load preferences, recurse into entries, or change admission.
 */
internal object RecoveryStorageInventory {
    private const val MAX_ENTRIES_PER_ROOT = 256

    fun capture(context: Context): RecoveryStorageReport {
        fun root(area: RecoveryStorageReport.Area, path: () -> File): RecoveryStorageReport.Root =
            try { inspectRoot(area, path()) } catch (_: Exception) {
                RecoveryStorageReport.Root(area, RecoveryStorageReport.Status.UNREADABLE)
            }
        return RecoveryStorageReport(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE, listOf(
            // Canonicalise only the trusted Context roots; never resolve a child link.
            root(RecoveryStorageReport.Area.FILES) { context.filesDir.canonicalFile },
            root(RecoveryStorageReport.Area.PREFERENCES) {
                File(File(context.applicationInfo.dataDir).canonicalFile, "shared_prefs")
            },
            root(RecoveryStorageReport.Area.LEGACY_CAMERA) {
                File(context.cacheDir.canonicalFile, "camera-captures")
            },
        ))
    }

    private fun inspectRoot(area: RecoveryStorageReport.Area, root: File): RecoveryStorageReport.Root {
        val stat = try { Os.lstat(root.path) } catch (error: ErrnoException) {
            return RecoveryStorageReport.Root(area, if (error.errno == OsConstants.ENOENT)
                RecoveryStorageReport.Status.ABSENT else RecoveryStorageReport.Status.UNREADABLE)
        }
        if (OsConstants.S_ISLNK(stat.st_mode) || root.absoluteFile != root.canonicalFile)
            return RecoveryStorageReport.Root(area, RecoveryStorageReport.Status.LINK_OR_ALIAS)
        if (!OsConstants.S_ISDIR(stat.st_mode))
            return RecoveryStorageReport.Root(area, RecoveryStorageReport.Status.NOT_A_DIRECTORY)
        val listed = root.listFiles() ?: return RecoveryStorageReport.Root(area, RecoveryStorageReport.Status.UNREADABLE)
        val entries = listed.sortedBy { it.name }.take(MAX_ENTRIES_PER_ROOT).map { file ->
            try {
                val metadata = Os.lstat(file.path)
                val kind = when {
                    OsConstants.S_ISLNK(metadata.st_mode) -> RecoveryStorageReport.Kind.SYMBOLIC_LINK
                    OsConstants.S_ISREG(metadata.st_mode) -> RecoveryStorageReport.Kind.REGULAR_FILE
                    OsConstants.S_ISDIR(metadata.st_mode) -> RecoveryStorageReport.Kind.DIRECTORY
                    else -> RecoveryStorageReport.Kind.OTHER
                }
                RecoveryStorageReport.Entry(file.name, kind,
                    if (kind == RecoveryStorageReport.Kind.REGULAR_FILE) metadata.st_size else null,
                    kind == RecoveryStorageReport.Kind.REGULAR_FILE && metadata.st_nlink > 1L)
            } catch (_: Exception) {
                RecoveryStorageReport.Entry(file.name, RecoveryStorageReport.Kind.METADATA_UNAVAILABLE)
            }
        }
        return RecoveryStorageReport.Root(area, RecoveryStorageReport.Status.PRESENT, listed.size, entries)
    }
}
