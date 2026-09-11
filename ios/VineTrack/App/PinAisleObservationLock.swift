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
        /// Most recent separately delivered observation that confirmed this aisle.
        let confirmedAt: Date
    }

    /// Sample identity is its provider timestamp. Fresh stationary observations
    /// remain distinct; replayed, out-of-order, stale, or implausibly future
    /// samples do not create confidence.
    static func acceptsObservation(
        observedAt: Date,
        previousObservedAt: Date?,
        receivedAt: Date
    ) -> Bool {
        let age = receivedAt.timeIntervalSince(observedAt)
        guard age >= -1, age <= LocationService.staleLocationThreshold else { return false }
        guard let previousObservedAt else { return true }
        return observedAt > previousObservedAt
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
        var confirmedAt: Date?

        for item in recent {
            guard let itemBlock = item.paddockId, let aisle = item.aisleNumber else {
                block = nil
                lockedAisle = nil
                candidateAisle = nil
                candidateCount = 0
                supportCount = 0
                contradictionAisle = nil
                contradictionCount = 0
                confirmedAt = nil
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
                confirmedAt = nil
            }

            if let currentLock = lockedAisle {
                if sameAisle(currentLock, aisle) {
                    if item.isQualified {
                        supportCount = min(maximumObservationCount, supportCount + 1)
                        confirmedAt = item.observedAt
                    }
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
                        confirmedAt = item.observedAt
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
                    confirmedAt = item.observedAt
                }
            }
        }

        guard let block, let lockedAisle, let confirmedAt,
              supportCount >= supportingObservationCount else { return nil }
        return Lock(
            paddockId: block,
            aisleNumber: lockedAisle,
            supportingObservations: supportCount,
            confirmedAt: confirmedAt
        )
    }

    static func resolve(locations: [CLLocation], current: CLLocation, paddock: Paddock?) -> Lock? {
        guard let paddock else { return nil }
        let ordered = locations
            .filter { $0.timestamp <= current.timestamp && age(of: $0.timestamp, at: current.timestamp) <= maximumObservationAge }
            .suffix(maximumObservationCount)
        let evidence = ordered.map { location -> Evidence in
            let coordinate = location.coordinate
            guard PinAisleGeometry.polygonContains(coordinate, in: paddock) else {
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
              isValid(lock, capturedAt: current.timestamp, currentCoordinate: current.coordinate, paddock: paddock)
        else { return nil }
        return lock
    }

    /// Validate the complete scoped lock at the frozen press. A brief lateral
    /// contradiction may keep the lock, but only while the current fix remains
    /// inside the same block and within mapped row longitudinal extent.
    static func isValid(
        _ lock: Lock?,
        capturedAt: Date,
        currentCoordinate: CLLocationCoordinate2D,
        paddock: Paddock?
    ) -> Bool {
        guard let lock, let paddock,
              lock.paddockId == paddock.id,
              capturedAt.timeIntervalSince(lock.confirmedAt) >= -1,
              capturedAt.timeIntervalSince(lock.confirmedAt) <= maximumObservationAge,
              PinAisleGeometry.polygonContains(currentCoordinate, in: paddock),
              let rows = PinAisleGeometry.rowsBounding(path: lock.aisleNumber, in: paddock),
              PinAisleGeometry.isWithinLongitudinalExtent(
                of: rows,
                coordinate: currentCoordinate,
                in: paddock
              )
        else { return false }
        return true
    }

    private static func age(of date: Date, at reference: Date) -> TimeInterval {
        max(0, reference.timeIntervalSince(date))
    }

    private static func sameAisle(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.01
    }

}
