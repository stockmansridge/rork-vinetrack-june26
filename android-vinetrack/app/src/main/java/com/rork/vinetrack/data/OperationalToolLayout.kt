package com.rork.vinetrack.data

/**
 * The user's saved Operational Tools layout (SQL 159), plus its sync state.
 *
 * Stable tool IDs only — never display names or array positions. The same
 * layout is shared with iOS and (later) the portal, so the IDs must match
 * `public.operational_tool_catalogue`.
 */
data class OperationalToolLayout(
    val visibleToolIds: List<String> = emptyList(),
    val hiddenToolIds: List<String> = emptyList(),
    /** False until the locally cached layout for the current user is applied. */
    val isReady: Boolean = false,
    /** True when a local change has not yet reached the server. */
    val hasPendingSync: Boolean = false,
    /** Non-blocking status message for the customisation screen. */
    val syncMessage: String? = null,
) {
    val isCustomised: Boolean get() = visibleToolIds.isNotEmpty() || hiddenToolIds.isNotEmpty()
}

/**
 * Pure layout resolution shared by the Home grid, the customisation screen and
 * the unit tests. Kept free of Android/network dependencies on purpose.
 *
 * Rules (identical to the iOS `OperationalToolLayoutStore`):
 * * Only tools the caller is authorised to see are ever returned.
 * * Saved order wins; newly released authorised tools are appended at the end.
 * * Unknown / retired IDs in a saved layout are ignored.
 * * A tool hidden by permission is NOT reported as user-hidden.
 */
object OperationalToolLayoutResolver {

    const val MINIMUM_VISIBLE_MESSAGE = "At least one operational tool must remain visible."

    const val OFFLINE_SAVE_MESSAGE =
        "Your tool layout has been saved on this device and will sync when a connection is available."

    /** Visible tool IDs, in display order. */
    fun visibleToolIds(layout: OperationalToolLayout, authorisedIds: List<String>): List<String> {
        val authorised = authorisedIds.toSet()
        val hidden = layout.hiddenToolIds.toSet()
        val result = LinkedHashSet<String>()
        layout.visibleToolIds.forEach { id -> if (id in authorised) result.add(id) }
        authorisedIds.forEach { id -> if (id !in result && id !in hidden) result.add(id) }
        return result.toList()
    }

    /** Tool IDs the user chose to hide and is still authorised to restore. */
    fun hiddenToolIds(layout: OperationalToolLayout, authorisedIds: List<String>): List<String> {
        val authorised = authorisedIds.toSet()
        val result = LinkedHashSet<String>()
        layout.hiddenToolIds.forEach { id -> if (id in authorised) result.add(id) }
        return result.toList()
    }

    /**
     * Merges an edited (authorised-only) layout back onto the saved one,
     * carrying unauthorised saved IDs through untouched so restoring a
     * permission also restores the tool's saved placement.
     */
    fun merge(
        current: OperationalToolLayout,
        editedVisible: List<String>,
        editedHidden: List<String>,
        authorisedIds: List<String>,
    ): OperationalToolLayout {
        val authorised = authorisedIds.toSet()
        val carriedVisible = current.visibleToolIds.filter { it !in authorised && it !in editedHidden }
        val carriedHidden = current.hiddenToolIds.filter { it !in authorised && it !in editedVisible }
        val visible = (editedVisible + carriedVisible).distinct()
        val hidden = (editedHidden + carriedHidden).distinct().filter { it !in visible }
        return current.copy(visibleToolIds = visible, hiddenToolIds = hidden)
    }

    /**
     * Hides one tool. Returns null when it is the last visible tool — at least
     * one must always remain.
     */
    fun hide(
        current: OperationalToolLayout,
        toolId: String,
        authorisedIds: List<String>,
    ): OperationalToolLayout? {
        val visible = visibleToolIds(current, authorisedIds).toMutableList()
        if (visible.size <= 1 || !visible.remove(toolId)) return null
        val hidden = hiddenToolIds(current, authorisedIds).toMutableList()
        if (toolId !in hidden) hidden.add(toolId)
        return merge(current, visible, hidden, authorisedIds)
    }

    /** Restores a hidden tool to the END of the visible list. */
    fun show(
        current: OperationalToolLayout,
        toolId: String,
        authorisedIds: List<String>,
    ): OperationalToolLayout {
        val hidden = hiddenToolIds(current, authorisedIds).toMutableList()
        if (!hidden.remove(toolId)) return current
        val visible = visibleToolIds(current, authorisedIds).toMutableList()
        if (toolId !in visible) visible.add(toolId)
        return merge(current, visible, hidden, authorisedIds)
    }

    /** Reorders the visible list by moving one item. */
    fun move(
        current: OperationalToolLayout,
        fromIndex: Int,
        toIndex: Int,
        authorisedIds: List<String>,
    ): OperationalToolLayout {
        val visible = visibleToolIds(current, authorisedIds).toMutableList()
        if (fromIndex !in visible.indices || toIndex !in visible.indices || fromIndex == toIndex) return current
        val moved = visible.removeAt(fromIndex)
        visible.add(toIndex, moved)
        return merge(current, visible, hiddenToolIds(current, authorisedIds), authorisedIds)
    }
}
