package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.data.spray.*
import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneId

class SprayProgramRound2Test {
    @Test fun `status follows explicit completion then ended inactive Trip then active`() {
        val record = SprayRecord(id = "spray", vineyardId = "vineyard", tripId = "trip")
        val trip = Trip(id = "trip", vineyardId = "vineyard")
        assertEquals(SprayStatus.COMPLETED, sprayRecordStatus(record.copy(endTime = "2026-07-01T01:00:00Z"), listOf(trip.copy(isActive = true))))
        assertEquals(SprayStatus.IN_PROGRESS, sprayRecordStatus(record, listOf(trip.copy(isActive = true, endTime = "2026-07-01T01:00:00Z"))))
        assertEquals(SprayStatus.COMPLETED, sprayRecordStatus(record, listOf(trip.copy(isActive = false, endTime = "2026-07-01T01:00:00Z"))))
        assertEquals(SprayStatus.COMPLETED, sprayRecordStatus(record, listOf(trip.copy(isActive = false, isPaused = true, endTime = "2026-07-01T01:00:00Z"))))
        assertEquals(SprayStatus.NOT_STARTED, sprayRecordStatus(record, emptyList()))
    }

    @Test fun `both canonical RPC sources retain exact timestamp and form fields`() {
        val record = SprayRecord(id = "spray", vineyardId = "vineyard", notes = "Queued edit")
        for (source in listOf("trip_end", "server_now")) {
            val response = SprayCompletionResponse(record.id, "2026-07-01T01:00:00.123456+00:00", source, true,
                "2026-07-01T02:00:00Z", syncVersion = 8)
            val applied = response.applyingTo(record)
            assertEquals(response.endTime, applied.endTime)
            assertEquals(record.notes, applied.notes)
            assertEquals(8L, applied.syncVersion)
        }
    }

    @Test fun `RPC errors preserve operator instructions`() {
        val racedActiveTrip = SprayCompletionRejected("ACTIVE_TRIP", "canonical-trip")
        assertEquals("canonical-trip", racedActiveTrip.tripId)
        assertEquals("This spray still has an active Trip. End the Trip to complete the spray.", racedActiveTrip.message)
        assertEquals("This spray still has an active Trip. End the Trip to complete the spray.", SprayCompletionErrors.message("ACTIVE_TRIP"))
        assertEquals("No linked Trip is available. Mark this spray complete now?", SprayCompletionErrors.message("UNLINKED_CONFIRMATION_REQUIRED"))
        assertEquals("Manual spray records must be managed through the manual spray workflow.", SprayCompletionErrors.message("MANUAL_SPRAY_WORKFLOW_REQUIRED"))
    }

    @Test fun `EL9 completion preserves same stage repeat and higher stages`() {
        val first = SprayRecord(id = "first", vineyardId = "vineyard", sprayReference = "EL9 — 3-5 Leaves", isTemplate = true)
        val repeat = first.copy(id = "repeat", sprayReference = "EL9 — Repeat 7-14 day intervals")
        val later = first.copy(id = "later", sprayReference = "EL12 — Shoot Development")
        val lower = first.copy(id = "lower", sprayReference = "EL4 — Budburst")
        val completed = first.copy(id = "application", isTemplate = false, sprayReference = "3-5 Leaves / E-L Stage 9")
        assertEquals(listOf("repeat", "later"), SprayProgramProgression.remaining(listOf(later, first, lower, repeat), listOf(completed)).map { it.id })
        assertEquals(listOf("lower", "first", "later"), SprayProgramProgression.remaining(listOf(later, first, lower), emptyList()).map { it.id })
    }

    @Test fun `explicit provenance wins and fallback is not fuzzy`() {
        val first = SprayRecord(id = "first", vineyardId = "vineyard", sprayReference = "EL9 — Same name", isTemplate = true)
        val second = first.copy(id = "second")
        val completed = first.copy(id = "application", isTemplate = false, sprayJobId = first.id)
        assertEquals(listOf("second"), SprayProgramProgression.remaining(listOf(first, second), listOf(completed)).map { it.id })
        assertEquals(1, SprayProgramProgression.remaining(listOf(first), listOf(completed.copy(sprayJobId = null, sprayReference = "EL9 — Same name additional"))).size)
    }

    @Test fun `reference rows preserve rates and exclude operational fields`() {
        val products = listOf(SprayChemical(id = "area", name = "Area", ratePerHa = 120.0, unit = "mL", rateBasis = "whole_block_area"),
            SprayChemical(id = "volume", name = "Volume", ratePer100L = 40.0, unit = "mL", rateBasis = "per_100_litres"))
        val step = SprayRecord(id = "step", vineyardId = "vineyard", sprayReference = "EL9 — Leaves", isTemplate = true,
            tanks = listOf(SprayTank(id = "tank", chemicals = products)))
        val rows = SprayProgramReferenceDataset.rows(listOf(step), emptyList())
        assertEquals(listOf("120.00 mL/ha", "40.00 mL/100 L"), rows.map { it.rate })
        val csv = SprayProgramReferenceDataset.csv(rows)
        assertTrue(csv.contains("Program Step"))
        assertFalse(csv.contains("Operator"))
        assertFalse(csv.contains("Tank"))
    }

    @Test fun `registered fallback includes all target-matched grapevine ranges without midpoint or other crops`() {
        val chemical = SavedChemical(id = "product", vineyardId = "vineyard", name = "Product", unit = "Kg", registeredUses = listOf(
            com.rork.vinetrack.data.chemical.ChemicalRegisteredUse(crop = "Grapevines", targetRaw = "Downy mildew", rates = listOf(
                com.rork.vinetrack.data.chemical.ChemicalLabelRate(label = "Dilute", basis = com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis.RANGE_PER_100_LITRES, minValue = 150.0, maxValue = 200.0, unit = "g"),
                com.rork.vinetrack.data.chemical.ChemicalLabelRate(label = "High pressure", basis = com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis.RANGE_PER_100_LITRES, minValue = 250.0, maxValue = 300.0, unit = "g")
            )),
            com.rork.vinetrack.data.chemical.ChemicalRegisteredUse(crop = "Tobacco", targetRaw = "Downy mildew", rates = listOf(
                com.rork.vinetrack.data.chemical.ChemicalLabelRate(basis = com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis.PER_HECTARE, value = 999.0, unit = "kg")
            ))
        ))
        val product = SprayChemical(id = "line", name = "Product", savedChemicalId = chemical.id)
        val step = SprayRecord(id = "step", vineyardId = "vineyard", isTemplate = true, targets = listOf("downy"))
        val rate = SprayProgramReferenceDataset.rate(product, step, listOf(chemical), mapOf("downy" to "Downy mildew"))
        assertTrue(rate.contains("150")); assertTrue(rate.contains("200"))
        assertTrue(rate.contains("250")); assertTrue(rate.contains("300"))
        assertFalse(rate.contains("175")); assertFalse(rate.contains("999"))
        assertEquals("", SprayProgramReferenceDataset.rate(product, step.copy(targets = listOf("unknown")), listOf(chemical), emptyMap()))
    }

    @Test fun `small precise programmed rates never round to zero`() {
        val product = SprayChemical(id = "small", name = "Small", ratePerHa = 1.0, unit = "Litres", rateBasis = "whole_block_area")
        val step = SprayRecord(id = "step", vineyardId = "vineyard", sprayReference = "EL9 — Leaves", isTemplate = true)
        assertEquals("0.001 L/ha", SprayProgramReferenceDataset.rate(product, step, emptyList(), emptyMap()))
    }

    @Test fun `provenance supplies canonical stage when application reference is unstaged`() {
        val step = SprayRecord(id = "step", vineyardId = "vineyard", sprayReference = "Leaves", isTemplate = true, templateGrowthStageCode = "EL9")
        val later = step.copy(id = "later", sprayReference = "Shoot", templateGrowthStageCode = "EL12")
        val application = step.copy(id = "application", isTemplate = false, templateGrowthStageCode = null, sprayJobId = step.id)
        assertEquals(listOf("later"), SprayProgramProgression.remaining(listOf(step, later), listOf(application)).map { it.id })
    }

    @Test fun `vintage dataset uses local half-open season event date and completed only`() {
        val zone = ZoneId.of("Australia/Sydney")
        val window = SeasonWindow.forVintage(2027, 7, 1)
        val trip = Trip(id = "trip", vineyardId = "vineyard", isActive = false, isPaused = true, endTime = "2026-07-01T01:00:00Z")
        val valid = SprayRecord(id = "valid", vineyardId = "vineyard", tripId = trip.id, date = "2026-06-30T14:00:00Z")
        val upcoming = valid.copy(id = "upcoming", tripId = null)
        val previous = valid.copy(id = "previous", date = "2026-06-30T13:59:59Z", endTime = "2026-10-01T00:00:00Z")
        val boundary = valid.copy(id = "boundary", date = "2027-06-30T14:00:00Z")
        val deleted = valid.copy(id = "deleted", deletedAt = "2026-08-01T00:00:00Z")
        assertEquals(listOf("valid"), SprayProgramProgression.completed(listOf(valid, upcoming, previous, boundary, deleted, valid.copy(id = "template", isTemplate = true)),
            listOf(trip), "vineyard", window, zone).map { it.id })
    }
}
