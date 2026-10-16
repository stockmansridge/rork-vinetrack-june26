package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.VineyardMember
import kotlinx.serialization.Serializable

/** A reachable membership RPC explicitly denied this vineyard; unlike a token/transport error. */
internal class VineyardMembershipDenied : IllegalStateException("Vineyard membership was denied")

/** Captured async publication boundary, including A→B→A and same-user reauthentication. */
internal data class QuickActionLoadScope(
    val userId: String?, val vineyardId: String?, val identityEpoch: Long,
    val selectionEpoch: Long, val generation: Long,
) {
    fun isCurrent(current: QuickActionLoadScope, authenticated: Boolean): Boolean = authenticated && this == current
}

/** Verified reference data, never authority for another account, session or vineyard. */
@Serializable
internal data class QuickActionOfflineSnapshot(
    val userId: String,
    val vineyardId: String,
    val identityEpoch: Long,
    val members: List<VineyardMember>? = null,
    val buttons: ButtonConfigRepository.LauncherButtons? = null,
) {
    fun matches(user: String, vineyard: String, epoch: Long): Boolean =
        userId == user && vineyardId == vineyard && identityEpoch == epoch
}
