import CoreLocation

struct RowLine {
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
}

func calculateRowLines(
    polygonCoords: [CLLocationCoordinate2D],
    direction: Double,
    count: Int,
    width: Double,
    offset: Double = 0
) -> [RowLine] {
    guard polygonCoords.count >= 3, count > 0, width > 0 else { return [] }

    let centroidLat: Double = polygonCoords.map(\.latitude).reduce(0, +) / Double(polygonCoords.count)
    let centroidLon: Double = polygonCoords.map(\.longitude).reduce(0, +) / Double(polygonCoords.count)

    let bearingRad: Double = direction * .pi / 180.0
    let perpRad: Double = bearingRad + .pi / 2.0

    let mPerDegLat: Double = 111_320.0
    let mPerDegLon: Double = 111_320.0 * cos(centroidLat * .pi / 180.0)

    var maxDist: Double = 0
    for i in 0..<polygonCoords.count {
        for j in (i + 1)..<polygonCoords.count {
            let dLat: Double = (polygonCoords[i].latitude - polygonCoords[j].latitude) * mPerDegLat
            let dLon: Double = (polygonCoords[i].longitude - polygonCoords[j].longitude) * mPerDegLon
            maxDist = max(maxDist, sqrt(dLat * dLat + dLon * dLon))
        }
    }
    let halfLen: Double = maxDist * 1.5

    let totalW: Double = Double(count - 1) * width
    let startOff: Double = -totalW / 2.0

    var result: [RowLine] = []
    for i in 0..<count {
        let off: Double = startOff + Double(i) * width + offset
        let cLat: Double = centroidLat + off * cos(perpRad) / mPerDegLat
        let cLon: Double = centroidLon + off * sin(perpRad) / mPerDegLon

        let dLat: Double = halfLen * cos(bearingRad) / mPerDegLat
        let dLon: Double = halfLen * sin(bearingRad) / mPerDegLon

        let s = CLLocationCoordinate2D(latitude: cLat - dLat, longitude: cLon - dLon)
        let e = CLLocationCoordinate2D(latitude: cLat + dLat, longitude: cLon + dLon)

        if let clipped = clipLineToPolygon(start: s, end: e, polygon: polygonCoords) {
            result.append(clipped)
        }
    }
    return result
}

private func clipLineToPolygon(
    start: CLLocationCoordinate2D,
    end: CLLocationCoordinate2D,
    polygon: [CLLocationCoordinate2D]
) -> RowLine? {
    var pts: [CLLocationCoordinate2D] = []
    let n: Int = polygon.count
    for i in 0..<n {
        let j: Int = (i + 1) % n
        if let pt = segmentIntersection(a1: start, a2: end, b1: polygon[i], b2: polygon[j]) {
            pts.append(pt)
        }
    }
    guard pts.count >= 2 else { return nil }
    let dx: Double = end.latitude - start.latitude
    let dy: Double = end.longitude - start.longitude
    let useDx: Bool = abs(dx) > 1e-14
    let sorted = pts.sorted { a, b in
        let tA: Double = useDx ? (a.latitude - start.latitude) / dx : (a.longitude - start.longitude) / dy
        let tB: Double = useDx ? (b.latitude - start.latitude) / dx : (b.longitude - start.longitude) / dy
        return tA < tB
    }
    return RowLine(start: sorted[0], end: sorted[sorted.count - 1])
}

private func segmentIntersection(
    a1: CLLocationCoordinate2D, a2: CLLocationCoordinate2D,
    b1: CLLocationCoordinate2D, b2: CLLocationCoordinate2D
) -> CLLocationCoordinate2D? {
    let d1x: Double = a2.latitude - a1.latitude
    let d1y: Double = a2.longitude - a1.longitude
    let d2x: Double = b2.latitude - b1.latitude
    let d2y: Double = b2.longitude - b1.longitude
    let cross: Double = d1x * d2y - d1y * d2x
    guard abs(cross) > 1e-14 else { return nil }
    let dx: Double = b1.latitude - a1.latitude
    let dy: Double = b1.longitude - a1.longitude
    let t: Double = (dx * d2y - dy * d2x) / cross
    let u: Double = (dx * d1y - dy * d1x) / cross
    guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
    return CLLocationCoordinate2D(latitude: a1.latitude + t * d1x, longitude: a1.longitude + t * d1y)
}
