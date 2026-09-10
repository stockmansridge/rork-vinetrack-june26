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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import java.util.UUID

sealed class ManualSprayMutationException(message: String) : Exception(message) {
    class StaleVersion : ManualSprayMutationException("This spray changed on another device. Reload it and reconcile your changes before saving again.")
    class Deleted : ManualSprayMutationException("This manual spray has already been deleted. Its saved retry was discarded.")

    companion object {
        fun classify(error: Throwable): ManualSprayMutationException? {
            if (error is ManualSprayMutationException) return error
            val diagnostic = buildString {
                append(error.message.orEmpty())
                if (error is BackendError.Server) append(' ').append(error.body)
            }
            return when {
                "40001" in diagnostic -> StaleVersion()
                "55000" in diagnostic -> Deleted()
                else -> null
            }
        }
    }
}

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
    private val mutex = Mutex()
    private var operations: List<PendingManualSprayOperation> = store.load()

    fun pendingOperations(): List<PendingManualSprayOperation> = operations

    fun pendingPayloads(): List<ManualSprayPayload> {
        val deleted = operations.filter { it.kind == PendingManualSprayKind.DELETE }
            .map { it.payload.vineyardId to it.payload.manualEntryId }.toSet()
        return operations.filter {
            it.kind == PendingManualSprayKind.SAVE && (it.payload.vineyardId to it.payload.manualEntryId) !in deleted
        }.map { it.payload }
    }

    suspend fun save(payload: ManualSprayPayload, expectedVersion: Int?): ManualSpraySaveResponse? = mutex.withLock {
        payload.validationError()?.let { throw IllegalArgumentException(it) }
        val sameIdentity = operations.firstOrNull {
            it.kind == PendingManualSprayKind.SAVE && it.payload.vineyardId == payload.vineyardId &&
                it.payload.manualEntryId == payload.manualEntryId
        }
        if (sameIdentity != null && (sameIdentity.payload != payload || sameIdentity.expectedVersion != expectedVersion)) {
            throw IllegalStateException("This manual spray already has an exact saved retry. Retry it before making further changes.")
        }
        val operation = sameIdentity ?: PendingManualSprayOperation(
            UUID.randomUUID().toString(), PendingManualSprayKind.SAVE, payload, expectedVersion,
        ).also { created -> persist(operations + created, "The complete manual spray could not be saved on this device.") }
        return@withLock runCatching { gateway.save(operation.id, operation.payload, operation.expectedVersion) }.fold(
            onSuccess = { response ->
                if (!response.matches(operation)) {
                    markFailed(operation.id, IllegalStateException("The server did not confirm this exact manual spray."))
                    null
                } else {
                    persist(operations.filterNot { it.id == operation.id }, "The server saved the spray, but confirmation could not be retained.")
                    response
                }
            },
            onFailure = { error ->
                val terminal = ManualSprayMutationException.classify(error)
                if (terminal != null) {
                    persist(operations.filterNot { it.id == operation.id }, "The rejected spray retry could not be cleared from this device.")
                    throw terminal
                }
                markFailed(operation.id, error)
                null
            },
        )
    }

    suspend fun delete(payload: ManualSprayPayload): Boolean = mutex.withLock {
        val sameIdentity: (PendingManualSprayOperation) -> Boolean = {
            it.payload.vineyardId == payload.vineyardId && it.payload.manualEntryId == payload.manualEntryId
        }
        val existingDelete = operations.firstOrNull { it.kind == PendingManualSprayKind.DELETE && sameIdentity(it) }
        val operation = existingDelete ?: PendingManualSprayOperation(
            UUID.randomUUID().toString(), PendingManualSprayKind.DELETE, payload,
        ).also { created ->
            persist(operations.filterNot(sameIdentity) + created, "The manual spray deletion could not be saved on this device.")
        }
        return@withLock runCatching { gateway.delete(operation.id, operation.payload) }.fold(
            onSuccess = {
                persist(operations.filterNot { it.id == operation.id }, "The server deleted the spray, but confirmation could not be retained.")
                true
            },
            onFailure = { error -> markFailed(operation.id, error); false },
        )
    }

    suspend fun replay(roleForVineyard: (String) -> String?) = mutex.withLock {
        operations.toList().forEach { operation ->
            if (!canManageManualSprays(roleForVineyard(operation.payload.vineyardId))) return@forEach
            val identity = operation.payload.vineyardId to operation.payload.manualEntryId
            if (operation.kind == PendingManualSprayKind.SAVE && operations.any {
                    it.kind == PendingManualSprayKind.DELETE && (it.payload.vineyardId to it.payload.manualEntryId) == identity
                }) return@forEach
            try {
                if (operation.kind == PendingManualSprayKind.SAVE) {
                    val response = gateway.save(operation.id, operation.payload, operation.expectedVersion)
                    if (!response.matches(operation)) {
                        markFailed(operation.id, IllegalStateException("The server did not confirm this exact manual spray."))
                        return@forEach
                    }
                } else gateway.delete(operation.id, operation.payload)
                persist(operations.filterNot { it.id == operation.id }, "The server confirmed a manual spray operation, but that confirmation could not be retained.")
            } catch (error: Throwable) {
                if (ManualSprayMutationException.classify(error) != null) {
                    persist(operations.filterNot { it.id == operation.id }, "The rejected manual spray retry could not be cleared from this device.")
                } else markFailed(operation.id, error)
            }
        }
    }

    private fun ManualSpraySaveResponse.matches(operation: PendingManualSprayOperation): Boolean =
        serverConfirmed && source == "manual" && status == "completed" && operationId == operation.id &&
            manualEntryId == operation.payload.manualEntryId && sprayRecordId == operation.payload.sprayRecordId &&
            tripId == operation.payload.tripId

    private fun persist(candidate: List<PendingManualSprayOperation>, message: String) {
        check(store.save(candidate)) { message }
        operations = candidate
    }

    private fun markFailed(id: String, error: Throwable) {
        val candidate = operations.map {
            if (it.id == id) it.copy(attemptCount = it.attemptCount + 1, lastError = error.message ?: "No connection") else it
        }
        if (store.save(candidate)) operations = candidate
    }
}
