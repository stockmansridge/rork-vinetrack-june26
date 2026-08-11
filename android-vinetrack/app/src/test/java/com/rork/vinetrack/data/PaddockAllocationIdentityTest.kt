package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockVarietyAllocation
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWrite
import com.rork.vinetrack.data.model.PendingWriteStatus
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Block/allocation integrity contract (audit #5-#8).
 *
 * `variety_allocations[].id` is the picking log's planting-group MEMBER
 * identity (sql/184) — an Android read → edit → write round-trip must keep
 * every id byte-for-byte, decode every alias spelling other writers use, and
 * normalise legacy spellings back to the canonical shared contract.
 */
class PaddockAllocationIdentityTest {

    /** Same tolerant config as the shared SupabaseClient decoder. */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = false
        explicitNulls = false
    }

    // MARK: - Alias-tolerant decode (#7)

    @Test
    fun decodesCanonicalCamelCaseKeys() {
        val decoded = json.decodeFromString<PaddockVarietyAllocation>(
            """{"id":"A1","varietyId":"V1","varietyKey":"pinot_noir","name":"Pinot Noir",
                "percent":42.5,"clone":"777","rootstock":"Richter 110",
                "cloneKey":"pinot_noir_777","rootstockKey":"richter_110"}""",
        )
        assertEquals("A1", decoded.id)
        assertEquals("V1", decoded.varietyId)
        assertEquals("pinot_noir", decoded.varietyKey)
        assertEquals("Pinot Noir", decoded.displayName)
        assertEquals(42.5, decoded.displayPercent!!, 1e-9)
        assertEquals("777", decoded.clone)
        assertEquals("Richter 110", decoded.rootstock)
        assertEquals("pinot_noir_777", decoded.cloneKey)
        assertEquals("richter_110", decoded.rootstockKey)
    }

    @Test
    fun decodesSnakeCaseAliases() {
        val decoded = json.decodeFromString<PaddockVarietyAllocation>(
            """{"id":"A2","variety_id":"V2","variety_key":"chardonnay",
                "variety_name":"Chardonnay","percentage":57.5,
                "clone_key":"chardonnay_i10v1","rootstock_key":"own_roots"}""",
        )
        assertEquals("A2", decoded.id)
        assertEquals("V2", decoded.varietyId)
        assertEquals("chardonnay", decoded.varietyKey)
        assertEquals("Chardonnay", decoded.displayName)
        assertEquals(57.5, decoded.displayPercent!!, 1e-9)
        assertEquals("chardonnay_i10v1", decoded.cloneKey)
        assertEquals("own_roots", decoded.rootstockKey)
    }

    @Test
    fun decodesLegacyVarietyNameAndPercentageSpellings() {
        val decoded = json.decodeFromString<PaddockVarietyAllocation>(
            """{"varietyName":"Shiraz","percentage":100.0}""",
        )
        assertNull(decoded.id)
        assertEquals("Shiraz", decoded.displayName)
        assertEquals(100.0, decoded.displayPercent!!, 1e-9)
    }

    // MARK: - Canonical encode (#6, #8)

    @Test
    fun encodePreservesIdAndCanonicalKeys() {
        val allocation = PaddockVarietyAllocation(
            id = "11111111-1111-1111-1111-111111111111",
            varietyKey = "pinot_noir",
            varietyId = "V1",
            name = "Pinot Noir",
            percent = 42.5,
            clone = "777",
            rootstock = "Richter 110",
            cloneKey = "pinot_noir_777",
            rootstockKey = "richter_110",
        )
        val obj = canonicalAllocationsJson(listOf(allocation))[0].jsonObject
        assertEquals("11111111-1111-1111-1111-111111111111", obj["id"]!!.jsonPrimitive.content)
        assertEquals("pinot_noir", obj["varietyKey"]!!.jsonPrimitive.content)
        assertEquals("V1", obj["varietyId"]!!.jsonPrimitive.content)
        assertEquals("Pinot Noir", obj["name"]!!.jsonPrimitive.content)
        assertEquals(42.5, obj["percent"]!!.jsonPrimitive.content.toDouble(), 1e-9)
        assertEquals("777", obj["clone"]!!.jsonPrimitive.content)
        assertEquals("Richter 110", obj["rootstock"]!!.jsonPrimitive.content)
        assertEquals("pinot_noir_777", obj["cloneKey"]!!.jsonPrimitive.content)
        assertEquals("richter_110", obj["rootstockKey"]!!.jsonPrimitive.content)
    }

    @Test
    fun encodeNormalisesLegacySpellingsToCanonicalContract() {
        // Legacy row: varietyName/percentage spellings only.
        val legacy = PaddockVarietyAllocation(varietyName = "Shiraz", percentage = 100.0)
        val obj = canonicalAllocationsJson(listOf(legacy))[0].jsonObject
        assertEquals("Shiraz", obj["name"]!!.jsonPrimitive.content)
        assertEquals(100.0, obj["percent"]!!.jsonPrimitive.content.toDouble(), 1e-9)
        assertFalse(obj.containsKey("varietyName"))
        assertFalse(obj.containsKey("percentage"))
    }

    @Test
    fun encodeNeverMintsAnIdForLegacyAllocations() {
        val legacy = PaddockVarietyAllocation(name = "Merlot", percent = 10.0)
        val obj = canonicalAllocationsJson(listOf(legacy))[0].jsonObject
        // A legacy id-less allocation stays id-less — identity is never
        // invented on an Android save.
        assertFalse(obj.containsKey("id"))
    }

    @Test
    fun readEditWriteRoundTripKeepsAllIdsIdentical() {
        // Portal-shaped JSONB with a multi-section group (two same-variety
        // allocations with identical clone AND rootstock — ids are the ONLY
        // thing telling them apart) plus a snake_case legacy sibling.
        val serverJson = """[
            {"id":"AAAAAAAA-0000-0000-0000-000000000001","name":"Pinot Noir","percent":45.0,
             "clone":"777","rootstock":"Richter 110","cloneKey":"pinot_noir_777","rootstockKey":"richter_110"},
            {"id":"AAAAAAAA-0000-0000-0000-000000000002","name":"Pinot Noir","percent":40.0,
             "clone":"777","rootstock":"Richter 110","cloneKey":"pinot_noir_777","rootstockKey":"richter_110"},
            {"id":"AAAAAAAA-0000-0000-0000-000000000003","variety_name":"Chardonnay","percentage":15.0,
             "clone_key":"chardonnay_i10v1","rootstock_key":"own_roots"}
        ]"""
        val decoded = json.decodeFromString<List<PaddockVarietyAllocation>>(serverJson)
        assertEquals(3, decoded.size)

        // Android edits an unrelated field on one section.
        val edited = decoded.map {
            if (it.id == "AAAAAAAA-0000-0000-0000-000000000002") it.copy(percent = 41.0) else it
        }
        val encoded = canonicalAllocationsJson(edited).jsonArray
        val encodedIds = encoded.map { it.jsonObject["id"]!!.jsonPrimitive.content }
        assertEquals(
            listOf(
                "AAAAAAAA-0000-0000-0000-000000000001",
                "AAAAAAAA-0000-0000-0000-000000000002",
                "AAAAAAAA-0000-0000-0000-000000000003",
            ),
            encodedIds,
        )
        // The legacy sibling's aliases were normalised, identity untouched.
        val legacy = encoded[2].jsonObject
        assertEquals("Chardonnay", legacy["name"]!!.jsonPrimitive.content)
        assertEquals(15.0, legacy["percent"]!!.jsonPrimitive.content.toDouble(), 1e-9)
        assertEquals("chardonnay_i10v1", legacy["cloneKey"]!!.jsonPrimitive.content)
        assertEquals("own_roots", legacy["rootstockKey"]!!.jsonPrimitive.content)
    }

    // MARK: - Offline outbox payloads (#5)

    private fun makePaddock(allocations: List<PaddockVarietyAllocation>): Paddock = Paddock(
        id = "P1",
        vineyardId = "VY1",
        name = "Stockman's Ridge",
        varietyAllocations = allocations,
    )

    @Test
    fun queuedBlockEditPayloadSurvivesRestartWithIdsIntact() {
        val payloadJson = Json { encodeDefaults = true }
        val allocations = listOf(
            PaddockVarietyAllocation(id = "A1", name = "Pinot Noir", percent = 45.0, clone = "777", rootstock = "Richter 110"),
            PaddockVarietyAllocation(id = "A2", name = "Pinot Noir", percent = 40.0, clone = "777", rootstock = "Richter 110"),
        )
        val payload = PaddockEditSync.Payload(
            kind = PaddockEditSync.KIND_UPSERT,
            paddockId = "P1",
            vineyardId = "VY1",
            paddock = makePaddock(allocations),
        )
        // Serialise → deserialise: the exact shape a restart replays from disk.
        val replayed = payloadJson.decodeFromString(
            PaddockEditSync.Payload.serializer(),
            payloadJson.encodeToString(PaddockEditSync.Payload.serializer(), payload),
        )
        assertEquals(listOf("A1", "A2"), replayed.paddock!!.varietyAllocations!!.map { it.id })
    }

    @Test
    fun overlayRestoresOfflineBlockEditAfterColdRestart() {
        val payloadJson = Json { encodeDefaults = true }
        val allocations = listOf(PaddockVarietyAllocation(id = "A1", name = "Pinot Noir", percent = 100.0))
        val edited = makePaddock(allocations).copy(name = "Renamed Block")
        val marker = PendingWrite(
            id = "W1",
            entityType = PendingEntityType.PADDOCK,
            opType = PendingOpType.UPDATE,
            payloadJson = payloadJson.encodeToString(
                PaddockEditSync.Payload.serializer(),
                PaddockEditSync.Payload(
                    kind = PaddockEditSync.KIND_UPSERT,
                    paddockId = "P1",
                    vineyardId = "VY1",
                    paddock = edited,
                ),
            ),
            clientId = "P1",
            createdAt = 1L,
            updatedAt = 1L,
        )
        val baseline = listOf(makePaddock(allocations)) // pre-edit cached copy
        val overlaid = PendingWriteOverlay.overlayPaddocks(baseline, listOf(marker), "VY1")
        assertEquals("Renamed Block", overlaid.single().name)
        assertEquals(listOf("A1"), overlaid.single().varietyAllocations!!.map { it.id })

        // Once replay succeeds the marker is gone — baseline wins again.
        val cleared = PendingWriteOverlay.overlayPaddocks(baseline, emptyList(), "VY1")
        assertEquals("Stockman's Ridge", cleared.single().name)
    }

    @Test
    fun overlayAppliesPartialEditsWithoutInventingBlocks() {
        val payloadJson = Json { encodeDefaults = true }
        val marker = PendingWrite(
            id = "W2",
            entityType = PendingEntityType.PADDOCK,
            opType = PendingOpType.UPDATE,
            payloadJson = payloadJson.encodeToString(
                PaddockEditSync.Payload.serializer(),
                PaddockEditSync.Payload(
                    kind = PaddockEditSync.KIND_ALLOCATIONS,
                    paddockId = "GHOST",
                    vineyardId = "VY1",
                    allocations = listOf(PaddockVarietyAllocation(id = "AX", name = "Merlot", percent = 100.0)),
                ),
            ),
            clientId = "GHOST",
            createdAt = 1L,
            updatedAt = 1L,
            status = PendingWriteStatus.FAILED,
        )
        val baseline = listOf(makePaddock(listOf(PaddockVarietyAllocation(id = "A1", name = "Pinot Noir", percent = 100.0))))
        val overlaid = PendingWriteOverlay.overlayPaddocks(baseline, listOf(marker), "VY1")
        // Partial edit for an unknown block never invents a row.
        assertEquals(1, overlaid.size)
        assertEquals(listOf("A1"), overlaid.single().varietyAllocations!!.map { it.id })
        assertTrue(overlaid.single().id == "P1")
    }
}
