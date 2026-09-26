package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.OperatorCategory
import com.rork.vinetrack.data.model.WorkTaskLabourLine
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.resolveTripOperatorCategory
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WorkerTypeIntegrityTest {
    @Test fun `server shaped worker type retains Mitch identity and hourly rate`() {
        val json = """[{"id":"14a43189-ebe4-4343-80d0-baa4a738b008","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Vineyard Manager (Mitch)","cost_per_hour":38,"created_at":"2026-09-01T12:34:56.123456+00:00","updated_at":"2026-09-02T12:34:56+00:00","deleted_at":null,"client_updated_at":null}]"""
        val rows = SupabaseClient.json.decodeFromString(ListSerializer(OperatorCategory.serializer()), json)
        assertEquals(1, rows.size)
        assertEquals("14a43189-ebe4-4343-80d0-baa4a738b008", rows.single().id)
        assertEquals("Vineyard Manager (Mitch)", rows.single().name)
        assertEquals(38.0, rows.single().costPerHour!!, 0.001)
        assertNull(rows.single().deletedAt)
    }

    @Test fun `audited seven worker types preserve id name and rate`() {
        val json = """[
            {"id":"f8f0700e-01e6-4e76-96ce-d8f2d0c9f3b9","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Contractor","cost_per_hour":55},
            {"id":"82eaf220-fd6a-4ba8-a9f3-0f54fdef7fbc","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"General Hand","cost_per_hour":32},
            {"id":"3359a58a-b3b1-4cd6-9fb2-d3a38f435499","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Tractor Operator","cost_per_hour":45},
            {"id":"150f6f18-eab4-4c3c-bb5f-613e98d254da","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Victoria Labour Hire ($32/Hr)","cost_per_hour":32},
            {"id":"c0f3b25f-6abb-4617-86e0-7f5f24eda739","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Victoria Labour Hire ($35/Hr)","cost_per_hour":35},
            {"id":"79fe2c89-05c5-4b2e-8202-65066a7e8b24","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Vineyard Manager","cost_per_hour":65},
            {"id":"14a43189-ebe4-4343-80d0-baa4a738b008","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","name":"Vineyard Manager (Mitch)","cost_per_hour":38}
        ]"""
        val rows = SupabaseClient.json.decodeFromString(ListSerializer(OperatorCategory.serializer()), json)
        assertEquals(7, rows.size)
        val expected = listOf(
            Triple("f8f0700e-01e6-4e76-96ce-d8f2d0c9f3b9", "Contractor", 55.0),
            Triple("82eaf220-fd6a-4ba8-a9f3-0f54fdef7fbc", "General Hand", 32.0),
            Triple("3359a58a-b3b1-4cd6-9fb2-d3a38f435499", "Tractor Operator", 45.0),
            Triple("150f6f18-eab4-4c3c-bb5f-613e98d254da", "Victoria Labour Hire ($32/Hr)", 32.0),
            Triple("c0f3b25f-6abb-4617-86e0-7f5f24eda739", "Victoria Labour Hire ($35/Hr)", 35.0),
            Triple("79fe2c89-05c5-4b2e-8202-65066a7e8b24", "Vineyard Manager", 65.0),
            Triple("14a43189-ebe4-4343-80d0-baa4a738b008", "Vineyard Manager (Mitch)", 38.0),
        )
        expected.forEach { (id, name, rate) ->
            val row = rows.single { it.id == id }
            assertEquals(name, row.name)
            assertEquals(rate, row.costPerHour!!, 0.001)
        }
    }

    @Test fun `membership keeps saved manager default when worker type label is missing`() {
        val json = """[{"membership_id":"a37e4812-c559-4750-8da1-fb6fa5f98ce8","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","user_id":"4728e1e6-c538-4f0d-bc2f-6c9dcde9ac69","role":"manager","worker_type_id":"14a43189-ebe4-4343-80d0-baa4a738b008","worker_type_name":null}]"""
        val member = SupabaseClient.json.decodeFromString(ListSerializer(VineyardMember.serializer()), json).single()
        assertEquals("manager", member.role)
        assertEquals("14a43189-ebe4-4343-80d0-baa4a738b008", member.operatorCategoryId)
        assertNull(member.operatorCategoryName)
    }

    @Test fun `explicit none sends JSON null while reassignment sends exact ID`() {
        val cleared = workerTypeAssignmentArgs("vineyard", "user", null)
        assertEquals(JsonNull, cleared["p_worker_type_id"])
        val assigned = workerTypeAssignmentArgs("vineyard", "user", "14a43189-ebe4-4343-80d0-baa4a738b008")
        assertEquals("14a43189-ebe4-4343-80d0-baa4a738b008", assigned["p_worker_type_id"]?.jsonPrimitive?.content)
    }

    @Test fun `completed trip uses linked worker type for two hours and survives serialized reload`() {
        val trip = Trip(id = "trip-fixture", vineyardId = "fixture-vineyard", operatorUserId = "fixture-worker",
            operatorCategoryId = "fixture-type", startTime = "2026-09-01T08:00:00Z",
            endTime = "2026-09-01T10:00:00Z", isActive = false)
        val category = OperatorCategory(id = "fixture-type", vineyardId = "fixture-vineyard", name = "Fixture worker", costPerHour = 38.0)
        val restored = SupabaseClient.json.decodeFromString(Trip.serializer(), SupabaseClient.json.encodeToString(Trip.serializer(), trip))
        assertEquals("fixture-worker", restored.operatorUserId)
        assertEquals("fixture-type", restored.operatorCategoryId)
        assertEquals("fixture-type", resolveTripOperatorCategory(restored, listOf(category))?.id)
        val estimate = TripCostEstimator.estimate(restored, null, listOf(category), emptyList(), emptyList())
        assertEquals(2.0, estimate.labour.hours, 0.001)
        assertEquals(38.0, estimate.labour.costPerHour!!, 0.001)
        assertEquals(76.0, estimate.labour.cost, 0.001)
        assertEquals(0.0, TripCostEstimator.estimate(restored, null, emptyList(), emptyList(), emptyList()).labour.cost, 0.001)
    }

    @Test fun `completed trip should retain original rate after catalogue changes`() {
        val trip = Trip(id = "trip-fixture", vineyardId = "fixture-vineyard", operatorUserId = "fixture-worker",
            operatorCategoryId = "fixture-type", startTime = "2026-09-01T08:00:00Z",
            endTime = "2026-09-01T10:00:00Z", isActive = false)
        val oldRate = OperatorCategory("fixture-type", "fixture-vineyard", "Fixture worker", 38.0)
        val changedRate = oldRate.copy(costPerHour = 45.0)
        assertEquals(76.0, TripCostEstimator.estimate(trip, null, listOf(oldRate), emptyList(), emptyList()).labour.cost, 0.001)
        // Read-only estimate currently has no historical rate snapshot: regression stays red.
        assertEquals(76.0, TripCostEstimator.estimate(trip, null, listOf(changedRate), emptyList(), emptyList()).labour.cost, 0.001)
    }

    @Test fun `saved two hours at thirty eight retains identity snapshot and seventy six cost`() {
        val json = """[{"id":"11111111-1111-4111-8111-111111111111","work_task_id":"22222222-2222-4222-8222-222222222222","vineyard_id":"fe952afe-437f-4be7-8cbf-fdd8e630411c","work_date":"2026-09-01","worker_type_id":"14a43189-ebe4-4343-80d0-baa4a738b008","worker_type":"Vineyard Manager (Mitch)","worker_count":1,"hours_per_worker":2,"hourly_rate":38,"total_hours":2,"total_cost":76,"deleted_at":null}]"""
        val line = SupabaseClient.json.decodeFromString(ListSerializer(WorkTaskLabourLine.serializer()), json).single()
        assertEquals("14a43189-ebe4-4343-80d0-baa4a738b008", line.operatorCategoryId)
        assertEquals(2.0, WorkTaskLabourCosting.personHours(line), 0.001)
        assertEquals(76.0, WorkTaskLabourCosting.lineCost(line)!!, 0.001)
        assertEquals(76.0, line.totalCost!!, 0.001)
    }
}
