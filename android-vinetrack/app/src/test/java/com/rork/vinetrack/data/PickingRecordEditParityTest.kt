package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PickingRecord
import com.rork.vinetrack.data.model.plantingGroupKey
import com.rork.vinetrack.data.model.plantingGroupTotals
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
 *  * the local vintage mirror recomputes when the picked date changes,
 *  * Block + Variety + Vintage totals (the actual yield) recompute after
 *    an edit, and
 *  * the planting-GROUP identity (`planting_group_key` +
 *    `variety_allocation_ids` members + rootstock snapshot, sql/184)
 *    round-trips exactly — identical sections share ONE group key, every
 *    member allocation id is preserved under the group (never one
 *    arbitrary id), and unlinked records stay unlinked (never guessed).
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
        plantingGroupKey: String? = null,
        varietyAllocationIds: List<String>? = null,
        clone: String? = "PT23",
        rootstock: String? = null,
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
        plantingGroupKey = plantingGroupKey,
        varietyAllocationIds = varietyAllocationIds,
        clone = clone,
        rootstock = rootstock,
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
        assertEquals(record.plantingGroupKey, replayed.plantingGroupKey)
        assertEquals(record.varietyAllocationIds, replayed.varietyAllocationIds)
        assertEquals(record.clone, replayed.clone)
        assertEquals(record.rootstock, replayed.rootstock)
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

    // ---- Planting-group identity (sql/184) -------------------------------------

    @Test
    fun updatePayloadCarriesPlantingGroupIdentity() {
        // A multi-section group: BOTH member allocation ids travel under the
        // group key — never one arbitrary id.
        val members = listOf(
            "11111111-2222-4333-8444-555555555555",
            "66666666-7777-4888-8999-aaaaaaaaaaaa",
        )
        val record = makeRecord(
            varietyName = "Pinot Noir",
            plantingGroupKey = plantingGroupKey("Pinot Noir", "777", "Richter 110"),
            varietyAllocationIds = members,
            clone = "777",
            rootstock = "Richter 110",
        )
        val payload = PickingRecordUpdateSync.Payload.from(record, "2027-02-11T00:00:00Z")
        val encoded = json.encodeToString(PickingRecordUpdateSync.Payload.serializer(), payload)

        assertTrue(encoded.contains("pinot noir|777|richter 110"))
        assertTrue(encoded.contains("11111111-2222-4333-8444-555555555555"))
        assertTrue(encoded.contains("66666666-7777-4888-8999-aaaaaaaaaaaa"))

        val replayed = json.decodeFromString(PickingRecordUpdateSync.Payload.serializer(), encoded).toRecord()
        assertEquals(record.plantingGroupKey, replayed.plantingGroupKey)
        assertEquals(members, replayed.varietyAllocationIds)
        assertEquals(record.clone, replayed.clone)
        assertEquals(record.rootstock, replayed.rootstock)
    }

    @Test
    fun createPayloadCarriesPlantingGroupForOfflineReplay() {
        // An offline-created pick must replay the exact group link with every
        // member id intact.
        val members = listOf(
            "11111111-2222-4333-8444-555555555555",
            "66666666-7777-4888-8999-aaaaaaaaaaaa",
        )
        val record = makeRecord(
            varietyName = "Pinot Noir",
            plantingGroupKey = plantingGroupKey("Pinot Noir", "777", "Richter 110"),
            varietyAllocationIds = members,
            clone = "777",
            rootstock = "Richter 110",
        )
        val payload = PickingRecordCreateSync.Payload(
            id = record.id,
            vineyardId = record.vineyardId,
            pickedAt = record.pickedAt,
            paddockId = record.paddockId,
            paddockName = record.paddockName,
            varietyId = record.varietyId,
            varietyKey = record.varietyKey,
            varietyName = record.varietyName,
            plantingGroupKey = record.plantingGroupKey,
            varietyAllocationIds = record.varietyAllocationIds,
            clone = record.clone,
            rootstock = record.rootstock,
            weightKg = record.weightKg,
            clientUpdatedAt = "2027-02-11T00:00:00Z",
        )
        val encoded = json.encodeToString(PickingRecordCreateSync.Payload.serializer(), payload)
        val decoded = json.decodeFromString(PickingRecordCreateSync.Payload.serializer(), encoded)
        assertEquals(record.plantingGroupKey, decoded.plantingGroupKey)
        assertEquals(members, decoded.varietyAllocationIds)
        assertEquals(record.rootstock, decoded.rootstock)
    }

    @Test
    fun identicalSectionsShareOnePlantingGroupKey() {
        // The motivating case: one block, two Pinot Noir sections, BOTH
        // Clone 777 · Richter 110 — they are ONE planting group. The key is
        // case/whitespace-insensitive so client drift can never fork it
        // (exact parity with iOS PlantingGroup.key and SQL
        // public.planting_group_key).
        val a = plantingGroupKey("Pinot Noir", "777", "Richter 110")
        val b = plantingGroupKey(" PINOT  Noir ", "777 ", "richter 110")
        assertEquals(a, b)
        assertEquals("pinot noir|777|richter 110", a)

        // Different rootstock = different group.
        assertFalse(a == plantingGroupKey("Pinot Noir", "777", "Own roots"))

        // nulls normalise to empty segments.
        assertEquals("chardonnay||", plantingGroupKey("Chardonnay", null, null))
    }

    @Test
    fun linkedGroupWithoutMemberIdsKeepsEmptyListNotNull() {
        // Legacy member allocations may have no minted ids — the group is
        // still linked: key set, members empty (never null).
        val record = makeRecord(
            varietyName = "Chardonnay",
            plantingGroupKey = plantingGroupKey("Chardonnay", null, null),
            varietyAllocationIds = emptyList(),
            clone = null,
        )
        val payload = PickingRecordUpdateSync.Payload.from(record, "2027-02-11T00:00:00Z")
        val replayed = json.decodeFromString(
            PickingRecordUpdateSync.Payload.serializer(),
            json.encodeToString(PickingRecordUpdateSync.Payload.serializer(), payload),
        ).toRecord()
        assertEquals("chardonnay||", replayed.plantingGroupKey)
        assertEquals(emptyList<String>(), replayed.varietyAllocationIds)
    }

    @Test
    fun serverRowWithoutPlantingGroupColumnsDecodesAsUnlinked() {
        // Pre-184 rows (and rows on a not-yet-migrated server) decode with a
        // null group link — they are never backfilled by guessing.
        val row = """
            {"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
             "vineyard_id":"$vineyard","picked_at":"2027-02-10",
             "paddock_id":"$blockA","paddock_name":"Block A",
             "variety_name":"Pinot Noir","clone":"777","weight_kg":850.0}
        """.trimIndent()
        val decoded = json.decodeFromString(PickingRecord.serializer(), row)
        assertNull(decoded.plantingGroupKey)
        assertNull(decoded.varietyAllocationIds)
        assertNull(decoded.rootstock)
        assertEquals("777", decoded.clone)
    }

    @Test
    fun unlinkedHistoricalRecordStaysUnlinkedThroughUnrelatedEdits() {
        val edited = makeRecord(clone = "777").copy(weightKg = 990.0)
        assertNull(edited.plantingGroupKey)
        assertNull(edited.varietyAllocationIds)

        val payload = PickingRecordUpdateSync.Payload.from(edited, "2027-02-11T00:00:00Z")
        val replayed = json.decodeFromString(
            PickingRecordUpdateSync.Payload.serializer(),
            json.encodeToString(PickingRecordUpdateSync.Payload.serializer(), payload),
        ).toRecord()
        assertNull(replayed.plantingGroupKey)
        assertNull(replayed.varietyAllocationIds)
        assertEquals("777", replayed.clone)
    }

    @Test
    fun plantingGroupTotalsPartitionAndReconcileExactly() {
        // Yield Overview contract (matches iOS
        // plantingGroupTotalsPartitionAndReconcileExactly): one production
        // row per planting group; identical sections are ONE row; the
        // unlinked bucket is last; group rows sum exactly to the variety
        // total.
        val key777 = plantingGroupKey("Pinot Noir", "777", "Richter 110")
        val key667 = plantingGroupKey("Pinot Noir", "667", "Richter 110")
        val records = listOf(
            makeRecord(varietyName = "Pinot Noir", plantingGroupKey = key777, clone = "777", rootstock = "Richter 110", weightKg = 2000.0),
            makeRecord(varietyName = "Pinot Noir", plantingGroupKey = key777, clone = "777", rootstock = "Richter 110", weightKg = 2140.0),
            makeRecord(varietyName = "Pinot Noir", plantingGroupKey = key667, clone = "667", rootstock = "Richter 110", weightKg = 2590.0),
            makeRecord(varietyName = "Pinot Noir", plantingGroupKey = null, clone = null, weightKg = 500.0),
        )

        val groups = plantingGroupTotals(records)
        assertEquals(3, groups.size)
        assertEquals(key777, groups[0].groupKey)
        assertEquals(2, groups[0].pickCount)
        assertEquals(4.14, groups[0].actualYieldTonnes, 1e-9)
        assertEquals(key667, groups[1].groupKey)
        assertEquals(2.59, groups[1].actualYieldTonnes, 1e-9)
        assertNull(groups.last().groupKey)
        assertEquals(1, groups.last().pickCount)

        assertEquals(records.sumOf { it.weightKg }, groups.sumOf { it.totalWeightKg }, 1e-9)
    }

    @Test
    fun grapeValueStaysDerivedNeverStored() {
        val edited = makeRecord(weightKg = 2000.0, sold = true).copy(pricePerTonne = 1500.0)
        assertEquals(3000.0, edited.displayGrapeValue!!, 1e-9)
        val unsold = edited.copy(sold = false, soldTo = null, pricePerTonne = null)
        assertNull(unsold.displayGrapeValue)
    }
}
