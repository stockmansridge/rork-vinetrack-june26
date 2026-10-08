package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.GrapeAllocation
import com.rork.vinetrack.data.model.GrapeAllocationBlock
import com.rork.vinetrack.data.model.GrapeAllocationCalculator
import com.rork.vinetrack.data.model.GrapeAllocationHierarchy
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class GrapeAllocationHierarchyTest {
    private val vineyard = "v"
    private fun allocation(tonnes: Double = 5.0, own: Boolean = false, id: String = "a", blocks: List<Pair<String, Double?>> = emptyList()) = GrapeAllocation(
        id = id, vineyardId = vineyard, vintage = 2026, varietyName = "Pinot Gris",
        allocationType = if (own) GrapeAllocation.TYPE_OWN_USE else GrapeAllocation.TYPE_EXTERNAL, quantityTonnes = tonnes,
        blocks = blocks.mapIndexed { index, (block, quantity) -> GrapeAllocationBlock("$id-$index", id, vineyard, block, "Old snapshot", quantity) },
    )
    private fun rows(allocations: List<GrapeAllocation>, estimates: List<GrapeAllocationHierarchy.Estimate> = emptyList()) =
        GrapeAllocationHierarchy.rows("pinot gris", vineyard, 2026, allocations, estimates, mapOf("b7" to "B7", "b49" to "B49"))

    @Test fun customerRelationshipsUseSetupNamesAndPersistedIDs() {
        val pinot = allocation(blocks = listOf("b7" to null))
        val sb = allocation(id = "sb", blocks = listOf("b49" to null)).copy(varietyName = "Sauvignon Blanc")
        assertEquals("B7", rows(listOf(pinot, sb)).first().name)
        assertEquals(listOf(pinot.id), rows(listOf(pinot, sb)).first().allocationIds)
        val sauvignon = GrapeAllocationHierarchy.rows("sauvignon blanc", vineyard, 2026, listOf(pinot, sb), emptyList(), mapOf("b49" to "B49"))
        assertEquals("B49", sauvignon.first().name)
        assertEquals(5.0, sauvignon.first().externalTonnes, 0.0)
    }
    @Test fun severalAllocationsAndSplitReconcileWithCanonicalParent() {
        val own = allocation(2.0, own = true, id = "own", blocks = listOf("b7" to 2.0))
        val external = allocation(6.0, blocks = listOf("b7" to 1.0, "b49" to 4.0))
        val children = rows(listOf(own, external))
        val b7 = children.first { it.paddockId == "b7" }
        assertEquals(2.0, b7.ownUseTonnes, 0.0)
        assertEquals(1.0, b7.externalTonnes, 0.0)
        assertEquals(setOf("own", "a"), b7.allocationIds.toSet())
        assertEquals(1.0, children.first { it.paddockId == null }.allocatedTonnes, 0.0)
        val parent = GrapeAllocationCalculator.canonicalVarietyRows(emptyMap(), listOf(own, external), 2026).first()
        assertEquals(parent.ownUseTonnes, children.sumOf { it.ownUseTonnes }, 0.0)
        assertEquals(parent.externalTonnes, children.sumOf { it.externalTonnes }, 0.0)
    }
    @Test fun missingMultiBlockQuantitiesNeverInventDistribution() {
        val children = rows(listOf(allocation(9.0, blocks = listOf("b7" to 3.0, "b49" to null))))
        assertEquals(0.0, children.first { it.paddockId == "b49" }.allocatedTonnes, 0.0)
        assertTrue(children.first { it.paddockId == "b49" }.hasUnspecifiedQuantity)
        assertEquals(6.0, children.first { it.paddockId == null }.allocatedTonnes, 0.0)
        val missing = rows(listOf(allocation(blocks = listOf("b7" to null, "b49" to null))))
        assertEquals(5.0, missing.first { it.paddockId == null }.allocatedTonnes, 0.0)
    }
    @Test fun explicitZeroAndDuplicateLinksArePreserved() {
        val zero = rows(listOf(allocation(blocks = listOf("b7" to 0.0))))
        assertEquals(0.0, zero.first { it.paddockId == "b7" }.externalTonnes, 0.0)
        assertEquals(5.0, zero.first { it.paddockId == null }.externalTonnes, 0.0)
        val duplicate = rows(listOf(allocation(blocks = listOf("B7" to 2.0, "b7" to 3.0))))
        assertEquals(1, duplicate.size)
        assertEquals(5.0, duplicate.first().externalTonnes, 0.0)
        assertEquals(1, duplicate.first().allocationIds.size)
    }
    @Test fun unknownEstimateIsNotZeroAndKnownSupplyBalances() {
        val a = allocation(blocks = listOf("b7" to null))
        val known = rows(listOf(a), listOf(GrapeAllocationHierarchy.Estimate("b7", "Pinot Gris", 8.0)))
        assertEquals(8.0, known.first().estimatedTonnes!!, 0.0)
        assertEquals(3.0, known.first().balanceTonnes!!, 0.0)
        val unknown = rows(listOf(a), listOf(GrapeAllocationHierarchy.Estimate("b7", "Pinot Gris", null)))
        assertNull(unknown.first().estimatedTonnes)
        assertNull(unknown.first().balanceTonnes)
        val noBlock = rows(listOf(allocation())).first()
        assertEquals("No block specified", noBlock.name)
        assertNull(noBlock.estimatedTonnes)
    }
    @Test fun estimateGroupsSumWithoutCopyingVarietyTotal() {
        val children = rows(emptyList(), listOf(
            GrapeAllocationHierarchy.Estimate("b7", "Pinot Gris", 4.0), GrapeAllocationHierarchy.Estimate("b7", "PINOT GRIS", 2.0),
            GrapeAllocationHierarchy.Estimate("b49", "Pinot Gris", 7.0), GrapeAllocationHierarchy.Estimate("b49", "Sauvignon Blanc", 20.0)))
        assertEquals(6.0, children.first { it.paddockId == "b7" }.estimatedTonnes!!, 0.0)
        assertEquals(7.0, children.first { it.paddockId == "b49" }.estimatedTonnes!!, 0.0)
        assertEquals(13.0, children.sumOf { it.estimatedTonnes ?: 0.0 }, 0.0)
    }
    @Test fun vineyardVintageAndRelationshipIsolation() {
        val a = allocation(blocks = listOf("b7" to null))
        val children = rows(listOf(a, a.copy(vineyardId = "other"), a.copy(vintage = 2025), a.copy(deletedAt = "deleted")))
        assertEquals(5.0, children.first().externalTonnes, 0.0)
        assertEquals(listOf(a.id), children.first().allocationIds)
        val corrupt = a.copy(blocks = a.blocks.map { it.copy(allocationId = "other") })
        assertNull(rows(listOf(corrupt)).first().paddockId)
    }
    @Test fun legacyOverassignmentReconcilesWithoutChangingRecords() {
        val a = allocation(blocks = listOf("b7" to 7.0))
        val children = rows(listOf(a))
        assertEquals(-2.0, children.first { it.paddockId == null }.allocatedTonnes, 0.0)
        assertEquals(5.0, children.sumOf { it.allocatedTonnes }, 0.0)
        assertEquals(7.0, a.blocks.first().quantityTonnes!!, 0.0)
    }
    @Test fun portalAliasesCapitalizationAndDistinctVarieties() {
        listOf("Pinot Gris", " pinot   grigio ", "PINOT_GRIGIO", "Pinot Gris / Grigio", "PG").forEach { alias ->
            assertEquals("pinot gris", GrapeAllocationHierarchy.varietyKey(alias))
            assertEquals("Pinot Gris", GrapeAllocationHierarchy.varietyLabel(alias))
        }
        assertEquals("Sauvignon Blanc", GrapeAllocationHierarchy.varietyLabel("sauvignon blanc"))
        assertEquals("Gruner Veltliner", GrapeAllocationHierarchy.varietyLabel("grüner veltliner"))
        assertEquals("shiraz", GrapeAllocationHierarchy.varietyKey("Syrah"))
        assertNotEquals(GrapeAllocationHierarchy.varietyKey("Pinot Noir"), GrapeAllocationHierarchy.varietyKey("Pinot Gris"))
        assertNotEquals(GrapeAllocationHierarchy.varietyKey("Custom-A"), GrapeAllocationHierarchy.varietyKey("Custom A"))
        assertNotEquals(GrapeAllocationHierarchy.varietyKey("Savagnin"), GrapeAllocationHierarchy.varietyKey("Sauvignon Blanc"))
        assertEquals("Custom Variety", GrapeAllocationHierarchy.varietyLabel("custom variety"))
    }
    @Test fun groupedSupplyChildrenAndVineyardTotalsReconcileWithDamage() {
        val varieties = listOf("pinot gris", "Pinot Grigio", "SAUVIGNON BLANC").mapIndexed { index, name ->
            SeasonYieldProjection.VarietyRow(index.toString(), null, name, false, true,
                listOf(4.0, 6.0, 8.0)[index], listOf(4.0, 6.0, 8.0)[index],
                listOf(3.0, 5.0, 7.0)[index], listOf(3.0, 5.0, 7.0)[index], listOf("b7"))
        }
        val own = allocation(2.0, own = true, id = "own", blocks = listOf("b7" to null))
        val external = allocation(5.0, blocks = listOf("b7" to 2.0, "b49" to 2.0)).copy(varietyName = "Pinot Grigio")
        val sb = allocation(3.0, id = "sb", blocks = listOf("b49" to null)).copy(varietyName = "sauvignon blanc")
        listOf(false, true).forEach { damage ->
            val projection = SeasonYieldProjection.Result(vineyard, 2026, damage, true, 18.0, 15.0, 18.0, 15.0,
                "fixture", null, 2, 2, 0, 2, 0, emptyList(), varieties, emptyList())
            val grouped = GrapeAllocationHierarchy.varietyRows(GrapeAllocationHierarchy.supply(projection),
                listOf(own, external, sb, external.copy(vineyardId = "other"), external.copy(vintage = 2025), external.copy(deletedAt = "deleted")), vineyard, 2026)
            assertEquals(2, grouped.size)
            val pinot = grouped.first { it.varietyKey == "pinot gris" }
            assertEquals("Pinot Gris", pinot.displayName)
            assertEquals(if (damage) 8.0 else 10.0, pinot.estimatedTonnes!!, 0.0)
            assertEquals(2.0, pinot.ownUseTonnes, 0.0)
            assertEquals(5.0, pinot.externalTonnes, 0.0)
            val children = rows(listOf(own, external), listOf(
                GrapeAllocationHierarchy.Estimate("b7", "Pinot Gris", if (damage) 3.0 else 4.0),
                GrapeAllocationHierarchy.Estimate("b7", "Pinot Grigio", if (damage) 5.0 else 6.0)))
            assertEquals(pinot.estimatedTonnes!!, children.sumOf { it.estimatedTonnes ?: 0.0 }, 0.0)
            assertEquals(pinot.ownUseTonnes, children.sumOf { it.ownUseTonnes }, 0.0)
            assertEquals(pinot.externalTonnes, children.sumOf { it.externalTonnes }, 0.0)
            assertEquals(setOf(own.id, external.id), children.flatMap { it.allocationIds }.toSet())
            val summary = GrapeAllocationCalculator.canonicalSummary(projection, listOf(own, external, sb), 2026)
            assertEquals(summary.estimatedTonnes!!, grouped.sumOf { it.estimatedTonnes ?: 0.0 }, 0.0)
            assertEquals(summary.ownUseTonnes, grouped.sumOf { it.ownUseTonnes }, 0.0)
            assertEquals(summary.committedTonnes, grouped.sumOf { it.externalTonnes }, 0.0)
            assertEquals(summary.balanceTonnes!!, grouped.sumOf { it.balanceTonnes ?: 0.0 }, 0.0)
        }
        assertEquals("Pinot Grigio", external.varietyName)
        assertEquals(listOf(2.0, 2.0), external.blocks.map { it.quantityTonnes })
    }
    @Test fun groupedUnknownSupplyStaysUnknownAndCustomNamesStaySeparate() {
        val supply = listOf(
            GrapeAllocationCalculator.CanonicalSupply("a", "Pinot Gris", 4.0, 4.0, true),
            GrapeAllocationCalculator.CanonicalSupply("b", "Pinot Grigio", null, 2.0, false))
        val grouped = GrapeAllocationHierarchy.varietyRows(supply,
            listOf(allocation(id = "custom-a").copy(varietyName = "Custom-A"), allocation(id = "custom-b").copy(varietyName = "Custom A")), vineyard, 2026)
        assertEquals(3, grouped.size)
        val pinot = grouped.first { it.varietyKey == "pinot gris" }
        assertNull(pinot.estimatedTonnes)
        assertNull(pinot.balanceTonnes)
        assertEquals(6.0, pinot.knownEstimatedTonnes, 0.0)
        assertFalse(pinot.isEstimateComplete)
        val children = rows(emptyList(), listOf(GrapeAllocationHierarchy.Estimate("b7", "Pinot Gris", 4.0),
            GrapeAllocationHierarchy.Estimate("b7", "Pinot Grigio", null)))
        assertNull(children.first().estimatedTonnes)
    }
    @Test fun canonicalHeaderAndBlockReloadKeepIdentityAndExactQuantity() {
        val original = allocation(5.123456789, blocks = listOf("b7" to 2.123456789, "b49" to 3.0))
        // Production reads header and relationship rows separately; blocks are @Transient.
        val header = Json.decodeFromString<GrapeAllocation>(Json.encodeToString(original.copy(notes = "Edited through child")))
        val links = Json.decodeFromString<List<GrapeAllocationBlock>>(Json.encodeToString(original.blocks))
        val reloaded = header.copy(blocks = links)
        assertEquals(original.id, reloaded.id)
        assertEquals(original.quantityTonnes, reloaded.quantityTonnes, 0.0)
        assertEquals(original.blocks.map { it.id }, reloaded.blocks.map { it.id })
        assertEquals(original.quantityTonnes, rows(listOf(reloaded)).sumOf { it.allocatedTonnes }, 1e-10)
    }
}
