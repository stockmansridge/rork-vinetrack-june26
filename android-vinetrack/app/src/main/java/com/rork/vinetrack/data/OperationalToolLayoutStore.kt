package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import com.rork.vinetrack.data.auth.SessionStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * Per-user layout for the Home "Operational Tools" grid (SQL 159), mirroring
 * the iOS `OperationalToolLayoutStore`.
 *
 * * Keyed by the authenticated user ID — never by vineyard — so the layout
 *   follows the user across vineyards, devices and platforms.
 * * The cached layout is applied synchronously on [configure] so the grid never
 *   flashes hidden tiles while the server call is in flight.
 * * Every change saves locally first, then pushes to Supabase. A failed push
 *   keeps the local layout and is retried on the next load or change.
 * * Saved arrays hold raw tool IDs. Unauthorised tools are filtered at display
 *   time only, so restoring access restores the saved placement.
 */
class OperationalToolLayoutStore(
    context: Context,
    private val session: SessionStore,
    private val scope: CoroutineScope,
    private val repository: OperationalToolPreferencesRepository = OperationalToolPreferencesRepository(session),
) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_operational_tools", Context.MODE_PRIVATE)

    private val _layout = MutableStateFlow(OperationalToolLayout())
    val layout: StateFlow<OperationalToolLayout> = _layout.asStateFlow()

    private var userId: String? = null
    private var lastServerRefreshMs = 0L

    /**
     * Applies the cached layout for the signed-in user, then refreshes from the
     * server in the background. Safe to call repeatedly (e.g. every sign-in and
     * every foreground).
     */
    fun configure(userId: String?) {
        if (userId == this.userId && _layout.value.isReady) return
        this.userId = userId
        lastServerRefreshMs = 0L
        if (userId == null) {
            _layout.value = OperationalToolLayout(isReady = true)
            return
        }
        _layout.value = readCache(userId).copy(isReady = true)
        refreshFromServer()
    }

    /** Clears in-memory state on sign-out; the per-user cache stays on disk. */
    fun signOut() {
        userId = null
        lastServerRefreshMs = 0L
        _layout.value = OperationalToolLayout()
    }

    /**
     * Background refresh. Throttled to once a minute; a failure silently keeps
     * the cached layout so Operational Tools are never blocked.
     */
    fun refreshFromServer(force: Boolean = false) {
        val user = userId ?: return
        val now = System.currentTimeMillis()
        if (!force && now - lastServerRefreshMs < REFRESH_THROTTLE_MS) return
        lastServerRefreshMs = now
        scope.launch {
            runCatching { repository.fetch() }
                .onSuccess { remote ->
                    if (userId != user) return@onSuccess
                    if (_layout.value.hasPendingSync) {
                        // A local change never reached the server — push it
                        // instead of letting a stale server copy win.
                        push(_layout.value.visibleToolIds, _layout.value.hiddenToolIds)
                    } else {
                        applyRemote(remote, user)
                    }
                }
                .onFailure { lastServerRefreshMs = 0L }
        }
    }

    /**
     * Persists an edited layout: local cache + UI first, server after. The
     * caller supplies the authorised-only lists; unauthorised saved IDs are
     * carried through by [OperationalToolLayoutResolver.merge].
     */
    fun save(visibleToolIds: List<String>, hiddenToolIds: List<String>, authorisedIds: List<String>) {
        val user = userId ?: return
        if (visibleToolIds.isEmpty()) return
        val merged = OperationalToolLayoutResolver.merge(
            _layout.value,
            visibleToolIds,
            hiddenToolIds,
            authorisedIds,
        )
        _layout.value = merged.copy(isReady = true, hasPendingSync = true, syncMessage = null)
        writeCache(user, merged.visibleToolIds, merged.hiddenToolIds, pending = true)
        push(merged.visibleToolIds, merged.hiddenToolIds)
    }

    /** Back to the VineTrack default order with every authorised tool shown. */
    fun resetToDefault() {
        val user = userId ?: return
        _layout.value = OperationalToolLayout(isReady = true)
        writeCache(user, emptyList(), emptyList(), pending = false)
        scope.launch {
            runCatching { repository.reset() }
                .onSuccess { remote -> if (userId == user) applyRemote(remote, user) }
                .onFailure {
                    if (userId != user) return@onFailure
                    _layout.value = _layout.value.copy(
                        hasPendingSync = true,
                        syncMessage = OperationalToolLayoutResolver.OFFLINE_SAVE_MESSAGE,
                    )
                    writeCache(user, emptyList(), emptyList(), pending = true)
                }
        }
    }

    /** Dismisses the "saved on this device" notice once the user has seen it. */
    fun clearSyncMessage() {
        if (_layout.value.syncMessage != null) {
            _layout.value = _layout.value.copy(syncMessage = null)
        }
    }

    private fun push(visible: List<String>, hidden: List<String>) {
        val user = userId ?: return
        scope.launch {
            runCatching { repository.save(visible, hidden) }
                .onSuccess { remote ->
                    if (userId != user) return@onSuccess
                    // Only adopt the server answer when nothing changed locally
                    // in the meantime (it may have dropped retired IDs).
                    if (_layout.value.visibleToolIds == visible && _layout.value.hiddenToolIds == hidden) {
                        applyRemote(remote, user)
                    } else {
                        _layout.value = _layout.value.copy(hasPendingSync = false, syncMessage = null)
                    }
                }
                .onFailure {
                    if (userId != user) return@onFailure
                    // Keep the local layout and mark it for retry — never revert
                    // the user's change because the network was unavailable.
                    _layout.value = _layout.value.copy(
                        hasPendingSync = true,
                        syncMessage = OperationalToolLayoutResolver.OFFLINE_SAVE_MESSAGE,
                    )
                    writeCache(user, visible, hidden, pending = true)
                }
        }
    }

    private fun applyRemote(remote: OperationalToolPreferencesDto, user: String) {
        val visible = remote.visibleToolIds.distinct()
        val hidden = remote.hiddenToolIds.distinct().filter { it !in visible }
        _layout.value = OperationalToolLayout(
            visibleToolIds = visible,
            hiddenToolIds = hidden,
            isReady = true,
            hasPendingSync = false,
            syncMessage = null,
        )
        writeCache(user, visible, hidden, pending = false)
    }

    // ---- local cache (per user) -------------------------------------------

    private fun cacheKey(user: String) = "layout_$user"

    private fun readCache(user: String): OperationalToolLayout {
        val raw = prefs.getString(cacheKey(user), null) ?: return OperationalToolLayout()
        return runCatching {
            val obj = JSONObject(raw)
            OperationalToolLayout(
                visibleToolIds = obj.optJSONArray("visible").toStringList(),
                hiddenToolIds = obj.optJSONArray("hidden").toStringList(),
                hasPendingSync = obj.optBoolean("pending", false),
            )
        }.getOrDefault(OperationalToolLayout())
    }

    private fun writeCache(user: String, visible: List<String>, hidden: List<String>, pending: Boolean) {
        val obj = JSONObject().apply {
            put("visible", JSONArray(visible))
            put("hidden", JSONArray(hidden))
            put("pending", pending)
        }
        prefs.edit { putString(cacheKey(user), obj.toString()) }
    }

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) return emptyList()
        return (0 until length()).mapNotNull { optString(it, null)?.takeIf { s -> s.isNotBlank() } }
    }

    private companion object {
        const val REFRESH_THROTTLE_MS = 60_000L
    }
}
