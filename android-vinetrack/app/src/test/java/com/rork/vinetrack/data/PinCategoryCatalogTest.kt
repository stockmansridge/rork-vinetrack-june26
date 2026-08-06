package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Canonical pin-category colour contract tests — mirrored by iOS
 * `PinCategoryCatalogTests`. The id/colour pairs asserted here MUST stay
 * identical to the Swift suite so both platforms render every category the
 * same colour, and unknown/historical categories the same neutral gray.
 */
class PinCategoryCatalogTest {

    @Test
    fun `stored display text normalises to stable category ids`() {
        assertEquals(PinCategoryCatalog.VINE_ISSUE, PinCategoryCatalog.canonicalId("Vine Issue"))
        assertEquals(PinCategoryCatalog.VINE_ISSUE, PinCategoryCatalog.canonicalId("vine-issue"))
        assertEquals(PinCategoryCatalog.VINE_ISSUE, PinCategoryCatalog.canonicalId("  VINE   ISSUE  "))
        assertEquals(PinCategoryCatalog.BROKEN_POST, PinCategoryCatalog.canonicalId("Broken Post"))
        assertEquals(PinCategoryCatalog.BROKEN_WIRE, PinCategoryCatalog.canonicalId("broken_wire"))
        assertEquals(PinCategoryCatalog.IRRIGATION, PinCategoryCatalog.canonicalId("Irrigation"))
        assertEquals(PinCategoryCatalog.OTHER, PinCategoryCatalog.canonicalId("Other"))
    }

    @Test
    fun `unknown or missing categories resolve to null`() {
        assertNull(PinCategoryCatalog.canonicalId(null))
        assertNull(PinCategoryCatalog.canonicalId(""))
        assertNull(PinCategoryCatalog.canonicalId("   "))
        assertNull(PinCategoryCatalog.canonicalId("Netting"))
        assertNull(PinCategoryCatalog.canonicalId("Growth Stage 12"))
    }

    @Test
    fun `canonical colour tokens are deterministic per category id`() {
        assertEquals("blue", PinCategoryCatalog.colorToken(PinCategoryCatalog.IRRIGATION))
        assertEquals("brown", PinCategoryCatalog.colorToken(PinCategoryCatalog.BROKEN_POST))
        assertEquals("green", PinCategoryCatalog.colorToken(PinCategoryCatalog.VINE_ISSUE))
        assertEquals("orange", PinCategoryCatalog.colorToken(PinCategoryCatalog.BROKEN_WIRE))
        assertEquals("gray", PinCategoryCatalog.colorToken(PinCategoryCatalog.OTHER))
    }

    @Test
    fun `unknown categories render as unassigned gray, never another colour`() {
        assertEquals("gray", PinCategoryCatalog.colorToken(null))
        assertEquals("gray", PinCategoryCatalog.colorToken("mystery_id"))
        assertEquals("gray", PinCategoryCatalog.colorTokenForRaw(null))
        assertEquals("gray", PinCategoryCatalog.colorTokenForRaw("Netting"))
    }

    @Test
    fun `raw stored value resolves straight to its canonical colour`() {
        assertEquals("green", PinCategoryCatalog.colorTokenForRaw("Vine Issue"))
        assertEquals("brown", PinCategoryCatalog.colorTokenForRaw("Broken Post"))
        assertEquals("orange", PinCategoryCatalog.colorTokenForRaw("Broken Wire"))
        assertEquals("blue", PinCategoryCatalog.colorTokenForRaw("irrigation"))
    }
}
