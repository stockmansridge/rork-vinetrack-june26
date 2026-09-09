package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.ManualSprayPayload
import com.rork.vinetrack.data.model.ManualSpraySaveResponse
import com.rork.vinetrack.data.model.canManageManualSprays
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.UUID

interface ManualSprayGateway {
    suspend fun save(operationId: String, payload: ManualSprayPayload, expectedVersion: Int?): ManualSpraySaveResponse
    suspend fun delete(operationId: String, payload: ManualSprayPayload)
}

class ManualSprayEntryRepository(private val session: SessionStore) : ManualSprayGateway {
    @Serializable private data class SaveArgs(
        @SerialName("p_operation_id") val operationId: String,
        @SerialName("p_payload") val payload: ManualSprayPayload,
        @SerialName("p_expected_version") val expectedVersion: Int? = null,
    )

    @Serializable private data class DeleteArgs(
        @SerialName("p_operation_id") val operationId: String,
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_manual_entry_id") val manualEntryId: String,
        @SerialName("p_spray_record_id") val sprayRecordId: String,
        @SerialName("p_trip_id") val tripId: String,
    )

    override suspend fun save(operationId: String, payload: ManualSprayPayload, expectedVersion: Int?): ManualSpraySaveResponse {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("save_manual_spray_v1")) {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            contentType(ContentType.Application.Json)
            setBody(SaveArgs(operationId, payload, expectedVersion))
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        return response.body()
    }

    override suspend fun delete(operationId: String, payload: ManualSprayPayload) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("delete_manual_spray_v1")) {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
            contentType(ContentType.Application.Json)
            setBody(DeleteArgs(operationId, payload.vineyardId, payload.manualEntryId, payload.sprayRecordId, payload.tripId))
        }
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
    }
}

@Serializable
enum class PendingManualSprayKind { SAVE, DELETE }

@Serializable
data class PendingManualSprayOperation(
    val id: String,
    val kind: PendingManualSprayKind,
    val payload: ManualSprayPayload,
    val expectedVersion: Int? = null,
    val attemptCount: Int = 0,
    val lastError: String? = null,
)

interface ManualSprayOperationStoring {
    fun load(): List<PendingManualSprayOperation>
    fun save(operations: List<PendingManualSprayOperation>): Boolean
}

class ManualSprayOperationStore(context: Context) : ManualSprayOperationStoring {
    private val preferences = context.applicationContext.getSharedPreferences("vinetrack_manual_spray_operations_v1", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    override fun load(): List<PendingManualSprayOperation> = preferences.getString("operations", null)?.let {
        runCatching { json.decodeFromString(ListSerializer(PendingManualSprayOperation.serializer()), it) }.getOrDefault(emptyList())
    } ?: emptyList()
    override fun save(operations: List<PendingManualSprayOperation>): Boolean = preferences.edit().putString("operations", json.encodeToString(ListSerializer(PendingManualSprayOperation.serializer()), operations)).commit()
}

class ManualSprayEntryCoordinator(
    private val gateway: ManualSprayGateway,
    private val store: ManualSprayOperationStoring,
) {
    private var operations: MutableList<PendingManualSprayOperation> = store.load().toMutableList()

    fun pendingPayloads(): List<ManualSprayPayload> {
        val deleted = operations.filter { it.kind == PendingManualSprayKind.DELETE }.map { it.payload.manualEntryId }.toSet()
        return operations.filter { it.kind == PendingManualSprayKind.SAVE && it.payload.manualEntryId !in deleted }.map { it.payload }
    }

    suspend fun save(payload: ManualSprayPayload, expectedVersion: Int?): ManualSpraySaveResponse? {
        payload.validationError()?.let { throw IllegalArgumentException(it) }
        operations.removeAll { it.kind == PendingManualSprayKind.SAVE && it.payload.manualEntryId == payload.manualEntryId }
        val operation = PendingManualSprayOperation(UUID.randomUUID().toString(), PendingManualSprayKind.SAVE, payload, expectedVersion)
        operations += operation
        check(store.save(operations)) { "The complete manual spray could not be saved on this device." }
        return runCatching { gateway.save(operation.id, payload, expectedVersion) }.fold(
            onSuccess = { response ->
                operations.removeAll { it.id == operation.id }
                check(store.save(operations)) { "The server saved the spray, but confirmation could not be retained." }
                response
            },
            onFailure = { error -> markFailed(operation.id, error); null },
        )
    }

    suspend fun delete(payload: ManualSprayPayload): Boolean {
        operations.removeAll { it.payload.manualEntryId == payload.manualEntryId }
        val operation = PendingManualSprayOperation(UUID.randomUUID().toString(), PendingManualSprayKind.DELETE, payload)
        operations += operation
        check(store.save(operations)) { "The manual spray deletion could not be saved on this device." }
        return runCatching { gateway.delete(operation.id, payload) }.fold(
            onSuccess = { operations.removeAll { it.id == operation.id }; store.save(operations); true },
            onFailure = { error -> markFailed(operation.id, error); false },
        )
    }

    suspend fun replay(currentRole: String?) {
        if (!canManageManualSprays(currentRole)) return
        operations.toList().forEach { operation ->
            if (operation.kind == PendingManualSprayKind.SAVE && operations.any { it.kind == PendingManualSprayKind.DELETE && it.payload.manualEntryId == operation.payload.manualEntryId }) return@forEach
            runCatching {
                if (operation.kind == PendingManualSprayKind.SAVE) gateway.save(operation.id, operation.payload, operation.expectedVersion)
                else gateway.delete(operation.id, operation.payload)
            }.onSuccess { operations.removeAll { it.id == operation.id }; store.save(operations) }
                .onFailure { markFailed(operation.id, it) }
        }
    }

    private fun markFailed(id: String, error: Throwable) {
        val index = operations.indexOfFirst { it.id == id }
        if (index < 0) return
        val current = operations[index]
        operations[index] = current.copy(attemptCount = current.attemptCount + 1, lastError = error.message ?: "No connection")
        store.save(operations)
    }
}
