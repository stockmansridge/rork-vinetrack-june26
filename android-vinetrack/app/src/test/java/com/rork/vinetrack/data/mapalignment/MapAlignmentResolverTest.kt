package com.rork.vinetrack.data.mapalignment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * V1 scope precedence: Enabled Block > Enabled Vineyard > None.
 *
 * The most important property here is the negative one: an alignment captured on
 * ONE Android installation must never leak to another device, because that would
 * turn one operator's imagery observation into a vineyard-wide correction.
 *
 * The second is that a DISABLED alignment is not an active candidate — it must
 * fall through rather than win and silently suppress the scope beneath it.
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
        enabled: Boolean = true,
    ) = MapAlignment(
        id = id,
        scope = MapAlignmentScope(installationId, vineyardId, blockId),
        eastOffsetMetres = east,
        northOffsetMetres = north,
        isEnabled = enabled,
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

    // ----- Enablement is part of candidate selection -----

    @Test
    fun `a disabled block alignment does not suppress an enabled vineyard alignment`() {
        val alignments = listOf(
            alignment("vineyard", installA, "v1"),
            alignment("block-off", installA, "v1", blockId = "b1", enabled = false),
        )
        // Switching a block override off must reveal the vineyard correction,
        // not silently cancel it via an identity transform.
        assertEquals("vineyard", resolve(alignments, blockId = "b1")?.id)
        assertEquals("vineyard", resolve(alignments.reversed(), blockId = "b1")?.id)
    }

    @Test
    fun `a disabled vineyard alignment resolves to none`() {
        val alignments = listOf(alignment("vineyard-off", installA, "v1", enabled = false))
        assertNull(resolve(alignments))
        assertNull(resolve(alignments, blockId = "b1"))
    }

    @Test
    fun `a disabled block alignment with no vineyard alignment resolves to none`() {
        val alignments = listOf(
            alignment("block-off", installA, "v1", blockId = "b1", enabled = false),
        )
        assertNull(resolve(alignments, blockId = "b1"))
    }

    @Test
    fun `an enabled zero-offset block override wins over an enabled vineyard alignment`() {
        val zeroBlock = alignment(
            "block-zero",
            installA,
            "v1",
            blockId = "b1",
            east = 0.0,
            north = 0.0,
        )
        val alignments = listOf(alignment("vineyard", installA, "v1"), zeroBlock)

        // "This block intentionally needs no correction" is an ACTIVE override.
        val winner = resolve(alignments, blockId = "b1")
        assertEquals("block-zero", winner?.id)
        assertEquals("block-zero", resolve(alignments.reversed(), blockId = "b1")?.id)

        // It wins as a candidate, yet transforms as identity for that block.
        assertTrue("enabled zero offset must still be an identity transform", winner!!.isIdentity)
        assertTrue("enablement, not isIdentity, decides candidacy", winner.isEnabled)

        // Another block in the same vineyard still gets the vineyard alignment.
        assertEquals("vineyard", resolve(alignments, blockId = "b2")?.id)
    }

    @Test
    fun `a disabled alignment from another installation still never applies`() {
        val alignments = listOf(
            alignment("other-off", installB, "v1", enabled = false),
            alignment("other-block-off", installB, "v1", blockId = "b1", enabled = false),
        )
        assertNull(resolve(alignments, installationId = installA, blockId = "b1"))
        assertNull(resolve(alignments, installationId = installA))
        // Enabling them changes nothing for installation A either.
        assertNull(
            resolve(
                listOf(alignment("other-on", installB, "v1")),
                installationId = installA,
            ),
        )
    }

    @Test
    fun `a disabled block falls through to the vineyard only within its own installation`() {
        val alignments = listOf(
            alignment("a-vineyard", installA, "v1"),
            alignment("b-block-off", installB, "v1", blockId = "b1", enabled = false),
            alignment("b-vineyard", installB, "v1"),
        )
        assertEquals("a-vineyard", resolve(alignments, installationId = installA, blockId = "b1")?.id)
        assertEquals("b-vineyard", resolve(alignments, installationId = installB, blockId = "b1")?.id)
    }

    @Test
    fun `resolveOrNone yields identity when the only candidate is disabled`() {
        val disabledOnly = listOf(alignment("off", installA, "v1", enabled = false))
        val none = MapAlignmentResolver.resolveOrNone(disabledOnly, installA, "v1")
        assertTrue(none.isIdentity)
        assertEquals("none", none.id)
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
