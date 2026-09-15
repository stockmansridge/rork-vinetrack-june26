package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * V1 scope precedence: Block > Vineyard > None.
 *
 * The most important property here is the negative one: an alignment captured on
 * ONE Android installation must never leak to another device, because that would
 * turn one operator's imagery observation into a vineyard-wide correction.
 */
class MapAlignmentResolverTest {

    private val installA = "install-a"
    private val installB = "install-b"

    private fun alignment(
        id: String,
        installationId: String,
        vineyardId: String,
        blockId: String? = null,
        east: Double = 5.0,
        north: Double = 5.0,
    ) = MapAlignment(
        id = id,
        scope = MapAlignmentScope(installationId, vineyardId, blockId),
        eastOffsetMetres = east,
        northOffsetMetres = north,
        isEnabled = true,
    )

    private fun resolve(
        alignments: List<MapAlignment>,
        installationId: String = installA,
        vineyardId: String = "v1",
        blockId: String? = null,
    ) = MapAlignmentResolver.resolve(alignments, installationId, vineyardId, blockId)

    @Test
    fun `installation A alignment does not apply to installation B`() {
        val onlyA = listOf(alignment("a", installA, "v1"))
        assertEquals("a", resolve(onlyA, installationId = installA)?.id)
        assertNull(
            "one device's alignment must never become a vineyard-wide correction",
            resolve(onlyA, installationId = installB),
        )
    }

    @Test
    fun `vineyard A alignment does not apply to vineyard B`() {
        val onlyV1 = listOf(alignment("a", installA, "v1"))
        assertEquals("a", resolve(onlyV1, vineyardId = "v1")?.id)
        assertNull(resolve(onlyV1, vineyardId = "v2"))
    }

    @Test
    fun `vineyard alignment applies when no block override exists`() {
        val alignments = listOf(alignment("vineyard", installA, "v1"))
        // With no block in context, and with a block that has no override.
        assertEquals("vineyard", resolve(alignments)?.id)
        assertEquals("vineyard", resolve(alignments, blockId = "b1")?.id)
    }

    @Test
    fun `matching block override wins over vineyard alignment`() {
        val alignments = listOf(
            alignment("vineyard", installA, "v1"),
            alignment("block", installA, "v1", blockId = "b1"),
        )
        assertEquals("block", resolve(alignments, blockId = "b1")?.id)
        // Order must not matter.
        assertEquals("block", resolve(alignments.reversed(), blockId = "b1")?.id)
    }

    @Test
    fun `another block's override does not apply`() {
        val alignments = listOf(
            alignment("vineyard", installA, "v1"),
            alignment("block2", installA, "v1", blockId = "b2"),
        )
        // Block b1 has no override, so it falls back to the vineyard alignment —
        // it must NOT borrow b2's override.
        assertEquals("vineyard", resolve(alignments, blockId = "b1")?.id)
    }

    @Test
    fun `a block override alone is not used outside its block`() {
        val onlyBlockOverride = listOf(alignment("block2", installA, "v1", blockId = "b2"))
        assertNull(resolve(onlyBlockOverride, blockId = "b1"))
        assertNull("no block context cannot use a block override", resolve(onlyBlockOverride))
        assertEquals("block2", resolve(onlyBlockOverride, blockId = "b2")?.id)
    }

    @Test
    fun `no matching scope produces no alignment`() {
        assertNull(resolve(emptyList()))
        assertNull(
            resolve(
                listOf(
                    alignment("other-install", installB, "v1"),
                    alignment("other-vineyard", installA, "v2"),
                    alignment("other-both", installB, "v2", blockId = "b1"),
                ),
                blockId = "b1",
            ),
        )
    }

    @Test
    fun `a block override for another installation never wins`() {
        val alignments = listOf(
            alignment("vineyard-a", installA, "v1"),
            alignment("block-b", installB, "v1", blockId = "b1"),
        )
        assertEquals("vineyard-a", resolve(alignments, installationId = installA, blockId = "b1")?.id)
    }

    @Test
    fun `resolveOrNone yields a behaviourally invisible alignment when nothing matches`() {
        val none = MapAlignmentResolver.resolveOrNone(emptyList(), installA, "v1", "b1")
        assertTrue("no match must render exactly as production does today", none.isIdentity)
        assertEquals(installA, none.androidInstallationId)
        assertEquals("v1", none.vineyardId)

        // A real match is returned untouched.
        val real = alignment("vineyard", installA, "v1")
        assertEquals("vineyard", MapAlignmentResolver.resolveOrNone(listOf(real), installA, "v1").id)
    }

    @Test
    fun `scope helpers describe the override relationship`() {
        val block = MapAlignmentScope(installA, "v1", "b1")
        val vineyard = MapAlignmentScope(installA, "v1")
        assertTrue(block.isBlockOverride)
        assertEquals(vineyard, block.asVineyardScope())
        assertEquals(vineyard, vineyard.asVineyardScope())
    }
}
