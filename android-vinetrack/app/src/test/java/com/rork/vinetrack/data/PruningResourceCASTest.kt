package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class PruningResourceCASTest {
    private val json = Json { encodeDefaults = true; explicitNulls = true; ignoreUnknownKeys = true }

    @Test fun `six explicit keys retain timestamp precision and intentional clears`() {
        val base = PruningResourceSnapshot("activity", "vineyard", "2026-10-08T01:02:03.123456+00:00", null, "old")
        val link = PruningResourceLink(null, null, "Other", "author", expected = base)
        val body = json.encodeToJsonElement(link.request("activity", "vineyard")).jsonObject
        assertEquals(6, body.size)
        assertEquals(JsonNull, body["p_external_resource_id"])
        assertEquals(JsonNull, body["p_worker_user_id"])
        assertEquals(JsonNull, body["p_expected_external_resource_id"])
        assertEquals(base.clientUpdatedAt, body["p_expected_client_updated_at"]?.jsonPrimitive?.content)
    }

    @Test fun `successful and duplicate retries acknowledge the same generation`() {
        val base = PruningResourceSnapshot("activity", "vineyard", null, null, null)
        val link = PruningResourceLink(null, "operator", "Operator", "author", expected = base)
        for (duplicate in listOf(false, true)) {
            val accepted = link.accepting(PruningResourceCASResult("activity", true, null, "operator", idempotent = duplicate), "activity")
            assertTrue(accepted.acknowledged)
            assertEquals(base, accepted.expected)
            assertEquals(link.generation, accepted.generation)
        }
    }

    @Test fun `stale cross device response preserves local selection and original baseline`() {
        val base = PruningResourceSnapshot("activity", "vineyard", "2026-10-08T00:00:00.123456Z", null, null)
        val canonical = PruningResourceSnapshot("activity", "vineyard", "2026-10-08T01:00:00Z", "portal-crew", null)
        val link = PruningResourceLink(null, "operator", "My operator", "author", expected = base)
        val result = PruningResourceCASResult("activity", false, "portal-crew", null, conflict = true, canonical = canonical)
        val conflicted = link.accepting(result, "activity")
        assertTrue(conflicted.isPending)
        assertEquals("operator", conflicted.workerUserId)
        assertEquals("My operator", conflicted.name)
        assertEquals(base, conflicted.expected)
        assertEquals(canonical, conflicted.conflict)
        assertTrue(conflicted.message!!.contains("conflict"))
        assertThrows(IllegalArgumentException::class.java) { conflicted.request("activity", "vineyard") }
    }

    @Test fun `wrong identity and absent response keys are not success`() {
        val link = PruningResourceLink(null, "operator", "Operator", "author")
        assertThrows(IllegalStateException::class.java) { link.accepting(PruningResourceCASResult("activity", true, null, null), "activity") }
        assertThrows(kotlinx.serialization.SerializationException::class.java) {
            json.decodeFromString<PruningResourceCASResult>("""{"activity_id":"activity","applied":true}""")
        }
    }

    @Test fun `missing baseline fields are not authoritative nulls`() {
        assertThrows(kotlinx.serialization.SerializationException::class.java) {
            json.decodeFromString<PruningResourceSnapshot>("""{"id":"activity","vineyard_id":"vineyard"}""")
        }
    }

    @Test fun `cross vineyard and two identities cannot produce a CAS request`() {
        val base = PruningResourceSnapshot("activity", "vineyard", null, null, null)
        val link = PruningResourceLink("crew", "operator", "Invalid", "author", expected = base)
        assertThrows(IllegalArgumentException::class.java) { link.request("activity", "vineyard") }
        assertThrows(IllegalArgumentException::class.java) { link.copy(workerUserId = null).request("activity", "other-vineyard") }
    }

    @Test fun `serialized draft preserves retry baseline conflict snapshot and costing`() {
        val base = PruningResourceSnapshot("activity", "vineyard", "2026-10-08T00:00:00.123456Z", null, null)
        val canonical = base.copy(workerUserId = "portal-operator")
        val link = PruningResourceLink("crew", null, "Crew", "author", expected = base, conflict = canonical)
        val draft = PruningActivityDraft("activity", "vineyard", "2026-10-08", worker = "Crew", resourceSnapshot = base, resourceLink = link, labourHours = 8.0, hourlyRate = 25.0)
        val recovered = json.decodeFromString<PruningActivityDraft>(json.encodeToString(PruningActivityDraft.serializer(), draft))
        assertEquals(link, recovered.resourceLink)
        assertEquals(200.0, recovered.labourCost!!, 0.0)
        assertEquals(base, recovered.resourceSnapshot)
    }

    @Test fun `legacy draft absence never becomes an intentional resource clear`() {
        val draft = json.decodeFromString<PruningActivityDraft>("""{"id":"legacy","vineyardId":"vineyard","date":"2026-10-08","worker":"Historical crew"}""")
        assertNull(draft.resourceLink)
        assertNull(draft.resourceSnapshot)
        assertEquals("Historical crew", draft.worker)
    }

    @Test fun `stage compatibility dates do not become plans or completion limits`() {
        val stage = WorkTask("task", "vineyard", date = "2027-01-01T00:00:00Z", scheduleBasis = "el_stage", targetELStage = 35)
        assertNull(stage.startEpochMs)
        assertNull(WorkTaskCompletion.workDate(stage, ZoneId.of("UTC")))
        assertTrue(stage.matchesStageRange(35, 35))
        assertFalse(stage.matchesStageRange(36, 43))
        assertTrue(WorkTaskCompletion.isValid(stage, LocalDate.parse("2026-10-08"), ZoneId.of("UTC"), Instant.parse("2026-10-08T12:00:00Z")))
        assertFalse(stage.copy(scheduleBasis = "date").matchesStageRange(1, 43))
    }
}
