package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.WorkTask

/**
 * Resolution states for a per-task deep link (Pruning Activity Report →
 * "Open Work Task"). Local cache is authoritative for the first frame; the
 * backend is only consulted when the cache can't answer.
 */
sealed interface WorkTaskDeepLinkState {
    /** No link requested. */
    data object Closed : WorkTaskDeepLinkState

    /** Not in the local cache yet — a targeted refresh is in flight. */
    data object Resolving : WorkTaskDeepLinkState

    /** Task found; render the existing Work Task detail screen. */
    data class Available(val task: WorkTask) : WorkTaskDeepLinkState

    /** Deleted or no longer visible to this user after a refresh. */
    data object Unavailable : WorkTaskDeepLinkState
}

/**
 * Pure resolution rules shared by the screen and its regression tests.
 *
 * Cache-first: a task already held locally opens instantly and offline. A
 * missing task is only reported as [WorkTaskDeepLinkState.Unavailable] once a
 * backend refresh has completed, so a cold cache never shows a false
 * "deleted" message.
 */
object WorkTaskDeepLink {

    fun resolve(
        taskId: String?,
        cachedTasks: List<WorkTask>,
        hasRefreshed: Boolean,
    ): WorkTaskDeepLinkState {
        val id = taskId?.takeIf { it.isNotBlank() } ?: return WorkTaskDeepLinkState.Closed
        val task = cachedTasks.firstOrNull { it.id == id }
        return when {
            // Soft-deleted server-side: definitive, no refresh can bring it back.
            task != null && task.deletedAt != null -> WorkTaskDeepLinkState.Unavailable
            task != null -> WorkTaskDeepLinkState.Available(task)
            hasRefreshed -> WorkTaskDeepLinkState.Unavailable
            else -> WorkTaskDeepLinkState.Resolving
        }
    }

    /**
     * True when the cache can't answer and the screen must wait for a refresh
     * before it may claim the task is gone.
     */
    fun needsRefresh(taskId: String?, cachedTasks: List<WorkTask>): Boolean {
        val id = taskId?.takeIf { it.isNotBlank() } ?: return false
        return cachedTasks.none { it.id == id }
    }

    /** Friendly, non-technical copy for [WorkTaskDeepLinkState.Unavailable]. */
    const val UNAVAILABLE_TITLE: String = "Work Task unavailable"

    const val UNAVAILABLE_MESSAGE: String =
        "This Work Task has been deleted or is no longer available to you. " +
            "The pruning record itself is unchanged."
}
