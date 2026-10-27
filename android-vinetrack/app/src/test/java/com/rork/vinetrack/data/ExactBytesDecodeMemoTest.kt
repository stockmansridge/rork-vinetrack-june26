package com.rork.vinetrack.data

import org.junit.Assert.*
import org.junit.Test

class ExactBytesDecodeMemoTest {
    @Test fun `identical bytes reuse decode but changed bytes cannot reuse old value`() {
        val memo = ExactBytesDecodeMemo<Any>()
        var calls = 0
        fun decode(raw: String) = memo.decode(raw) { calls++; Any() }
        val a = decode("account-A vineyard-A bytes")
        assertSame(a, decode("account-A vineyard-A bytes"))
        assertNotSame(a, decode("account-B vineyard-A bytes"))
        assertNotSame(a, decode("account-A vineyard-B bytes"))
        assertEquals(3, calls)
    }

    @Test fun `least recently used entries and source byte budget are bounded`() {
        val memo = ExactBytesDecodeMemo<Any>(maxSourceBytes = 8, maxEntries = 2)
        fun decode(raw: String) = memo.decode(raw) { Any() }
        val a = decode("aa")
        val b = decode("bb")
        assertSame(a, decode("aa"))
        decode("cc")
        assertNotSame(b, decode("bb"))
    }

    @Test fun `oversized and ineligible decodes are not retained`() {
        val memo = ExactBytesDecodeMemo<Any>(maxSourceBytes = 2)
        assertNotSame(memo.decode("large") { Any() }, memo.decode("large") { Any() })
        assertNotSame(memo.decode("a", canRetain = { false }) { Any() },
            memo.decode("a", canRetain = { false }) { Any() })
    }

    @Test fun `failed decode cannot poison later retry or become an empty cached value`() {
        val memo = ExactBytesDecodeMemo<String>()
        try {
            memo.decode("unreadable") { error("Synthetic corruption") }
            fail("Expected decode failure")
        } catch (_: IllegalStateException) { }
        assertEquals("repaired", memo.decode("unreadable") { "repaired" })
    }
}
