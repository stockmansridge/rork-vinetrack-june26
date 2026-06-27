import Foundation
import CoreLocation

@Observable
@MainActor
class YieldEstimationViewModel {
    var selectedPaddockIds: Set<UUID> = []
    var sampleSites: [SampleSite] = []
    var isGenerated: Bool = false
    var pathWaypoints: [CoordinatePoint] = []
    var isPathGenerated: Bool = false
    var blockBunchWeightsKg: [UUID: Double] = [:]
    var previousBunchWeights: [BunchWeightRecord] = []
    var selectedSite: SampleSite?
    var sessionId: UUID?
    var isCompleted: Bool = false
    var completedAt: Date?

    func togglePaddock(_ paddockId: UUID) {
        if selectedPaddockIds.contains(paddockId) {
            selectedPaddockIds.remove(paddockId)
        } else {
            selectedPaddockIds.insert(paddockId)
        }
        sampleSites = []
        isGenerated = false
        pathWaypoints = []
        isPathGenerated = false
    }

    func selectAll(paddocks: [Paddock]) {
        selectedPaddockIds = Set(paddocks.map(\.id))
        sampleSites = []
        isGenerated = false
        pathWaypoints = []
        isPathGenerated = false
    }

    func deselectAll() {
        selectedPaddockIds.removeAll()
        sampleSites = []
        isGenerated = false
        pathWaypoints = []
        isPathGenerated = false
    }

    func generateSampleSites(paddocks: [Paddock], samplesPerHectare: Int) {
        var allSites: [SampleSite] = []
        var globalIndex = 1

        let selected = paddocks.filter { selectedPaddockIds.contains($0.id) }

        for paddock in selected {
            let area = paddock.areaHectares
            guard area > 0 else { continue }

            let totalSamples = max(1, Int(round(Double(samplesPerHectare) * area)))

            let sites = generateSitesOnRows(
                paddock: paddock,
                totalSamples: totalSamples,
                startIndex: globalIndex
            )

            allSites.append(contentsOf: sites)
            globalIndex += sites.count
        }

        sampleSites = allSites
        isGenerated = true
        pathWaypoints = []
        isPathGenerated = false
        sessionId = UUID()
    }

    func recordBunchCount(siteId: UUID, bunchesPerVine: Double, recordedBy: String) {
        guard let index = sampleSites.firstIndex(where: { $0.id == siteId }) else { return }
        sampleSites[index].bunchCountEntry = BunchCountEntry(
            bunchesPerVine: bunchesPerVine,
            recordedAt: Date(),
            recordedBy: recordedBy
        )
    }

    func generatePath(paddocks: [Paddock]) {
        guard !sampleSites.isEmpty else { return }

        let selected = paddocks.filter { selectedPaddockIds.contains($0.id) }
        var waypoints: [CoordinatePoint] = []

        for paddock in selected {
            let sitesInPaddock = sampleSites.filter { $0.paddockId == paddock.id }
            guard !sitesInPaddock.isEmpty else { continue }

            let lanes = computeMidlineLanes(paddock: paddock)
            guard !lanes.isEmpty else { continue }

            for (laneIdx, lane) in lanes.enumerated() {
                let isReversed = laneIdx % 2 == 1
                let entry = isReversed ? lane.end : lane.start
                let exit = isReversed ? lane.start : lane.end
                waypoints.append(entry)
                waypoints.append(exit)
            }
        }

        pathWaypoints = waypoints
        isPathGenerated = true
    }

    private struct MidlineLane {
        let start: CoordinatePoint
        let end: CoordinatePoint
    }

    private func computeMidlineLanes(paddock: Paddock) -> [MidlineLane] {
        let polygon = paddock.polygonPoints
        guard !paddock.rows.isEmpty, polygon.count >= 3 else { return [] }

        let mPerDegLat = 111_320.0
        let centroidLat = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count)
        let centroidLon = polygon.map(\.longitude).reduce(0, +) / Double(polygon.count)
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        let rowAngleRad = paddock.rowDirection * .pi / 180.0

        let sortedRows = paddock.rows.sorted { a, b in
            let cAx = ((a.startPoint.longitude + a.endPoint.longitude) / 2 - centroidLon) * mPerDegLon
            let cAy = ((a.startPoint.latitude + a.endPoint.latitude) / 2 - centroidLat) * mPerDegLat
            let cBx = ((b.startPoint.longitude + b.endPoint.longitude) / 2 - centroidLon) * mPerDegLon
            let cBy = ((b.startPoint.latitude + b.endPoint.latitude) / 2 - centroidLat) * mPerDegLat
            let projA = cAx * cos(rowAngleRad) - cAy * sin(rowAngleRad)
            let projB = cBx * cos(rowAngleRad) - cBy * sin(rowAngleRad)
            return projA < projB
        }

        func orientRow(_ row: PaddockRow) -> (start: CoordinatePoint, end: CoordinatePoint) {
            let sx = (row.startPoint.longitude - centroidLon) * mPerDegLon
            let sy = (row.startPoint.latitude - centroidLat) * mPerDegLat
            let ex = (row.endPoint.longitude - centroidLon) * mPerDegLon
            let ey = (row.endPoint.latitude - centroidLat) * mPerDegLat
            let projS = sx * sin(rowAngleRad) + sy * cos(rowAngleRad)
            let projE = ex * sin(rowAngleRad) + ey * cos(rowAngleRad)
            if projS <= projE { return (row.startPoint, row.endPoint) }
            return (row.endPoint, row.startPoint)
        }

        var rowPairs: [[PaddockRow]] = []
        var i = 0
        while i < sortedRows.count {
            if i + 1 < sortedRows.count {
                rowPairs.append([sortedRows[i], sortedRows[i + 1]])
                i += 2
            } else {
                rowPairs.append([sortedRows[i]])
                i += 1
            }
        }

        var lanes: [MidlineLane] = []
        for pair in rowPairs {
            let rawStart: CoordinatePoint
            let rawEnd: CoordinatePoint
            if pair.count == 2 {
                let (s1, e1) = orientRow(pair[0])
                let (s2, e2) = orientRow(pair[1])
                rawStart = CoordinatePoint(
                    latitude: (s1.latitude + s2.latitude) / 2,
                    longitude: (s1.longitude + s2.longitude) / 2
                )
                rawEnd = CoordinatePoint(
                    latitude: (e1.latitude + e2.latitude) / 2,
                    longitude: (e1.longitude + e2.longitude) / 2
                )
            } else {
                let (s, e) = orientRow(pair[0])
                rawStart = s
                rawEnd = e
            }

            let extDirLat = rawEnd.latitude - rawStart.latitude
            let extDirLon = rawEnd.longitude - rawStart.longitude
            let extLen = sqrt(extDirLat * extDirLat * mPerDegLat * mPerDegLat + extDirLon * extDirLon * mPerDegLon * mPerDegLon)
            let extFactor: Double = extLen > 0 ? 500.0 / extLen : 0
            let extStart = CoordinatePoint(
                latitude: rawStart.latitude - extDirLat * extFactor,
                longitude: rawStart.longitude - extDirLon * extFactor
            )
            let extEnd = CoordinatePoint(
                latitude: rawEnd.latitude + extDirLat * extFactor,
                longitude: rawEnd.longitude + extDirLon * extFactor
            )
            let clipped = clipMidlineToPolygon(start: extStart, end: extEnd, polygon: polygon)
            if let c = clipped {
                lanes.append(MidlineLane(start: c.start, end: c.end))
            } else {
                lanes.append(MidlineLane(start: rawStart, end: rawEnd))
            }
        }

        return lanes
    }

    private func clipMidlineToPolygon(start: CoordinatePoint, end: CoordinatePoint, polygon: [CoordinatePoint]) -> (start: CoordinatePoint, end: CoordinatePoint)? {
        let ax = start.longitude
        let ay = start.latitude
        let bx = end.longitude
        let by = end.latitude
        let dx = bx - ax
        let dy = by - ay

        var tValues: [Double] = []

        let n = polygon.count
        for i in 0..<n {
            let j = (i + 1) % n
            let cx = polygon[i].longitude
            let cy = polygon[i].latitude
            let ex = polygon[j].longitude - cx
            let ey = polygon[j].latitude - cy

            let denom = dx * ey - dy * ex
            guard abs(denom) > 1e-15 else { continue }

            let t = ((cx - ax) * ey - (cy - ay) * ex) / denom
            let u = ((cx - ax) * dy - (cy - ay) * dx) / denom

            if u >= 0 && u <= 1 && t > -0.001 && t < 1.001 {
                tValues.append(min(max(t, 0), 1))
            }
        }

        if pointInPolygon(lat: ay, lon: ax, polygon: polygon) {
            tValues.append(0.0)
        }
        if pointInPolygon(lat: by, lon: bx, polygon: polygon) {
            tValues.append(1.0)
        }

        guard tValues.count >= 2 else { return nil }
        tValues.sort()

        let t0 = tValues.first!
        let t1 = tValues.last!
        guard t1 - t0 > 1e-10 else { return nil }

        let clippedStart = CoordinatePoint(
            latitude: ay + t0 * dy,
            longitude: ax + t0 * dx
        )
        let clippedEnd = CoordinatePoint(
            latitude: ay + t1 * dy,
            longitude: ax + t1 * dx
        )
        return (clippedStart, clippedEnd)
    }

    private func sortRowsPerpendicular(rows: [PaddockRow], paddock: Paddock) -> [PaddockRow] {
        let polygon = paddock.polygonPoints
        guard !polygon.isEmpty else { return rows }
        let mPerDegLat = 111_320.0
        let centroidLat = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count)
        let centroidLon = polygon.map(\.longitude).reduce(0, +) / Double(polygon.count)
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        let rowAngleRad = paddock.rowDirection * .pi / 180.0

        return rows.sorted { a, b in
            let cAx = ((a.startPoint.longitude + a.endPoint.longitude) / 2 - centroidLon) * mPerDegLon
            let cAy = ((a.startPoint.latitude + a.endPoint.latitude) / 2 - centroidLat) * mPerDegLat
            let cBx = ((b.startPoint.longitude + b.endPoint.longitude) / 2 - centroidLon) * mPerDegLon
            let cBy = ((b.startPoint.latitude + b.endPoint.latitude) / 2 - centroidLat) * mPerDegLat
            let projA = cAx * cos(rowAngleRad) - cAy * sin(rowAngleRad)
            let projB = cBx * cos(rowAngleRad) - cBy * sin(rowAngleRad)
            return projA < projB
        }
    }

    // MARK: - Yield Calculation

    func calculateYieldEstimates(paddocks: [Paddock], damageFactorProvider: ((UUID) -> Double)? = nil) -> [BlockYieldEstimate] {
        let selected = paddocks.filter { selectedPaddockIds.contains($0.id) }
        var estimates: [BlockYieldEstimate] = []

        for paddock in selected {
            let sitesInPaddock = sampleSites.filter { $0.paddockId == paddock.id }
            let recordedSites = sitesInPaddock.filter { $0.isRecorded }
            let damageFactor = damageFactorProvider?(paddock.id) ?? 1.0

            guard !recordedSites.isEmpty else {
                estimates.append(BlockYieldEstimate(
                    paddockId: paddock.id,
                    paddockName: paddock.name,
                    areaHectares: paddock.areaHectares,
                    totalVines: paddock.effectiveVineCount,
                    averageBunchesPerVine: 0,
                    totalBunches: 0,
                    averageBunchWeightKg: bunchWeightKg(for: paddock.id),
                    damageFactor: damageFactor,
                    estimatedYieldKg: 0,
                    estimatedYieldTonnes: 0,
                    samplesRecorded: 0,
                    samplesTotal: sitesInPaddock.count,
                    damageRecords: []
                ))
                continue
            }

            let avgBunches = recordedSites.reduce(0.0) { $0 + ($1.bunchCountEntry?.bunchesPerVine ?? 0) } / Double(recordedSites.count)
            let avgBunchesRounded = (avgBunches * 100).rounded() / 100

            let totalVines = paddock.effectiveVineCount
            let totalBunches = Double(totalVines) * avgBunchesRounded
            let blockWeight = bunchWeightKg(for: paddock.id)
            let yieldKg = totalBunches * blockWeight * damageFactor
            let yieldTonnes = yieldKg / 1000.0

            estimates.append(BlockYieldEstimate(
                paddockId: paddock.id,
                paddockName: paddock.name,
                areaHectares: paddock.areaHectares,
                totalVines: totalVines,
                averageBunchesPerVine: avgBunchesRounded,
                totalBunches: totalBunches,
                averageBunchWeightKg: blockWeight,
                damageFactor: damageFactor,
                estimatedYieldKg: yieldKg,
                estimatedYieldTonnes: yieldTonnes,
                samplesRecorded: recordedSites.count,
                samplesTotal: sitesInPaddock.count,
                damageRecords: []
            ))
        }

        return estimates
    }

    var recordedSiteCount: Int {
        sampleSites.filter { $0.isRecorded }.count
    }

    var totalSiteCount: Int {
        sampleSites.count
    }

    func loadSession(_ session: YieldEstimationSession) {
        sessionId = session.id
        selectedPaddockIds = Set(session.selectedPaddockIds)
        sampleSites = session.sampleSites
        isGenerated = !session.sampleSites.isEmpty
        pathWaypoints = session.pathWaypoints
        isPathGenerated = !session.pathWaypoints.isEmpty
        blockBunchWeightsKg = session.blockBunchWeightsKg
        previousBunchWeights = session.previousBunchWeights
        isCompleted = session.isCompleted
        completedAt = session.completedAt
    }

    func toSession(vineyardId: UUID, samplesPerHectare: Int) -> YieldEstimationSession {
        YieldEstimationSession(
            id: sessionId ?? UUID(),
            vineyardId: vineyardId,
            selectedPaddockIds: Array(selectedPaddockIds),
            samplesPerHectare: samplesPerHectare,
            sampleSites: sampleSites,
            blockBunchWeightsKg: blockBunchWeightsKg,
            previousBunchWeights: previousBunchWeights,
            pathWaypoints: pathWaypoints,
            isCompleted: isCompleted,
            completedAt: completedAt
        )
    }

    func markCompleted() {
        isCompleted = true
        completedAt = Date()
    }

    func resetForNewEstimation() {
        sessionId = nil
        selectedPaddockIds.removeAll()
        sampleSites = []
        isGenerated = false
        pathWaypoints = []
        isPathGenerated = false
        blockBunchWeightsKg = [:]
        selectedSite = nil
        isCompleted = false
        completedAt = nil
    }

    // MARK: - Sample Generation

    func bunchWeightKg(for paddockId: UUID) -> Double {
        blockBunchWeightsKg[paddockId] ?? 0.15
    }

    func setBunchWeight(_ weightKg: Double, for paddockId: UUID) {
        blockBunchWeightsKg[paddockId] = weightKg
    }

    var totalSelectedArea: Double { 0 }

    func totalSelectedArea(paddocks: [Paddock]) -> Double {
        paddocks
            .filter { selectedPaddockIds.contains($0.id) }
            .reduce(0) { $0 + $1.areaHectares }
    }

    func expectedSampleCount(paddocks: [Paddock], samplesPerHectare: Int) -> Int {
        paddocks
            .filter { selectedPaddockIds.contains($0.id) }
            .reduce(0) { total, paddock in
                total + max(1, Int(round(Double(samplesPerHectare) * paddock.areaHectares)))
            }
    }

    private func generateSitesOnRows(paddock: Paddock, totalSamples: Int, startIndex: Int) -> [SampleSite] {
        let rows = paddock.rows
        let polygon = paddock.polygonPoints
        guard !rows.isEmpty, polygon.count >= 3 else { return [] }

        let mPerDegLat = 111_320.0
        let centroidLat = polygon.map(\.latitude).reduce(0, +) / Double(polygon.count)
        let centroidLon = polygon.map(\.longitude).reduce(0, +) / Double(polygon.count)
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        let rowAngleRad = paddock.rowDirection * .pi / 180.0

        struct ClippedSegment {
            let row: PaddockRow
            let startLat: Double
            let startLon: Double
            let endLat: Double
            let endLon: Double
            let length: Double
        }

        var segmentsByRow: [Int: [ClippedSegment]] = [:]

        for row in rows {
            let segments = clipRowToPolygon(row: row, polygon: polygon)
            for seg in segments {
                let dLat = (seg.endLat - seg.startLat) * mPerDegLat
                let dLon = (seg.endLon - seg.startLon) * mPerDegLon
                let length = sqrt(dLat * dLat + dLon * dLon)
                guard length > 0.5 else { continue }
                segmentsByRow[row.number, default: []].append(ClippedSegment(
                    row: row,
                    startLat: seg.startLat, startLon: seg.startLon,
                    endLat: seg.endLat, endLon: seg.endLon,
                    length: length
                ))
            }
        }

        guard !segmentsByRow.isEmpty else { return [] }

        let sortedRowNumbers = segmentsByRow.keys.sorted { a, b in
            let rowA = rows.first { $0.number == a }
            let rowB = rows.first { $0.number == b }
            guard let rA = rowA, let rB = rowB else { return a < b }
            let cAx = ((rA.startPoint.longitude + rA.endPoint.longitude) / 2 - centroidLon) * mPerDegLon
            let cAy = ((rA.startPoint.latitude + rA.endPoint.latitude) / 2 - centroidLat) * mPerDegLat
            let cBx = ((rB.startPoint.longitude + rB.endPoint.longitude) / 2 - centroidLon) * mPerDegLon
            let cBy = ((rB.startPoint.latitude + rB.endPoint.latitude) / 2 - centroidLat) * mPerDegLat
            let projA = cAx * cos(rowAngleRad) - cAy * sin(rowAngleRad)
            let projB = cBx * cos(rowAngleRad) - cBy * sin(rowAngleRad)
            return projA < projB
        }

        var rowPairs: [[Int]] = []
        var ri = 0
        while ri < sortedRowNumbers.count {
            if ri + 1 < sortedRowNumbers.count {
                rowPairs.append([sortedRowNumbers[ri], sortedRowNumbers[ri + 1]])
                ri += 2
            } else {
                rowPairs.append([sortedRowNumbers[ri]])
                ri += 1
            }
        }

        func orientSegment(_ seg: ClippedSegment) -> ClippedSegment {
            let sx = (seg.startLon - centroidLon) * mPerDegLon
            let sy = (seg.startLat - centroidLat) * mPerDegLat
            let ex = (seg.endLon - centroidLon) * mPerDegLon
            let ey = (seg.endLat - centroidLat) * mPerDegLat
            let projS = sx * sin(rowAngleRad) + sy * cos(rowAngleRad)
            let projE = ex * sin(rowAngleRad) + ey * cos(rowAngleRad)
            if projS <= projE { return seg }
            return ClippedSegment(row: seg.row, startLat: seg.endLat, startLon: seg.endLon,
                                 endLat: seg.startLat, endLon: seg.startLon, length: seg.length)
        }

        func flipSegment(_ seg: ClippedSegment) -> ClippedSegment {
            ClippedSegment(row: seg.row, startLat: seg.endLat, startLon: seg.endLon,
                          endLat: seg.startLat, endLon: seg.startLon, length: seg.length)
        }

        var orderedSegments: [ClippedSegment] = []

        for (pairIdx, pair) in rowPairs.enumerated() {
            var pairSegs: [ClippedSegment] = []
            for rowNum in pair {
                if let segs = segmentsByRow[rowNum] {
                    pairSegs.append(contentsOf: segs.map(orientSegment))
                }
            }

            pairSegs.sort { a, b in
                let aProj = ((a.startLon + a.endLon) / 2 - centroidLon) * mPerDegLon * sin(rowAngleRad)
                    + ((a.startLat + a.endLat) / 2 - centroidLat) * mPerDegLat * cos(rowAngleRad)
                let bProj = ((b.startLon + b.endLon) / 2 - centroidLon) * mPerDegLon * sin(rowAngleRad)
                    + ((b.startLat + b.endLat) / 2 - centroidLat) * mPerDegLat * cos(rowAngleRad)
                return aProj < bProj
            }

            if pairIdx % 2 == 1 {
                pairSegs.reverse()
                pairSegs = pairSegs.map(flipSegment)
            }

            orderedSegments.append(contentsOf: pairSegs)
        }

        guard !orderedSegments.isEmpty else { return [] }

        let totalLength = orderedSegments.reduce(0.0) { $0 + $1.length }
        guard totalLength > 0 else { return [] }

        let spacingMetres = totalLength / Double(totalSamples + 1)
        let jitterRange = spacingMetres * 0.4
        var rng = SystemRandomNumberGenerator()

        func jitteredStep() -> Double {
            let offset = Double.random(in: -jitterRange...jitterRange, using: &rng)
            return max(spacingMetres * 0.25, spacingMetres + offset)
        }

        var sites: [SampleSite] = []
        var accumulatedDistance: Double = 0
        var nextSiteDistance = Double.random(in: (spacingMetres * 0.5)...(spacingMetres * 1.5), using: &rng)
        var siteIndex = startIndex

        for seg in orderedSegments {
            let segStartDist = accumulatedDistance
            let segEndDist = accumulatedDistance + seg.length

            while nextSiteDistance <= segEndDist && sites.count < totalSamples {
                let distAlong = nextSiteDistance - segStartDist
                let fraction = distAlong / seg.length

                let lat = seg.startLat + fraction * (seg.endLat - seg.startLat)
                let lon = seg.startLon + fraction * (seg.endLon - seg.startLon)

                sites.append(SampleSite(
                    paddockId: paddock.id,
                    paddockName: paddock.name,
                    rowNumber: seg.row.number,
                    latitude: lat,
                    longitude: lon,
                    siteIndex: siteIndex
                ))
                siteIndex += 1
                nextSiteDistance += jitteredStep()
            }

            accumulatedDistance = segEndDist
        }

        if sites.count < totalSamples {
            let remaining = totalSamples - sites.count
            let segCount = orderedSegments.count
            for i in 0..<remaining {
                let seg = orderedSegments[i % segCount]
                let fraction = Double(i + 1) / Double(remaining + 1)
                let lat = seg.startLat + fraction * (seg.endLat - seg.startLat)
                let lon = seg.startLon + fraction * (seg.endLon - seg.startLon)

                sites.append(SampleSite(
                    paddockId: paddock.id,
                    paddockName: paddock.name,
                    rowNumber: seg.row.number,
                    latitude: lat,
                    longitude: lon,
                    siteIndex: siteIndex
                ))
                siteIndex += 1
            }
        }

        return sites
    }

    private struct RowSegment {
        let startLat: Double
        let startLon: Double
        let endLat: Double
        let endLon: Double
    }

    private func clipRowToPolygon(row: PaddockRow, polygon: [CoordinatePoint]) -> [RowSegment] {
        let ax = row.startPoint.longitude
        let ay = row.startPoint.latitude
        let bx = row.endPoint.longitude
        let by = row.endPoint.latitude
        let dx = bx - ax
        let dy = by - ay

        var tValues: [Double] = [0.0, 1.0]

        let n = polygon.count
        for i in 0..<n {
            let j = (i + 1) % n
            let cx = polygon[i].longitude
            let cy = polygon[i].latitude
            let ex = polygon[j].longitude - cx
            let ey = polygon[j].latitude - cy

            let denom = dx * ey - dy * ex
            guard abs(denom) > 1e-15 else { continue }

            let t = ((cx - ax) * ey - (cy - ay) * ex) / denom
            let u = ((cx - ax) * dy - (cy - ay) * dx) / denom

            if u >= 0 && u <= 1 && t > -0.001 && t < 1.001 {
                tValues.append(min(max(t, 0), 1))
            }
        }

        tValues.sort()

        var segments: [RowSegment] = []
        for i in 0..<(tValues.count - 1) {
            let t0 = tValues[i]
            let t1 = tValues[i + 1]
            guard t1 - t0 > 1e-10 else { continue }

            let midT = (t0 + t1) / 2.0
            let midLat = ay + midT * dy
            let midLon = ax + midT * dx

            if pointInPolygon(lat: midLat, lon: midLon, polygon: polygon) {
                segments.append(RowSegment(
                    startLat: ay + t0 * dy, startLon: ax + t0 * dx,
                    endLat: ay + t1 * dy, endLon: ax + t1 * dx
                ))
            }
        }

        return segments
    }

    private func pointInPolygon(lat: Double, lon: Double, polygon: [CoordinatePoint]) -> Bool {
        let n = polygon.count
        guard n >= 3 else { return false }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let yi = polygon[i].latitude
            let xi = polygon[i].longitude
            let yj = polygon[j].latitude
            let xj = polygon[j].longitude

            if ((yi > lat) != (yj > lat)) &&
                (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
