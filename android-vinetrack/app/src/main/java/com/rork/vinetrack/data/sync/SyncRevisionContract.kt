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
     * SQLSTATEs PostgREST ALSO maps to 409, which are emphatically not revision conflicts.
     *
     * `23505` (unique_violation) is the dangerous one: a duplicate key means nobody edited
     * concurrently, the write is simply invalid, and telling the grower "this was also
     * changed on another device — both versions are saved" sends them hunting for a second
     * version that does not exist, while the real cause goes unreported.
     */
    private val nonRevisionConflictCodes: List<String> = listOf("23505", "23503", "23514", "23502")

    /**
     * Whether a failed response is a revision conflict rather than a transport,
     * auth or server failure.
     *
     * Tolerant, but only in the safe direction:
     *  - the sql/198 marker in the body is CONCLUSIVE whatever the status, because a gateway
     *    or proxy can rewrite a status code while the message travels in the body;
     *  - a bare 409 with no usable body IS treated as a conflict — with no evidence either
     *    way, the fail-safe reading is the one that keeps the grower's edit queued;
     *  - a 409 that EXPLAINS ITSELF as something else (unique / foreign-key / check / not-null
     *    violation) is NOT a conflict.
     *
     * The two mistakes cost very different amounts, which is why the default leans this way:
     * a conflict misread as a transport failure is retried forever with the same stale
     * `base_revision` and can never converge, whereas a failure misread as a conflict merely
     * asks a human to look at something.
     */
    fun isRevisionConflict(status: Int, body: String?): Boolean {
        val text = body ?: ""
        if (text.contains(CONFLICT_MESSAGE)) return true
        if (text.contains(CONFLICT_SQLSTATE)) return true
        if (status != 409) return false
        // A 409 naming a different SQLSTATE is that error, not a stale-revision refusal.
        return nonRevisionConflictCodes.none { text.contains(it) }
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
