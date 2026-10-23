package com.rork.vinetrack.data

/** Transport connectivity and persisted tokens alone are never replay authority. */
internal object StartupReplayAdmission {
    data class Identity(val userId: String, val vineyardId: String, val accountEpoch: Long)

    fun identity(
        authenticatedOnline: Boolean,
        online: Boolean,
        mainRoute: Boolean,
        userId: String?,
        vineyardId: String?,
        memberIds: Set<String>,
        accountEpoch: Long,
        evidenceReadable: Boolean,
    ): Identity? {
        if (!authenticatedOnline || !online || !mainRoute || !evidenceReadable) return null
        if (userId.isNullOrBlank() || vineyardId.isNullOrBlank() || vineyardId !in memberIds) return null
        return Identity(userId, vineyardId, accountEpoch)
    }
}
