package com.rork.vinetrack.data

import kotlinx.coroutines.CancellationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import java.util.UUID

/** Last canonical response only. Offline selection is not server write authorisation. */
class FertigationProgramStepCache(
    private val read: (String) -> String?,
    private val write: (String, String) -> Unit,
) {
    @Serializable
    data class Snapshot(val ownerId: String, val vineyardId: String, val fetchedAt: Long, val steps: List<JsonObject>)
    data class Result(val steps: List<JsonObject>, val isCached: Boolean, val fetchedAt: Long)
    private val json = Json { ignoreUnknownKeys = true }
    private fun owner(value: String): String = UUID.fromString(value).toString()
    private fun key(ownerId: String, vineyardId: String): String = "fertigation_steps_${owner(ownerId)}_${owner(vineyardId)}"
    private fun adminKey(ownerId: String): String = "fertigation_admin_${owner(ownerId)}"
    private fun cached(ownerId: String, vineyardId: String): Result? {
        val raw = read(key(ownerId, vineyardId)) ?: return null
        val snapshot = json.decodeFromString<Snapshot>(raw)
        check(snapshot.ownerId == owner(ownerId) && snapshot.vineyardId == owner(vineyardId))
        check(snapshot.steps.all { FertigationDomain.isSelectable(it, vineyardId, true) })
        return Result(snapshot.steps, true, snapshot.fetchedAt)
    }
    /** An authoritative false is persisted even when an old list exists. Failed checks can
     * only reuse the same account's affirmative System Admin result, never a vineyard role. */
    suspend fun load(ownerId: String, vineyardId: String, adminCheck: suspend () -> Boolean,
        fetch: suspend () -> List<JsonObject>, isCurrentAccount: () -> Boolean = { true }): Result? {
        fun requireAccount() { if (!isCurrentAccount()) throw CancellationException("Account changed.") }
        requireAccount()
        val admin = try { adminCheck() } catch (e: Exception) {
            if (e is CancellationException) throw e
            requireAccount()
            if (read(adminKey(ownerId)) != "true") return null
            return cached(ownerId, vineyardId)
        }
        requireAccount()
        write(adminKey(ownerId), admin.toString())
        check(admin) { "System Admin required." }
        val steps = try {
            fetch().also { rows -> requireAccount(); check(rows.all { FertigationDomain.isSelectable(it, vineyardId, true) }) }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            requireAccount()
            if (e is IllegalStateException && e.message == "System Admin required.") {
                write(adminKey(ownerId), "false")
                throw e
            }
            return cached(ownerId, vineyardId)
        }
        val snapshot = Snapshot(owner(ownerId), owner(vineyardId), System.currentTimeMillis(), steps)
        write(key(ownerId, vineyardId), json.encodeToString(snapshot))
        return Result(steps, false, snapshot.fetchedAt)
    }
}
