package com.rork.vinetrack.data

import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.chemical.ChemicalLookupAdvisory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The slow-search advisory (A2) — pins the canonical wording and the state
 * machine behind the bright-green notice so both platforms stay word-for-word
 * aligned and a duplicate Search tap can never fire a second request.
 */
class ChemicalLookupAdvisoryTest {

    // ---- Canonical wording, pinned ----

    @Test
    fun `the idle advisory is the exact agreed sentence`() {
        assertEquals(
            "Chemical search can take a little time while VineTrack checks current " +
                "registration and label information.",
            ChemicalLookupAdvisory.IDLE_TEXT,
        )
        assertEquals(ChemicalLookupAdvisory.IDLE_TEXT, ChemicalLookupAdvisory.text(isSearching = false))
    }

    @Test
    fun `the active advisory says to keep the screen open`() {
        assertEquals(
            "Searching current registration and label information — this can take a " +
                "little time. Please keep this screen open.",
            ChemicalLookupAdvisory.SEARCHING_TEXT,
        )
        assertEquals(ChemicalLookupAdvisory.SEARCHING_TEXT, ChemicalLookupAdvisory.text(isSearching = true))
    }

    @Test
    fun `the advisory never fakes progress`() {
        // No percentage, no invented completion time — in either state.
        for (text in listOf(ChemicalLookupAdvisory.IDLE_TEXT, ChemicalLookupAdvisory.SEARCHING_TEXT)) {
            assertFalse(text.contains("%"))
            assertFalse(text.lowercase().contains("second"))
            assertFalse(text.lowercase().contains("minute left"))
        }
        // And the two states are genuinely different sentences.
        assertTrue(ChemicalLookupAdvisory.IDLE_TEXT != ChemicalLookupAdvisory.SEARCHING_TEXT)
    }

    // ---- Duplicate-request prevention (fixture 14) ----

    @Test
    fun `a second search cannot start while one is running`() {
        assertTrue(ChemicalLookupAdvisory.canStartSearch("Custodia", isSearching = false, countryCode = "AU"))
        // The duplicate tap: same query, request in flight — refused.
        assertFalse(ChemicalLookupAdvisory.canStartSearch("Custodia", isSearching = true, countryCode = "AU"))
    }

    @Test
    fun `a search without a query or a country fails closed`() {
        assertFalse(ChemicalLookupAdvisory.canStartSearch("   ", isSearching = false, countryCode = "AU"))
        // No vineyard country -> no jurisdiction -> no register to search.
        assertFalse(ChemicalLookupAdvisory.canStartSearch("Custodia", isSearching = false, countryCode = ""))
    }

    // ---- A slow lookup is bounded, never abandoned early ----

    @Test
    fun `the structured lookup allows minutes before timing out`() {
        // Matches the iOS timeouts: 30 s search, 180 s structured lookup.
        // A first-time label extraction takes minutes ON PURPOSE — the bound
        // exists to catch a hung connection, not to rush the register.
        assertEquals(30_000L, ChemicalInfoService.SEARCH_TIMEOUT_MS)
        assertEquals(180_000L, ChemicalInfoService.STRUCTURED_TIMEOUT_MS)
        assertTrue(ChemicalInfoService.STRUCTURED_TIMEOUT_MS >= 3 * 60 * 1000L)
    }
}
