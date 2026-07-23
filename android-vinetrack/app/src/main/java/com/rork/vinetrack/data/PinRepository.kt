package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.Pin
import io.ktor.client.call.body
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Write path for operational pins, mirroring the iOS pin sync behaviour.
 *
 * Inserts and updates go straight to the PostgREST `pins` table (RLS scopes
 * them to the signed-in user's vineyard role). Deletes route through the
 * `soft_delete_pin` RPC so the server enforces the manager/supervisor
 * permission and stamps `deleted_at` instead of hard-deleting.
 *
 * Display-only — it never mutates records it doesn't own and only sends the
 * fields the Android UI edits, leaving every other column untouched.
 */
class PinRepository(private val session: SessionStore) {

    /** Mutable fields the Android pin editor exposes. */
    @Serializable
    data class PinInput(
        // Client-generated stable UUID. Left null by callers; [createPin] fills it
        // before insert so the row id is idempotency-ready for future offline
        // replay. Mirrors the client-id style used by trip/operator-category creates.
        val id: String? = null,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String? = null,
        /** Active trip at drop time so the pin appears in that trip's detail (iOS parity). */
        @SerialName("trip_id") val tripId: String? = null,
        val title: String? = null,
        val category: String? = null,
        // iOS-parity identity columns: the launcher button's name and colour
        // token, stored on the row so every device renders the same colour
        // without needing the vineyard's button configuration.
        @SerialName("button_name") val buttonName: String? = null,
        @SerialName("button_color") val buttonColor: String? = null,
        val mode: String? = null,
        val notes: String? = null,
        val side: String? = null,
        /** Device bearing captured at drop time (degrees 0–360), when available. */
        val heading: Double? = null,
        @SerialName("row_number") val rowNumber: Int? = null,
        // Row-attachment columns, populated when a GPS launcher pin snaps to a
        // mapped vine row. Left null (and untouched) for non-snapped pins.
        @SerialName("pin_row_number") val pinRowNumber: Double? = null,
        @SerialName("pin_side") val pinSide: String? = null,
        @SerialName("along_row_distance_m") val alongRowDistanceM: Double? = null,
        @SerialName("is_completed") val isCompleted: Boolean = false,
        val latitude: Double? = null,
        val longitude: Double? = null,
        @SerialName("created_by") val createdBy: String? = null,
    )

    /** Subset of editable fields used for PATCH updates (no created_by overwrite). */
    @Serializable
    private data class PinPatch(
        @SerialName("paddock_id") val paddockId: String? = null,
        val title: String? = null,
        val category: String? = null,
        val mode: String? = null,
        val notes: String? = null,
        val side: String? = null,
        @SerialName("row_number") val rowNumber: Int? = null,
        @SerialName("is_completed") val isCompleted: Boolean,
        // Last-write-wins marker for normal online edits, matching the iOS pin
        // contract. Only normal field edits stamp this; completion/photo/delete
        // writes stay narrow and never send it.
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    /**
     * Completion-only PATCH body. Kept deliberately narrow (just `is_completed`)
     * so a completion toggle never overwrites title/notes/category/mode/row
     * fields that may have changed elsewhere. This is the safe write shape a
     * future offline completion queue would replay.
     */
    @Serializable
    private data class CompletionPatch(@SerialName("is_completed") val isCompleted: Boolean)

    @Serializable
    private data class PhotoPatch(@SerialName("photo_path") val photoPath: String?)

    /**
     * Descriptive-only PATCH body for offline text/category/mode edits (Stage
     * 9B-3). Deliberately narrow: it carries only the user-editable descriptive
     * fields plus the last-write-wins [clientUpdatedAt] stamp, so a delayed edit
     * replay can never clobber completion, photo, paddock, side, or row/snap
     * columns. This is the safe write shape [updatePinFields] replays.
     */
    @Serializable
    private data class EditPatch(
        val title: String? = null,
        val category: String? = null,
        val mode: String? = null,
        val notes: String? = null,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
    )

    @Serializable
    private data class SoftDeleteArgs(@SerialName("p_pin_id") val pinId: String)

    suspend fun createPin(input: PinInput): Pin = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        // Generate the pin id on the client so the insert carries a stable UUID.
        // Pins remain online-only here (no enqueue/replay); the client id simply
        // makes a future offline queue idempotent against retries.
        val body = input.copy(
            id = input.id ?: UUID.randomUUID().toString(),
            createdBy = input.createdBy ?: session.userId,
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("pins")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        when {
            response.status.isSuccess() -> response.body<List<Pin>>().firstOrNull()
                ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    suspend fun updatePin(
        id: String,
        paddockId: String?,
        title: String?,
        category: String?,
        mode: String?,
        notes: String?,
        side: String?,
        rowNumber: Int?,
        isCompleted: Boolean,
    ): Pin = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val patch = PinPatch(
            paddockId = paddockId,
            title = title,
            category = category,
            mode = mode,
            notes = notes,
            side = side,
            rowNumber = rowNumber,
            isCompleted = isCompleted,
            clientUpdatedAt = Instant.now().toString(),
        )
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("pins?id=eq.$id")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(patch)
        }
        when {
            response.status.isSuccess() -> response.body<List<Pin>>().firstOrNull()
                ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Update only a pin's completion state, leaving every other column
     * untouched. Separate from [updatePin] so a completion toggle can't clobber
     * editable fields changed by another device/user.
     */
    suspend fun updatePinCompletion(id: String, isCompleted: Boolean): Pin = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("pins?id=eq.$id")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(CompletionPatch(isCompleted))
        }
        when {
            response.status.isSuccess() -> response.body<List<Pin>>().firstOrNull()
                ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Set or clear a pin's `photo_path` after a storage upload/removal. Kept
     * separate from [updatePin] so photo writes don't disturb the editable
     * field set, and returns the reconciled row so the UI can refresh.
     */
    suspend fun updatePhotoPath(id: String, photoPath: String?): Pin = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("pins?id=eq.$id")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(PhotoPatch(photoPath))
        }
        when {
            response.status.isSuccess() -> response.body<List<Pin>>().firstOrNull()
                ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * PATCH only a pin's descriptive fields (title/category/mode/notes) with a
     * last-write-wins [clientUpdatedAt] stamp, leaving every other column
     * untouched (Stage 9B-3). Separate from [updatePin] so a queued offline
     * edit replay never disturbs completion, photo, paddock, side, or row/snap
     * fields changed elsewhere. Returns the reconciled server row.
     */
    suspend fun updatePinFields(
        id: String,
        title: String?,
        category: String?,
        mode: String?,
        notes: String?,
        clientUpdatedAt: String,
    ): Pin = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val patch = EditPatch(
            title = title,
            category = category,
            mode = mode,
            notes = notes,
            clientUpdatedAt = clientUpdatedAt,
        )
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl("pins?id=eq.$id")) {
            authHeaders(token)
            headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json)
            setBody(patch)
        }
        when {
            response.status.isSuccess() -> response.body<List<Pin>>().firstOrNull()
                ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Read a single live pin row (including its conflict metadata) for the edit
     * replay's stale-guard (Stage 9B-3). Returns null when the pin is missing
     * or soft-deleted, so the caller can block an edit against a vanished pin.
     */
    suspend fun fetchPin(id: String): Pin? = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(
            SupabaseClient.restUrl("pins?id=eq.$id&deleted_at=is.null&select=*"),
        ) {
            authHeaders(token)
        }
        when {
            response.status.isSuccess() -> response.body<List<Pin>>().firstOrNull()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    suspend fun softDeletePin(id: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("soft_delete_pin")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(SoftDeleteArgs(id))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun io.ktor.client.request.HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
}
