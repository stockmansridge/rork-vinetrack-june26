package com.rork.vinetrack.data.isolation

import android.system.Os
import android.system.OsConstants
import com.rork.vinetrack.BuildConfig

/** Platform durability adapter, unused by live repositories until a separately approved cutover. */
internal object AndroidIsolationSafety {
    val isActivated: Boolean get() = BuildConfig.FIELD_STORAGE_ISOLATION_ACTIVATED

    fun disk(): IsolationDisk = IsolationDisk(syncDirectory = { directory ->
        val descriptor = Os.open(directory.absolutePath, OsConstants.O_RDONLY, 0)
        try { Os.fsync(descriptor) } finally { Os.close(descriptor) }
    })
}
