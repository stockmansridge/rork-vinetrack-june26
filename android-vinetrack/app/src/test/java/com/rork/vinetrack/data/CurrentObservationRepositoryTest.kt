package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CurrentObservationRepositoryTest {
    @Test fun staleWuAndManualRefreshNeverDispatchToDavis() {
        assertEquals("wunderground_pws", CurrentObservationRepository.actionFor("wunderground_pws", "ok", true, false))
        assertEquals("wunderground_pws", CurrentObservationRepository.actionFor("wunderground_pws", "ok", false, true))
        assertNull(CurrentObservationRepository.actionFor("wunderground_pws", "ok", false, false))
    }

    @Test fun davisAndNoneKeepTheirOwnRouting() {
        assertEquals("davis_weatherlink", CurrentObservationRepository.actionFor("davis_weatherlink", "no_data", false, false))
        assertNull(CurrentObservationRepository.actionFor("none", "not_configured", true, true))
        assertNull(CurrentObservationRepository.actionFor("davis_weatherlink", "not_configured", true, true))
    }
}
