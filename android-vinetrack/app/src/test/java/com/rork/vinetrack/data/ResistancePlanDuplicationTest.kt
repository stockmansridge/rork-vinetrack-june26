package com.rork.vinetrack.data

import com.rork.vinetrack.data.resistance.InMemoryResistancePlanLocalStore
import com.rork.vinetrack.data.resistance.ResistanceCrop
import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceJurisdiction
import com.rork.vinetrack.data.resistance.ResistancePlan
import com.rork.vinetrack.data.resistance.ResistancePlanRepository
import com.rork.vinetrack.data.resistance.ResistancePlannedChemistrySource
import com.rork.vinetrack.data.resistance.ResistancePlannedPosition
import com.rork.vinetrack.data.resistance.ResistancePlannedProduct
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Plan-list management tests: duplication identity rules, multiple plans for the
 * SAME season and disease, per-plan isolation, and archive.
 *
 * These pin the Plan List contract: mobile never auto-selects a plan, so the data
 * layer must make several same-season/same-disease plans first-class — stable ids,
 * independent edits, independent archives, and duplicates that mint NEW identities
 * (position ids are the seam sql/201 spray jobs point at).
 *
 * Mirrored on iOS by `ResistancePlanListManagementTests.swift` case for case.
 */
class ResistancePlanDuplicationTest {

    private val vineyard = "vy-1"

    private fun repository() = ResistancePlanRepository(
        local = InMemoryResistancePlanLocalStore(),
        remote = null,
        clock = { 5_000L },
        currentUserId = { "user-1" },
    )

    private fun position(id: String, code: String, productId: String) = ResistancePlannedPosition(
        id = id,
        products = listOf(
            ResistancePlannedProduct(
                id = productId,
                groupCodes = listOf(code),
                source = ResistancePlannedChemistrySource.GROUP,
            ),
        ),
    )

    private fun makePlan(
        id: String = "plan-a",
        seasonId: String = "2026/27",
        disease: ResistanceDisease = ResistanceDisease.POWDERY_MILDEW,
        notes: String? = null,
    ) = ResistancePlan(
        id = id,
        vineyardId = vineyard,
        seasonId = seasonId,
        seasonStartYear = 2026,
        disease = disease,
        jurisdiction = ResistanceJurisdiction.AUSTRALIA,
        crop = ResistanceCrop.GRAPE,
        blockIds = listOf("block-a", "block-b"),
        positions = listOf(
            position("pos-1", "3", "prod-1"),
            position("pos-2", "11", "prod-2"),
        ),
        notes = notes,
        rulesetId = "AU_GRAPE_POWDERY_2026_07_22",
        rulesetVersion = "2026.07.22",
        createdAtEpochMs = 1_000L,
        updatedAtEpochMs = 1_000L,
    )

    // ------------------------------------------------------------------
    // Duplication mints new identities
    // ------------------------------------------------------------------

    @Test
    fun duplicateMintsNewPlanAndPositionIds() {
        val source = makePlan(notes = "Plan A")
        val copy = source.duplicated(nowMs = 9_000L, by = null)

        assertNotEquals(source.id, copy.id)

        // Every position id is NEW — sql/201 spray jobs point at position ids, so a
        // reused id would let jobs created from Plan A claim coverage on the copy.
        val sourcePositionIds = source.positions.map { it.id }.toSet()
        val copyPositionIds = copy.positions.map { it.id }.toSet()
        assertEquals(source.positions.size, copyPositionIds.size)
        assertTrue(copyPositionIds.intersect(sourcePositionIds).isEmpty())

        // Product ids are minted fresh too.
        val sourceProductIds = source.positions.flatMap { p -> p.products.map { it.id } }.toSet()
        val copyProductIds = copy.positions.flatMap { p -> p.products.map { it.id } }.toSet()
        assertEquals(sourceProductIds.size, copyProductIds.size)
        assertTrue(copyProductIds.intersect(sourceProductIds).isEmpty())
    }

    @Test
    fun duplicateCopiesContentButNeverServerState() {
        val source = makePlan(notes = "Plan A").copy(serverRevision = 7L)
        val copy = source.duplicated(nowMs = 9_000L, by = null)

        // Content copied verbatim, order preserved.
        assertEquals(source.seasonId, copy.seasonId)
        assertEquals(source.seasonStartYear, copy.seasonStartYear)
        assertEquals(source.disease, copy.disease)
        assertEquals(source.blockIds, copy.blockIds)
        assertEquals(
            source.positions.map { it.componentGroups },
            copy.positions.map { it.componentGroups },
        )
        assertEquals(source.rulesetId, copy.rulesetId)
        assertEquals(source.rulesetVersion, copy.rulesetVersion)

        // SERVER STATE is not content. The copy has never been accepted by the
        // server, so its first push must be a CREATE (sql/198) — never an update
        // asserting Plan A's revision.
        assertNull(copy.serverRevision)
        assertNull(copy.deletedAtEpochMs)
        assertEquals(9_000L, copy.createdAtEpochMs)
        assertEquals(9_000L, copy.updatedAtEpochMs)
        assertEquals("Plan A (copy)", copy.notes)
    }

    @Test
    fun displayTitlePrefersNameAndFallsBackToSeasonDisease() {
        assertEquals("Early cover strategy", makePlan(notes = "Early cover strategy").displayTitle)
        assertEquals("Powdery Mildew — 2026/27", makePlan(notes = null).displayTitle)
        assertEquals("Powdery Mildew — 2026/27", makePlan(notes = "   \n ").displayTitle)
        // Only the first line of a multi-line note becomes the title.
        assertEquals("Plan B", makePlan(notes = "Plan B\nlong details here").displayTitle)
    }

    // ------------------------------------------------------------------
    // Multiple plans, same season + disease
    // ------------------------------------------------------------------

    @Test
    fun plansForSameSeasonAndDiseaseCoexistIndependently() {
        val repo = repository()
        repo.load(vineyard)

        repo.save(makePlan(id = "plan-a", notes = "Plan A"))
        repo.save(makePlan(id = "plan-b", notes = "Plan B"))

        assertEquals(2, repo.plans.value.size)
        assertEquals(2, repo.plans("2026/27", ResistanceDisease.POWDERY_MILDEW).size)
        assertEquals("Plan A", repo.plan("plan-a")?.notes)
        assertEquals("Plan B", repo.plan("plan-b")?.notes)
    }

    @Test
    fun editingOnePlanNeverTouchesItsSibling() {
        val repo = repository()
        repo.load(vineyard)
        repo.save(makePlan(id = "plan-a", notes = "Plan A"))
        repo.save(makePlan(id = "plan-b", notes = "Plan B"))

        val planA = repo.plan("plan-a")
        assertNotNull(planA)
        repo.save(planA!!.addingPosition(nowMs = 2_000L))

        assertEquals(3, repo.plan("plan-a")?.positions?.size)
        val untouched = repo.plan("plan-b")
        assertNotNull(untouched)
        assertEquals(2, untouched!!.positions.size)
        assertEquals(1_000L, untouched.updatedAtEpochMs)
        assertEquals("Plan B", untouched.notes)
    }

    @Test
    fun archivingOnePlanLeavesTheOtherLive() {
        val repo = repository()
        repo.load(vineyard)
        repo.save(makePlan(id = "plan-a"))
        repo.save(makePlan(id = "plan-b"))

        repo.delete("plan-a")

        assertNull(repo.plan("plan-a"))
        assertNotNull(repo.plan("plan-b"))
        assertEquals(1, repo.plans.value.size)
        // The archived plan stays queued as a tombstone so the delete propagates —
        // the existing sql/196 soft-delete contract, unchanged.
        assertTrue(repo.isPending("plan-a"))
    }

    @Test
    fun duplicateSavedThroughRepositoryIsItsOwnRow() {
        val repo = repository()
        repo.load(vineyard)
        repo.save(makePlan(id = "plan-a", notes = "Plan A"))

        val source = repo.plan("plan-a")
        assertNotNull(source)
        val copy = source!!.duplicated(nowMs = 9_000L, by = null)
        repo.save(copy)

        assertEquals(2, repo.plans.value.size)

        // Editing the copy leaves the source untouched — and vice versa.
        val stored = repo.plan(copy.id)
        assertNotNull(stored)
        repo.save(stored!!.settingBlockIds(listOf("block-c"), 9_500L))
        assertEquals(listOf("block-a", "block-b"), repo.plan("plan-a")?.blockIds)
        assertEquals(listOf("block-c"), repo.plan(copy.id)?.blockIds)
    }
}
