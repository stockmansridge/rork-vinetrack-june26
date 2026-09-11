import Foundation
import CoreLocation

/// Observation-backed aisle identity used by automatic pin capture outside trips.
/// Coordinates are never averaged: history establishes only the mapped aisle,
/// while the current accepted fix remains the capture and snap source.
nonisolated enum PinAisleObservationLock {
    static let maximumObservationCount: Int = 16
    static let maximumObservationAge: TimeInterval = 20
    static let supportingObservationCount: Int = 3
    static let contradictoryObservationCount: Int = 3

    struct Evidence: Sendable, Equatable {
        let observedAt: Date
        let paddockId: UUID?
        let aisleNumber: Double?
        let isQualified: Bool
    }

    struct Lock: Sendable, Equatable {
        let paddockId: UUID
        let aisleNumber: Double
        let supportingObservations: Int
    }

    static func resolve(evidence: [Evidence], capturedAt: Date) -> Lock? {
        let recent = evidence
            .filter { age(of: $0.observedAt, at: capturedAt) <= maximumObservationAge }
            .suffix(maximumObservationCount)

        var block: UUID?
        var lockedAisle: Double?
        var candidateAisle: Double?
        var candidateCount = 0
        var supportCount = 0
        var contradictionAisle: Double?
        var contradictionCount = 0

        for item in recent {
            guard let itemBlock = item.paddockId, let aisle = item.aisleNumber else {
                block = nil
                lockedAisle = nil
                candidateAisle = nil
                candidateCount = 0
                supportCount = 0
                contradictionAisle = nil
                contradictionCount = 0
                continue
            }
            if block != itemBlock {
                block = itemBlock
                lockedAisle = nil
                candidateAisle = nil
                candidateCount = 0
                supportCount = 0
                contradictionAisle = nil
                contradictionCount = 0
            }

            if let currentLock = lockedAisle {
                if sameAisle(currentLock, aisle) {
                    if item.isQualified { supportCount = min(maximumObservationCount, supportCount + 1) }
                    contradictionAisle = nil
                    contradictionCount = 0
                } else if item.isQualified {
                    if contradictionAisle.map({ sameAisle($0, aisle) }) == true {
                        contradictionCount += 1
                    } else {
                        contradictionAisle = aisle
                        contradictionCount = 1
                    }
                    if contradictionCount >= contradictoryObservationCount {
                        candidateAisle = aisle
                        candidateCount = contradictionCount
                        supportCount = contradictionCount
                        lockedAisle = aisle
                        contradictionAisle = nil
                        contradictionCount = 0
                    }
                }
            } else if item.isQualified {
                if candidateAisle.map({ sameAisle($0, aisle) }) == true {
                    candidateCount += 1
                } else {
                    candidateAisle = aisle
                    candidateCount = 1
                }
                if candidateCount >= supportingObservationCount {
                    lockedAisle = aisle
                    supportCount = candidateCount
                }
            }
        }

        guard let block, let lockedAisle, supportCount >= supportingObservationCount else { return nil }
        return Lock(paddockId: block, aisleNumber: lockedAisle, supportingObservations: supportCount)
    }

    static func resolve(locations: [CLLocation], current: CLLocation, paddock: Paddock?) -> Lock? {
        guard let paddock else { return nil }
        let ordered = locations
            .filter { $0.timestamp <= current.timestamp && age(of: $0.timestamp, at: current.timestamp) <= maximumObservationAge }
            .suffix(maximumObservationCount)
        let evidence = ordered.map { location -> Evidence in
            let coordinate = location.coordinate
            guard RowGuidance.paddock(for: coordinate, in: [paddock])?.id == paddock.id else {
                return Evidence(observedAt: location.timestamp, paddockId: nil, aisleNumber: nil, isQualified: false)
            }
            let approximate = PinAisleGeometry.approximateAisle(containing: coordinate, in: paddock)
            let qualified = PinAisleGeometry.aisle(
                containing: coordinate,
                in: paddock,
                horizontalAccuracyMetres: location.horizontalAccuracy
            )
            return Evidence(
                observedAt: location.timestamp,
                paddockId: paddock.id,
                aisleNumber: approximate?.aisleNumber,
                isQualified: qualified?.aisleNumber == approximate?.aisleNumber
            )
        }
        guard let lock = resolve(evidence: evidence, capturedAt: current.timestamp),
              lock.paddockId == paddock.id,
              PinAisleGeometry.approximateAisle(containing: current.coordinate, in: paddock) != nil
        else { return nil }
        return lock
    }

    private static func age(of date: Date, at reference: Date) -> TimeInterval {
        max(0, reference.timeIntervalSince(date))
    }

    private static func sameAisle(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.01
    }

}
