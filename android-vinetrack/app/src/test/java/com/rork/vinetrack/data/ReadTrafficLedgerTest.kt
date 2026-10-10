package com.rork.vinetrack.data

import org.junit.Assert.*
import org.junit.Test

/** Counter semantics only; these inputs are not production HTTP measurements. */
class ReadTrafficLedgerTest {
    @Test fun cumulativeProgressCountsBytesOnceIncludingPartialResponses() {
        val ledger = ReadTrafficLedger()
        val attempt = ledger.begin(ReadTrafficLedger.Dataset.WORK_TASKS, "fingerprint", false)
        ledger.received(attempt, 10); ledger.received(attempt, 10); ledger.received(attempt, 5); ledger.received(attempt, 23)
        assertEquals(ReadTrafficLedger.Totals(1, 0, 0, 23), ledger.snapshot().values.single())
    }
    @Test fun retryAndRepeatAreActualSeparateAttemptsNotSkippedRequests() {
        val ledger = ReadTrafficLedger()
        ledger.received(ledger.begin(ReadTrafficLedger.Dataset.WORK_TASKS, "same", false), 17)
        ledger.received(ledger.begin(ReadTrafficLedger.Dataset.WORK_TASKS, "same", true), 29)
        ledger.received(ledger.begin(ReadTrafficLedger.Dataset.WORK_TASKS, "same", false), 29)
        assertEquals(ReadTrafficLedger.Totals(3, 2, 1, 75), ledger.snapshot().values.single())
    }
    @Test fun clearRejectsLateBytesAndDoesNotCarryRepeatedRequestsAcrossCapture() {
        val ledger = ReadTrafficLedger()
        val old = ledger.begin(ReadTrafficLedger.Dataset.WORK_TASKS, "same", false)
        ledger.clear(); ledger.received(old, 100)
        assertTrue(ledger.snapshot().isEmpty())
        ledger.begin(ReadTrafficLedger.Dataset.WORK_TASKS, "same", false)
        assertEquals(0, ledger.snapshot().values.single().repeated)
    }
    @Test fun datasetTotalsAndFingerprintsRemainBoundedWithoutExportingKeys() {
        val ledger = ReadTrafficLedger()
        repeat(2001) { ledger.begin(ReadTrafficLedger.Dataset.OTHER, "digest-$it", false) }
        assertEquals(1, ledger.evictedFingerprints())
        ledger.begin(ReadTrafficLedger.Dataset.PINS, "pin-digest", false)
        assertEquals(2001, ledger.snapshot()[ReadTrafficLedger.Dataset.OTHER]?.attempts)
        assertEquals(1, ledger.snapshot()[ReadTrafficLedger.Dataset.PINS]?.attempts)
        assertFalse(ledger.snapshot().toString().contains("digest"))
    }
}
