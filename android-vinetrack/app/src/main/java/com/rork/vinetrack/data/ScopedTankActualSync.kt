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
    /** P0 3.1.9: the actual's Trip is under a durable occurrence tank-conflict hold. */
    private val isTankHeld: (SprayTankActual, AuthRetentionGuard.AccountAccess) -> Boolean = { _, _ -> false },
    /**
     * P0 3.1.9 Phase B: tank session IDs on the server Trip row. When supplied, an actual is
     * uploaded only while its session is present; null (unknown) holds the actual.
     */
    private val serverSessionIds: (suspend (SprayTankActual, AuthRetentionGuard.AccountAccess) -> Set<String>?)? = null,
    /** P0 3.1.9 Phase B: server readback; the actual is marked synced only on an exact match. */
    private val readBack: (suspend (SprayTankActual, AuthRetentionGuard.AccountAccess) -> SprayTankActual?)? = null,
) {
    /** Last fixed code per actual id for diagnostics; never contains quantities. */
    val lastHoldCodes: MutableMap<String, String> = java.util.concurrent.ConcurrentHashMap()

    suspend fun replay(
        access: AuthRetentionGuard.AccountAccess,
        vineyardId: String?,
        hasUnresolvedDependency: (SprayTankActual) -> Boolean,
        canPublishVineyard: (String) -> Boolean,
    ) {
        if (!store.hasReadableSyncEvidence()) return
        for (actual in store.pendingOwned(access).sortedBy { it.clientUpdatedAt }) {
            if (!withAccountAccess(access) { }) return
            if (hasUnresolvedDependency(actual) || isTankHeld(actual, access)) continue
            try {
                if (serverSessionIds != null) {
                    val ids = serverSessionIds.invoke(actual, access)
                    currentCoroutineContext().ensureActive()
                    if (ids == null || actual.tankSessionId !in ids) {
                        lastHoldCodes[actual.id] = TankDependencyVerification.ACTUAL_SESSION_NOT_ON_SERVER
                        continue
                    }
                }
                upsert(actual, access)
                currentCoroutineContext().ensureActive()
                if (readBack != null) {
                    val row = readBack.invoke(actual, access)
                    currentCoroutineContext().ensureActive()
                    if (!TankDependencyVerification.actualMatches(actual, row)) {
                        lastHoldCodes[actual.id] = TankDependencyVerification.ACTUAL_READBACK_MISMATCH
                        continue
                    }
                }
                lastHoldCodes.remove(actual.id)
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
