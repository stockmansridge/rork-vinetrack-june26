package com.rork.vinetrack.data

import androidx.lifecycle.SavedStateHandle
import com.rork.vinetrack.data.model.BunchCountEntry
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.ui.main.*
import org.junit.Assert.*
import org.junit.Test

class Issue49FieldNavigationTest {
    private val ended = TripsKnowledge(setOf("ended", "active"), setOf("active"), TripsListKnowledge.Cached)
    private fun sites(recorded: Int = 4) = (1..19).map { i -> SampleSite("site$i", "block", "Block", i, -33.0, 149.0, i,
        if (i <= recorded) BunchCountEntry(i.toDouble(), "2026-11-02T00:00:00Z", "operator") else null) }

    @Test fun tripTabRevisitClearsCompletedDetailNotLiveTrip() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.setSelectedTripId("ended"); work.openTab(MainTab.Home, ended); work.openTab(MainTab.Trip, ended)
        assertNull(work.selectedTripId.value)
        work.setSelectedTripId("active"); work.openTab(MainTab.Home, ended); work.openTab(MainTab.Trip, ended)
        assertEquals("active", work.selectedTripId.value)
    }
    @Test fun unknownRestoredSelectionSurvivesUntilKnowledgeArrives() {
        val handle = SavedStateHandle(); val work = WorkContextViewModel(handle)
        work.setSelectedTripId("active")
        val restored = WorkContextViewModel(SavedStateHandle(handle.keys().associateWith { handle.get<Any?>(it) }))
        restored.openTab(MainTab.Trip, TripsKnowledge.Unknown)
        assertEquals("active", restored.selectedTripId.value)
        restored.reconcileTripContext(ended); assertEquals("active", restored.selectedTripId.value)
    }
    @Test fun explicitHistoryRemainsOpenUntilFreshTabEntry() {
        val work = WorkContextViewModel(SavedStateHandle())
        work.reconcileTripContext(ended); work.setSelectedTripId("ended")
        work.reconcileTripContext(ended); assertEquals("ended", work.selectedTripId.value)
        work.openTab(MainTab.Trip); assertNull(work.selectedTripId.value)
    }
    @Test fun fourOfNineteenFinishRequiresWarningWithoutFabricatingZeros() {
        val sites = sites(); val before = sites.toList()
        assertTrue(YieldSamplingNavigation.canFinish(sites)); assertTrue(YieldSamplingNavigation.needsPartialConfirmation(sites))
        assertEquals(4, sites.count { it.isRecorded }); assertEquals(15, sites.count { it.bunchCountEntry == null })
        assertEquals(before, sites)
    }
    @Test fun skipNavigatesRouteOrderWithoutRecordingAnything() {
        val sites = sites(); val before = sites.toList()
        assertEquals("site6", YieldSamplingNavigation.next(sites, "site5"))
        assertEquals(before, sites); assertFalse(sites[4].isRecorded)
    }
    @Test fun previousCanReviewRecordedSamples() {
        assertEquals("site4", YieldSamplingNavigation.previous(sites(), "site5"))
        assertNull(YieldSamplingNavigation.previous(sites(), "site1"))
    }
    @Test fun recordNextSkipsJustSavedSiteEvenBeforeRecomposition() {
        assertEquals("site6", YieldSamplingNavigation.next(sites(), "site5", justRecorded = true))
        assertEquals("site5", YieldSamplingNavigation.next(sites(), "site19", justRecorded = true))
    }
    @Test fun explicitRouteOrderUsesNumbersNotInputOrGpsOrder() {
        val reversed = sites().reversed()
        assertEquals((1..19).toList(), YieldSamplingNavigation.ordered(reversed).map { it.siteIndex })
        assertEquals("site6", YieldSamplingNavigation.next(reversed, "site5"))
    }
    @Test fun zeroRecordedCannotFinishAllRecordedNeedsNoPartialWarning() {
        assertFalse(YieldSamplingNavigation.canFinish(sites(0)))
        assertFalse(YieldSamplingNavigation.needsPartialConfirmation(sites(19)))
        assertTrue(YieldSamplingNavigation.canFinish(sites(19)))
    }
}
