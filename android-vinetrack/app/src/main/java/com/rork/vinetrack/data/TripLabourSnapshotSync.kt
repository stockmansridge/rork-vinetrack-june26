package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.Trip
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Durable original-fact journal. Financial values never enter the operational Trip row. */
class TripLabourSnapshotSync(
    private val session: SessionStore,
    private val pending: PendingWriteRepository,
    private val trips: TripRepository,
) {
    @Serializable
    data class Snapshot(
        val tripId: String,
        val workerUserId: String?,
        val workerTypeId: String?,
        val workerTypeName: String?,
        val hourlyRate: Double?,
        val capturedAt: String,
    )

    private fun captureArgs(snapshot: Snapshot): JsonObject = buildJsonObject {
        put("p_trip_id", JsonPrimitive(snapshot.tripId))
        put("p_worker_user_id", snapshot.workerUserId?.let(::JsonPrimitive) ?: JsonNull)
        put("p_worker_type_id", snapshot.workerTypeId?.let(::JsonPrimitive) ?: JsonNull)
        put("p_worker_type_name", snapshot.workerTypeName?.let(::JsonPrimitive) ?: JsonNull)
        put("p_hourly_rate", snapshot.hourlyRate?.let(::JsonPrimitive) ?: JsonNull)
        put("p_captured_at", JsonPrimitive(snapshot.capturedAt))
    }

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    /** First writer wins. Repeated start callbacks never replace original rate or timestamp. */
    fun record(snapshot: Snapshot) {
        if (pending.list().any { it.entityType == PendingEntityType.TRIP_LABOUR && it.clientId == snapshot.tripId }) return
        pending.enqueue(PendingEntityType.TRIP_LABOUR, PendingOpType.CREATE,
            json.encodeToString(Snapshot.serializer(), snapshot), snapshot.tripId)
    }

    /** Captures first, then finalises only after the server records the actual end clocks. */
    suspend fun replay(tripId: String? = null) {
        if (session.accessToken == null) return
        val writes = pending.list().filter {
            it.entityType == PendingEntityType.TRIP_LABOUR && it.status in PendingWriteStatus.unresolved &&
                (tripId == null || it.clientId == tripId)
        }
        for (write in writes) {
            val snapshot = runCatching { json.decodeFromString(Snapshot.serializer(), write.payloadJson) }.getOrNull()
            if (snapshot == null) {
                pending.updateStatus(write.id, PendingWriteStatus.BLOCKED, "Saved Trip labour facts are unreadable.")
                continue
            }
            try {
                val server = trips.fetchTrip(snapshot.tripId) ?: continue
                val captured = rpc("capture_trip_labour_start_v1", captureArgs(snapshot))
                if (!captured) {
                    pending.updateStatus(write.id, PendingWriteStatus.FAILED, "Trip labour start needs to sync.")
                    continue
                }
                if (server.endTime != null && !server.isActive) {
                    if (rpc("finalise_trip_labour_v1", buildJsonObject { put("p_trip_id", JsonPrimitive(snapshot.tripId)) })) pending.remove(write.id)
                    else pending.updateStatus(write.id, PendingWriteStatus.FAILED, "Trip labour finalisation needs to sync.")
                }
            } catch (_: Exception) {
                pending.updateStatus(write.id, PendingWriteStatus.FAILED, "Trip labour will retry when connected.")
            }
        }
    }

    private suspend fun rpc(name: String, payload: JsonObject): Boolean {
        val token = session.accessToken ?: return false
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer $token")
            }
            contentType(ContentType.Application.Json)
            setBody(payload)
        }
        return response.status.isSuccess()
    }
}
