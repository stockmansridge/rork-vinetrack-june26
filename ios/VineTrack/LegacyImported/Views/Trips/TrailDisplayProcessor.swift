import Foundation
import CoreLocation
import SwiftUI

/// Lightweight, display-only segment of the travelled trail. The map renders
/// one `MapPolyline` per segment, so the total polyline count on screen equals
/// the number of segments produced here (capped at 3–5).
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

/// Pure functions that turn the full recorded trip points into a tiny set of
/// coloured polylines suitable for live SwiftUI/MapKit rendering. Persisted
/// `trip.pathPoints` are never mutated — the downsample/bucket only affects
/// what is drawn.
enum TrailDisplayProcessor {

    /// Bucket palette (oldest → newest). Five fixed steps so we always render
    /// at most five `MapPolyline` overlays regardless of trip length.
    static let palette: [Color] = [
        Color(red: 1.00, green: 0.18, blue: 0.12),  // red — oldest
        Color(red: 1.00, green: 0.45, blue: 0.10),  // orange
        Color(red: 1.00, green: 0.78, blue: 0.10),  // amber/yellow
        Color(red: 0.65, green: 0.85, blue: 0.15),  // yellow-green
        Color(red: 0.15, green: 0.78, blue: 0.25),  // green — newest
    ]

    /// Produce display-ready trail segments.
    ///
    /// - Parameters:
    ///   - points: full recorded trip points (untouched).
    ///   - maxDisplayPoints: hard cap on points rendered (default 500).
    ///   - maxColourBuckets: number of polylines / colour buckets (3–5).
    /// - Returns: between 0 and `maxColourBuckets` `TrailSegment`s.
    static func makeDisplayTrailSegments(
        points: [CoordinatePoint],
        maxDisplayPoints: Int = 500,
        maxColourBuckets: Int = 5
    ) -> [TrailSegment] {
        guard points.count > 1 else { return [] }

        let buckets = max(3, min(maxColourBuckets, palette.count))

        // 1. Take the latest window so the live tractor position stays accurate.
        let recent = points.suffix(maxDisplayPoints * 4) // headroom before downsample

        // 2. Downsample to ≤ maxDisplayPoints by stride. Always preserve the
        //    last point so the trail end matches the current GPS fix.
        let coords: [CLLocationCoordinate2D]
        if recent.count <= maxDisplayPoints {
            coords = recent.map { $0.coordinate }
        } else {
            let stride = max(1, recent.count / maxDisplayPoints)
            var sampled: [CLLocationCoordinate2D] = []
            sampled.reserveCapacity(maxDisplayPoints + 2)
            var i = 0
            let arr = Array(recent)
            while i < arr.count {
                sampled.append(arr[i].coordinate)
                i += stride
            }
            if let last = arr.last?.coordinate,
               sampled.last?.latitude != last.latitude
                || sampled.last?.longitude != last.longitude {
                sampled.append(last)
            }
            coords = sampled
        }

        let n = coords.count
        guard n > 1 else { return [] }

        // 3. Slice into N contiguous buckets, oldest → newest. Overlap by one
        //    point so adjacent polylines join visually with no gap.
        var segments: [TrailSegment] = []
        segments.reserveCapacity(buckets)

        let perBucket = max(1, Int((Double(n) / Double(buckets)).rounded(.up)))
        var idx = 0
        for b in 0..<buckets {
            let start = max(0, idx - (b == 0 ? 0 : 1))
            let end = min(idx + perBucket, n)
            if end <= start { break }
            let slice = Array(coords[start..<end])
            if slice.count >= 2 {
                let colorIndex = Int(Double(b) / Double(max(1, buckets - 1))
                                     * Double(palette.count - 1))
                segments.append(
                    TrailSegment(
                        id: b,
                        coordinates: slice,
                        color: palette[min(colorIndex, palette.count - 1)]
                    )
                )
            }
            idx = end
            if idx >= n { break }
        }

        return segments
    }
}
