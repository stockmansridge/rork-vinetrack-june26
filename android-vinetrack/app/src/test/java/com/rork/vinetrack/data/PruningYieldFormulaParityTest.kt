package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.PruningYieldDefaults
import com.rork.vinetrack.data.model.PruningYieldFormula
import com.rork.vinetrack.data.model.PruningYieldInputFormat
import com.rork.vinetrack.data.model.PruningYieldSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cross-platform parity vectors for the Pruning Yield Calculator.
 *
 * The SAME input vectors and expected outputs are asserted by
 * `PruningYieldSettingsTests.swift` in the iOS test target, so both
 * platforms are pinned to identical formula results (sql/181 shared
 * per-block configuration contract).
 */
class PruningYieldFormulaParityTest {

    private val vineyard = "11111111-1111-4111-8111-111111111111"
    private val blockA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val blockB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    // ---- Formula parity vectors (must match iOS exactly) --------------------

    @Test
    fun spurVector() {
        val budsPerVine = PruningYieldFormula.budsPerVine(
            pruneMethod = "spur", budsPerSpur = 2.0, spursPerVine = 6.0, budsPerCane = 10.0, canesPerVine = 4.0,
        )
        assertEquals(12.0, budsPerVine, 0.0)
        val bunchesPerHa = PruningYieldFormula.bunchesPerHectare(1.5, budsPerVine, 2000.0)
        assertEquals(36_000.0, bunchesPerHa, 0.0)
        val kgPerHa = PruningYieldFormula.yieldKgPerHectare(bunchesPerHa, 120.0)
        assertEquals(4320.0, kgPerHa, 0.0)
        val tPerHa = PruningYieldFormula.yieldTonnesPerHectare(kgPerHa)
        assertEquals(4.32, tPerHa, 1e-9)
        val total = PruningYieldFormula.totalYieldTonnes(tPerHa, 1.8)
        assertEquals(7.776, total!!, 1e-9)
    }

    @Test
    fun caneVector() {
        val budsPerVine = PruningYieldFormula.budsPerVine(
            pruneMethod = "cane", budsPerSpur = 2.0, spursPerVine = 6.0, budsPerCane = 10.0, canesPerVine = 4.0,
        )
        assertEquals(40.0, budsPerVine, 0.0)
        val bunchesPerHa = PruningYieldFormula.bunchesPerHectare(1.2, budsPerVine, 1650.0)
        assertEquals(79_200.0, bunchesPerHa, 0.0)
        val kgPerHa = PruningYieldFormula.yieldKgPerHectare(bunchesPerHa, 95.0)
        assertEquals(7524.0, kgPerHa, 1e-9)
        val tPerHa = PruningYieldFormula.yieldTonnesPerHectare(kgPerHa)
        assertEquals(7.524, tPerHa, 1e-9)
        val total = PruningYieldFormula.totalYieldTonnes(tPerHa, 2.5)
        assertEquals(18.81, total!!, 1e-9)
    }

    @Test
    fun zeroAreaHasNoBlockTotal() {
        assertNull(PruningYieldFormula.totalYieldTonnes(4.32, 0.0))
    }

    // ---- Defaults match the shared contract (sql/181 column defaults) -------

    @Test
    fun canonicalDefaults() {
        val s = PruningYieldSettings(id = "x", vineyardId = vineyard, paddockId = blockA)
        assertEquals("spur", s.pruneMethod)
        assertEquals(1.5, s.bunchesPerBud, 0.0)
        assertEquals(2.0, s.budsPerSpur, 0.0)
        assertEquals(6.0, s.spursPerVine, 0.0)
        assertEquals(10.0, s.budsPerCane, 0.0)
        assertEquals(4.0, s.canesPerVine, 0.0)
        assertNull(s.vinesPerHa)
        assertEquals(120.0, s.bunchWeightGrams, 0.0)
        assertEquals(1.5, PruningYieldDefaults.BUNCHES_PER_BUD, 0.0)
    }

    // ---- Field text round-trip (same convention as iOS) ----------------------

    @Test
    fun inputTextFormatting() {
        assertEquals("2", PruningYieldInputFormat.text(2.0))
        assertEquals("1.5", PruningYieldInputFormat.text(1.5))
        assertEquals("120", PruningYieldInputFormat.text(120.0))
        assertEquals("0.125", PruningYieldInputFormat.text(0.125))
        assertEquals("", PruningYieldInputFormat.text(null))
        assertEquals(1.5, PruningYieldInputFormat.parse("1,5"), 0.0)
        assertEquals(0.0, PruningYieldInputFormat.parse("junk"), 0.0)
        assertNull(PruningYieldInputFormat.parseOptional(""))
        assertEquals(1800.0, PruningYieldInputFormat.parseOptional(" 1800 ")!!, 0.0)
    }

    // ---- Per-block independence via value equality ---------------------------

    @Test
    fun inputsEqualIgnoresIdentity() {
        val a = PruningYieldSettings(id = "a", vineyardId = vineyard, paddockId = blockA, vinesPerHa = 2000.0)
        val b = PruningYieldSettings(id = "b", vineyardId = vineyard, paddockId = blockB, vinesPerHa = 2000.0)
        assertTrue(a.inputsEqual(b))
        assertFalse(a.inputsEqual(b.copy(spursPerVine = 8.0)))
    }

    // ---- Legacy device-local save migrates faithfully ------------------------

    @Test
    fun legacyConversionParity() {
        // Mirrors the iOS legacyConversion test: "Cane" normalises to "cane",
        // comma decimals parse, blank vines/ha becomes null.
        val converted = PruningYieldSettings(
            id = "x",
            vineyardId = vineyard,
            paddockId = blockA,
            pruneMethod = if ("Cane".equals("cane", ignoreCase = true)) "cane" else "spur",
            bunchesPerBud = PruningYieldInputFormat.parse("1,2"),
            budsPerSpur = PruningYieldInputFormat.parse("2"),
            spursPerVine = PruningYieldInputFormat.parse("6"),
            budsPerCane = PruningYieldInputFormat.parse("12"),
            canesPerVine = PruningYieldInputFormat.parse("3"),
            vinesPerHa = PruningYieldInputFormat.parseOptional(""),
            bunchWeightGrams = PruningYieldInputFormat.parse("95"),
        )
        assertEquals("cane", converted.pruneMethod)
        assertEquals(1.2, converted.bunchesPerBud, 0.0)
        assertEquals(12.0, converted.budsPerCane, 0.0)
        assertEquals(3.0, converted.canesPerVine, 0.0)
        assertNull(converted.vinesPerHa)
        assertEquals(95.0, converted.bunchWeightGrams, 0.0)
    }
}
