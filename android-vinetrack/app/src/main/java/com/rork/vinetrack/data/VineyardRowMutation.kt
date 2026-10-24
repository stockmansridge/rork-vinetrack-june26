package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Originating account + exact authenticated ownership for independent Pin/Growth writes.
 * No queue claims, payload edits or retry counters live at this transport boundary. */
internal class VineyardRowMutation(private val session: SessionStore) {
    private val access = session.accountAccess() ?: throw BackendError.Unauthorized
    private val gate = OperationalWrites.authority ?: throw BackendError.Unauthorized

    private fun requireAccount() {
        if (!session.isAccountAccessCurrent(access) || OperationalWrites.authority !== gate ||
            gate.accountBinding() != access.userId) throw BackendError.Unauthorized
    }

    fun requireWrite(vineyard: String) {
        requireAccount()
        if (!uuid.matches(vineyard)) throw VineyardWriteAuthority.Restricted("WRITE_SCOPE_UNRESOLVED")
        gate.requireWrite(vineyard)
    }

    fun requireOwner(owner: String?) {
        requireAccount()
        if (!access.userId.equals(owner, true)) throw BackendError.Unauthorized
    }

    suspend fun resolve(table: String, id: String, expectedVineyard: String? = null): String {
        requireAccount()
        if (table !in setOf("pins", "growth_stage_records") || !uuid.matches(id)) {
            throw VineyardWriteAuthority.Restricted("WRITE_SCOPE_UNRESOLVED")
        }
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(table)) {
            attributes.put(SupabaseClient.accountRequestScope, access)
            headers {
                append("apikey", SupabaseClient.anonKey)
                append("Authorization", "Bearer ${session.accessToken ?: throw BackendError.Unauthorized}")
            }
            url { parameters.append("id", "eq.$id"); parameters.append("select", "id,vineyard_id") }
        }
        requireAccount()
        if (!response.status.isSuccess()) throw BackendError.Server(response.status.value, response.bodyAsText())
        val rows = response.body<List<Ownership>>()
        requireAccount()
        val row = rows.singleOrNull()?.takeIf {
            it.id.equals(id, true) && (expectedVineyard == null || it.vineyardId.equals(expectedVineyard, true))
        } ?: throw VineyardWriteAuthority.Restricted("WRITE_SCOPE_UNRESOLVED")
        requireWrite(row.vineyardId)
        return row.vineyardId
    }

    fun authorize(builder: HttpRequestBuilder, vineyard: String) = with(builder) {
        requireWrite(vineyard)
        attributes.put(SupabaseClient.accountRequestScope, access)
        attributes.put(SupabaseClient.operationalWriteVineyard, vineyard)
    }

    suspend fun send(vineyard: String, request: suspend () -> HttpResponse): HttpResponse {
        requireWrite(vineyard)
        val response = request()
        // Genuine success remains acknowledgeable even if expiry arrives in flight.
        if (response.status.isSuccess()) return response
        val error = BackendError.Server(response.status.value, response.bodyAsText())
        requireAccount()
        if (OperationalWrites.handleServerError(error, vineyard)) {
            throw VineyardWriteAuthority.Restricted(gate.heldReason(vineyard) ?: "VT_READ_ONLY")
        }
        if (error.code == 401 || error.code == 403) throw BackendError.Unauthorized
        throw error
    }

    @Serializable private data class Ownership(val id: String, @SerialName("vineyard_id") val vineyardId: String)
    private companion object {
        val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    }
}
