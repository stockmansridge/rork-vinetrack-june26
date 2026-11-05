package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PanelCountMeasurement
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class PanelCountContractTest {
    @Test fun validatesRecordedFootprintWithoutDoubleCorrection() {
        val m = requireNotNull(PanelCountMeasurement.make(
            totalBunches = 120, plantedPositions = 10, fruitingVines = 8,
            missingPositions = 1, nonproductiveVines = 1, panelLengthMetres = 6.0))
        assertEquals(12.0, m.bunchesPerPlantingPosition, 0.0)
        assertEquals(m, Json.decodeFromString<PanelCountMeasurement>(Json.encodeToString(m)))
    }

    @Test fun rejectsMissingDenominatorsAndInvalidValues() {
        assertNull(PanelCountMeasurement.make(12, 10, 8, 1, 0, null))
        assertNull(PanelCountMeasurement.make(-1, 10, 9, 1, 0, null))
        assertNull(PanelCountMeasurement.make(0, 0, 0, 0, 0, null))
        assertNull(PanelCountMeasurement.make(0, 2, 2, 0, 0, Double.POSITIVE_INFINITY))
        assertEquals(0.0, requireNotNull(PanelCountMeasurement.make(0, 2, 2, 0, 0, null)).bunchesPerPlantingPosition, 0.0)
    }
}
