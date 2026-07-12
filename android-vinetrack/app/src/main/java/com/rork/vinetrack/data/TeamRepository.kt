package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.Invitation
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Write path for vineyard team management, mirroring the iOS
 * `SupabaseTeamRepository`. All mutations go through the shared SECURITY DEFINER
 * RPCs (sql/079) which enforce owner/manager permission server-side, so the
 * Android UI only needs to gate visibility — the server stays authoritative.
 */
class TeamRepository(private val session: SessionStore) {

    /** Pending invitations for a vineyard (joined to the vineyard name). */
    suspend fun listPendingInvitations(vineyardId: String): List<Invitation> =
        withContext(Dispatchers.IO) {
            requireConfig()
            val token = session.accessToken ?: throw BackendError.Unauthorized
            val path = "invitations?select=*,vineyards(name)" +
                "&vineyard_id=eq.$vineyardId&status=eq.pending&order=created_at.desc"
            val response = SupabaseClient.http.get(SupabaseClient.restUrl(path)) {
                authHeaders(token)
            }
            when {
                response.status.isSuccess() -> response.body()
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

    /**
     * Pending invitations visible to the signed-in user (RLS-scoped), joined to
     * the vineyard name. Mirrors the iOS `listPendingInvitations()` (no
     * vineyard filter) used by the first-login / waiting-for-invite flow;
     * callers filter to the user's own email client-side, exactly like iOS.
     */
    suspend fun listMyPendingInvitations(): List<Invitation> = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val path = "invitations?select=*,vineyards(name)&status=eq.pending&order=created_at.desc"
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(path)) {
            authHeaders(token)
        }
        when {
            response.status.isSuccess() -> response.body()
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    /**
     * Accepts an invitation via the `accept_invitation` RPC. Ensures the
     * caller's `profiles` row exists first (id + email upsert), mirroring the
     * iOS `SupabaseTeamRepository.acceptInvitation` — the RPC links the
     * membership to the profile, so a first-login user without a profile row
     * would otherwise fail.
     */
    suspend fun acceptInvitation(invitationId: String): Unit = withContext(Dispatchers.IO) {
        ensureMyProfileExists()
        rpc("accept_invitation", InvitationIdArg(invitationId))
    }

    /** Declines an invitation via the `decline_invitation` RPC (mirrors iOS). */
    suspend fun declineInvitation(invitationId: String): Unit = withContext(Dispatchers.IO) {
        rpc("decline_invitation", InvitationIdArg(invitationId))
    }

    /** Upserts the caller's `profiles` row (id + email) so RPCs that join to it succeed. */
    private suspend fun ensureMyProfileExists() = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val userId = session.userId ?: throw BackendError.Unauthorized
        val email = session.userEmail?.trim().orEmpty()
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("profiles?on_conflict=id")) {
            authHeaders(token)
            headers { append("Prefer", "resolution=merge-duplicates,return=minimal") }
            contentType(ContentType.Application.Json)
            setBody(ProfileUpsertArg(id = userId, email = email))
        }
        when {
            response.status.isSuccess() -> Unit
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    suspend fun updateMemberRole(vineyardId: String, userId: String, role: String) =
        rpc("update_member_role", UpdateRoleArgs(vineyardId, userId, role))

    suspend fun updateMemberOperatorCategory(vineyardId: String, userId: String, operatorCategoryId: String?) =
        rpc("update_member_worker_type", UpdateCategoryArgs(vineyardId, userId, operatorCategoryId))

    suspend fun removeMember(vineyardId: String, userId: String) =
        rpc("remove_member", RemoveMemberArgs(vineyardId, userId))

    suspend fun transferOwnership(vineyardId: String, newOwnerId: String, removeOldOwner: Boolean) =
        rpc("transfer_vineyard_ownership", TransferArgs(vineyardId, newOwnerId, removeOldOwner))

    /** Invite a member by email. Returns the created invitation. */
    suspend fun inviteMember(
        vineyardId: String,
        email: String,
        role: String,
        operatorCategoryId: String?,
    ): Invitation = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("create_invitation")) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(
                CreateInvitationArgs(
                    vineyardId = vineyardId,
                    email = email.trim().lowercase(),
                    role = role,
                    operatorCategoryId = operatorCategoryId,
                    expiresAt = null,
                )
            )
        }
        when {
            response.status.isSuccess() -> response.body<List<Invitation>>().firstOrNull()
                ?: throw BackendError.Server(response.status.value, "Empty response")
            response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(response.status.value, response.bodyAsText())
        }
    }

    private suspend inline fun <reified T> rpc(name: String, args: T) = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl(name)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(args)
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

    private fun HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }

    @Serializable
    private data class UpdateRoleArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_user_id") val userId: String,
        @SerialName("p_role") val role: String,
    )

    @Serializable
    private data class UpdateCategoryArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_user_id") val userId: String,
        @SerialName("p_worker_type_id") val operatorCategoryId: String?,
    )

    @Serializable
    private data class RemoveMemberArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_user_id") val userId: String,
    )

    @Serializable
    private data class TransferArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_new_owner_id") val newOwnerId: String,
        @SerialName("p_remove_old_owner") val removeOldOwner: Boolean,
    )

    @Serializable
    private data class InvitationIdArg(
        @SerialName("p_invitation_id") val invitationId: String,
    )

    @Serializable
    private data class ProfileUpsertArg(val id: String, val email: String)

    @Serializable
    private data class CreateInvitationArgs(
        @SerialName("p_vineyard_id") val vineyardId: String,
        @SerialName("p_email") val email: String,
        @SerialName("p_role") val role: String,
        @SerialName("p_operator_category_id") val operatorCategoryId: String?,
        @SerialName("p_expires_at") val expiresAt: String?,
    )
}
