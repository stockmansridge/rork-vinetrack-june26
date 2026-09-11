package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PinAisleObservationLockTest {
    private val now = 1_000_000_000_000L

    private fun item(
        millisecondsAgo: Long,
        block: String?,
        aisle: Double?,
        qualified: Boolean = true,
    ) = PinAisleObservationLock.Evidence(
        observedAtElapsedRealtimeNanos = now - millisecondsAgo * 1_000_000L,
        paddockId = block,
        aisleNumber = aisle,
        isQualified = qualified,
    )

    @Test fun requiresSupportingObservationsNotElapsedTime() {
        val two = listOf(item(2_000, "a", 12.5), item(1_000, "a", 12.5))
        assertNull(PinAisleObservationLock.resolve(two, now))
        assertEquals(12.5, PinAisleObservationLock.resolve(two + item(0, "a", 12.5), now)?.aisleNumber)
    }

    @Test fun holdsBriefOutlierAndSwitchesOnSustainedContradiction() {
        val established = listOf(item(6_000, "a", 12.5), item(5_000, "a", 12.5), item(4_000, "a", 12.5))
        val oneOutlier = established + item(3_000, "a", 13.5)
        assertEquals(12.5, PinAisleObservationLock.resolve(oneOutlier, now)?.aisleNumber)
        val switched = oneOutlier + listOf(item(2_000, "a", 13.5), item(1_000, "a", 13.5))
        assertEquals(13.5, PinAisleObservationLock.resolve(switched, now)?.aisleNumber)
    }

    @Test fun blockChangeHeadlandAndExpiryRequireFreshSupport() {
        val established = listOf(item(6_000, "a", 12.5), item(5_000, "a", 12.5), item(4_000, "a", 12.5))
        assertNull(PinAisleObservationLock.resolve(established + item(1_000, "b", 12.5), now))
        assertNull(PinAisleObservationLock.resolve(established + item(1_000, "a", null), now))
        val expired = listOf(item(23_000, "a", 12.5), item(22_000, "a", 12.5), item(21_000, "a", 12.5))
        assertNull(PinAisleObservationLock.resolve(expired, now))
    }
}
