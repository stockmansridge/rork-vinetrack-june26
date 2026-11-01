package com.rork.vinetrack.data.auth

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pure JVM tests for the exact AndroidX writer payload; file/identity tests are native. */
class ProfileInstallerSkipContractTest {
    private fun marker(timestamp: Long): ByteArray = ByteArrayOutputStream().use { bytes ->
        DataOutputStream(bytes).use { it.writeLong(timestamp) }
        bytes.toByteArray()
    }

    @Test fun acceptsCurrentInstallTimestamp() = assertTrue(ProfileInstallerSkipContract.accepts(marker(100L), 100L))
    @Test fun acceptsPreviousInstallAfterInPlaceUpdate() = assertTrue(ProfileInstallerSkipContract.accepts(marker(99L), 100L))
    @Test fun acceptsOldestPositiveTimestamp() = assertTrue(ProfileInstallerSkipContract.accepts(marker(1L), 100L))
    @Test fun acceptsLongBoundaryWithoutOverflow() = assertTrue(ProfileInstallerSkipContract.accepts(marker(Long.MAX_VALUE), Long.MAX_VALUE))
    @Test fun rejectsFutureTimestamp() = assertFalse(ProfileInstallerSkipContract.accepts(marker(101L), 100L))
    @Test fun rejectsZeroTimestamp() = assertFalse(ProfileInstallerSkipContract.accepts(marker(0L), 100L))
    @Test fun rejectsNegativeTimestamp() = assertFalse(ProfileInstallerSkipContract.accepts(marker(-1L), 100L))
    @Test fun rejectsMinimumLongTimestamp() = assertFalse(ProfileInstallerSkipContract.accepts(marker(Long.MIN_VALUE), 100L))
    @Test fun rejectsUnknownPackageTimestamp() = assertFalse(ProfileInstallerSkipContract.accepts(marker(1L), 0L))
    @Test fun rejectsNegativePackageTimestamp() = assertFalse(ProfileInstallerSkipContract.accepts(marker(1L), -1L))
    @Test fun rejectsEmptyPayload() = assertFalse(ProfileInstallerSkipContract.accepts(byteArrayOf(), 100L))
    @Test fun rejectsEveryTruncation() {
        for (length in 1..7) assertFalse(ProfileInstallerSkipContract.accepts(marker(100L).copyOf(length), 100L))
    }
    @Test fun rejectsTrailingBytes() = assertFalse(ProfileInstallerSkipContract.accepts(marker(100L) + byteArrayOf(0), 100L))
    @Test fun rejectsDifferentProfileVerifierFormat() = assertFalse(ProfileInstallerSkipContract.accepts(ByteArray(24), 100L))
    @Test fun rejectsTextDisguisedAsMarker() = assertFalse(ProfileInstallerSkipContract.accepts("12345678".toByteArray(), 100L))
    @Test fun rejectsLittleEndianTimestamp() = assertFalse(ProfileInstallerSkipContract.accepts(marker(100L).reversedArray(), 100L))
}
