package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.*
import org.junit.Test

class SprayStartOutcomeTest {
    @Test fun blankHoursRemainOptionalThroughExistingActivation() {
        assertTrue(SprayStartEngineHours.isValid("  "))
        val active = requireNotNull(SavedTripActivation.activate(Trip("original", "vineyard"), "2026-10-16T08:00:00Z", SprayStartEngineHours.parse("")))
        assertNull(active.startEngineHours)
        assertTrue(active.isActive)
        assertEquals("original", active.id)
    }
    @Test fun validEnteredHoursIncludingZeroAndCommaArePreserved() {
        for ((text, value) in listOf("123.5" to 123.5, "123,5" to 123.5, "0" to 0.0)) {
            assertTrue(SprayStartEngineHours.isValid(text))
            val active = requireNotNull(SavedTripActivation.activate(Trip("original", "vineyard"), "2026-10-16T08:00:00Z", SprayStartEngineHours.parse(text)))
            assertEquals(value, requireNotNull(active.startEngineHours), 0.0)
            assertEquals("original", active.id)
        }
    }
    @Test fun malformedAndNegativeHoursDoNotMasqueradeAsBlank() {
        for (text in listOf("-1", "1..2", "NaN", "Infinity", ".", "abc")) assertFalse(text, SprayStartEngineHours.isValid(text))
    }
    @Test fun successRequiresTheActualTripIdentifierAndNoError() {
        assertTrue(SprayStartOutcome(tripId = "original").isStarted)
        assertFalse(SprayStartOutcome(message = "Activation rejected").isStarted)
        assertFalse(SprayStartOutcome(tripId = "original", message = "Recovery pending").isStarted)
        assertFalse(SprayStartOutcome().isStarted)
    }
    @Test fun activationDoesNotReopenExistingActiveOrEndedEvidence() {
        assertNull(SavedTripActivation.activate(Trip("active", "vineyard", isActive = true), "2026-10-16T08:00:00Z"))
        assertNull(SavedTripActivation.activate(Trip("ended", "vineyard", endTime = "2026-10-15T08:00:00Z"), "2026-10-16T08:00:00Z"))
    }
}
