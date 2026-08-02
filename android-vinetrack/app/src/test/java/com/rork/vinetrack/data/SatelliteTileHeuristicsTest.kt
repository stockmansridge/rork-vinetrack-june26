package com.rork.vinetrack.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * The grey block-setup map came from Esri answering HTTP 200 with a flat
 * "Map data not yet available" placeholder past the local level of detail.
 * These tests pin the detection that makes the provider fall back to a lower
 * zoom and upscale real imagery instead of painting the placeholder.
 */
class SatelliteTileHeuristicsTest {

    private fun rgb(r: Int, g: Int, b: Int): Int =
        (0xFF shl 24) or (r shl 16) or (g shl 8) or b

    private fun tile(size: Int = 256, pixel: (Int) -> Int): IntArray =
        IntArray(size) { pixel(it) }

    @Test
    fun flatLightGreyPlaceholder_isDetected() {
        val pixels = tile { rgb(235, 235, 235) }
        assertTrue(SatelliteTileHeuristics.isUnavailableTile(pixels))
    }

    @Test
    fun placeholderWithDarkGreyText_isStillDetected() {
        // ~8 % of the tile is the dark neutral "Map data not yet available" text.
        val pixels = tile { index -> if (index % 12 == 0) rgb(120, 120, 120) else rgb(233, 233, 233) }
        assertTrue(SatelliteTileHeuristics.isUnavailableTile(pixels))
    }

    @Test
    fun vineyardImagery_isNeverMistakenForThePlaceholder() {
        val random = Random(7)
        val pixels = tile { rgb(70 + random.nextInt(40), 95 + random.nextInt(50), 55 + random.nextInt(30)) }
        assertFalse(SatelliteTileHeuristics.isUnavailableTile(pixels))
    }

    @Test
    fun barePaleSoil_isNotThePlaceholder() {
        // Light but colour-cast (red/yellow) — real imagery, must be kept.
        val random = Random(11)
        val pixels = tile { rgb(215 + random.nextInt(20), 200 + random.nextInt(20), 170 + random.nextInt(20)) }
        assertFalse(SatelliteTileHeuristics.isUnavailableTile(pixels))
    }

    @Test
    fun darkNeutralImagery_isNotThePlaceholder() {
        // Deep shadow: neutral but nowhere near light — must be kept.
        val pixels = tile { rgb(30, 32, 31) }
        assertFalse(SatelliteTileHeuristics.isUnavailableTile(pixels))
    }

    @Test
    fun tooFewSamples_neverReportsUnavailable() {
        assertFalse(SatelliteTileHeuristics.isUnavailableTile(IntArray(0)))
        assertFalse(SatelliteTileHeuristics.isUnavailableTile(IntArray(4) { rgb(235, 235, 235) }))
    }
}
