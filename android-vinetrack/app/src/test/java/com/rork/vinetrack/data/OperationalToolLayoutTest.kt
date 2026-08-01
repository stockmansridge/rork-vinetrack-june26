package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Customisable Operational Tools (SQL 159) — layout resolution rules shared by
 * the Home grid and the Customise Tools screen. Mirrors the iOS
 * `OperationalToolLayoutTests`.
 */
class OperationalToolLayoutTest {

    /** Catalogue order used by the tests (matches the 12-tile grid). */
    private val allIds = listOf(
        "work_tasks", "equipment_maintenance", "fuel_log", "irrigation_advisor",
        "disease_risk", "yield_records", "growth_stages", "optimal_ripeness",
        "cost_reports", "fertiliser_calculator", "pruning_tracker", "irrigation_records",
    )

    /** Operator-style catalogue: no costing permission. */
    private val noCostingIds = allIds.filterNot { it == "cost_reports" }

    @Test
    fun `new user with no preference sees every authorised tool in default order`() {
        val layout = OperationalToolLayout(isReady = true)
        assertEquals(allIds, OperationalToolLayoutResolver.visibleToolIds(layout, allIds))
        assertTrue(OperationalToolLayoutResolver.hiddenToolIds(layout, allIds).isEmpty())
    }

    @Test
    fun `saved order is honoured`() {
        val layout = OperationalToolLayout(
            visibleToolIds = listOf("irrigation_records", "work_tasks"),
            hiddenToolIds = listOf("cost_reports"),
        )
        val visible = OperationalToolLayoutResolver.visibleToolIds(layout, allIds)
        assertEquals("irrigation_records", visible[0])
        assertEquals("work_tasks", visible[1])
        assertTrue("cost_reports" !in visible)
    }

    @Test
    fun `newly released tool is appended to the end of the visible list`() {
        // Saved layout from an older release that never knew irrigation_records.
        val saved = allIds.filterNot { it == "irrigation_records" }
        val layout = OperationalToolLayout(visibleToolIds = saved)
        val visible = OperationalToolLayoutResolver.visibleToolIds(layout, allIds)
        assertEquals("irrigation_records", visible.last())
        assertEquals(allIds.size, visible.size)
    }

    @Test
    fun `unknown tool ids in a saved layout are ignored`() {
        val layout = OperationalToolLayout(
            visibleToolIds = listOf("seeder_records", "work_tasks", "not_a_tool"),
            hiddenToolIds = listOf("ghost_tool", "fuel_log"),
        )
        val visible = OperationalToolLayoutResolver.visibleToolIds(layout, allIds)
        assertTrue(visible.none { it == "seeder_records" || it == "not_a_tool" })
        assertEquals("work_tasks", visible.first())
        assertEquals(listOf("fuel_log"), OperationalToolLayoutResolver.hiddenToolIds(layout, allIds))
    }

    @Test
    fun `unauthorised tools never appear in the visible or hidden lists`() {
        val layout = OperationalToolLayout(
            visibleToolIds = listOf("cost_reports", "work_tasks"),
            hiddenToolIds = listOf("fuel_log"),
        )
        val visible = OperationalToolLayoutResolver.visibleToolIds(layout, noCostingIds)
        val hidden = OperationalToolLayoutResolver.hiddenToolIds(layout, noCostingIds)
        assertTrue("cost_reports" !in visible)
        assertTrue("cost_reports" !in hidden)
        assertEquals(listOf("fuel_log"), hidden)
    }

    @Test
    fun `a permission-restricted tool keeps its saved place for when access returns`() {
        val layout = OperationalToolLayout(visibleToolIds = listOf("cost_reports", "work_tasks"))
        // The operator reorders what they can see; cost_reports must survive.
        val edited = OperationalToolLayoutResolver.merge(
            layout,
            listOf("fuel_log", "work_tasks"),
            emptyList(),
            noCostingIds,
        )
        assertTrue("cost_reports" in edited.visibleToolIds)
        // With costing restored the tool is visible again.
        assertTrue("cost_reports" in OperationalToolLayoutResolver.visibleToolIds(edited, allIds))
    }

    @Test
    fun `hiding a tool moves it to the hidden list`() {
        val layout = OperationalToolLayout(isReady = true)
        val hidden = OperationalToolLayoutResolver.hide(layout, "fuel_log", allIds)
        requireNotNull(hidden)
        assertTrue("fuel_log" !in OperationalToolLayoutResolver.visibleToolIds(hidden, allIds))
        assertEquals(listOf("fuel_log"), OperationalToolLayoutResolver.hiddenToolIds(hidden, allIds))
    }

    @Test
    fun `hiding the last visible tool is refused`() {
        val single = listOf("work_tasks")
        val layout = OperationalToolLayout(
            visibleToolIds = single,
            hiddenToolIds = allIds - "work_tasks",
        )
        assertEquals(1, OperationalToolLayoutResolver.visibleToolIds(layout, allIds).size)
        assertNull(OperationalToolLayoutResolver.hide(layout, "work_tasks", allIds))
    }

    @Test
    fun `restoring a hidden tool appends it to the end`() {
        val layout = OperationalToolLayoutResolver.hide(
            OperationalToolLayout(isReady = true), "work_tasks", allIds,
        )!!
        val restored = OperationalToolLayoutResolver.show(layout, "work_tasks", allIds)
        val visible = OperationalToolLayoutResolver.visibleToolIds(restored, allIds)
        assertEquals("work_tasks", visible.last())
        assertTrue(OperationalToolLayoutResolver.hiddenToolIds(restored, allIds).isEmpty())
    }

    @Test
    fun `moving a tool changes only its position`() {
        val layout = OperationalToolLayout(isReady = true)
        val moved = OperationalToolLayoutResolver.move(layout, fromIndex = 11, toIndex = 0, authorisedIds = allIds)
        val visible = OperationalToolLayoutResolver.visibleToolIds(moved, allIds)
        assertEquals("irrigation_records", visible.first())
        assertEquals(allIds.size, visible.size)
        assertEquals(allIds.toSet(), visible.toSet())
    }

    @Test
    fun `an out of range move is a no-op`() {
        val layout = OperationalToolLayout(visibleToolIds = listOf("work_tasks", "fuel_log"))
        assertEquals(layout, OperationalToolLayoutResolver.move(layout, 0, 99, allIds))
        assertEquals(layout, OperationalToolLayoutResolver.move(layout, 1, 1, allIds))
    }

    @Test
    fun `merge never leaves a tool both visible and hidden`() {
        val layout = OperationalToolLayout(
            visibleToolIds = listOf("work_tasks", "fuel_log"),
            hiddenToolIds = listOf("cost_reports"),
        )
        val merged = OperationalToolLayoutResolver.merge(
            layout,
            listOf("work_tasks", "fuel_log", "cost_reports"),
            emptyList(),
            allIds,
        )
        assertTrue("cost_reports" in merged.visibleToolIds)
        assertTrue("cost_reports" !in merged.hiddenToolIds)
    }

    @Test
    fun `reset clears every customisation`() {
        val reset = OperationalToolLayout(isReady = true)
        assertEquals(allIds, OperationalToolLayoutResolver.visibleToolIds(reset, allIds))
        assertTrue(!reset.isCustomised)
    }
}
