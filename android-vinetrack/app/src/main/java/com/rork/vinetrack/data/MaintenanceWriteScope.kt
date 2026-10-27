package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** One operation, one authenticated account incarnation. Never borrows selection. */
internal class MaintenanceWriteScope(private val session: SessionStore) {
    val account = session.accountAccess() ?: throw BackendError.Unauthorized
    private val authority = OperationalWrites.authority ?: throw BackendError.Unauthorized
    private val admission = TripWriteAdmission(
        isAccountCurrent = {
            session.isAccountAccessCurrent(account) && OperationalWrites.authority === authority &&
                authority.accountBinding() == account.userId
        },
        resolve = { emptyList() },
    )

    fun requireCurrent() { admission.requireCurrent() }
    fun requireLocalWrite(vineyardId: String) {
        requireUuid(vineyardId)
        admission.requireVineyard(vineyardId.lowercase(java.util.Locale.ROOT))
    }

    @Serializable
    private data class Ownership(val id: String, @SerialName("vineyard_id") val vineyardId: String)

    suspend fun owner(id: String, expectedVineyard: String? = null, allowMissingForCreate: Boolean = false, table: String = "maintenance_logs"): String {
        requireUuid(id)
        expectedVineyard?.let { requireUuid(it); admission.requireVineyard(it.lowercase(java.util.Locale.ROOT)) }
        admission.requireCurrent()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(table)) {
            attributes.put(SupabaseClient.accountRequestScope, account)
            url { parameters.append("select", "id,vineyard_id"); parameters.append("id", "eq.$id") }
            headers { append("apikey", SupabaseClient.anonKey); append("Authorization", "Bearer $token") }
        }
        admission.requireCurrent()
        if (!response.status.isSuccess()) {
            if (response.status.value == 401 || response.status.value == 403) throw BackendError.Unauthorized
            throw BackendError.Server(response.status.value, response.bodyAsText())
        }
        val rows = response.body<List<Ownership>>()
        if (rows.isEmpty() && allowMissingForCreate && expectedVineyard != null) {
            admission.requireVineyard(expectedVineyard.lowercase(java.util.Locale.ROOT))
            return expectedVineyard.lowercase(java.util.Locale.ROOT)
        }
        val row = rows.singleOrNull()
        if (row == null || !row.id.equals(id, true) ||
            (expectedVineyard != null && !row.vineyardId.equals(expectedVineyard, true))) {
            throw VineyardWriteAuthority.Restricted("WRITE_SCOPE_UNRESOLVED")
        }
        requireUuid(row.vineyardId)
        val vineyard = row.vineyardId.lowercase(java.util.Locale.ROOT)
        admission.requireVineyard(vineyard)
        return vineyard
    }

    suspend fun <T> send(vineyard: String, operation: suspend () -> T): T = try {
        admission.send(vineyard, operation)
    } catch (error: BackendError.Server) {
        // Structured expiry is classified by send before ordinary permission failures.
        if (error.code == 401 || error.code == 403) throw BackendError.Unauthorized
        throw error
    }

    companion object {
        private val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
        fun requireUuid(value: String) {
            if (!uuid.matches(value)) throw VineyardWriteAuthority.Restricted("WRITE_SCOPE_UNRESOLVED")
        }
        fun objectOwner(path: String): Pair<String, String> {
            val parts = path.split('/')
            if (parts.size != 4 || parts[1] != "maintenance" || parts[3] != "photo.jpg") {
                throw VineyardWriteAuthority.Restricted("WRITE_SCOPE_UNRESOLVED")
            }
            requireUuid(parts[0]); requireUuid(parts[2])
            if (path != "${parts[0].lowercase(java.util.Locale.ROOT)}/maintenance/${parts[2].lowercase(java.util.Locale.ROOT)}/photo.jpg") {
                throw VineyardWriteAuthority.Restricted("WRITE_SCOPE_UNRESOLVED")
            }
            return parts[0] to parts[2]
        }
    }
}
