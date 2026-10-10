package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.AuthRetentionGuard
import com.rork.vinetrack.data.model.SprayTankActual
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Frozen original confirmations: explicit confirmation actor plus original-session callback admission. */
class ScopedTankActualSync(
    private val store: SprayTankActualStore,
    private val withAccountAccess: (AuthRetentionGuard.AccountAccess, () -> Unit) -> Boolean,
    private val upsert: suspend (SprayTankActual, AuthRetentionGuard.AccountAccess) -> Unit,
    private val fetch: suspend (String, AuthRetentionGuard.AccountAccess) -> List<SprayTankActual>,
) {
    suspend fun replay(
        access: AuthRetentionGuard.AccountAccess,
        vineyardId: String?,
        hasUnresolvedDependency: (SprayTankActual) -> Boolean,
        canPublishVineyard: (String) -> Boolean,
    ) {
        if (!store.hasReadableSyncEvidence()) return
        for (actual in store.pendingOwned(access).sortedBy { it.clientUpdatedAt }) {
            if (!withAccountAccess(access) { }) return
            if (hasUnresolvedDependency(actual)) continue
            try {
                upsert(actual, access)
                currentCoroutineContext().ensureActive()
                withAccountAccess(access) { store.markSyncedIfCurrent(actual) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // Original values and pending marker remain; no reset or blind resend here.
            }
        }
        if (vineyardId == null || !withAccountAccess(access) { }) return
        try {
            val remote = fetch(vineyardId, access)
            currentCoroutineContext().ensureActive()
            if (remote.any { it.vineyardId != vineyardId }) return
            withAccountAccess(access) {
                if (canPublishVineyard(vineyardId) && store.hasReadableSyncEvidence()) store.mergeRemoteForAccount(remote, access)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // Failed reads never establish authoritative emptiness.
        }
    }
}
