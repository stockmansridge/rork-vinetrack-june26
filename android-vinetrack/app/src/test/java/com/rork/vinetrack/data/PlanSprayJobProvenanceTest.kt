package com.rork.vinetrack.data

import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceJurisdiction
import com.rork.vinetrack.data.resistance.ResistancePlan
import com.rork.vinetrack.data.resistance.ResistancePlannedChemistrySource
import com.rork.vinetrack.data.resistance.ResistancePlannedPosition
import com.rork.vinetrack.data.resistance.ResistancePlannedProduct
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * STAGE 5B — Resistance Plan -> Spray Job -> Spray Record (sql/201).
 * The Kotlin twin of `SprayJobPlanProvenanceTests.swift`; both suites pin the
 * SAME contract:
 *  * a job created from a plan position freezes the position VERBATIM as its
 *    original-intent snapshot — later plan edits never rewrite it;
 *  * one position may generate many jobs; each carries its own link;
 *  * plan DEVIATION (proposal differs from original intent) is separate from
 *    resistance COMPLIANCE (always the engine's live call);
 *  * the queued create payload carries the whole link, so offline creates
 *    survive any sync ordering;
 *  * pre-5B queued spray-record markers stay decodable as unlinked creates.
 */
class PlanSprayJobProvenanceTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val vineyard = "11111111-2222-4333-8444-555555555501"
    private val planId = "bbbbbbb1-0000-4000-8000-000000000201"
    private val chemicalId = "aaaaaaa1-0000-4000-8000-000000000301"

    private fun frac3Position() = ResistancePlannedPosition(
        id = "pos-1",
        products = listOf(
            ResistancePlannedProduct(
                id = "prod-1",
                groupCodes = listOf("3"),
                source = ResistancePlannedChemistrySource.GROUP,
            ),
        ),
        note = "first cover spray",
    )

    private fun plan(position: ResistancePlannedPosition) = ResistancePlan(
        id = planId,
        vineyardId = vineyard,
        seasonId = "2026/27",
        seasonStartYear = 2026,
        disease = ResistanceDisease.POWDERY_MILDEW,
        jurisdiction = ResistanceJurisdiction.fromCountryCode("AU"),
        positions = listOf(position),
        createdAtEpochMs = 0L,
        updatedAtEpochMs = 0L,
        serverRevision = 4L,
    )

    private fun snapshotObject(position: ResistancePlannedPosition) =
        json.encodeToJsonElement(ResistancePlannedPosition.serializer(), position).jsonObject

    private fun jobWith(
        snapshot: ResistancePlannedPosition?,
        lines: List<Pair<String?, String>>,
    ) = PlanSprayJob(
        id = "ccccccc1-0000-4000-8000-000000000202",
        vineyardId = vineyard,
        name = "Job",
        status = "planned",
        chemicalLines = buildJsonArray {
            lines.forEach { (id, name) ->
                add(
                    buildJsonObject {
                        id?.let { put("chemical_id", JsonPrimitive(it)) }
                        put("name", JsonPrimitive(name))
                    },
                )
            }
        },
        resistancePlanId = snapshot?.let { planId },
        resistancePositionId = snapshot?.id,
        resistancePositionSnapshot = snapshot?.let { snapshotObject(it) },
    )

    // ------------------------------------------------------------------
    // Wire payload: sql/201 columns ride the create itself
    // ------------------------------------------------------------------

    @Test
    fun insertPayloadCarriesProvenanceColumns() {
        val position = frac3Position()
        val insert = SprayJobPlanRepository.buildInsert(
            plan = plan(position),
            position = position,
            name = "Powdery Mildew 2026/27 — Spray 1",
            target = "Powdery Mildew",
            createdBy = null,
        )
        val encoded = json.encodeToJsonElement(PlanSprayJobInsert.serializer(), insert).jsonObject

        assertEquals(planId, encoded["resistance_plan_id"]?.jsonPrimitive?.content)
        assertEquals("pos-1", encoded["resistance_position_id"]?.jsonPrimitive?.content)
        assertEquals("planned", encoded["status"]?.jsonPrimitive?.content)
        assertEquals("false", encoded["is_template"]?.jsonPrimitive?.content)
        assertEquals("4", encoded["resistance_plan_source_revision"]?.jsonPrimitive?.content)

        val snapshot = encoded["resistance_position_snapshot"]!!.jsonObject
        // The snapshot's own id must equal the position id (sql/201 shape).
        assertEquals("pos-1", snapshot["id"]?.jsonPrimitive?.content)
        val snapshotGroups = snapshot["products"]!!.jsonArray[0]
            .jsonObject["group_codes"]!!.jsonArray
        assertEquals("3", snapshotGroups[0].jsonPrimitive.content)

        // Prefill only what the plan genuinely knows: identity, never rates.
        val line = encoded["chemical_lines"]!!.jsonArray[0].jsonObject
        assertEquals("FRAC 3", line["name"]?.jsonPrimitive?.content)
        assertNull(line["rate"])
    }

    // ------------------------------------------------------------------
    // Frozen original intent
    // ------------------------------------------------------------------

    @Test
    fun planEditNeverRewritesFrozenSnapshot() {
        val original = frac3Position()
        val insert = SprayJobPlanRepository.buildInsert(
            plan = plan(original),
            position = original,
            name = "Job",
            target = null,
            createdBy = null,
        )

        // Manager later edits the position to FRAC 11 — a NEW plan document.
        val edited = original.copy(
            products = listOf(
                ResistancePlannedProduct(
                    id = "prod-1",
                    groupCodes = listOf("11"),
                    source = ResistancePlannedChemistrySource.GROUP,
                ),
            ),
        )
        assertEquals(setOf("11"), edited.componentGroups)

        // The job's frozen snapshot still says FRAC 3.
        val frozen = insert.asJob().snapshotPosition()!!
        assertEquals(setOf("3"), frozen.componentGroups)
        assertEquals("FRAC 3", insert.asJob().originalIntentLabel)
    }

    // ------------------------------------------------------------------
    // One position -> many jobs
    // ------------------------------------------------------------------

    @Test
    fun onePositionManyJobsEachCarryTheLink() {
        val position = frac3Position()
        val first = SprayJobPlanRepository.buildInsert(
            plan = plan(position), position = position,
            name = "Block A run", target = null, createdBy = null,
        )
        val second = SprayJobPlanRepository.buildInsert(
            plan = plan(position), position = position,
            name = "Block B run", target = null, createdBy = null,
        )
        assertNotEquals(first.id, second.id)
        assertEquals(first.resistancePositionId, second.resistancePositionId)
        assertEquals(first.resistancePlanId, second.resistancePlanId)
    }

    // ------------------------------------------------------------------
    // Deviation ≠ compliance
    // ------------------------------------------------------------------

    @Test
    fun deviationIsSeparateFromCompliance() {
        val snapshot = ResistancePlannedPosition(
            id = "pos-1",
            products = listOf(
                ResistancePlannedProduct(
                    id = "prod-1",
                    groupCodes = listOf("3"),
                    source = ResistancePlannedChemistrySource.SAVED_CHEMICAL,
                    savedChemicalId = chemicalId,
                    productName = "Talendo",
                ),
            ),
        )

        val matching = jobWith(snapshot, listOf(chemicalId to "Talendo"))
        assertFalse(matching.deviatesFromPlan)

        val deviating = jobWith(snapshot, listOf(null to "Different Product"))
        assertTrue(deviating.deviatesFromPlan)

        // A legacy unlinked job has no plan to deviate from.
        val unlinked = jobWith(null, listOf(null to "Anything"))
        assertFalse(unlinked.deviatesFromPlan)
    }

    // ------------------------------------------------------------------
    // Offline safety: queued payloads
    // ------------------------------------------------------------------

    @Test
    fun jobCreateMarkerRoundTripsProvenanceAndPaddocks() {
        val position = frac3Position()
        val payload = SprayJobCreateSync.Payload(
            insert = SprayJobPlanRepository.buildInsert(
                plan = plan(position), position = position,
                name = "Offline job", target = null, createdBy = null,
            ),
            paddockIds = listOf("aaaaaaa1-0000-4000-8000-000000000201"),
        )
        val decoded = json.decodeFromString(
            SprayJobCreateSync.Payload.serializer(),
            json.encodeToString(SprayJobCreateSync.Payload.serializer(), payload),
        )
        assertEquals(planId, decoded.insert.resistancePlanId)
        assertEquals("pos-1", decoded.insert.resistancePositionId)
        assertEquals(
            setOf("3"),
            decoded.insert.asJob().snapshotPosition()!!.componentGroups,
        )
        assertEquals(listOf("aaaaaaa1-0000-4000-8000-000000000201"), decoded.paddockIds)
    }

    @Test
    fun queuedRecordMarkerCarriesJobLinkAndLegacyMarkersDecodeUnlinked() {
        // A job-originated record create carries spray_job_id through the outbox.
        val linked = SprayRecordCreateSync.Payload(
            id = "r-1",
            vineyardId = vineyard,
            date = "2026-08-10T09:00:00Z",
            startTime = "2026-08-10T09:00:00Z",
            sprayJobId = "ccccccc1-0000-4000-8000-000000000202",
            clientUpdatedAt = "2026-08-10T09:00:00Z",
        )
        val roundTripped = json.decodeFromString(
            SprayRecordCreateSync.Payload.serializer(),
            json.encodeToString(SprayRecordCreateSync.Payload.serializer(), linked),
        )
        assertEquals("ccccccc1-0000-4000-8000-000000000202", roundTripped.sprayJobId)

        // A pre-5B queued marker (no sprayJobId key) decodes as a plain
        // unlinked create — never dropped, never guessed.
        val legacy = """
            {"id":"r-legacy","vineyardId":"$vineyard","date":"2026-01-01T00:00:00Z",
             "startTime":"2026-01-01T00:00:00Z","clientUpdatedAt":"2026-01-01T00:00:00Z"}
        """.trimIndent()
        val decodedLegacy = json.decodeFromString(SprayRecordCreateSync.Payload.serializer(), legacy)
        assertNull(decodedLegacy.sprayJobId)
    }
}
