package com.rork.vinetrack.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** One device-wide destructive request. Persist BEFORE dispatch; restart permits reads only.
 * No spray payload, existing queue, or historical journal is written by this guard.
 */
class ChemicalRemovalGuard(private val read: () -> String?, private val write: (String?) -> Boolean) {
    @Serializable enum class Action { ARCHIVE, DELETE, RESTORE }
    @Serializable data class Target(val owner: String, val vineyard: String, val id: String, val name: String, val action: Action)
    data class State(val target: Target? = null, val busy: Boolean = false, val message: String? = null, val unreadable: Boolean = false)
    private val json = Json { ignoreUnknownKeys = false }
    private val mutable = MutableStateFlow(load())
    val state = mutable.asStateFlow()
    private fun load(): State = try {
        read()?.let { State(target = json.decodeFromString<Target>(it), message = "Previous request retained. Check the original chemical with the server; do not submit another removal.") } ?: State()
    } catch (_: Exception) { State(unreadable = true, message = "Removal evidence could not be read. Further removals are blocked; contact support without clearing storage.") }
    private fun persist(value: String?): Boolean = try { write(value) } catch (_: Exception) { false }
    @Synchronized fun begin(target: Target): Boolean {
        if (mutable.value.target != null || mutable.value.unreadable) return false
        if (!persist(json.encodeToString(Target.serializer(), target))) {
            mutable.value = State(message = "Could not save the request safely. Nothing was sent.")
            return false
        }
        mutable.value = State(target, busy = true, message = "Processing and checking with server…")
        return true
    }
    @Synchronized fun checking(target: Target): Boolean {
        if (mutable.value.target != target || mutable.value.busy) return false
        mutable.value = mutable.value.copy(busy = true)
        return true
    }
    @Synchronized fun hold(target: Target, message: String) {
        if (mutable.value.target == target) mutable.value = State(target, message = message)
    }
    @Synchronized fun finish(target: Target, message: String): Boolean {
        if (mutable.value.target != target) return false
        if (!persist(null)) { hold(target, "Server checked, but the local acknowledgement could not be saved. Check again; do not repeat the action."); return false }
        mutable.value = State(message = message)
        return true
    }
    fun dismissMessage() { if (mutable.value.target == null && !mutable.value.unreadable) mutable.value = State() }
    fun matchesScope(target: Target, owner: String?, vineyard: String?) = target.owner == owner && target.vineyard == vineyard
    fun isConfirmed(target: Target, row: com.rork.vinetrack.data.model.SavedChemical?): Boolean {
        if (row != null && (row.id != target.id || row.vineyardId != target.vineyard)) return false
        return when (target.action) {
            Action.ARCHIVE -> row != null && (!row.isActive || row.deletedAt != null)
            Action.DELETE -> row == null
            Action.RESTORE -> row != null && row.isActive && row.deletedAt == null
        }
    }
}
