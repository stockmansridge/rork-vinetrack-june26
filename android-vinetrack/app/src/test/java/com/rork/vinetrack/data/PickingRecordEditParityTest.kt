package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PickingRecord
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * Cross-platform parity contract for EDITING Detailed picking records
 * (sql/180 UPDATE). The same rules are asserted by
 * `PickingRecordEditTests.swift` in the iOS test target:
 *
 *  * an edit keeps the record id (update-in-place, never a duplicate),
 *  * the client write payload NEVER carries `vintage` or `grape_value`
 *    (both server-authoritative),
 *  * the historical sugar unit is preserved unless the sugar value itself
 *    is re-entered,
 *  * the local vintage mirror recomputes when the picked date changes, and
 *  * Block + Variety + Vintage totals (the actual yield) recompute after
 *    an edit.
 */
class PickingRecordEditParityTest {

    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val blockA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val blockB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun makeRecord(
        id: String = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        pickedAt: String = "2027-02-10",
        vintage: Int = 2027,
        paddockId: String = blockA,
        varietyName: String = "Shiraz",
        clone: String? = "PT23",
        weightKg: Double = 850.0,
        sold: Boolean = true,
    ): PickingRecord = PickingRecord(
        id = id,
        vineyardId = vineyard,
        pickedAt = pickedAt,
        vintage = vintage,
        paddockId = paddockId,
        paddockName = "Block A",
        varietyId = "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        varietyKey = "shiraz",
        varietyName = varietyName,
        clone = clone,
        weightKg = weightKg,
        sugarValue = 13.2,
        sugarUnit = "baume",
        ph = 3.45,
        taGPerL = 6.1,
        purpose = "Table wine",
        sold = sold,
        soldTo = if (sold) "Winery Co" else null,
        pricePerTonne = if (sold) 1800.0 else null,
        notes = "First pick",
    )

    // ---- Write payload rules (must match iOS exactly) ------------------------

    @Test
    fun updatePayloadNeverCarriesServerAuthoritativeFields() {
        val record = makeRecord()
        val payload = PickingRecordUpdateSync.Payload.from(record, "2027-02-11T00:00:00Z")
        val encoded = json.encodeToString(PickingRecordUpdateSync.Payload.serializer(), payload)

        assertFalse(encoded.contains("\"vintage\""))
        assertFalse(encoded.contains("grape_value"))
        assertFalse(encoded.contains("grapeValue"))
        assertTrue(encoded.contains("\"id\""))
        assertTrue(encoded.contains("\"pickedAt\""))
        assertTrue(encoded.contains("\"clientUpdatedAt\""))
    }

    @Test
    fun updatePayloadRoundTripsTheFullEditedSnapshot() {
        val record = makeRecord()
        val payload = PickingRecordUpdateSync.Payload.from(record, "2027-02-11T00:00:00Z")
        val encoded = json.encodeToString(PickingRecordUpdateSync.Payload.serializer(), payload)
        val decoded = json.decodeFromString(PickingRecordUpdateSync.Payload.serializer(), encoded)
        val replayed = decoded.toRecord()

        assertEquals(record.id, replayed.id)
        assertEquals(record.pickedAt, replayed.pickedAt)
        assertEquals(record.paddockId, replayed.paddockId)
        assertEquals(record.varietyKey, replayed.varietyKey)
        assertEquals(record.varietyName, replayed.varietyName)
        assertEquals(record.clone, replayed.clone)
        assertEquals(record.weightKg, replayed.weightKg, 1e-9)
        assertEquals(record.sugarUnit, replayed.sugarUnit)
        assertEquals(record.soldTo, replayed.soldTo)
        assertEquals(record.notes, replayed.notes)
        // The replayed record's vintage mirror defaults to 0 — the server
        // re-derives the authoritative vintage from picked_at on update.
        assertEquals(0, replayed.vintage)
        assertNull(replayed.grapeValue)
    }

    @Test
    fun editKeepsRecordIdentity() {
        val original = makeRecord()
        val edited = original.copy(weightKg = 990.0, notes = "Corrected weight")

        assertEquals(original.id, edited.id)
        val payload = PickingRecordUpdateSync.Payload.from(edited, "2027-02-11T00:00:00Z")
        assertEquals(original.id, payload.id)
    }

    // ---- Sugar unit preservation ---------------------------------------------

    @Test
    fun editPreservesHistoricalSugarUnit() {
        // A record entered in Brix keeps Brix through unrelated edits even if
        // the vineyard preference is Baumé today.
        val record = makeRecord().copy(sugarUnit = "brix", sugarValue = 22.5)
        val edited = record.copy(weightKg = 1200.0)

        assertEquals("brix", edited.sugarUnit)
        assertEquals(22.5, edited.sugarValue!!, 1e-9)
        assertEquals(SugarMeasurementUnit.Brix, SugarMeasurementUnit.from(edited.sugarUnit))
    }

    @Test
    fun clearingSugarValueClearsUnitTogether() {
        val edited = makeRecord().copy(sugarValue = null, sugarUnit = null)
        assertNull(SugarMeasurementUnit.from(edited.sugarUnit))
    }

    // ---- Vintage mirror on date change ---------------------------------------

    @Test
    fun vintageMirrorsDateChangeUnderJulySeasonStart() {
        // 1 July season start: a Feb 2027 pick is Vintage 2027; moving the
        // date to Aug 2027 crosses the season boundary → Vintage 2028.
        val before = VintageResolver.vintageYear(LocalDate.of(2027, 2, 10), 7, 1)
        val after = VintageResolver.vintageYear(LocalDate.of(2027, 8, 10), 7, 1)
        assertEquals(2027, before)
        assertEquals(2028, after)
    }

    // ---- Totals recompute after edit ------------------------------------------

    private fun detailedActualTonnes(
        records: List<PickingRecord>,
        paddockId: String,
        varietyName: String?,
        vintage: Int,
    ): Double? {
        val matching = records.filter { record ->
            record.paddockId == paddockId && record.vintage == vintage &&
                (varietyName.isNullOrBlank() ||
                    com.rork.vinetrack.data.model.canonicalVarietyName(record.varietyName) ==
                    com.rork.vinetrack.data.model.canonicalVarietyName(varietyName))
        }
        if (matching.isEmpty()) return null
        return matching.sumOf { it.weightKg } / 1000.0
    }

    @Test
    fun totalsRecomputeAfterWeightEdit() {
        val a = makeRecord(id = "a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1", weightKg = 800.0)
        val b = makeRecord(id = "b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2", weightKg = 200.0)
        assertEquals(1.0, detailedActualTonnes(listOf(a, b), blockA, "Shiraz", 2027)!!, 1e-9)

        val edited = b.copy(weightKg = 700.0)
        val records = listOf(a, b).map { if (it.id == edited.id) edited else it }
        assertEquals(1.5, detailedActualTonnes(records, blockA, "Shiraz", 2027)!!, 1e-9)
        // Still exactly two records — the edit replaced, never duplicated.
        assertEquals(2, records.size)
    }

    @Test
    fun movingRecordToAnotherBlockMovesTheTotals() {
        val a = makeRecord(id = "a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1", weightKg = 800.0)
        val moved = makeRecord(id = "b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2", weightKg = 200.0)
            .copy(paddockId = blockB, paddockName = "Block B")

        val records = listOf(a, moved)
        assertEquals(0.8, detailedActualTonnes(records, blockA, "Shiraz", 2027)!!, 1e-9)
        assertEquals(0.2, detailedActualTonnes(records, blockB, "Shiraz", 2027)!!, 1e-9)
    }

    @Test
    fun grapeValueStaysDerivedNeverStored() {
        val edited = makeRecord(weightKg = 2000.0, sold = true).copy(pricePerTonne = 1500.0)
        assertEquals(3000.0, edited.displayGrapeValue!!, 1e-9)
        val unsold = edited.copy(sold = false, soldTo = null, pricePerTonne = null)
        assertNull(unsold.displayGrapeValue)
    }
}
