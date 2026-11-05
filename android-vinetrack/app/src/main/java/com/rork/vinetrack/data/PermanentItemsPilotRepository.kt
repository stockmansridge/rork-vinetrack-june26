package com.rork.vinetrack.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.headers
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import java.io.ByteArrayOutputStream
import java.util.UUID

/** Issue #53. Separate from existing Pins and all Trip/Spray journals. */
object PermanentItemPilotPolicy {
    const val FLAG = "permanent_items_admin_preview"
    val TYPES = linkedMapOf(
        "irrigation_valve" to "Irrigation Valve", "flush_valve" to "Flush Valve",
        "pump" to "Pump", "filter" to "Filter", "tank" to "Tank",
        "gate" to "Gate", "water_point" to "Water Point", "other" to "Other"
    )
    fun valid(name: String, type: String, lat: Double, lon: Double): Boolean =
        name.trim().length in 1..100 && type in TYPES &&
            lat.isFinite() && lon.isFinite() && lat in -90.0..90.0 && lon in -180.0..180.0
    fun allowed(admin: Boolean, flag: Boolean, user: String?, vineyard: String?, role: String?): Boolean =
        admin && flag && !user.isNullOrBlank() && !vineyard.isNullOrBlank() && !role.isNullOrBlank()
}

@Serializable
data class PermanentItemPilotRow(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("paddock_id") val paddockId: String? = null,
    val name: String,
    @SerialName("item_type") val itemType: String,
    val latitude: Double,
    val longitude: Double,
    val notes: String? = null,
    @SerialName("photo_path") val photoPath: String? = null,
    @SerialName("server_revision") val serverRevision: Long = 1,
    @SerialName("archived_at") val archivedAt: String? = null
)

@Serializable
data class PermanentItemPilotOperation(
    @SerialName("p_operation_id") val operationId: String,
    @SerialName("p_action") val action: String,
    @SerialName("p_item_id") val itemId: String,
    @SerialName("p_vineyard_id") val vineyardId: String,
    @SerialName("p_expected_revision") val expectedRevision: Long? = null,
    @SerialName("p_name") val name: String? = null,
    @SerialName("p_item_type") val itemType: String? = null,
    @SerialName("p_latitude") val latitude: Double? = null,
    @SerialName("p_longitude") val longitude: Double? = null,
    @SerialName("p_paddock_id") val paddockId: String? = null,
    @SerialName("p_notes") val notes: String? = null,
    @SerialName("p_photo_path") val photoPath: String? = null
)

@Serializable
private data class PermanentItemPilotReceipt(
    @SerialName("item_id") val itemId: String,
    @SerialName("server_revision") val serverRevision: Long,
    @SerialName("operation_id") val operationId: String
)

/**
 * Persist one unconfirmed operation per account+vineyard before network dispatch.
 * Replays retain the original UUID and exact payload; only server read-back
 * clears it. Never share queues, acknowledgements or snapshots with Trips/Pins.
 */
class PermanentItemsPilotRepository(context: Context) {
    private val session = SessionStore(context.applicationContext)
    private val json = SupabaseClient.json
    private val prefs = context.applicationContext.getSharedPreferences(
        "permanent_items_pilot_pending_v1", Context.MODE_PRIVATE
    )
    private fun key(vineyard: String, account: String) = "$account|$vineyard"

    private fun requireScope(vineyard: String, account: String) {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        if (session.userId != account || session.selectedVineyardId != vineyard ||
            session.accessToken.isNullOrBlank())
            throw SecurityException("Account or vineyard changed. This write was not sent.")
    }
    private fun actor(vineyard: String): String {
        val account = session.userId ?: throw BackendError.Unauthorized
        requireScope(vineyard, account)
        return account
    }
    private fun token() = session.accessToken ?: throw BackendError.Unauthorized

    fun pending(vineyard: String): PermanentItemPilotOperation? {
        val account = session.userId ?: return null
        if (session.selectedVineyardId != vineyard) return null
        return prefs.getString(key(vineyard, account), null)?.let {
            runCatching { json.decodeFromString<PermanentItemPilotOperation>(it) }.getOrNull()
        }
    }
    suspend fun pilotEnabled(vineyard: String): Boolean = withContext(Dispatchers.IO) {
        val account = actor(vineyard)
        val admin = SystemAdminRepository(session)
        if (!admin.isSystemAdmin()) return@withContext false
        val flag = admin.fetchFlags().any { it.key == PermanentItemPilotPolicy.FLAG && it.isEnabled }
        requireScope(vineyard, account)
        flag
    }
    suspend fun list(vineyard: String): List<PermanentItemPilotRow> = withContext(Dispatchers.IO) {
        val account = actor(vineyard)
        val response = SupabaseClient.http.get(SupabaseClient.restUrl("permanent_items")) {
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer " + token()) }
            url {
                parameters.append("select", "id,vineyard_id,paddock_id,name,item_type,latitude,longitude,notes,photo_path,server_revision,archived_at")
                parameters.append("vineyard_id", "eq.$vineyard")
                parameters.append("order", "name.asc")
            }
        }
        val text = succeeded(response.status.value, response.bodyAsText())
        requireScope(vineyard, account)
        json.decodeFromString<List<PermanentItemPilotRow>>(text)
    }
    fun operation(vineyard: String, action: String, previous: PermanentItemPilotRow?,
                  name: String, type: String, lat: Double, lon: Double, block: String?,
                  notes: String?, photo: String? = previous?.photoPath): PermanentItemPilotOperation {
        require(action in setOf("create", "update", "archive"))
        if (action != "archive") require(PermanentItemPilotPolicy.valid(name, type, lat, lon))
        if (action != "create") require(previous != null && previous.vineyardId == vineyard && previous.archivedAt == null)
        return PermanentItemPilotOperation(
            UUID.randomUUID().toString(), action, previous?.id ?: UUID.randomUUID().toString(),
            vineyard, previous?.serverRevision, name.trim(), type, lat, lon, block,
            notes?.trim()?.ifBlank { null }, photo
        )
    }
    suspend fun commit(op: PermanentItemPilotOperation): PermanentItemPilotRow =
        withContext(Dispatchers.IO) {
            val vineyard = op.vineyardId
            val account = actor(vineyard)
            val existing = pending(vineyard)
            if (existing != null && existing.operationId != op.operationId)
                error("A previous Permanent Item save is pending. Retry it first.")
            if (existing == null) {
                check(prefs.edit().putString(key(vineyard, account), json.encodeToString(op)).commit()) {
                    "Unable to persist the operation on this device."
                }
            }
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("apply_permanent_item_v1")) {
                headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer " + token()) }
                contentType(ContentType.Application.Json)
                setBody(op)
            }
            val receipt = json.decodeFromString<List<PermanentItemPilotReceipt>>(
                succeeded(response.status.value, response.bodyAsText())).singleOrNull()
            if (receipt == null || receipt.itemId != op.itemId || receipt.operationId != op.operationId ||
                receipt.serverRevision < 1) error("Server receipt mismatch. Retry the same operation.")
            requireScope(vineyard, account)
            val read = SupabaseClient.http.get(SupabaseClient.restUrl("permanent_items")) {
                headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer " + token()) }
                url {
                    parameters.append("select", "id,vineyard_id,paddock_id,name,item_type,latitude,longitude,notes,photo_path,server_revision,archived_at")
                    parameters.append("id", "eq." + op.itemId)
                    parameters.append("vineyard_id", "eq.$vineyard")
                    parameters.append("server_revision", "eq." + receipt.serverRevision)
                }
            }
            val verified = json.decodeFromString<List<PermanentItemPilotRow>>(
                succeeded(read.status.value, read.bodyAsText())).singleOrNull()
            if (verified == null || verified.id != op.itemId || verified.vineyardId != vineyard ||
                verified.serverRevision != receipt.serverRevision ||
                (op.action == "archive") != (verified.archivedAt != null) ||
                (op.action != "archive" && (verified.name != op.name || verified.itemType != op.itemType ||
                verified.latitude != op.latitude || verified.longitude != op.longitude ||
                verified.paddockId != op.paddockId || verified.notes != op.notes ||
                verified.photoPath != op.photoPath)))
                error("Server read-back differs; retry the same operation.")
            requireScope(vineyard, account)
            check(prefs.edit().remove(key(vineyard, account)).commit()) {
                "Write verified but local receipt still pending; retry the same operation."
            }
            verified
        }
    suspend fun retry(vineyard: String): PermanentItemPilotRow =
        commit(pending(vineyard) ?: error("No pending operation."))

    /** Upload after row creation only. Unique private path, no overwrite. */
    suspend fun uploadJpeg(vineyard: String, itemId: String, raw: ByteArray): String =
        withContext(Dispatchers.IO) {
            val account = actor(vineyard)
            val bitmap = BitmapFactory.decodeByteArray(raw, 0, raw.size)
                ?: error("Invalid photo.")
            val ratio = minOf(1.0, 1600.0 / maxOf(bitmap.width, bitmap.height).coerceAtLeast(1))
            val w = (bitmap.width * ratio).toInt().coerceAtLeast(1)
            val h = (bitmap.height * ratio).toInt().coerceAtLeast(1)
            val scaled = if (w == bitmap.width && h == bitmap.height) bitmap
                else Bitmap.createScaledBitmap(bitmap, w, h, true)
            val output = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 75, output)
            if (scaled !== bitmap) scaled.recycle()
            bitmap.recycle()
            val jpeg = output.toByteArray()
            require(jpeg.isNotEmpty() && jpeg.size <= 5 * 1024 * 1024) {
                "Photo exceeds private storage limit (5 MiB)."
            }
            val path = vineyard.lowercase() + "/" + itemId.lowercase() + "/" +
                UUID.randomUUID().toString().lowercase() + ".jpg"
            val response = SupabaseClient.http.post(
                SupabaseClient.storageUrl("object/permanent-item-photos/$path")) {
                headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer " + token()) }
                contentType(ContentType.Image.JPEG)
                setBody(jpeg)
            }
            succeeded(response.status.value, response.bodyAsText())
            requireScope(vineyard, account)
            path
        }
    private fun succeeded(code: Int, body: String): String {
        if (code in 200..299) return body
        if (code == 401 || code == 403) throw BackendError.Unauthorized
        throw BackendError.Server(code, body)
    }
}
