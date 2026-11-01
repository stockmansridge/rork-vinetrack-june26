package com.rork.vinetrack.data.auth

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * AndroidX ProfileInstaller.noteProfileWrittenFor writes exactly one big-endian long:
 * PackageInfo.lastUpdateTime. This is runtime bookkeeping, not retained vineyard work.
 * An older positive timestamp is valid after an in-place update; do not require equality.
 * The caller must additionally verify the exact root/name, regular-file type, link count
 * and descriptor identity. A matching name alone is never sufficient.
 */
internal object ProfileInstallerSkipContract {
    const val FILE_NAME = "profileinstaller_profileWrittenFor_lastUpdateTime.dat"
    const val BYTE_COUNT = 8

    fun accepts(bytes: ByteArray, packageLastUpdateTime: Long): Boolean {
        if (bytes.size != BYTE_COUNT || packageLastUpdateTime <= 0L) return false
        val writtenFor = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN).long
        return writtenFor in 1L..packageLastUpdateTime
    }
}
