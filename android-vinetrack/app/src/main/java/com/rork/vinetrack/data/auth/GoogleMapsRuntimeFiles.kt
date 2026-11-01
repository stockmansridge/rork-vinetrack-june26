package com.rork.vinetrack.data.auth

import android.system.Os
import android.system.OsConstants
import java.io.File

/**
 * Exact SDK-owned runtime paths, NOT retained vineyard operations or ownership evidence.
 *
 * These names were observed together in the affected installation. The Maps parameter
 * caches and SDK token file must not be interpreted as unsigned field work. Their opaque
 * bytes are left entirely to the SDK: never read, log, delete, migrate or adopt them here.
 * In particular, _m_t can contain SDK token material; it must not enter support output.
 *
 * Only three exact top-level names are covered. No DATA_ prefix, extension, directory,
 * backup, foreign-package suffix or unknown-file exemption is granted. The existing
 * validators still inspect every business store and enforce account/vineyard authority.
 */
internal object GoogleMapsRuntimeFiles {
    fun recognises(name: String, packageName: String): Boolean {
        // A trusted Context supplies this in production; reject malformed caller input too.
        if (!packageName.matches(Regex("[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z][A-Za-z0-9_]*)+"))) return false
        return name == "SavedClientParameters.data.cs" || name == "_m_t" ||
            name == "DATA_ServerControlledParametersManager.data.v1.$packageName"
    }

    /** Read metadata only. A familiar name never authorises a directory or a file alias. */
    fun validate(file: File, filesRoot: File, packageName: String) {
        check(recognises(file.name, packageName))
        val root = filesRoot.absoluteFile
        check(root == root.canonicalFile)
        check(file.absoluteFile == File(root, file.name) && file.absoluteFile == file.canonicalFile)
        val rootStat = Os.lstat(root.path)
        check(OsConstants.S_ISDIR(rootStat.st_mode))
        val before = Os.lstat(file.path)
        check(OsConstants.S_ISREG(before.st_mode) && before.st_nlink == 1L &&
            before.st_dev == rootStat.st_dev && before.st_uid == rootStat.st_uid)
        // No opening or parsing. Check path identity again; SDK size/mtime changes are
        // expected runtime activity and must not become new field-recovery blockers.
        check(file.absoluteFile == file.canonicalFile)
        val after = Os.lstat(file.path)
        check(OsConstants.S_ISREG(after.st_mode) && after.st_nlink == 1L &&
            after.st_dev == before.st_dev && after.st_ino == before.st_ino && after.st_uid == before.st_uid)
    }
}
