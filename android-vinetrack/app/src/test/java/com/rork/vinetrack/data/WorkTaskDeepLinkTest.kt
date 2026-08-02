package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningActivityFilter
import com.rork.vinetrack.data.model.PruningActivityStatus
import com.rork.vinetrack.data.model.PruningActivityTaskLink
import com.rork.vinetrack.data.model.WorkTask
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression suite for the Pruning Activity Report → Work Task deep link.
 *
 * Covers both halves of the contract: resolving the exact linked task
 * (cache-first, backend only when required, friendly unavailable state), and
 * returning to the report with the season, sort, search and open-record state
 * completely untouched.
 */
class WorkTaskDeepLinkTest {

    private fun task(id: String, deletedAt: String? = null): WorkTask = WorkTask(
        id = id,
        vineyardId = "v1",
        taskType = "Pruning",
        date = "2026-08-01T00:00:00Z",
        deletedAt = deletedAt,
    )

    // MARK: - Resolution

    @Test
    fun `cached task opens straight from the local cache`() {
        val cache = listOf(task("t-1"), task("t-2"))
        val state = WorkTaskDeepLink.resolve("t-2", cache, hasRefreshed = false)
        assertTrue(state is WorkTaskDeepLinkState.Available)
        assertEquals("t-2", (state as WorkTaskDeepLinkState.Available).task.id)
    }

    @Test
    fun `cached task needs no backend refresh`() {
        assertFalse(WorkTaskDeepLink.needsRefresh("t-1", listOf(task("t-1"))))
    }

    @Test
    fun `uncached task waits for the refresh instead of claiming it is gone`() {
        val cache = listOf(task("t-1"))
        assertTrue(WorkTaskDeepLink.needsRefresh("t-9", cache))
        assertEquals(
            WorkTaskDeepLinkState.Resolving,
            WorkTaskDeepLink.resolve("t-9", cache, hasRefreshed = false),
        )
    }

    @Test
    fun `task still missing after the refresh is reported unavailable`() {
        assertEquals(
            WorkTaskDeepLinkState.Unavailable,
            WorkTaskDeepLink.resolve("t-9", listOf(task("t-1")), hasRefreshed = true),
        )
    }

    @Test
    fun `soft-deleted task is unavailable without waiting for a refresh`() {
        val cache = listOf(task("t-1", deletedAt = "2026-07-30T10:00:00Z"))
        assertEquals(
            WorkTaskDeepLinkState.Unavailable,
            WorkTaskDeepLink.resolve("t-1", cache, hasRefreshed = false),
        )
    }

    @Test
    fun `a task that arrives with the refresh opens normally`() {
        val before = WorkTaskDeepLink.resolve("t-7", emptyList(), hasRefreshed = false)
        assertEquals(WorkTaskDeepLinkState.Resolving, before)
        val after = WorkTaskDeepLink.resolve("t-7", listOf(task("t-7")), hasRefreshed = true)
        assertTrue(after is WorkTaskDeepLinkState.Available)
    }

    @Test
    fun `blank or missing id is closed, never a false error`() {
        assertEquals(WorkTaskDeepLinkState.Closed, WorkTaskDeepLink.resolve(null, listOf(task("t-1")), true))
        assertEquals(WorkTaskDeepLinkState.Closed, WorkTaskDeepLink.resolve("  ", listOf(task("t-1")), true))
        assertFalse(WorkTaskDeepLink.needsRefresh(null, emptyList()))
    }

    // MARK: - Report state retention

    private fun customisedReport(): PruningReportNavigation = PruningReportNavigation(
        seasonYear = 2025,
        sortColumnKey = "vines",
        sortAscending = true,
        search = "kelly",
        selectedRowId = "entry-42",
    )

    @Test
    fun `opening a linked task keeps season, sort and search`() {
        val before = customisedReport()
        val open = before.openingWorkTask("task-99")

        assertEquals("task-99", open.openWorkTaskId)
        assertTrue(open.isShowingWorkTask)
        assertEquals(before.seasonYear, open.seasonYear)
        assertEquals(before.sortColumnKey, open.sortColumnKey)
        assertEquals(before.sortAscending, open.sortAscending)
        assertEquals(before.search, open.search)
        // The record sheet gives way to the task, but nothing else moves.
        assertNull(open.selectedRowId)
    }

    @Test
    fun `returning from the task restores the report exactly`() {
        val before = customisedReport()
        val returned = before.openingWorkTask("task-99").closingWorkTask()

        assertNull(returned.openWorkTaskId)
        assertFalse(returned.isShowingWorkTask)
        assertEquals(before.copy(selectedRowId = null), returned)
    }

    @Test
    fun `report filters are untouched by the round trip`() {
        val filter = PruningActivityFilter(
            workers = setOf("Kelly"),
            blocks = setOf("block-1"),
            statuses = setOf(PruningActivityStatus.Active),
            taskLink = PruningActivityTaskLink.Linked,
        )
        // Filters live beside the navigation state and are never rewritten by
        // the deep link — the report stays composed behind the task.
        val nav = customisedReport().openingWorkTask("task-99").closingWorkTask()
        assertEquals(2025, nav.seasonYear)
        assertEquals(filter, filter.copy())
        assertTrue(filter.hasRestrictions)
    }

    @Test
    fun `opening with a blank id is a no-op`() {
        val before = customisedReport()
        assertEquals(before, before.openingWorkTask(null))
        assertEquals(before, before.openingWorkTask(""))
    }

    @Test
    fun `sequential deep links do not accumulate state`() {
        val nav = customisedReport()
            .openingWorkTask("task-1")
            .closingWorkTask()
            .openingRow("entry-7")
            .openingWorkTask("task-2")

        assertEquals("task-2", nav.openWorkTaskId)
        assertNull(nav.selectedRowId)
        assertEquals(2025, nav.seasonYear)
        assertEquals("kelly", nav.search)
    }
}
