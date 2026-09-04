import CoreLocation
import SwiftUI

/// Lightweight, display-only segment of the travelled trail. The map renders
/// one `MapPolyline` per segment, so the total polyline count stays small.
struct TrailSegment: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
}

/// Diagnostic snapshot of the most recent trail render. Useful for the dev
/// readout / log messages — never persisted, never sent over the network.
struct TrailRenderStats {
    var fullTripPointCount: Int = 0
    var displayPointCount: Int = 0
    var displayPolylineCount: Int = 0
    var lastUpdatedAt: Date?
}

/// Pure display processing for complete recorded trip routes. Source points are
/// never mutated and no recent-only window is used.
enum TrailDisplayProcessor {
    static let palette: [Color] = [
        Color(red: 1.00, green: 0.18, blue: 0.12),
        Color(red: 1.00, green: 0.45, blue: 0.10),
        Color(red: 1.00, green: 0.78, blue: 0.10),
        Color(red: 0.65, green: 0.85, blue: 0.15),
        Color(red: 0.15, green: 0.78, blue: 0.25),
    ]

    /// Produces display-ready segments from the complete route. Largest
    /// Triangle Three Buckets retains representative turns across the full time
    /// range; global coordinate extrema are also forced into the result so map
    /// bounds cover the complete journey. Colour buckets share endpoints, so
    /// the restored trip remains one continuous chronological route.
    static func makeDisplayTrailSegments(
        points: [CoordinatePoint],
        maxDisplayPoints: Int = 500,
        maxColourBuckets: Int = 5
    ) -> [TrailSegment] {
        guard points.count > 1, maxDisplayPoints >= 2 else { return [] }

        let bucketCount = max(1, min(maxColourBuckets, palette.count, points.count / 2))
        let uniquePointCap = max(2, maxDisplayPoints - max(0, bucketCount - 1))
        let sampled = sampledPoints(points, maxCount: uniquePointCap)
        guard sampled.count > 1 else { return [] }

        let perBucket = max(1, Int(ceil(Double(sampled.count - 1) / Double(bucketCount))))
        var segments: [TrailSegment] = []
        var start = 0
        while start < sampled.count - 1 {
            let end = min(sampled.count, start + perBucket + 1)
            let colorIndex = Int(
                Double(segments.count) / Double(max(1, bucketCount - 1))
                    * Double(palette.count - 1)
            )
            segments.append(TrailSegment(
                id: segments.count,
                coordinates: sampled[start..<end].map(\.coordinate),
                color: palette[min(colorIndex, palette.count - 1)]
            ))
            start = end - 1
        }
        return segments
    }

    /// Complete-route display points before visual colour bucketing. Exposed
    /// internally so the rendering contract can be tested without MapKit.
    static func makeDisplayPoints(
        points: [CoordinatePoint],
        maxDisplayPoints: Int = 500
    ) -> [CoordinatePoint] {
        sampledPoints(points, maxCount: maxDisplayPoints)
    }

    private static func sampledPoints(
        _ points: [CoordinatePoint],
        maxCount: Int
    ) -> [CoordinatePoint] {
        guard points.count > maxCount, maxCount >= 2 else {
            return points
        }

        var mandatory: Set<Int> = [0, points.count - 1]
        if let minLatitude = points.indices.min(by: { points[$0].latitude < points[$1].latitude }) {
            mandatory.insert(minLatitude)
        }
        if let maxLatitude = points.indices.max(by: { points[$0].latitude < points[$1].latitude }) {
            mandatory.insert(maxLatitude)
        }
        if let minLongitude = points.indices.min(by: { points[$0].longitude < points[$1].longitude }) {
            mandatory.insert(minLongitude)
        }
        if let maxLongitude = points.indices.max(by: { points[$0].longitude < points[$1].longitude }) {
            mandatory.insert(maxLongitude)
        }
        if mandatory.count >= maxCount {
            return evenlySpacedMandatoryIndices(mandatory.sorted(), maxCount: maxCount)
                .map { points[$0] }
        }

        let lttbCount = max(2, maxCount - mandatory.count + 2)
        let representative = largestTriangleThreeBucketsIndices(points, threshold: lttbCount)
        var selected = mandatory.union(representative)

        if selected.count > maxCount {
            let removable = selected.subtracting(mandatory).sorted()
            for index in removable.reversed() where selected.count > maxCount {
                selected.remove(index)
            }
        }
        return selected.sorted().map { points[$0] }
    }

    private static func largestTriangleThreeBucketsIndices(
        _ points: [CoordinatePoint],
        threshold: Int
    ) -> Set<Int> {
        guard threshold < points.count, threshold > 2 else {
            return Set(points.indices)
        }

        let every = Double(points.count - 2) / Double(threshold - 2)
        var selected: Set<Int> = [0]
        var anchorIndex = 0

        for bucket in 0..<(threshold - 2) {
            let averageStart = min(points.count, Int(floor(Double(bucket + 1) * every)) + 1)
            let averageEnd = min(points.count, Int(floor(Double(bucket + 2) * every)) + 1)
            let averageRange = averageStart..<max(averageStart + 1, averageEnd)
            let averageCount = Double(averageRange.count)
            let averageLatitude = averageRange.reduce(0.0) { $0 + points[min($1, points.count - 1)].latitude } / averageCount
            let averageLongitude = averageRange.reduce(0.0) { $0 + points[min($1, points.count - 1)].longitude } / averageCount

            let rangeStart = min(points.count - 1, Int(floor(Double(bucket) * every)) + 1)
            let rangeEnd = min(points.count - 1, Int(floor(Double(bucket + 1) * every)) + 1)
            let anchor = points[anchorIndex]
            var bestIndex = rangeStart
            var largestArea = -1.0

            if rangeStart < rangeEnd {
                for index in rangeStart..<rangeEnd {
                    let candidate = points[index]
                    let area = abs(
                        (anchor.longitude - averageLongitude) * (candidate.latitude - anchor.latitude)
                            - (anchor.longitude - candidate.longitude) * (averageLatitude - anchor.latitude)
                    )
                    if area > largestArea {
                        largestArea = area
                        bestIndex = index
                    }
                }
            }
            selected.insert(bestIndex)
            anchorIndex = bestIndex
        }
        selected.insert(points.count - 1)
        return selected
    }

    private static func evenlySpacedMandatoryIndices(
        _ indices: [Int],
        maxCount: Int
    ) -> [Int] {
        guard indices.count > maxCount else { return indices }
        guard maxCount > 1 else { return [indices[0]] }
        return (0..<maxCount).map { position in
            let offset = Int(round(Double(position) * Double(indices.count - 1) / Double(maxCount - 1)))
            return indices[offset]
        }
    }
}
