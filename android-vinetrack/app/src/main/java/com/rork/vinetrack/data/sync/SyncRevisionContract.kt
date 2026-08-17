package com.rork.vinetrack.data.sync

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Client half of the sql/198 server-authoritative revision contract.
 *
 * ONE implementation, shared by every versioned entity (`resistance_plans`,
 * `pruning_seasons`, `pruning_yield_settings`), because three subtly different
 * PT409 parsers is exactly how one of them ends up classifying a conflict as a
 * network error and silently dropping a grower's edit.
 *
 * THE RULE: a device wall clock records WHEN a human edited. It does not record
 * WHICH server version they based that edit on. Those are different facts, and
 * only the second one can decide whether a write is stale. `server_revision` is
 * that second fact, issued by the server and unforgeable by clients.
 *
 * Mirrors `SyncRevisionContract.swift` on iOS. Both platforms must agree on
 * decode, on what is sent, and on what counts as a conflict — see
 * `SyncRevisionParityTest` / `SyncRevisionParityTests`.
 */
object SyncRevisionContract {

    /**
     * Machine-readable marker raised by `reject_stale_client_write()` (sql/198).
     *
     * Matched on the MESSAGE rather than only on the HTTP status: a gateway or
     * proxy can rewrite a status code, but the message travels in the body.
     */
    const val CONFLICT_MESSAGE: String = "REVISION_CONFLICT"

    /** PostgREST maps SQLSTATE class `PT` to an HTTP status; `PT409` -> 409 Conflict. */
    const val CONFLICT_SQLSTATE: String = "PT409"

    private val lenientJson = Json { ignoreUnknownKeys = true; isLenient = true }

    /**
     * Whether a failed response is a revision conflict rather than a transport,
     * auth or server failure.
     *
     * Deliberately tolerant. A 409 whose body did not survive, and a
     * REVISION_CONFLICT that arrived with some other status, are both still
     * conflicts — and misclassifying either one as "sync failed" would send the
     * app into a blind retry loop that can never succeed, because the same stale
     * `base_revision` will be rejected every time.
     */
    fun isRevisionConflict(status: Int, body: String?): Boolean {
        val text = body ?: ""
        if (text.contains(CONFLICT_MESSAGE)) return true
        if (text.contains(CONFLICT_SQLSTATE)) return true
        return status == 409
    }

    /**
     * The server's current revision, read out of the PostgREST error body.
     *
     * sql/198 puts it in the error DETAIL as a JSON object. Null when the body
     * could not be parsed — the conflict is still a conflict, it just cannot say
     * which version won, and a conflict with a missing revision must never be
     * downgraded to a success.
     */
    fun serverRevisionFrom(body: String?): Long? = detailValue(body, "server_revision")

    /** The `base_revision` the server rejected, echoed back for diagnostics. */
    fun baseRevisionFrom(body: String?): Long? = detailValue(body, "base_revision")

    private fun detailValue(body: String?, key: String): Long? {
        val text = body?.takeIf { it.isNotBlank() } ?: return null
        val root = runCatching { lenientJson.parseToJsonElement(text) as? JsonObject }.getOrNull()
            ?: return null
        // `details` is a JSON object encoded as a STRING by PostgREST, so it needs
        // a second parse. Some versions pass it through as a real object.
        val detailsElement = root["details"] ?: root["detail"] ?: return null
        val nested = runCatching { detailsElement as? JsonObject }.getOrNull()
            ?: runCatching {
                lenientJson.parseToJsonElement(detailsElement.jsonPrimitive.content) as? JsonObject
            }.getOrNull()
            ?: return null
        return runCatching { nested[key]?.jsonPrimitive?.content?.toLongOrNull() }.getOrNull()
    }
}

/**
 * A rejected write, preserved in full.
 *
 * Carries BOTH authored versions rather than a `hasConflict` flag. A flag would
 * tell the grower that something went wrong while having thrown away the plan
 * they actually wrote, which is worse than the silent data loss this whole
 * contract exists to fix — at least that failure was invisible rather than
 * taunting.
 *
 * @param T the entity payload type (a whole document, never a field-level diff).
 */
@Serializable
data class SyncRevisionConflict<T>(
    /** Primary key of the row that conflicted. */
    val rowId: String,
    /** Table name, e.g. `resistance_plans`. Distinguishes conflicts in one store. */
    val entity: String,
    /** What THIS device authored and has not yet landed. Still queued. */
    val localPending: T,
    /**
     * The server's current version. Null only when the follow-up read also
     * failed — the local copy is still preserved, which is the part that matters.
     */
    val serverCurrent: T?,
    /** The revision the local edit was based on. */
    val baseRevision: Long?,
    /** The revision the server was actually at when it refused the write. */
    val serverRevision: Long?,
    val detectedAtEpochMs: Long,
)

/**
 * Thrown by a remote when the server refused a write on revision grounds.
 *
 * A distinct type, NOT [BackendError.Server]: a caller that cannot tell a
 * conflict from a 500 will retry it, and a retry carrying the same stale
 * `base_revision` is guaranteed to be refused again. Conflicts need a human;
 * transport failures need a retry. Same-looking failures, opposite handling.
 */
class RevisionConflictException(
    val rowId: String,
    val entity: String,
    val baseRevision: Long?,
    val serverRevision: Long?,
    val body: String? = null,
) : Exception(SyncRevisionContract.CONFLICT_MESSAGE)

/**
 * Outcome of one versioned write. Sealed so a caller cannot forget the conflict
 * branch — the compiler refuses an exhaustive `when` that omits it.
 */
sealed interface VersionedWriteOutcome<out T> {
    /**
     * The server accepted the write and returned the authoritative row,
     * including its NEW `server_revision`.
     */
    data class Applied<T>(val row: T) : VersionedWriteOutcome<T>

    /** Refused: someone else wrote since this device last read the row. */
    data class Conflict<T>(
        val rowId: String,
        val baseRevision: Long?,
        val serverRevision: Long?,
    ) : VersionedWriteOutcome<T>
}
