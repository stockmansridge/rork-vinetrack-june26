package com.rork.vinetrack.data.reporting

import com.rork.vinetrack.data.model.SprayChemical
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.SprayTank
import com.rork.vinetrack.data.model.SprayTankActual
import com.rork.vinetrack.data.model.SprayTankActualChemical
import com.rork.vinetrack.data.model.TankSession
import com.rork.vinetrack.data.model.Trip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SprayReportPayloadV1Test {
    @Test fun `projection preserves canonical row tank and quantities`() {
        val tripId = "a1b2c3d4-0000-4000-8000-000000000001"
        val vineyardId = "a1b2c3d4-0000-4000-8000-000000000002"
        val recordId = "a1b2c3d4-0000-4000-8000-000000000003"
        val lineId = "a1b2c3d4-0000-4000-8000-000000000004"
        val trip = Trip(
            id = tripId, vineyardId = vineyardId,
            startTime = "2026-09-04T00:00:00Z", endTime = "2026-09-04T03:35:00Z",
            tripFunction = "spraying", totalDistance = 12_439.15,
            rowSequence = listOf(1.5, 2.5), completedPaths = listOf(1.5),
            tankSessions = listOf(TankSession("session-1", tankNumber = 1, pathsCovered = listOf(1.5))),
            startEngineHours = 100.0, endEngineHours = 103.1,
        )
        val record = SprayRecord(
            id = recordId, vineyardId = vineyardId, tripId = tripId, sprayReference = "Late Woolly",
            tanks = listOf(SprayTank("tank-1", tankNumber = 1, waterVolume = 1500.0, chemicals = listOf(SprayChemical(lineId, "Product", 3000.0, unit = "Litres")))),
        )
        val actual = SprayTankActual(
            id = "a1b2c3d4-0000-4000-8000-000000000005", vineyardId = vineyardId,
            sprayRecordId = recordId, tripId = tripId, tankSessionId = "session-1", tankNumber = 1,
            waterVolumeL = 1450.0,
            chemicals = listOf(SprayTankActualChemical("a1b2c3d4-0000-4000-8000-000000000006", lineId, null, "Product", 2800.0, "Litres")),
            confirmedAt = "2026-09-04T01:00:00Z", confirmedBy = "a1b2c3d4-0000-4000-8000-000000000007",
        )

        val payload = SprayReportPayloadV1.offlineProjection(trip, record, "Stockmans Ridge", "Australia/Sydney", emptyList(), emptyList(), emptyList(), listOf(actual), 50)

        assertEquals("Tank 1", payload.rows.first().tankLabel)
        assertEquals(1500.0, payload.tanks.first().plannedWaterLitres, 0.0)
        assertEquals(1450.0, payload.tanks.first().actualWaterLitres!!, 0.0)
        assertEquals(3000.0, payload.tanks.first().chemicals.first().plannedAmountBase, 0.0)
        assertEquals(2800.0, payload.tanks.first().chemicals.first().actualAmountBase!!, 0.0)
        assertEquals(3.1, payload.equipment.engineHoursUsed!!, 0.000001)
    }

    @Test fun `filename uses canonical Android suffix and stable trip fragment`() {
        val trip = Trip(id = "a1b2c3d4-0000-4000-8000-000000000001", vineyardId = "v", startTime = "2026-09-04T00:00:00Z", endTime = "2026-09-04T00:01:00Z", tripFunction = "spraying")
        val record = SprayRecord(id = "r", vineyardId = "v", tripId = trip.id, sprayReference = "Late Woolly / Stage 2-3")
        val payload = SprayReportPayloadV1.offlineProjection(trip, record, "Stockmans Ridge", "Australia/Sydney", emptyList(), emptyList(), emptyList(), emptyList(), 0)
        val name = payload.exportFileName("android")
        assertTrue(name.startsWith("SprayReport_Stockmans_Ridge_"))
        assertTrue(name.endsWith("Late_Woolly_Stage_2-3_a1b2c3d4-android.pdf"))
    }
}
