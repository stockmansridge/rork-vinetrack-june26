package com.rork.vinetrack.data.model

import kotlinx.serialization.Serializable

/**
 * A pin photo retained locally because it couldn't be uploaded immediately
 * (Stage 7B — local persistence only).
 *
 * When a user attaches a photo to a pin that is created offline, or the photo
 * upload fails after an online pin row was created, the compressed JPEG is
 * copied into app-private storage and a record of it is kept here so a future
 * slice can replay the upload. Stage 7B does NOT upload or retry — it only
 * prevents the photo from being lost.
 *
 * Idempotency / association: the attachment is keyed to the client-generated
 * pin UUID ([clientPinId]). For offline-created pins that is the same id the
 * pin-create outbox replays with, so once the pin exists server-side the photo
 * can be associated with the correct row.
 */
@Serializable
data class PendingPhotoAttachment(
    /** Local primary key for this attachment row (client-generated UUID string). */
    val id: String,
    /** The client-generated pin UUID this photo belongs to. */
    val clientPinId: String,
    /** Vineyard the pin (and therefore its storage path) lives under. */
    val vineyardId: String,
    /** Absolute path to the compressed JPEG saved in app-private storage. */
    val localPath: String,
    /** Epoch millis the attachment was first persisted. */
    val createdAt: Long,
    /** Epoch millis of the last status/error change. */
    val updatedAt: Long,
    /** Lifecycle status (see [PendingPhotoStatus]). */
    val status: String = PendingPhotoStatus.PENDING,
    /** How many upload attempts have been made (0 until upload retry exists). */
    val attemptCount: Int = 0,
    /** Last failure message, if any, for diagnostics/UX. */
    val lastError: String? = null,
)

/** Lifecycle a pending photo attachment moves through once upload retry exists. */
object PendingPhotoStatus {
    /** Saved locally, waiting for an upload attempt. */
    const val PENDING = "pending"
    /** An upload attempt is currently in flight. */
    const val IN_PROGRESS = "in_progress"
    /** The last attempt failed; eligible for retry. */
    const val FAILED = "failed"
    /** Cannot proceed (e.g. local file missing or permission lost). */
    const val BLOCKED = "blocked"
    /** Successfully uploaded; safe to prune. */
    const val UPLOADED = "uploaded"

    /** Statuses that still count toward the "photos waiting to upload" total. */
    val unresolved: Set<String> = setOf(PENDING, IN_PROGRESS, FAILED, BLOCKED)
}
