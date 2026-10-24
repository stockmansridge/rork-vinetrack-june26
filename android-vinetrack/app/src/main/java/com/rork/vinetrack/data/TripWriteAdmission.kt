package com.rork.vinetrack.data

/** Resolves opaque Trip IDs without borrowing the selected vineyard. No operation
 * payload or journal is changed by admission, including a server-side hold. */
internal class TripWriteAdmission(
    private val isAccountCurrent: () -> Boolean,
    private val resolve: suspend (String) -> List<String>,
) {
    fun requireCurrent() {
        if (!isAccountCurrent()) throw BackendError.Unauthorized
    }

    fun requireVineyard(vineyardId: String) {
        requireCurrent()
        require(vineyardId.isNotBlank()) { "Trip vineyard is unresolved. Original work is retained." }
        OperationalWrites.requireWrite(vineyardId)
    }

    suspend fun owningVineyard(id: String): String {
        requireCurrent()
        val vineyard = resolve(id).singleOrNull()?.takeIf { it.isNotBlank() }
            ?: error("Trip ownership is unresolved. Original work is retained.")
        requireVineyard(vineyard)
        return vineyard
    }

    suspend fun <T> send(vineyardId: String, transport: suspend () -> T): T {
        requireVineyard(vineyardId)
        return try { transport() } catch (error: BackendError.Server) {
            // A stale response must not establish a hold for the next account.
            requireCurrent()
            if (OperationalWrites.handleServerError(error, vineyardId)) {
                throw VineyardWriteAuthority.Restricted(
                    OperationalWrites.authority?.heldReason(vineyardId) ?: "VT_READ_ONLY")
            }
            throw error
        }
    }
}
