package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.resistance.ResistanceDisease
import com.rork.vinetrack.data.resistance.ResistanceEventSource
import com.rork.vinetrack.data.resistance.ResistanceSeasonCalendar
import com.rork.vinetrack.data.spray.SprayApplicationBlockSnapshot
import com.rork.vinetrack.data.spray.SprayApplicationSnapshot
import com.rork.vinetrack.data.spray.SprayBlockAttributionDisplay
import com.rork.vinetrack.data.spray.SprayBlockInput
import com.rork.vinetrack.data.spray.SprayGeometryResolver
import com.rork.vinetrack.data.spray.SprayManualBlockAttribution
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
 * The MANUAL spray-entry attribution path and the EXPORT display rule (sql/195).
 *
 * `SprayBlockAttributionTest` covers the guided/calculated path. This file covers
 * the two surfaces that were still missing after it:
 *
 *  1. **Manual entry** — the second creation path, which until now received a
 *     block selection and silently discarded it, and whose save wiped the whole
 *     sql/191 geometry snapshot off any calculator-produced record it edited.
 *  2. **Exports** — where an honest unknown must read as "blocks not recorded"
 *     rather than as the vineyard's present-day blocks.
 *
 * The iOS suite `SprayBlockAttributionTests` asserts the same fixtures.
 */
class SprayManualBlockAttributionTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val calendar = ResistanceSeasonCalendar()

    private val blockA = "11111111-1111-4111-8111-111111111111"
    private val blockB = "22222222-2222-4222-8222-222222222222"
    private val blockC = "33333333-3333-4333-8333-333333333333"
    private val ghostBlock = "99999999-9999-4999-8999-999999999999"

    // ---------------------------------------------------------------- fixtures

    private fun paddock(id: String, name: String) = Paddock(
        id = id,
        vineyardId = "vineyard-1",
        name = name,
        rowLengthOverride = 10_000.0,
        rowWidth = 3.2,
    )

    private val vineyardBlocks = listOf(
        paddock(blockA, "Home Block"),
        paddock(blockB, "River Block"),
        paddock(blockC, "Hill Block"),
    )

    /** What the canonical resolver says about a selection — the reference values. */
    private fun resolverBlocks(ids: List<String>): List<SprayApplicationBlockSnapshot> {
        val inputs = ids.mapNotNull { id -> vineyardBlocks.firstOrNull { it.id == id } }
            .map { SprayBlockInput.from(it) }
        return SprayApplicationBlockSnapshot.project(SprayGeometryResolver.resolve(inputs).blocks)
            ?: emptyList()
    }

    private fun record(
        id: String = "spray-1",
        blocks: List<SprayApplicationBlockSnapshot>?,
        targets: List<String>? = listOf(SprayTarget.POWDERY_MILDEW.raw),
    ) = SprayRecord(
        id = id,
        vineyardId = "vineyard-1",
        date = "2026-10-01T08:00:00Z",
        startTime = "2026-10-01T08:00:00Z",
        endTime = "2026-10-01T09:00:00Z",
        targets = targets,
        applicationBlocks = blocks,
    )

    /** A record produced by the Spray Calculator, with a full sql/191 snapshot. */
    private fun calculatedRecord(
        blocks: List<SprayApplicationBlockSnapshot>?,
    ): SprayRecord = SprayRecord(
        id = "spray-calculated",
        vineyardId = "vineyard-1",
        date = "2026-10-01T08:00:00Z",
        startTime = "2026-10-01T08:00:00Z",
        endTime = "2026-10-01T09:00:00Z",
        grossAreaHa = 24.0,
        treatedAreaHa = 7.5,
        canonicalRowLengthMetres = 31_250.0,
        rowSpacingMetres = 3.2,
        bandWidthTotalMetres = 1.2,
        totalCarrierLitres = 2_250.0,
        targets = listOf(SprayTarget.POWDERY_MILDEW.raw),
        applicationBlocks = blocks,
    )

    // ------------------------------------------- 1. manual create records blocks

    @Test
    fun `manual create with two blocks persists exactly those two blocks`() {
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockA, blockC),
            recordedBlocks = null,
            availableBlocks = vineyardBlocks,
            isEdit = false,
        )

        assertNotNull(attribution)
        assertEquals(listOf(blockA, blockC), attribution!!.blockIds)
        // The block the operator did NOT select must be absent, not merely unticked.
        assertFalse(attribution.blockIds.contains(blockB))
        assertEquals("Home Block", attribution[0].blockName)
        assertEquals("Hill Block", attribution[1].blockName)
    }

    @Test
    fun `manual create with one block persists one block`() {
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockB),
            recordedBlocks = null,
            availableBlocks = vineyardBlocks,
            isEdit = false,
        )

        assertEquals(listOf(blockB), attribution?.blockIds)
    }

    @Test
    fun `manual create with no selection records nothing rather than no blocks`() {
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = emptyList(),
            recordedBlocks = null,
            availableBlocks = vineyardBlocks,
            isEdit = false,
        )

        // Null, never an empty list: "treated no blocks" is not a state a real
        // application can be in, and sql/195 rejects `[]` for that reason.
        assertNull(attribution)
        assertNull(SprayManualBlockAttribution.geometryToPersist(null, attribution))
    }

    @Test
    fun `manual selection order is preserved and duplicates collapse`() {
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockC, blockA, blockC),
            recordedBlocks = null,
            availableBlocks = vineyardBlocks,
            isEdit = false,
        )

        assertEquals(listOf(blockC, blockA), attribution?.blockIds)
    }

    // ------------------------------------------ 2. manual entry uses the resolver

    @Test
    fun `manual attribution values come from the canonical resolver`() {
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockA, blockC),
            recordedBlocks = null,
            availableBlocks = vineyardBlocks,
            isEdit = false,
        )

        // Manual entry must not invent a second geometry implementation: every
        // per-block value has to equal what the shared resolver produces for the
        // same selection.
        assertEquals(resolverBlocks(listOf(blockA, blockC)), attribution)
    }

    @Test
    fun `saved attribution ids equal the geometry block ids`() {
        val selection = listOf(blockA, blockC)
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = selection,
            recordedBlocks = null,
            availableBlocks = vineyardBlocks,
            isEdit = false,
        )
        val geometry = SprayGeometryResolver.resolve(
            selection.mapNotNull { id -> vineyardBlocks.firstOrNull { it.id == id } }
                .map { SprayBlockInput.from(it) }
        )

        // The invariant: what the geometry was calculated from IS what is recorded
        // as treated. "Calculated from A+C, recorded as A+B" must be impossible.
        assertEquals(geometry.blocks.map { it.blockId }, attribution?.blockIds)
    }

    // --------------------------------- 3. legacy NULL survives an unrelated edit

    @Test
    fun `editing an unrelated field on a legacy record leaves attribution null`() {
        val legacy = record(blocks = null)
        assertNull(legacy.applicationGeometry?.blocks)

        // The operator opens the record to fix the wind speed and never touches the
        // block selector, so it stays empty.
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = emptyList(),
            recordedBlocks = legacy.applicationGeometry?.blocks,
            availableBlocks = vineyardBlocks,
            isEdit = true,
        )

        assertNull(attribution)

        // The snapshot itself is NOT discarded, because this record does have a
        // recorded target (sql/193). Block attribution and target intent are
        // separate dimensions: the block stays unknown while the target stays
        // known, and collapsing either into the other would lose a real fact.
        val persisted = SprayManualBlockAttribution.geometryToPersist(
            existing = legacy.applicationGeometry,
            blocks = attribution,
        )
        assertNotNull(persisted)
        assertNull(persisted!!.blocks)
        assertFalse(persisted.hasRecordedBlocks)
        assertTrue(persisted.hasRecordedTargets)
        assertEquals(listOf(SprayTarget.POWDERY_MILDEW), persisted.targets)
    }

    @Test
    fun `a record with neither blocks nor any other value persists nothing`() {
        // The genuinely empty case: no targets, no geometry, no blocks. Here the
        // whole snapshot collapses to null so "never recorded" keeps one spelling.
        val bare = record(blocks = null, targets = null)
        assertNull(bare.applicationGeometry)

        assertNull(
            SprayManualBlockAttribution.geometryToPersist(
                existing = bare.applicationGeometry,
                blocks = null,
            )
        )
    }

    @Test
    fun `legacy null is never seeded from the vineyards current blocks`() {
        val legacy = record(blocks = null)

        // The vineyard has three blocks; a legacy record must acquire none of them.
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = emptyList(),
            recordedBlocks = legacy.applicationGeometry?.blocks,
            availableBlocks = vineyardBlocks,
            isEdit = true,
        )

        assertNull(attribution)
    }

    // ------------------------------- 4. explicit historical correction is allowed

    @Test
    fun `null becomes A only when the operator deliberately selects A`() {
        val legacy = record(blocks = null)

        val corrected = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockA),
            recordedBlocks = legacy.applicationGeometry?.blocks,
            availableBlocks = vineyardBlocks,
            isEdit = true,
        )

        assertEquals(listOf(blockA), corrected?.blockIds)

        val geometry = SprayManualBlockAttribution.geometryToPersist(
            existing = legacy.applicationGeometry,
            blocks = corrected,
        )
        assertNotNull(geometry)
        assertTrue(geometry!!.hasRecordedBlocks)
        // A correction records ONLY what was chosen — it does not also acquire the
        // rest of the vineyard.
        assertEquals(listOf(blockA), geometry.treatedBlockIds)
    }

    // ------------------------------------- 5. edit preservation (withBlocks rule)

    @Test
    fun `editing an unrelated field preserves calculated geometry and attribution`() {
        val original = resolverBlocks(listOf(blockA, blockC))
        val existing = calculatedRecord(original)
        val stored = existing.applicationGeometry
        assertNotNull(stored)

        // Selection untouched — the operator only changed the wind speed.
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = original.blockIds,
            recordedBlocks = stored!!.blocks,
            availableBlocks = vineyardBlocks,
            isEdit = true,
        )
        val persisted = SprayManualBlockAttribution.geometryToPersist(stored, attribution)

        assertNotNull(persisted)
        // Every frozen aggregate survives. This is the regression that mattered: the
        // manual sheet used to send no geometry at all, so this edit silently
        // cleared treated area, band width and row length.
        assertEquals(24.0, persisted!!.grossAreaHa!!, 0.0001)
        assertEquals(7.5, persisted.treatedAreaHa!!, 0.0001)
        assertEquals(31_250.0, persisted.canonicalRowLengthMetres!!, 0.0001)
        assertEquals(1.2, persisted.bandWidthTotalMetres!!, 0.0001)
        assertEquals(2_250.0, persisted.totalCarrierLitres!!, 0.0001)
        // And the attribution is the stored snapshot itself, not a re-projection.
        assertEquals(original, persisted.blocks)
    }

    @Test
    fun `unchanged selection is returned verbatim rather than refrozen`() {
        // A block whose stored snapshot deliberately DISAGREES with today's geometry,
        // as happens after a block is resurveyed.
        val historical = listOf(
            SprayApplicationBlockSnapshot(
                blockId = blockA,
                blockName = "Home Block (2019 survey)",
                grossAreaHa = 4.0,
                rowLengthMetres = 5_000.0,
            )
        )

        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockA),
            recordedBlocks = historical,
            availableBlocks = vineyardBlocks,
            isEdit = true,
        )

        // Today's resolver would say 10,000 m. The historical record keeps saying
        // 5,000 m, because that is what was true when the spray happened.
        assertEquals(historical, attribution)
        assertEquals(5_000.0, attribution!![0].rowLengthMetres!!, 0.0001)
        assertEquals("Home Block (2019 survey)", attribution[0].blockName)
    }

    @Test
    fun `changing the selection reprojects only the changed record`() {
        val original = resolverBlocks(listOf(blockA))
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockA, blockB),
            recordedBlocks = original,
            availableBlocks = vineyardBlocks,
            isEdit = true,
        )

        assertEquals(listOf(blockA, blockB), attribution?.blockIds)
        assertEquals("River Block", attribution!![1].blockName)
    }

    @Test
    fun `a deleted block keeps its attribution when the selection changes`() {
        // The record attributes a block that has since been deleted from the
        // vineyard, plus a live one.
        val stored = listOf(
            SprayApplicationBlockSnapshot(
                blockId = ghostBlock,
                blockName = "Old Trial Block",
                grossAreaHa = 1.5,
            ),
        ) + resolverBlocks(listOf(blockA))

        // The operator now also ticks C. The ghost block must survive: a completed
        // spray is a compliance document, not a view of today's vineyard.
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(ghostBlock, blockA, blockC),
            recordedBlocks = stored,
            availableBlocks = vineyardBlocks,
            isEdit = true,
        )

        assertEquals(listOf(ghostBlock, blockA, blockC), attribution?.blockIds)
        assertEquals("Old Trial Block", attribution!![0].blockName)
        assertEquals(1.5, attribution[0].grossAreaHa!!, 0.0001)
    }

    @Test
    fun `deselecting a deleted block removes it as an explicit correction`() {
        val stored = listOf(
            SprayApplicationBlockSnapshot(blockId = ghostBlock, blockName = "Old Trial Block"),
        ) + resolverBlocks(listOf(blockA))

        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockA),
            recordedBlocks = stored,
            availableBlocks = vineyardBlocks,
            isEdit = true,
        )

        assertEquals(listOf(blockA), attribution?.blockIds)
    }

    @Test
    fun `an unknown id with nothing behind it is dropped`() {
        // Neither live nor previously recorded: there is nothing factual to store.
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockA, "not-a-block"),
            recordedBlocks = null,
            availableBlocks = vineyardBlocks,
            isEdit = false,
        )

        assertEquals(listOf(blockA), attribution?.blockIds)
    }

    // ------------------------------------------------ 6. offline round-trip

    @Test
    fun `manual attribution survives an offline json round trip`() {
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockA, blockC),
            recordedBlocks = null,
            availableBlocks = vineyardBlocks,
            isEdit = false,
        )
        val geometry = SprayManualBlockAttribution.geometryToPersist(null, attribution)

        val encoded = json.encodeToString(SprayApplicationSnapshot.serializer(), geometry!!)
        val decoded = json.decodeFromString(SprayApplicationSnapshot.serializer(), encoded)

        assertEquals(geometry.blocks, decoded.blocks)
        assertEquals(listOf(blockA, blockC), decoded.treatedBlockIds)
    }

    // ------------------------------------------------ 7. export display rule

    @Test
    fun `export shows current name when the block id still resolves`() {
        // Stored under the OLD name; the block has since been renamed.
        val stored = listOf(
            SprayApplicationBlockSnapshot(blockId = blockA, blockName = "North Three")
        )

        val resolved = SprayBlockAttributionDisplay.resolve(stored, vineyardBlocks)

        // The current name wins, so the reader can find the block in the app today.
        assertEquals("Home Block", resolved!![0].name)
        assertTrue(resolved[0].isLive)
    }

    @Test
    fun `export falls back to the stored name when the block is gone`() {
        val stored = listOf(
            SprayApplicationBlockSnapshot(blockId = ghostBlock, blockName = "Old Trial Block")
        )

        val resolved = SprayBlockAttributionDisplay.resolve(stored, vineyardBlocks)

        // Readability must not depend on the block still existing.
        assertEquals("Old Trial Block", resolved!![0].name)
        assertFalse(resolved[0].isLive)
    }

    @Test
    fun `export says unknown block only when neither name is available`() {
        val stored = listOf(SprayApplicationBlockSnapshot(blockId = ghostBlock, blockName = null))

        val resolved = SprayBlockAttributionDisplay.resolve(stored, vineyardBlocks)

        assertEquals(SprayBlockAttributionDisplay.UNKNOWN_BLOCK, resolved!![0].name)
    }

    @Test
    fun `export of two blocks lists human names and machine ids`() {
        val stored = resolverBlocks(listOf(blockA, blockC))

        assertEquals("Home Block, Hill Block", SprayBlockAttributionDisplay.summary(stored, vineyardBlocks))
        assertEquals(
            "Home Block; Hill Block",
            SprayBlockAttributionDisplay.namesCell(stored, vineyardBlocks),
        )
        assertEquals("$blockA; $blockC", SprayBlockAttributionDisplay.idsCell(stored))
    }

    @Test
    fun `export of unrecorded attribution says so and leaves machine cells empty`() {
        // The PDF gets prose a human can act on...
        assertEquals(
            SprayBlockAttributionDisplay.NOT_RECORDED,
            SprayBlockAttributionDisplay.summary(null, vineyardBlocks),
        )
        // ...and the machine-readable cells stay empty, so no parser has to
        // string-match English to detect absence.
        assertEquals("", SprayBlockAttributionDisplay.namesCell(null, vineyardBlocks))
        assertEquals("", SprayBlockAttributionDisplay.idsCell(null))
    }

    @Test
    fun `export never lists the vineyards current blocks for an unknown record`() {
        val summary = SprayBlockAttributionDisplay.summary(null, vineyardBlocks)

        assertFalse(summary.contains("Home Block"))
        assertFalse(summary.contains("River Block"))
        assertFalse(summary.contains("Hill Block"))
    }

    @Test
    fun `export id cell stays splittable on its separator`() {
        val stored = resolverBlocks(listOf(blockA, blockB, blockC))

        val cell = SprayBlockAttributionDisplay.idsCell(stored)
        val parsed = cell.split(SprayBlockAttributionDisplay.MACHINE_SEPARATOR)

        assertEquals(listOf(blockA, blockB, blockC), parsed)
    }

    // ------------------------- 8. persistence -> reload -> resistance projection

    @Test
    fun `persisted attribution reloads and projects one event per treated block`() {
        // Persist A + C, then read the record back the way a reload would.
        val attribution = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockA, blockC),
            recordedBlocks = null,
            availableBlocks = vineyardBlocks,
            isEdit = false,
        )
        val geometry = SprayManualBlockAttribution.geometryToPersist(null, attribution)
        val reloaded = record(blocks = geometry!!.blocks)

        // No caller-supplied resolver: the adapter reads the record's own attribution.
        val result = ResistanceEventSource.events(listOf(reloaded), calendar)

        assertEquals(2, result.events.size)
        assertEquals(setOf(blockA, blockC), result.events.map { it.blockId }.toSet())
        // Block B was never sprayed and must not appear.
        assertFalse(result.events.any { it.blockId == blockB })
        // Both projected events belong to the SAME application, so cost and spray
        // history never double-count the pass.
        assertEquals(setOf("spray-1"), result.events.map { it.applicationId }.toSet())
        assertFalse(result.hasUnresolvedBlockAttribution)
    }

    @Test
    fun `a reloaded legacy record is reported unresolved and enters no block history`() {
        val legacy = record(id = "legacy-1", blocks = null)

        val result = ResistanceEventSource.events(listOf(legacy), calendar)

        assertTrue(result.events.isEmpty())
        assertTrue(result.hasUnresolvedBlockAttribution)
        assertEquals(listOf("legacy-1"), result.unattributedToBlockRecordIds)
        // It is not silently assigned to any block, including the only one that
        // could look plausible.
        assertFalse(result.events.any { it.blockId == blockA })
    }

    @Test
    fun `unresolved and attributed applications coexist without contaminating blocks`() {
        val attributed = record(id = "attributed-1", blocks = resolverBlocks(listOf(blockA)))
        val legacy = record(id = "legacy-1", blocks = null)

        val result = ResistanceEventSource.events(listOf(attributed, legacy), calendar)

        // Block A's definite history contains exactly the attributed spray...
        assertEquals(listOf("attributed-1"), result.events.map { it.applicationId })
        // ...while the legacy spray is reported separately, so a per-block answer can
        // be qualified as incomplete rather than presented as clean.
        assertEquals(listOf("legacy-1"), result.unattributedToBlockRecordIds)
    }

    // ---------------------------- 9. the three unknowns stay separate dimensions

    @Test
    fun `known block with unknown target is target uncertainty only`() {
        val result = ResistanceEventSource.events(
            listOf(record(id = "s1", blocks = resolverBlocks(listOf(blockA)), targets = null)),
            calendar,
        )

        // The block is known, so this is NOT block-attribution uncertainty.
        assertFalse(result.hasUnresolvedBlockAttribution)
        assertEquals(1, result.events.size)
        assertEquals(blockA, result.events[0].blockId)
        // The target is what is missing, and it stays missing rather than being
        // inferred from the tank mix.
        assertFalse(result.events[0].targetsRecorded)
    }

    @Test
    fun `unknown block with known target is block uncertainty only`() {
        val result = ResistanceEventSource.events(
            listOf(
                record(
                    id = "s1",
                    blocks = null,
                    targets = listOf(SprayTarget.POWDERY_MILDEW.raw),
                )
            ),
            calendar,
        )

        assertTrue(result.hasUnresolvedBlockAttribution)
        val unresolved = result.unresolvedBlockApplications.single()
        // The target IS known, so the caller can say precisely which disease the
        // incomplete attribution bears on.
        assertTrue(unresolved.targetsRecorded)
        assertEquals(listOf(ResistanceDisease.POWDERY_MILDEW), unresolved.targets)
        assertTrue(unresolved.mayConcern(ResistanceDisease.POWDERY_MILDEW))
        assertFalse(unresolved.mayConcern(ResistanceDisease.DOWNY_MILDEW))
    }

    @Test
    fun `unrecorded targets on an unattributed spray may concern any disease`() {
        val result = ResistanceEventSource.events(
            listOf(record(id = "s1", blocks = null, targets = null)),
            calendar,
        )

        val unresolved = result.unresolvedBlockApplications.single()
        // Two unknowns compound rather than cancel: nothing establishes that this
        // spray was irrelevant to either disease.
        assertTrue(unresolved.mayConcern(ResistanceDisease.POWDERY_MILDEW))
        assertTrue(unresolved.mayConcern(ResistanceDisease.DOWNY_MILDEW))
    }

    @Test
    fun `block attribution is independent of chemistry availability`() {
        // No chemical snapshot anywhere on this record, yet the block attribution is
        // fully known. A caller must be able to report the chemistry gap without
        // implying the blocks are uncertain.
        val result = ResistanceEventSource.events(
            listOf(record(id = "s1", blocks = resolverBlocks(listOf(blockA, blockC)))),
            calendar,
        )

        assertFalse(result.hasUnresolvedBlockAttribution)
        assertEquals(setOf(blockA, blockC), result.events.map { it.blockId }.toSet())
        assertTrue(result.events.all { it.products.isEmpty() })
    }

    // ------------------------------------- 10. candidate per-block scoping

    @Test
    fun `a candidate selection projects per block and is not a whole vineyard event`() {
        // The Guided Spray selection state, projected through the SAME path a saved
        // record uses — no separate candidate list to drift.
        val candidateBlocks = SprayManualBlockAttribution.resolve(
            selectedBlockIds = listOf(blockA, blockC),
            recordedBlocks = null,
            availableBlocks = vineyardBlocks,
            isEdit = false,
        )
        val candidate = SprayRecord(
            id = "candidate-1",
            vineyardId = "vineyard-1",
            date = "2026-10-08T08:00:00Z",
            startTime = "2026-10-08T08:00:00Z",
            // No endTime: not yet applied, so this is a PLANNED event.
            targets = listOf(SprayTarget.POWDERY_MILDEW.raw),
            applicationBlocks = candidateBlocks,
        )

        val result = ResistanceEventSource.events(listOf(candidate), calendar)

        // Two blocks in, two independently-evaluable events out. The candidate is
        // never one vineyard-wide event to be filtered down afterwards.
        assertEquals(2, result.events.size)
        assertEquals(setOf(blockA, blockC), result.events.map { it.blockId }.toSet())
        assertFalse(result.events.any { it.blockId == blockB })
        assertTrue(result.events.all { it.applicationId == "candidate-1" })
    }

    @Test
    fun `candidate events carry each blocks own history separately`() {
        // A has prior Group 11 history; C does not. The projection must keep them
        // apart so a per-block evaluation cannot borrow A's history for C.
        val history = record(id = "past-1", blocks = resolverBlocks(listOf(blockA)))
        val candidate = record(id = "candidate-1", blocks = resolverBlocks(listOf(blockA, blockC)))

        val result = ResistanceEventSource.events(listOf(history, candidate), calendar)

        val byBlock = result.events.groupBy { it.blockId }
        assertEquals(setOf("past-1", "candidate-1"), byBlock[blockA]!!.map { it.applicationId }.toSet())
        assertEquals(listOf("candidate-1"), byBlock[blockC]!!.map { it.applicationId })
    }

    // -------------------------------------------- 11. no historical guessing

    @Test
    fun `attribution is never derived from row numbers or names`() {
        // A record with tank row applications but no block attribution. Row numbers
        // are not unique across blocks and carry no block reference, so they must
        // not become attribution.
        val legacy = record(id = "legacy-rows", blocks = null)

        val result = ResistanceEventSource.events(listOf(legacy), calendar)

        assertTrue(result.events.isEmpty())
        assertEquals(listOf("legacy-rows"), result.unattributedToBlockRecordIds)
    }

    @Test
    fun `name collisions across vineyards cannot move history`() {
        // Another vineyard has a block with the SAME name and a different id.
        val otherVineyardBlock = Paddock(
            id = ghostBlock,
            vineyardId = "vineyard-2",
            name = "Home Block",
        )

        val stored = listOf(
            SprayApplicationBlockSnapshot(blockId = blockA, blockName = "Home Block")
        )
        val resolved = SprayBlockAttributionDisplay.resolve(
            stored,
            vineyardBlocks + otherVineyardBlock,
        )

        // Resolution is by id, so the identical name resolves to OUR block only.
        assertEquals(blockA, resolved!![0].blockId)
        assertEquals(1, resolved.size)
    }
}
