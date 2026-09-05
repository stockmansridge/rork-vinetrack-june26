package com.rork.vinetrack.ui.screens

import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.TankRowApplication
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.chemicalUnitFromBase
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TankMixPresentationTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val fullTank = SprayTank(
        id = "tank-1",
        tankNumber = 1,
        waterVolume = 2_000.0,
        sprayRatePerHa = 500.0,
        concentrationFactor = 1.0,
        rowApplications = listOf(TankRowApplication("rows-1", 1.0, 8.0)),
        chemicals = listOf(
            SprayChemical(
                id = "copper-1",
                name = "Frozen Copper",
                volumePerTank = 5_000.0,
                ratePerHa = 1_250.0,
                unit = "Litres",
            ),
        ),
    )

    private val partialTank = SprayTank(
        id = "tank-2",
        tankNumber = 2,
        waterVolume = 1_250.0,
        sprayRatePerHa = 500.0,
        concentrationFactor = 1.5,
        rowApplications = listOf(TankRowApplication("rows-2", 9.0, 12.5)),
        chemicals = listOf(
            SprayChemical(
                id = "copper-2",
                name = "Frozen Copper",
                volumePerTank = 3_125.0,
                ratePerHa = 1_250.0,
                unit = "Litres",
            ),
            SprayChemical(
                id = "powder-2",
                name = "Frozen Powder",
                volumePerTank = 625.0,
                ratePerHa = 250.0,
                unit = "g",
            ),
        ),
    )

    private fun record(tanks: List<SprayTank>? = listOf(partialTank, fullTank)) = SprayRecord(
        id = "record",
        vineyardId = "vineyard",
        tripId = "trip",
        sprayReference = "Frozen two-tank plan",
        tanks = tanks,
    )

    private fun trip(
        sessions: List<TankSession> = emptyList(),
        active: Boolean = true,
    ) = Trip(
        id = "trip",
        vineyardId = "vineyard",
        paddockName = "Local Block",
        isActive = active,
        totalTanks = 2,
        tankSessions = sessions,
    )

    @Test
    fun `frozen full and partial tank quantities sort without mutating storage`() {
        val stored = record()
        val before = stored.tanks
        val presentation = TankMixPresentation.from(stored, trip())

        assertEquals(listOf(1, 2), presentation.tanks.map { it.tankNumber })
        assertEquals(before, stored.tanks)
        assertEquals(listOf(2, 1), stored.tanks?.map { it.tankNumber })
        assertEquals(2_000.0, presentation.tanks[0].waterVolume, 0.0)
        assertEquals(1_250.0, presentation.tanks[1].waterVolume, 0.0)
        assertEquals(5_000.0, presentation.tanks[0].chemicals[0].volumePerTank, 0.0)
        assertEquals(3_125.0, presentation.tanks[1].chemicals[0].volumePerTank, 0.0)
        assertEquals(5.0, chemicalUnitFromBase("Litres", presentation.tanks[0].chemicals[0].volumePerTank), 0.0)
        assertEquals(625.0, chemicalUnitFromBase("g", presentation.tanks[1].chemicals[1].volumePerTank), 0.0)
        assertEquals(4.0, presentation.tanks[0].areaPerTank, 0.0)
        assertEquals(3.75, presentation.tanks[1].areaPerTank, 0.0)
        assertTrue(presentation.isPartial(presentation.tanks[1]))
        assertEquals("Rows 9–12.5", plannedRowRange(presentation.tanks[1].rowApplications.single()))
    }

    @Test
    fun `active next unfinished and final defaults use stored tank numbers`() {
        val endedOne = TankSession("ended-1", 1, "2026-09-04T00:00:00Z", "2026-09-04T00:05:00Z")
        val activeTwo = TankSession("active-2", 2, "2026-09-04T00:06:00Z")
        val activePresentation = TankMixPresentation.from(record(), trip(listOf(activeTwo, endedOne)))
        assertEquals(2, activePresentation.selectedTankNumber)
        assertEquals(2, activePresentation.activeTankNumber)
        assertEquals(PlannedTankProgress.CURRENT, activePresentation.progress(activePresentation.tanks[1]))

        val nextPresentation = TankMixPresentation.from(record(), trip(listOf(endedOne)))
        assertEquals(2, nextPresentation.selectedTankNumber)
        assertEquals(PlannedTankProgress.NEXT, nextPresentation.progress(nextPresentation.tanks[1]))

        val endedTwo = TankSession("ended-2", 2, "2026-09-04T00:06:00Z", "2026-09-04T00:10:00Z")
        val complete = TankMixPresentation.from(record(), trip(listOf(endedTwo, endedOne), active = false))
        assertEquals(2, complete.selectedTankNumber)
        assertEquals(setOf(1, 2), complete.completedTankNumbers)
        assertEquals(PlannedTankProgress.COMPLETED, complete.progress(complete.tanks[1]))
    }

    @Test
    fun `out of order and missing tank session numbers are ignored safely`() {
        val sessions = listOf(
            TankSession("unknown", 99, "2026-09-04T00:01:00Z"),
            TankSession("missing", 0, "2026-09-04T00:02:00Z", "2026-09-04T00:03:00Z"),
            TankSession("ended-2", 2, "2026-09-04T00:06:00Z", "2026-09-04T00:07:00Z"),
            TankSession("active-1", 1, "2026-09-04T00:04:00Z"),
        )
        val presentation = TankMixPresentation.from(record(), trip(sessions))

        assertEquals(1, presentation.activeTankNumber)
        assertEquals(1, presentation.selectedTankNumber)
        assertEquals(setOf(2), presentation.completedTankNumbers)
    }

    @Test
    fun `completed history and offline cache resolve only an exact trip id`() {
        val linked = record()
        val unrelated = record(listOf(fullTank)).copy(id = "other", tripId = "other-trip")
        val encoded = json.encodeToString(ListSerializer(SprayRecord.serializer()), listOf(unrelated, linked))
        val cached = json.decodeFromString(ListSerializer(SprayRecord.serializer()), encoded)
        val resolved = TankMixPresentation.linkedRecord("trip", cached)

        assertEquals("record", resolved?.id)
        assertNull(TankMixPresentation.linkedRecord("missing-trip", cached))
        val historical = TankMixPresentation.from(resolved, trip(active = false))
        assertTrue(historical.isAvailable)
        assertEquals(listOf(fullTank, partialTank), historical.tanks)
    }

    @Test
    fun `missing local record is unavailable and catalogue changes cannot restate frozen amounts`() {
        val unavailable = TankMixPresentation.from(null, trip())
        assertFalse(unavailable.isAvailable)
        assertNull(unavailable.selectedTankNumber)
        assertTrue(unavailable.tanks.isEmpty())

        val frozenRecord = record()
        var currentCatalogueChemical = SprayChemical(
            id = "catalogue",
            name = "Frozen Copper",
            volumePerTank = 99_000.0,
            unit = "mL",
        )
        val tripBefore = trip()
        val recordBefore = frozenRecord
        val presentation = TankMixPresentation.from(frozenRecord, tripBefore)
        currentCatalogueChemical = currentCatalogueChemical.copy(volumePerTank = 1.0)
        val selectedSecond = presentation.tanks.first { it.tankNumber == 2 }

        assertEquals(1_250.0, selectedSecond.waterVolume, 0.0)
        assertEquals(3_125.0, selectedSecond.chemicals[0].volumePerTank, 0.0)
        assertEquals(1.0, currentCatalogueChemical.volumePerTank, 0.0)
        assertEquals(recordBefore, frozenRecord)
        assertEquals(tripBefore, trip())
    }

    @Test
    fun `start end confirmation and tank status actions remain isolated and single invocation`() {
        var state = TankControlInteractionState()
        var starts = 0
        var ends = 0
        var opens = 0

        state.tapStart { starts += 1 }
        assertEquals(1, starts)
        assertEquals(0, ends)

        state = state.tapEnd()
        assertTrue(state.isEndConfirmationPresented)
        assertEquals(0, ends)
        state = state.cancelEnd()
        assertFalse(state.isEndConfirmationPresented)
        assertEquals(0, ends)

        state = state.tapEnd()
        state = state.confirmEnd { ends += 1 }
        assertEquals(1, ends)
        assertFalse(state.isEndConfirmationPresented)
        state = state.confirmEnd { ends += 1 }
        assertEquals(1, ends)

        state.tapStatus { opens += 1 }
        assertEquals(1, opens)
        assertEquals(1, starts)
        assertEquals(1, ends)
    }
}
