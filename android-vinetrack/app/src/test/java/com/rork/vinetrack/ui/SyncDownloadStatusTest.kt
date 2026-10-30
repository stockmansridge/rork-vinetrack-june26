package com.rork.vinetrack.ui

import com.rork.vinetrack.data.HomeReadKnowledge
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class SyncDownloadStatusTest {
    @Test fun onlyFreshSuccessfulOnlineReadsMayClaimCurrent() {
        val values = listOf(null, HomeReadKnowledge.Unknown, HomeReadKnowledge.Cached, HomeReadKnowledge.Fresh)
        for (knowledge in values) for (hasTime in listOf(false, true))
        for (failed in listOf(false, true)) for (online in listOf(false, true)) {
            val actual = syncDownloadStatus(knowledge, hasTime, failed, online)
            assertEquals("knowledge=$knowledge time=$hasTime failed=$failed online=$online",
                knowledge == HomeReadKnowledge.Fresh && !failed && online,
                actual.tone == SyncDownloadTone.Current)
        }
    }

    @Test fun neverDownloadedBlocksDoNotBecomeCurrentWithAnOldTimestamp() {
        for (hasTime in listOf(false, true)) {
            val status = syncDownloadStatus(HomeReadKnowledge.Unknown, hasTime, false, true)
            assertEquals("Not downloaded", status.label)
            assertEquals(SyncDownloadTone.Waiting, status.tone)
        }
    }

    @Test fun failedRefreshRetainsAndLabelsSavedData() {
        val retained = syncDownloadStatus(HomeReadKnowledge.Cached, true, true, true)
        assertEquals("Refresh failed - saved data retained", retained.label)
        assertEquals(SyncDownloadTone.Attention, retained.tone)
        val unavailable = syncDownloadStatus(HomeReadKnowledge.Unknown, false, true, true)
        assertEquals("Download failed", unavailable.label)
        assertEquals(SyncDownloadTone.Attention, unavailable.tone)
    }

    @Test fun successfulEmptyDatasetCanStillBeCurrent() {
        // Freshness is a successful read outcome, not a non-empty row count.
        assertEquals("Up to date", syncDownloadStatus(HomeReadKnowledge.Fresh, true, false, true).label)
        assertEquals("Saved data - offline", syncDownloadStatus(HomeReadKnowledge.Fresh, true, false, false).label)
    }

    @Test fun untrackedDomainTimestampIsOnlyHistoricalEvidence() {
        assertEquals("Last download recorded", syncDownloadStatus(null, true, false, true).label)
        assertNotEquals(SyncDownloadTone.Current, syncDownloadStatus(null, true, false, true).tone)
        assertEquals("Not downloaded", syncDownloadStatus(null, false, false, true).label)
    }
}
