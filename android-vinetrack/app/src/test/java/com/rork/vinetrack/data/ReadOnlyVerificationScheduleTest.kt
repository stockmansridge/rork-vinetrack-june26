package com.rork.vinetrack.data

import org.junit.Assert.*
import org.junit.Test

class ReadOnlyVerificationScheduleTest {
    data class Evidence(val account: String = "owner", val epoch: Long = 1, val vineyard: String = "vineyard", val dependencies: String = "all-acked", val end: String = "first-end")
    @Test fun sameEvidenceNeverRestartsThreeReadScheduleOnRepeatedSyncPasses() {
        val schedule = ReadOnlyVerificationSchedule<String, Evidence>()
        val evidence = Evidence()
        assertTrue(schedule.claim("trip", evidence)); repeat(100) { assertFalse(schedule.claim("trip", evidence)) }
        assertEquals(listOf(0L, 5_000L, 30_000L), schedule.delaysMillis)
    }
    @Test fun freshAcknowledgementInvalidatesStaleWorkerAndAllowsNewBoundedReads() {
        val schedule = ReadOnlyVerificationSchedule<String, Evidence>(); val before = Evidence(dependencies = "pending")
        assertTrue(schedule.claim("trip", before)); assertTrue(schedule.claim("trip", Evidence()))
        assertFalse(schedule.isCurrent("trip", before)); assertTrue(schedule.isCurrent("trip", Evidence()))
    }
    @Test fun accountEpochVineyardAndEndAreDistinctEvidenceNotReusableProof() {
        val schedule = ReadOnlyVerificationSchedule<String, Evidence>(); val a = Evidence()
        listOf(a, a.copy(account = "other"), a.copy(epoch = 2), a.copy(vineyard = "other"), a.copy(end = "changed")).forEach {
            assertTrue(schedule.claim("trip", it)); assertFalse(schedule.claim("trip", it))
        }
    }
    @Test fun independentTripsDoNotVetoEachOther() {
        val schedule = ReadOnlyVerificationSchedule<String, Evidence>()
        assertTrue(schedule.claim("a", Evidence())); assertTrue(schedule.claim("b", Evidence()))
        assertTrue(schedule.isCurrent("a", Evidence())); assertFalse(schedule.isCurrent("missing", Evidence()))
    }
}
