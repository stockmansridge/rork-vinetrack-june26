package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.BackendError
import com.rork.vinetrack.data.SupabaseClient
import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.content.ByteArrayContent
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Ktor-backed implementation of [VineyardInsightsSyncApi] against Supabase
 * (SQL 236).
 *
 * The payload shapes and the rules about what is and is not sent live on the
 * interface. This class is only the transport, so the replay rules in
 * [VineyardInsightsSyncWorker] can be exercised off-device against a fake.
 */
class VineyardInsightsSyncRepository(
    private val session: SessionStore,
) : VineyardInsightsSyncApi {

    // Full revision snapshots explicitly clear nullable columns. Partial PATCH DTOs
    // contain only the fields they own; omitted columns remain unchanged.
    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    private val payloadJson = Json(SupabaseClient.json) { explicitNulls = true; encodeDefaults = true }

    @Serializable
    private data class SoftDeletePatch(
        @SerialName("deleted_at") val deletedAt: String,
        @SerialName("client_updated_at") val clientUpdatedAt: String,
        @SerialName("client_revision_id") val clientRevisionId: String,
    )

    @Serializable
    private data class SoftDeleteNoteArgs(@SerialName("p_id") val id: String)

    @Serializable
    private data class ClaimCleanupArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_limit") val limit: Int,
    )

    @Serializable
    private data class CompleteCleanupArgs(
        @SerialName("p_id") val id: String,
        @SerialName("p_lease_token") val leaseToken: String,
    )

    @Serializable
    private data class FailCleanupArgs(
        @SerialName("p_id") val id: String,
        @SerialName("p_lease_token") val leaseToken: String,
        @SerialName("p_error") val error: String,
    )

    // ----------------------------------------------------------- Scout push
    //
    // Parent-first, always: visit, then assessments, then observations, then
    // photo rows. The SQL 236 foreign keys are real, so replaying a child
    // before its parent would be rejected. Ordering it here means offline
    // replay never depends on the order the operator happened to tap.

    override suspend fun pushVisit(
        visit: VineyardInsightsSyncApi.VisitUpsert,
        assessments: List<VineyardInsightsSyncApi.AssessmentUpsert>,
        observations: List<VineyardInsightsSyncApi.ObservationUpsert>,
    ): VineyardInsightsSyncApi.VisitRow = withContext(Dispatchers.IO) {
        val acknowledged = upsertVisitReturning(visit)
        // Release the active (visit, block) key before sending a re-selection.
        for (rows in listOf(assessments.filter { it.deletedAt != null }, assessments.filter { it.deletedAt == null })) {
            for (batch in rows.chunked(100)) {
                upsert("scout_block_assessments", batch, VineyardInsightsSyncApi.AssessmentUpsert.serializer())
            }
        }
        for (batch in observations.chunked(100)) {
            upsert("scout_observations", batch, VineyardInsightsSyncApi.ObservationUpsert.serializer())
        }
        acknowledged
    }

    override suspend fun pushPhotoRow(photo: VineyardInsightsSyncApi.PhotoUpsert) =
        withContext(Dispatchers.IO) {
            upsert(
                "scout_observation_photos",
                listOf(photo),
                VineyardInsightsSyncApi.PhotoUpsert.serializer(),
            )
        }

    /**
     * Upload photo bytes into the private `scout-photos` bucket.
     *
     * The path's first folder is the vineyard id because the SQL 236 storage
     * policies authorise on `storage_first_folder_uuid(name)`.
     */
    override suspend fun uploadPhotoBytes(path: String, jpeg: ByteArray): String =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.storageUrl("object/$PHOTO_BUCKET/$path"),
            ) {
                authHeaders(token)
                headers {
                    // Upsert so a retry after an ambiguous failure overwrites
                    // its own object rather than failing forever on a conflict.
                    append("x-upsert", "true")
                    append("cache-control", "3600")
                }
                setBody(ByteArrayContent(jpeg, ContentType.Image.JPEG))
            }
            when {
                response.status.isSuccess() -> path
                response.status.value == 401 || response.status.value == 403 ->
                    throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Hard-remove a storage object that NO metadata row references.
     *
     * Used for exactly one case: the operator deleted a photograph after its
     * bytes reached the bucket but before the row was written. That object is
     * unreachable by every client, so leaving it would be invisible clutter the
     * vineyard is billed for and can never review. A fully stored photograph is
     * never hard-deleted here — its row is tombstoned and the object retained as
     * evidence.
     */
    override suspend fun downloadPhotoBytes(path: String): ByteArray = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.storageUrl("object/authenticated/$PHOTO_BUCKET/$path")) {
            authHeaders(token)
        }
        when {
            response.status.isSuccess() -> response.body<ByteArray>()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    override suspend fun removePhotoObject(path: String) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.delete(
            SupabaseClient.storageUrl("object/$PHOTO_BUCKET/$path"),
        ) {
            authHeaders(token)
        }
        when {
            response.status.isSuccess() -> Unit
            // Already gone is the desired end state, not a failure.
            response.status.value == 404 -> Unit
            response.status.value == 401 || response.status.value == 403 ->
                throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /** Canonical permanent deletion with ledger, child cascades and durable Storage cleanup. */
    override suspend fun hardDeleteVisit(
        id: String,
        vineyardId: String,
        operationId: String,
        atIso: String,
    ) = withContext(Dispatchers.IO) {
        requireConfig()
        val userId = session.userId ?: throw BackendError.Unauthorized
        val token = session.accessToken ?: throw BackendError.Unauthorized
        suspend fun checkBoolean(rpc: String, body: String): Boolean {
            val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(rpc)) {
                authHeaders(token)
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            checkWrite(response.status.value) { response.bodyAsText() }
            check(session.userId == userId) { "Account changed; local Scout retained." }
            return response.body<Boolean>()
        }
        val preview = checkBoolean("can_use_vineyard_insights",
            payloadJson.encodeToString(ScoutPreviewArgs.serializer(), ScoutPreviewArgs(vineyardId)))
        val role = checkBoolean("has_vineyard_role",
            payloadJson.encodeToString(ScoutDeleteRoleArgs.serializer(), ScoutDeleteRoleArgs(vineyardId, listOf("owner", "manager"))))
        check(preview && role) {
            "Delete denied: only this vineyard’s Owner or Manager may delete Scouts. Local information has been retained."
        }
        val args = VineyardInsightsSyncApi.HardDeleteVisitArgs(
            vineyardId = vineyardId, visitId = id, operationId = operationId, deletedAt = atIso)
        val acknowledged = checkBoolean("hard_delete_scout_visit",
            payloadJson.encodeToString(VineyardInsightsSyncApi.HardDeleteVisitArgs.serializer(), args))
        check(acknowledged) { "Scout deletion was not acknowledged. Local information has been retained." }
    }

    @Serializable
    private data class ScoutPreviewArgs(@SerialName("p_vineyard_id") val vineyardId: String)

    @Serializable
    private data class ScoutDeleteRoleArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("allowed_roles") val roles: List<String>,
    )

    override suspend fun softDeletePhoto(
        revision: VineyardInsightsStore.PhotoDeletionRevision,
    ) = withContext(Dispatchers.IO) {
        patchRows(
            "scout_observation_photos?id=eq.${revision.photoId}",
            SoftDeletePatch(revision.deletedAt, revision.deletedAt, revision.id),
        )
    }

    // ----------------------------------------------------------- Scout pull

    override suspend fun fetchVisits(
        vineyardId: String,
        sinceIso: String?,
    ): List<VineyardInsightsSyncApi.VisitRow> =
        select(
            buildString {
                append("scout_visits?vineyard_id=eq.$vineyardId")
                if (sinceIso != null) append("&updated_at=gt.$sinceIso")
                append("&order=id.asc")
            },
        )

    override suspend fun fetchAssessments(
        vineyardId: String,
        visitIds: List<String>,
    ): List<VineyardInsightsSyncApi.AssessmentRow> =
        if (visitIds.isEmpty()) {
            emptyList()
        } else {
            visitIds.distinct().sorted().chunked(60).flatMap { ids ->
                select<VineyardInsightsSyncApi.AssessmentRow>(
                    "scout_block_assessments?vineyard_id=eq.$vineyardId&scout_visit_id=in.(${ids.joinToString(",")})&order=id.asc")
            }
        }

    override suspend fun fetchObservations(
        vineyardId: String,
        assessmentIds: List<String>,
    ): List<VineyardInsightsSyncApi.ObservationRow> =
        if (assessmentIds.isEmpty()) {
            emptyList()
        } else {
            assessmentIds.distinct().sorted().chunked(60).flatMap { ids ->
                select<VineyardInsightsSyncApi.ObservationRow>(
                    "scout_observations?vineyard_id=eq.$vineyardId&assessment_id=in.(${ids.joinToString(",")})&order=id.asc")
            }
        }

    override suspend fun fetchPhotos(
        vineyardId: String,
        observationIds: List<String>,
    ): List<VineyardInsightsSyncApi.PhotoRow> =
        if (observationIds.isEmpty()) {
            emptyList()
        } else {
            observationIds.distinct().sorted().chunked(60).flatMap { ids ->
                select<VineyardInsightsSyncApi.PhotoRow>(
                    "scout_observation_photos?vineyard_id=eq.$vineyardId&observation_id=in.(${ids.joinToString(",")})&order=id.asc")
            }
        }

    override suspend fun fetchNoteTypes(vineyardId: String): List<VineyardInsightsSyncApi.NoteTypeRow> =
        select(
            "vintage_note_types?select=id,vineyard_id,code,group_code,label,sort_order,is_system,is_active,deleted_at" +
                "&or=(vineyard_id.is.null,vineyard_id.eq.$vineyardId)&order=id.asc",
        )

    override suspend fun fetchNotes(
        vineyardId: String,
        sinceIso: String?,
    ): List<VineyardInsightsSyncApi.NoteRow> =
        select(
            buildString {
                append("vintage_notes?vineyard_id=eq.$vineyardId")
                if (sinceIso != null) append("&updated_at=gt.$sinceIso")
                append("&order=id.asc")
            },
        )

    override suspend fun fetchDeletions(
        vineyardId: String,
        deletedAtIso: String?,
    ): List<VineyardInsightsSyncApi.DeletionRow> = select(
        buildString {
            append("vineyard_insights_deletions?vineyard_id=eq.$vineyardId")
            if (deletedAtIso != null) append("&deleted_at=gte.$deletedAtIso")
            append("&order=deleted_at.asc,id.asc")
        },
    )

    override suspend fun claimPhotoCleanup(
        vineyardId: String,
        limit: Int,
    ): List<VineyardInsightsSyncApi.PhotoCleanupRow> = postRpcForRows(
        "claim_scout_photo_cleanup",
        ClaimCleanupArgs(vineyardId, limit),
    )

    override suspend fun acknowledgePhotoCleanup(id: String, leaseToken: String) {
        postRpc("complete_scout_photo_cleanup", CompleteCleanupArgs(id, leaseToken))
    }

    override suspend fun failPhotoCleanup(id: String, leaseToken: String, error: String) {
        postRpc("fail_scout_photo_cleanup", FailCleanupArgs(id, leaseToken, error.take(500)))
    }

    // ----------------------------------------------------------------- RPCs

    override suspend fun upsertNote(
        args: VineyardInsightsSyncApi.UpsertNoteArgs,
    ): VineyardInsightsSyncApi.NoteRow? = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("upsert_vintage_note")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(payloadJson.encodeToString(args))
        }
        when {
            response.status.isSuccess() ->
                response.body<List<VineyardInsightsSyncApi.NoteRow>>().firstOrNull()
            response.status.value == 401 || response.status.value == 403 ->
                throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    override suspend fun hardDeleteNote(
        id: String,
        vineyardId: String,
        operationId: String,
        atIso: String,
    ) = postRpc(
        rpc = "hard_delete_vintage_note",
        args = VineyardInsightsSyncApi.HardDeleteNoteArgs(
            vineyardId = vineyardId,
            noteId = id,
            operationId = operationId,
            deletedAt = atIso,
        ),
    )

    private suspend inline fun <reified T> postRpc(
        rpc: String,
        args: T,
    ) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(rpc)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(payloadJson.encodeToString(args))
        }
        checkWrite(response.status.value) { response.bodyAsText() }
    }

    private suspend inline fun <reified T, reified R> postRpcForRows(
        rpc: String,
        args: T,
    ): List<R> = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(rpc)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(payloadJson.encodeToString(args))
        }
        when {
            response.status.isSuccess() -> response.body<List<R>>()
            response.status.value == 401 || response.status.value == 403 ->
                throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    override suspend fun upsertNoteType(args: VineyardInsightsSyncApi.UpsertNoteTypeArgs) =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val response = SupabaseClient.http.post(
                SupabaseClient.rpcUrl("upsert_vintage_note_type"),
            ) {
                authHeaders(token)
                contentType(ContentType.Application.Json)
                setBody(payloadJson.encodeToString(args))
            }
            checkWrite(response.status.value) { response.bodyAsText() }
        }

    // ------------------------------------------------------------- Plumbing

    private suspend inline fun <reified T> select(path: String): List<T> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val rows = mutableListOf<T>()
            var continuation: String? = null
            val ledger = path.startsWith("vineyard_insights_deletions?")
            while (true) {
                val pagePath = path + "&limit=200" + (continuation ?: "")
                val response = SupabaseClient.http.get(SupabaseClient.restUrl(pagePath)) { authHeaders(token) }
                checkWrite(response.status.value) { response.bodyAsText() }
                check(session.accessToken == token) { "Account changed during Insights pull." }
                val page = response.body<List<T>>()
                if (page.isEmpty()) break
                rows.addAll(page)
                val last = payloadJson.encodeToJsonElement(kotlinx.serialization.serializer<T>(), page.last())
                    as kotlinx.serialization.json.JsonObject
                val id = (last.getValue("id") as kotlinx.serialization.json.JsonPrimitive).content
                val next = if (ledger) {
                    val at = java.net.URLEncoder.encode(
                        (last.getValue("deleted_at") as kotlinx.serialization.json.JsonPrimitive).content, "UTF-8")
                    "&or=(deleted_at.gt.$at,and(deleted_at.eq.$at,id.gt.$id))"
                } else "&id=gt.$id"
                check(next != continuation) { "Insights pagination did not advance." }
                continuation = next
            }
            rows
        }

    private suspend fun upsertVisitReturning(
        visit: VineyardInsightsSyncApi.VisitUpsert,
    ): VineyardInsightsSyncApi.VisitRow {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = payloadJson.encodeToString(
            kotlinx.serialization.builtins.ListSerializer(VineyardInsightsSyncApi.VisitUpsert.serializer()),
            listOf(visit),
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("scout_visits")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            headers { append("Prefer", "resolution=merge-duplicates,return=representation") }
            setBody(body)
        }
        return when {
            response.status.isSuccess() -> response.body<List<VineyardInsightsSyncApi.VisitRow>>().first()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private suspend fun <T> upsert(
        table: String,
        rows: List<T>,
        serializer: kotlinx.serialization.KSerializer<T>,
    ) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val body = payloadJson.encodeToString(
            kotlinx.serialization.builtins.ListSerializer(serializer),
            rows,
        )
        val response = SupabaseClient.http.post(SupabaseClient.restUrl(table)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            headers { append("Prefer", "resolution=merge-duplicates,return=minimal") }
            setBody(body)
        }
        checkWrite(response.status.value) { response.bodyAsText() }
    }

    private suspend fun patchRows(path: String, patch: SoftDeletePatch) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.patch(SupabaseClient.restUrl(path)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            headers { append("Prefer", "return=minimal") }
            setBody(patch)
        }
        checkWrite(response.status.value) { response.bodyAsText() }
    }

    private suspend fun checkWrite(status: Int, body: suspend () -> String) {
        when {
            status in 200..299 -> Unit
            status == 401 || status == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(status, body())
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

    companion object {
        const val PHOTO_BUCKET = "scout-photos"
    }
}
