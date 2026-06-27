package com.rork.vinetrack.ui

/**
 * Per-pin local sync/upload visibility (Android map + pins parity slice).
 *
 * Derived purely from the existing pending-write outbox and pending-photo
 * store — it adds no stored field to [com.rork.vinetrack.data.model.Pin] and
 * drives no replay/upload behaviour. It only tells the UI whether a pin is
 * saved locally but not yet fully synced, or whether its photo is still
 * waiting / blocked. The wording mirrors the Sync Status screen.
 */
data class PinSyncState(
    /** Pin create is queued and still unresolved (offline-created, not yet on the server). */
    val pendingCreate: Boolean = false,
    /** Pin create hit a blocking error and needs attention. */
    val blockedCreate: Boolean = false,
    /** A pin photo is retained locally and still waiting to upload. */
    val pendingPhoto: Boolean = false,
    /** The retained photo is blocked (retry cap / permanent error) and needs attention. */
    val blockedPhoto: Boolean = false,
    /** A Done/Open completion toggle is queued and still unresolved (Stage 9A). */
    val pendingCompletion: Boolean = false,
    /** The queued completion toggle hit a blocking error and needs attention. */
    val blockedCompletion: Boolean = false,
    /** A descriptive edit (title/notes/category/mode) is queued and unresolved (Stage 9B-3). */
    val pendingEdit: Boolean = false,
    /** The queued descriptive edit hit a blocking conflict/error and needs attention. */
    val blockedEdit: Boolean = false,
) {
    /** Anything blocked that the user may need to look at. */
    val needsAttention: Boolean get() = blockedCreate || blockedPhoto || blockedCompletion || blockedEdit

    /** Any unresolved local state worth surfacing on this pin. */
    val hasAny: Boolean get() = pendingCreate || pendingPhoto || pendingCompletion || pendingEdit || needsAttention

    /** Single most-important short label, matching Sync Status wording. */
    val primaryLabel: String?
        get() = when {
            needsAttention -> "Needs attention"
            pendingCreate -> "Pending sync"
            pendingCompletion -> "Pending sync"
            pendingEdit -> "Pending sync"
            pendingPhoto -> "Photo waiting to upload"
            else -> null
        }
}
