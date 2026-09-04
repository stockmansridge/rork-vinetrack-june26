package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * Display-only processing for complete trip routes. Persisted source points are
 * never changed and no recent-only window is applied.
 */
object TripPathDisplayProcessor {
    const val DEFAULT_MAX_DISPLAY_POINTS: Int = 500

    /**
     * Selects a bounded, chronological representation of the complete route.
     * Largest Triangle Three Buckets retains representative turns, while the
     * global coordinate extrema are forced into the result so camera bounds
     * cover the complete journey.
     */
    fun displayPoints(
        points: List<CoordinatePoint>,
        maxDisplayPoints: Int = DEFAULT_MAX_DISPLAY_POINTS,
        segmentStartIndices: Set<Int> = emptySet(),
    ): List<CoordinatePoint> {
        if (points.size <= maxDisplayPoints || maxDisplayPoints < 2) return points.toList()

        val mandatory = mutableSetOf(0, points.lastIndex)
        points.indices.minByOrNull { points[it].latitude }?.let(mandatory::add)
        points.indices.maxByOrNull { points[it].latitude }?.let(mandatory::add)
        points.indices.minByOrNull { points[it].longitude }?.let(mandatory::add)
        points.indices.maxByOrNull { points[it].longitude }?.let(mandatory::add)
        segmentStartIndices
            .filter { it > 0 && it < points.size }
            .forEach {
                mandatory += it - 1
                mandatory += it
            }

        if (mandatory.size >= maxDisplayPoints) {
            return evenlySpacedIndices(mandatory.sorted(), maxDisplayPoints).map(points::get)
        }

        val lttbCount = (maxDisplayPoints - mandatory.size + 2).coerceAtLeast(2)
        val selected = mandatory.union(largestTriangleThreeBucketsIndices(points, lttbCount)).toMutableSet()
        if (selected.size > maxDisplayPoints) {
            selected.subtract(mandatory).sortedDescending().forEach { index ->
                if (selected.size > maxDisplayPoints) selected.remove(index)
            }
        }
        return selected.sorted().map(points::get)
    }

    /**
     * Produces separate polylines when known recording restart boundaries are
     * supplied, preventing unrelated route sections from being connected.
     */
    fun displaySegments(
        points: List<CoordinatePoint>,
        maxDisplayPoints: Int = DEFAULT_MAX_DISPLAY_POINTS,
        segmentStartIndices: Set<Int> = emptySet(),
    ): List<List<CoordinatePoint>> {
        val displayed = displayPoints(points, maxDisplayPoints, segmentStartIndices)
        if (displayed.size < 2) return emptyList()
        val boundaries = segmentStartIndices.filter { it > 0 && it < points.size }.sorted()
        if (boundaries.isEmpty()) return listOf(displayed)

        val sourceIndexByPoint = points.withIndex().associate { it.value to it.index }
        val groups = mutableListOf<MutableList<CoordinatePoint>>()
        var current = mutableListOf<CoordinatePoint>()
        var boundaryCursor = 0
        displayed.forEach { point ->
            val sourceIndex = sourceIndexByPoint[point] ?: return@forEach
            while (boundaryCursor < boundaries.size && sourceIndex >= boundaries[boundaryCursor]) {
                if (current.size > 1) groups += current
                current = mutableListOf()
                boundaryCursor++
            }
            current += point
        }
        if (current.size > 1) groups += current
        return groups
    }

    private fun largestTriangleThreeBucketsIndices(
        points: List<CoordinatePoint>,
        threshold: Int,
    ): Set<Int> {
        if (threshold >= points.size || threshold <= 2) return points.indices.toSet()

        val every = (points.size - 2).toDouble() / (threshold - 2).toDouble()
        val selected = mutableSetOf(0)
        var anchorIndex = 0

        repeat(threshold - 2) { bucket ->
            val averageStart = (floor((bucket + 1) * every).toInt() + 1).coerceAtMost(points.size)
            val averageEnd = (floor((bucket + 2) * every).toInt() + 1).coerceAtMost(points.size)
            val safeEnd = averageEnd.coerceAtLeast(averageStart + 1)
            var averageLatitude = 0.0
            var averageLongitude = 0.0
            var averageCount = 0
            for (index in averageStart until safeEnd) {
                val point = points[index.coerceAtMost(points.lastIndex)]
                averageLatitude += point.latitude
                averageLongitude += point.longitude
                averageCount++
            }
            averageLatitude /= averageCount.toDouble()
            averageLongitude /= averageCount.toDouble()

            val rangeStart = (floor(bucket * every).toInt() + 1).coerceAtMost(points.lastIndex)
            val rangeEnd = (floor((bucket + 1) * every).toInt() + 1).coerceAtMost(points.lastIndex)
            val anchor = points[anchorIndex]
            var bestIndex = rangeStart
            var largestArea = -1.0
            for (index in rangeStart until rangeEnd) {
                val candidate = points[index]
                val area = abs(
                    (anchor.longitude - averageLongitude) * (candidate.latitude - anchor.latitude) -
                        (anchor.longitude - candidate.longitude) * (averageLatitude - anchor.latitude),
                )
                if (area > largestArea) {
                    largestArea = area
                    bestIndex = index
                }
            }
            selected += bestIndex
            anchorIndex = bestIndex
        }
        selected += points.lastIndex
        return selected
    }

    private fun evenlySpacedIndices(indices: List<Int>, maxCount: Int): List<Int> {
        if (indices.size <= maxCount) return indices
        if (maxCount <= 1) return listOf(indices.first())
        return List(maxCount) { position ->
            val offset = (position.toDouble() * (indices.size - 1) / (maxCount - 1)).roundToInt()
            indices[offset]
        }
    }
}
