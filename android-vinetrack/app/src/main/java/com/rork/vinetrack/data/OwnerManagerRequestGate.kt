package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.VineyardMember

/** Vineyard membership only: no system-admin or cross-vineyard role fallback. */
internal object OwnerManagerRequestGate {
    fun allows(role: String?): Boolean = role?.trim()?.lowercase() in setOf("owner", "manager")

    fun role(members: List<VineyardMember>, vineyardId: String, userId: String?): String? =
        userId?.let { user -> members.firstOrNull {
            it.userId.equals(user, true) && it.vineyardId?.equals(vineyardId, true) == true
        }?.role }

    suspend fun <T> financials(role: String?, request: suspend () -> List<T>): List<T> =
        if (allows(role)) request() else emptyList()

    suspend fun deleteWorkerType(role: String?, request: suspend () -> Unit) {
        if (!allows(role)) throw BackendError.Server(403, "Owner or manager role required")
        request()
    }

    fun isConvergedDelete(code: Int, body: String): Boolean {
        val message = body.lowercase()
        return code == 404 || message.contains("worker type not found") ||
            message.contains("already deleted") || message.contains("already absent")
    }
}
