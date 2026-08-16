package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceEventKind
import com.rork.vinetrack.data.resistance.ResistanceEventSource
import com.rork.vinetrack.data.resistance.ResistanceSeasonCalendar
import com.rork.vinetrack.data.spray.SprayApplicationBlockSnapshot
import com.rork.vinetrack.data.spray.SprayApplicationMode
import com.rork.vinetrack.data.spray.SprayApplicationPlan
import com.rork.vinetrack.data.spray.SprayApplicationPlanner
import com.rork.vinetrack.data.spray.SprayApplicationSnapshot
import com.rork.vinetrack.data.spray.SprayBandWidth
import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayCarrierVolumeCalculator
import com.rork.vinetrack.data.spray.SprayGeometryQuality
import com.rork.vinetrack.data.spray.SprayGeometryResolver
import com.rork.vinetrack.data.spray.SprayGeometrySource
import com.rork.vinetrack.data.spray.SprayTarget
import com.rork.vinetrack.data.spray.blockIds
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Block attribution contract (sql/195): WHICH blocks an application treated.
 *
 * The properties under test are the ones that make per-block resistance history
 * trustworthy, and each of them was genuinely absent before this work:
 *
 *  1. **Attribution is persisted at all.** The Blocks-step selection reached the
 *     geometry engine and was then discarded; now it survives.
 *  2. **Identity is the block id, never the name.** A rename must not move
 *     history, and a deleted block must not erase it.
 *  3. **Attribution cannot disagree with the geometry.** Both are projected from
 *     the same resolved block list, so "calculated from A+C, recorded as A+B" is
 *     unrepresentable rather than merely unlikely.
 *  4. **Unknown stays unknown.** A pre-195 record reads back as "blocks not
 *     recorded" and is never assigned to a block by inference.
 *
 * The iOS suite `SprayBlockAttributionTests` asserts the same fixtures.
 */
class SprayBlockAttributionTest {

    private val tolerance = 0.0001
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val calendar = ResistanceSeasonCalendar()

    private val blockA = "11111111-1111-4111-8111-111111111111"
    private val blockB = "22222222-2222-4222-8222-222222222222"
    private val blockC = "33333333-3333-4333-8333-333333333333"

    // ---------------------------------------------------------------- fixtures

    private fun blockInput(
        id: String,
        name: String?,
        grossHa: Double,
        rowLength: Double? = 10_000.0,
        rowSpacing: Double? = 3.2,
        rowCount: Int? = 40,
    ) = SprayBlockInput(
        blockId = id,
        blockName = name,
        grossAreaHectares = grossHa,
        mappedRowLengthMetres = rowLength,
        rowSpacingMetres = rowSpacing,
        rowCount = rowCount,
    )

    private fun planFor(
        blocks: List<SprayBlockInput>,
        mode: SprayApplicationMode = SprayApplicationMode.WHOLE_BLOCK,
        bandWidth: SprayBandWidth? = null,
    ): SprayApplicationPlan {
        val geometry = SprayGeometryResolver.resolve(blocks)
        return SprayApplicationPlanner.plan(
            blocks = blocks,
            mode = mode,
            bandWidth = bandWidth,
            carrier = SprayCarrierVolumeCalculator.perHectare(
                litresPerHectare = 300.0,
                areaHectares = geometry.grossAreaHectares,
                rowLengthMetres = geometry.totalRowLengthMetres,
                rowSpacingMetres = geometry.uniformRowSpacingMetres,
            ),
            tankCapacityLitres = 3_000.0,
            productLines = emptyList(),
        )
    }

    private fun recordWith(
        id: String,
        blocks: List<SprayApplicationBlockSnapshot>?,
        targets: List<String>? = listOf(SprayTarget.POWDERY_MILDEW.raw),
        endTime: String? = "2026-10-01T09:00:00Z",
        isTemplate: Boolean = false,
        deletedAt: String? = null,
    ) = SprayRecord(
        id = id,
        vineyardId = "vineyard-1",
        date = "2026-10-01T08:00:00Z",
        startTime = "2026-10-01T08:00:00Z",
        endTime = endTime,
        isTemplate = isTemplate,
        targets = targets,
        applicationBlocks = blocks,
        deletedAt = deletedAt,
    )

    // ------------------------------------------------- 1. persistence exists

    @Test
    fun `single block selection is persisted with identity and geometry`() {
        val snapshot = SprayApplicationSnapshot.from(
            planFor(listOf(blockInput(blockA, "Home Block", 10.0))),
        )

        val blocks = assertNotNull(snapshot.blocks).let { snapshot.blocks!! }
        assertEquals(1, blocks.size)
        assertEquals(blockA, blocks[0].blockId)
        assertEquals("Home Block", blocks[0].blockName)
        assertEquals(10.0, blocks[0].grossAreaHa!!, tolerance)
        assertEquals(10_000.0, blocks[0].rowLengthMetres!!, tolerance)
        assertEquals(3.2, blocks[0].rowSpacingMetres!!, tolerance)
        assertEquals(40, blocks[0].rowCount)
        assertEquals(SprayGeometrySource.MAPPED_ROWS, blocks[0].geometrySource)
        assertEquals(SprayGeometryQuality.AUTHORITATIVE, blocks[0].geometryQuality)
        assertTrue(snapshot.hasRecordedBlocks)
        assertEquals(listOf(blockA), snapshot.treatedBlockIds)
    }

    @Test
    fun `multiple blocks are persisted in selection order`() {
        val snapshot = SprayApplicationSnapshot.from(
            planFor(
                listOf(
                    blockInput(blockC, "Far Block", 5.0),
                    blockInput(blockA, "Home Block", 10.0),
                ),
            ),
        )

        assertEquals(listOf(blockC, blockA), snapshot.treatedBlockIds)
    }

    @Test
    fun `duplicate block ids are collapsed to first occurrence`() {
        // A block counted twice in one application would be counted twice by a
        // per-block resistance history.
        val normalised = SprayApplicationBlockSnapshot.normalised(
            listOf(
                SprayApplicationBlockSnapshot(blockId = blockC),
                SprayApplicationBlockSnapshot(blockId = blockA),
                SprayApplicationBlockSnapshot(blockId = blockC),
            ),
        )

        assertEquals(listOf(blockC, blockA), normalised!!.blockIds)
    }

    @Test
    fun `empty selection normalises to null not an empty list`() {
        // sql/195 rejects `[]`: absence of attribution is NULL and only NULL.
        assertNull(SprayApplicationBlockSnapshot.normalised(emptyList()))
        assertNull(SprayApplicationBlockSnapshot.project(emptyList()))
        assertNull(SprayApplicationBlockSnapshot.normalised(null))
    }

    @Test
    fun `blank block ids are discarded`() {
        assertNull(
            SprayApplicationBlockSnapshot.normalised(
                listOf(SprayApplicationBlockSnapshot(blockId = "   ")),
            ),
        )
    }

    // ------------------------------- 2. geometry / attribution invariant (§20)

    @Test
    fun `attribution ids are exactly the geometry ids`() {
        // THE invariant: the blocks the calculation used and the blocks the record
        // claims to have treated are the same list, because one is projected from
        // the other. There is no second selection to fall out of step.
        val inputs = listOf(
            blockInput(blockA, "Home Block", 10.0),
            blockInput(blockC, "Far Block", 5.0),
        )
        val plan = planFor(inputs)
        val snapshot = SprayApplicationSnapshot.from(plan)

        assertEquals(plan.geometry.blockIds, snapshot.treatedBlockIds)
        assertEquals(listOf(blockA, blockC), snapshot.treatedBlockIds)
    }

    @Test
    fun `per-block gross areas sum to the aggregate gross area`() {
        val plan = planFor(
            listOf(
                blockInput(blockA, "Home Block", 10.0),
                blockInput(blockC, "Far Block", 5.0),
            ),
        )
        val snapshot = SprayApplicationSnapshot.from(plan)

        val summed = snapshot.blocks!!.sumOf { it.grossAreaHa ?: 0.0 }
        assertEquals(15.0, summed, tolerance)
        assertEquals(snapshot.grossAreaHa!!, summed, tolerance)
    }

    @Test
    fun `per-block row lengths sum to the canonical row length`() {
        val plan = planFor(
            listOf(
                blockInput(blockA, "Home Block", 10.0, rowLength = 31_250.0),
                blockInput(blockC, "Far Block", 5.0, rowLength = 15_000.0),
            ),
        )
        val snapshot = SprayApplicationSnapshot.from(plan)

        val summed = snapshot.blocks!!.sumOf { it.rowLengthMetres ?: 0.0 }
        assertEquals(46_250.0, summed, tolerance)
        assertEquals(snapshot.canonicalRowLengthMetres!!, summed, tolerance)
    }

    @Test
    fun `banded treated area still comes from the aggregate not per block`() {
        // Per-block treated area is deliberately NOT stored: splitting the band
        // arithmetic per block would be a second implementation that could drift.
        val plan = planFor(
            listOf(blockInput(blockA, "Home Block", 10.0, rowLength = 31_250.0)),
            mode = SprayApplicationMode.BANDED,
            bandWidth = SprayBandWidth.total(0.8),
        )
        val snapshot = SprayApplicationSnapshot.from(plan)

        assertEquals(2.5, snapshot.treatedAreaHa!!, tolerance)
        assertEquals(10.0, snapshot.grossAreaHa!!, tolerance)
        // The per-block entry carries gross + row length, and no treated area.
        assertEquals(10.0, snapshot.blocks!![0].grossAreaHa!!, tolerance)
        assertEquals(31_250.0, snapshot.blocks!![0].rowLengthMetres!!, tolerance)
    }

    // ----------------------------------------------- 3. identity, not names

    @Test
    fun `block ids survive a rename because the name is only a snapshot`() {
        val original = SprayApplicationSnapshot.from(
            planFor(listOf(blockInput(blockA, "Home Block", 10.0))),
        )
        // The vineyard renames the block. The stored record is untouched: it holds
        // its own frozen copy and is never re-resolved from current state.
        val renamedLater = SprayApplicationSnapshot.from(
            planFor(listOf(blockInput(blockA, "Home Block RENAMED", 10.0))),
        )

        assertEquals(original.treatedBlockIds, renamedLater.treatedBlockIds)
        assertEquals("Home Block", original.blocks!![0].blockName)
        assertEquals("Home Block RENAMED", renamedLater.blocks!![0].blockName)
    }

    @Test
    fun `attribution survives a block that no longer exists`() {
        // No FK, by design: a completed spray is a compliance document and must keep
        // saying which block it treated even after that block is deleted.
        val stored = SprayApplicationSnapshot.fromColumns(
            grossAreaHa = 10.0,
            treatedAreaHa = null,
            applicationMode = "whole_block",
            treatedAreaMethod = null,
            bandWidthTotalMetres = null,
            bandWidthLeftMetres = null,
            bandWidthRightMetres = null,
            canonicalRowLengthMetres = null,
            rowSpacingMetres = null,
            geometrySource = null,
            geometryQuality = null,
            carrierVolumeBasis = null,
            totalCarrierLitres = null,
            carrierLitresPerHectare = null,
            diluteLitresPer100m = null,
            appliedLitresPer100m = null,
            concentrationFactor = null,
            blocks = listOf(
                SprayApplicationBlockSnapshot(blockId = blockC, blockName = "Deleted Block"),
            ),
        )

        assertEquals(listOf(blockC), stored!!.treatedBlockIds)
        assertEquals("Deleted Block", stored.blocks!![0].displayName)
    }

    @Test
    fun `a block recorded without a name reports a non-authoritative placeholder`() {
        val snapshot = SprayApplicationBlockSnapshot(blockId = blockA, blockName = null)
        assertEquals("Unnamed block", snapshot.displayName)
    }

    // -------------------------------------------- 4. unknown stays unknown

    @Test
    fun `a pre-195 record reads back as blocks not recorded`() {
        val legacy = SprayApplicationSnapshot.fromColumns(
            grossAreaHa = 10.0,
            treatedAreaHa = null,
            applicationMode = null,
            treatedAreaMethod = null,
            bandWidthTotalMetres = null,
            bandWidthLeftMetres = null,
            bandWidthRightMetres = null,
            canonicalRowLengthMetres = null,
            rowSpacingMetres = null,
            geometrySource = null,
            geometryQuality = null,
            carrierVolumeBasis = null,
            totalCarrierLitres = null,
            carrierLitresPerHectare = null,
            diluteLitresPer100m = null,
            appliedLitresPer100m = null,
            concentrationFactor = null,
            blocks = null,
        )

        assertNotNull(legacy)
        assertNull(legacy!!.blocks)
        assertFalse(legacy.hasRecordedBlocks)
        assertTrue(legacy.treatedBlockIds.isEmpty())
    }

    @Test
    fun `an all-null snapshot including blocks is still empty`() {
        assertNull(
            SprayApplicationSnapshot.fromColumns(
                grossAreaHa = null,
                treatedAreaHa = null,
                applicationMode = null,
                treatedAreaMethod = null,
                bandWidthTotalMetres = null,
                bandWidthLeftMetres = null,
                bandWidthRightMetres = null,
                canonicalRowLengthMetres = null,
                rowSpacingMetres = null,
                geometrySource = null,
                geometryQuality = null,
                carrierVolumeBasis = null,
                totalCarrierLitres = null,
                carrierLitresPerHectare = null,
                diluteLitresPer100m = null,
                appliedLitresPer100m = null,
                concentrationFactor = null,
                blocks = null,
            ),
        )
    }

    @Test
    fun `attribution alone is enough to make a snapshot non-empty`() {
        // A record that recorded ONLY its blocks must not be normalised away to
        // "nothing recorded".
        val snapshot = SprayApplicationSnapshot(
            blocks = listOf(SprayApplicationBlockSnapshot(blockId = blockA)),
        )
        assertFalse(snapshot.isEmpty)
    }

    // ------------------------------------------------------- offline round-trip

    @Test
    fun `attribution round-trips through the offline outbox json`() {
        val original = SprayApplicationSnapshot.from(
            planFor(
                listOf(
                    blockInput(blockA, "Home Block", 10.0),
                    blockInput(blockC, "Far Block", 5.0),
                ),
            ),
        )

        val decoded = json.decodeFromString<SprayApplicationSnapshot>(
            json.encodeToString(SprayApplicationSnapshot.serializer(), original),
        )

        assertEquals(listOf(blockA, blockC), decoded.treatedBlockIds)
        assertEquals("Home Block", decoded.blocks!![0].blockName)
        assertEquals(10.0, decoded.blocks!![0].grossAreaHa!!, tolerance)
        assertEquals(original, decoded)
    }

    @Test
    fun `a queued spray keeps the blocks chosen at save time`() {
        // Select A + C, save offline. The vineyard is reconfigured afterwards. The
        // queued payload is a frozen snapshot, so it still says A + C.
        val queued = SprayApplicationSnapshot.from(
            planFor(
                listOf(
                    blockInput(blockA, "Home Block", 10.0),
                    blockInput(blockC, "Far Block", 5.0),
                ),
            ),
        )
        val wire = json.encodeToString(SprayApplicationSnapshot.serializer(), queued)

        // ... meanwhile the operator edits blocks and adds a new one. Irrelevant:
        // nothing re-resolves the queued payload.
        val syncedLater = json.decodeFromString<SprayApplicationSnapshot>(wire)

        assertEquals(listOf(blockA, blockC), syncedLater.treatedBlockIds)
        assertFalse(syncedLater.treatedBlockIds.contains(blockB))
    }

    // ------------------------------------------------------- template semantics

    @Test
    fun `a template keeps intended block identity but drops per-block geometry`() {
        val spray = SprayApplicationSnapshot.from(
            planFor(
                listOf(
                    blockInput(blockA, "Home Block", 10.0),
                    blockInput(blockB, "Mid Block", 8.0),
                ),
            ),
        )

        val template = spray.templateConfiguration()

        assertNotNull(template)
        // Identity: reusable intent.
        assertEquals(listOf(blockA, blockB), template!!.treatedBlockIds)
        assertEquals("Home Block", template.blocks!![0].blockName)
        // Geometry outputs: recalculated per spray, so cleared.
        assertNull(template.blocks!![0].grossAreaHa)
        assertNull(template.blocks!![0].rowLengthMetres)
        assertNull(template.blocks!![0].rowSpacingMetres)
        assertNull(template.blocks!![0].rowCount)
        assertNull(template.blocks!![0].geometrySource)
        assertNull(template.blocks!![0].geometryQuality)
        // And the aggregate geometry stays cleared as before.
        assertNull(template.grossAreaHa)
        assertNull(template.canonicalRowLengthMetres)
    }

    @Test
    fun `instantiating a template and changing the selection freezes the new choice`() {
        // An old template must not dictate historical attribution after the operator
        // modifies the selection in the Blocks step.
        val template = SprayApplicationSnapshot.from(
            planFor(listOf(blockInput(blockA, "Home Block", 10.0))),
        ).templateConfiguration()

        assertEquals(listOf(blockA), template!!.treatedBlockIds)

        // Operator opens it and sprays C instead.
        val newSpray = SprayApplicationSnapshot.from(
            planFor(listOf(blockInput(blockC, "Far Block", 5.0))),
        )

        assertEquals(listOf(blockC), newSpray.treatedBlockIds)
        assertFalse(newSpray.treatedBlockIds.contains(blockA))
    }

    @Test
    fun `a template block that no longer exists is detectable by id`() {
        // §11: the client must be able to say "1 template block is no longer
        // available" rather than silently substituting another block.
        val template = SprayApplicationSnapshot.from(
            planFor(
                listOf(
                    blockInput(blockA, "Home Block", 10.0),
                    blockInput(blockC, "Far Block", 5.0),
                ),
            ),
        ).templateConfiguration()

        val availableBlockIds = setOf(blockA, blockB) // C was deleted.
        val missing = template!!.treatedBlockIds.filterNot(availableBlockIds::contains)

        assertEquals(listOf(blockC), missing)
    }

    // ------------------------------------------ resistance adapter projection

    @Test
    fun `a spray on one block produces one event for that block only`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith("app-1", listOf(SprayApplicationBlockSnapshot(blockId = blockA))),
            ),
            seasonCalendar = calendar,
        )

        assertEquals(1, result.events.size)
        assertEquals(blockA, result.events[0].blockId)
        assertEquals("app-1", result.events[0].applicationId)
        assertFalse(result.hasUnresolvedBlockAttribution)
    }

    @Test
    fun `a spray on A and C produces one event each and none for B`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith(
                    "app-1",
                    listOf(
                        SprayApplicationBlockSnapshot(blockId = blockA),
                        SprayApplicationBlockSnapshot(blockId = blockC),
                    ),
                ),
            ),
            seasonCalendar = calendar,
        )

        assertEquals(2, result.events.size)
        assertEquals(setOf(blockA, blockC), result.events.map { it.blockId }.toSet())
        assertTrue(result.events.none { it.blockId == blockB })
    }

    @Test
    fun `block projections of one spray share the same application id`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith(
                    "app-1",
                    listOf(
                        SprayApplicationBlockSnapshot(blockId = blockA),
                        SprayApplicationBlockSnapshot(blockId = blockC),
                    ),
                ),
            ),
            seasonCalendar = calendar,
        )

        // One application, not two: the general spray history must not double-count.
        assertEquals(setOf("app-1"), result.events.map { it.applicationId }.toSet())
    }

    @Test
    fun `block expansion does not alter declared target logic`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith(
                    "app-1",
                    listOf(
                        SprayApplicationBlockSnapshot(blockId = blockA),
                        SprayApplicationBlockSnapshot(blockId = blockC),
                    ),
                    targets = listOf(SprayTarget.DOWNY_MILDEW.raw),
                ),
            ),
            seasonCalendar = calendar,
        )

        assertEquals(2, result.events.size)
        result.events.forEach {
            assertTrue(it.targetsRecorded)
            assertEquals(listOf(ResistanceDisease.DOWNY_MILDEW), it.targets)
        }
    }

    @Test
    fun `block expansion preserves unrecorded targets as unrecorded`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith(
                    "app-1",
                    listOf(SprayApplicationBlockSnapshot(blockId = blockA)),
                    targets = null,
                ),
            ),
            seasonCalendar = calendar,
        )

        assertEquals(1, result.events.size)
        assertFalse(result.events[0].targetsRecorded)
        assertTrue(result.events[0].targets.isEmpty())
    }

    @Test
    fun `duplicate attributed blocks yield one event each`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith(
                    "app-1",
                    listOf(
                        SprayApplicationBlockSnapshot(blockId = blockA),
                        SprayApplicationBlockSnapshot(blockId = blockA),
                    ),
                ),
            ),
            seasonCalendar = calendar,
        )

        assertEquals(1, result.events.size)
    }

    // ------------------------------- unresolved historical attribution (§17/18)

    @Test
    fun `a null-attribution record produces no events and is reported unresolved`() {
        val result = ResistanceEventSource.events(
            records = listOf(recordWith("legacy-1", blocks = null)),
            seasonCalendar = calendar,
        )

        assertTrue(result.events.isEmpty())
        assertTrue(result.hasUnresolvedBlockAttribution)
        assertEquals(listOf("legacy-1"), result.unattributedToBlockRecordIds)
        assertTrue(result.hasExclusions)
    }

    @Test
    fun `an unresolved record is never assigned to any block`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith("legacy-1", blocks = null),
                recordWith("app-1", listOf(SprayApplicationBlockSnapshot(blockId = blockA))),
            ),
            seasonCalendar = calendar,
        )

        // Only the attributed spray becomes an event. The legacy one is not
        // silently folded onto block A just because it is the only block in play.
        assertEquals(1, result.events.size)
        assertEquals("app-1", result.events[0].applicationId)
        assertEquals(listOf("legacy-1"), result.unattributedToBlockRecordIds)
    }

    @Test
    fun `unresolved applications carry the context needed to qualify a clean result`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith(
                    "legacy-1",
                    blocks = null,
                    targets = listOf(SprayTarget.POWDERY_MILDEW.raw),
                ),
            ),
            seasonCalendar = calendar,
        )

        val unresolved = result.unresolvedBlockApplications.single()
        assertEquals("legacy-1", unresolved.applicationId)
        assertEquals("vineyard-1", unresolved.vineyardId)
        assertEquals(ResistanceEventKind.ACTUAL, unresolved.kind)
        assertEquals("2026/27", unresolved.seasonId)
        assertTrue(unresolved.targetsRecorded)
        assertEquals(listOf(ResistanceDisease.POWDERY_MILDEW), unresolved.targets)
        // It concerns powdery, and demonstrably not downy.
        assertTrue(unresolved.mayConcern(ResistanceDisease.POWDERY_MILDEW))
        assertFalse(unresolved.mayConcern(ResistanceDisease.DOWNY_MILDEW))
    }

    @Test
    fun `an unresolved record with unrecorded targets may concern any disease`() {
        // Two independent unknowns: block AND target. Neither may be collapsed into
        // the other, and an unrecorded target cannot be ruled out of relevance.
        val result = ResistanceEventSource.events(
            records = listOf(recordWith("legacy-1", blocks = null, targets = null)),
            seasonCalendar = calendar,
        )

        val unresolved = result.unresolvedBlockApplications.single()
        assertFalse(unresolved.targetsRecorded)
        assertTrue(unresolved.mayConcern(ResistanceDisease.POWDERY_MILDEW))
        assertTrue(unresolved.mayConcern(ResistanceDisease.DOWNY_MILDEW))
    }

    @Test
    fun `unresolved applications can be filtered by disease and season`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith("legacy-powdery", blocks = null, targets = listOf(SprayTarget.POWDERY_MILDEW.raw)),
                recordWith("legacy-downy", blocks = null, targets = listOf(SprayTarget.DOWNY_MILDEW.raw)),
            ),
            seasonCalendar = calendar,
        )

        assertEquals(
            listOf("legacy-powdery"),
            result.unresolvedApplications(ResistanceDisease.POWDERY_MILDEW).map { it.applicationId },
        )
        assertEquals(
            listOf("legacy-downy"),
            result.unresolvedApplications(ResistanceDisease.DOWNY_MILDEW, "2026/27").map { it.applicationId },
        )
        assertTrue(
            result.unresolvedApplications(ResistanceDisease.POWDERY_MILDEW, "2030/31").isEmpty(),
        )
    }

    @Test
    fun `templates and deleted records are excluded before the block check`() {
        // A template with no attribution is not an "unresolved application" — it was
        // never sprayed at all. Conflating the two would flood the report.
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith("tpl-1", blocks = null, isTemplate = true),
                recordWith("del-1", blocks = null, deletedAt = "2026-10-02T00:00:00Z"),
            ),
            seasonCalendar = calendar,
        )

        assertTrue(result.events.isEmpty())
        assertEquals(listOf("tpl-1"), result.templateRecordIds)
        assertEquals(listOf("del-1"), result.deletedRecordIds)
        assertFalse(result.hasUnresolvedBlockAttribution)
    }

    @Test
    fun `an undated record is reported undated rather than unresolved`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                SprayRecord(
                    id = "undated-1",
                    vineyardId = "vineyard-1",
                    date = null,
                    startTime = null,
                    applicationBlocks = listOf(SprayApplicationBlockSnapshot(blockId = blockA)),
                ),
            ),
            seasonCalendar = calendar,
        )

        assertEquals(listOf("undated-1"), result.undatedRecordIds)
        assertFalse(result.hasUnresolvedBlockAttribution)
    }

    @Test
    fun `a planned spray keeps its kind through block expansion`() {
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith(
                    "planned-1",
                    listOf(
                        SprayApplicationBlockSnapshot(blockId = blockA),
                        SprayApplicationBlockSnapshot(blockId = blockC),
                    ),
                    endTime = null,
                ),
            ),
            seasonCalendar = calendar,
        )

        assertEquals(2, result.events.size)
        result.events.forEach { assertEquals(ResistanceEventKind.PLANNED, it.kind) }
    }

    @Test
    fun `the adapter reads attribution from the record without a caller resolver`() {
        // §17: normal new records no longer depend on a caller-supplied resolver.
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith("app-1", listOf(SprayApplicationBlockSnapshot(blockId = blockA))),
            ),
            seasonCalendar = calendar,
        )

        assertEquals(listOf(blockA), result.events.map { it.blockId })
    }

    @Test
    fun `record level applicationGeometry exposes persisted attribution`() {
        val record = recordWith(
            "app-1",
            listOf(
                SprayApplicationBlockSnapshot(blockId = blockA, blockName = "Home Block"),
                SprayApplicationBlockSnapshot(blockId = blockC, blockName = "Far Block"),
            ),
        )

        val geometry = record.applicationGeometry
        assertNotNull(geometry)
        assertEquals(listOf(blockA, blockC), geometry!!.treatedBlockIds)
        assertTrue(geometry.hasRecordedBlocks)
    }

    @Test
    fun `a legacy record exposes no attribution through applicationGeometry`() {
        val record = recordWith("legacy-1", blocks = null)
        // The record still has targets recorded, so the snapshot exists — but its
        // block attribution is absent, and stays absent.
        assertFalse(record.applicationGeometry?.hasRecordedBlocks ?: false)
        assertTrue(record.applicationGeometry?.treatedBlockIds.orEmpty().isEmpty())
    }

    // ------------------------------------------------ chemistry independence

    @Test
    fun `block expansion does not alter chemical intelligence availability`() {
        // §19: block-unknown, target-unknown and chemistry-unavailable are three
        // independent dimensions and must not collapse into "missing data".
        val result = ResistanceEventSource.events(
            records = listOf(
                recordWith(
                    "app-1",
                    listOf(
                        SprayApplicationBlockSnapshot(blockId = blockA),
                        SprayApplicationBlockSnapshot(blockId = blockC),
                    ),
                ),
            ),
            seasonCalendar = calendar,
        )

        // No chemicals on the fixture, so both events agree on an empty product set
        // regardless of how many blocks the spray was expanded across.
        assertEquals(2, result.events.size)
        assertEquals(
            result.events[0].products.size,
            result.events[1].products.size,
        )
    }
}
