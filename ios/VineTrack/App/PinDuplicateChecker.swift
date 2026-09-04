import Foundation
import CoreLocation

/// Pure, read-only duplicate warning evaluator shared by every Repairs/Growth
/// creation surface. Type identity is always checked before spatial matching.
@MainActor
enum PinDuplicateChecker {
    static let fallbackRadiusMeters: Double = 3.0
    static let maxRadiusMeters: Double = 6.0
    static let minRadiusMeters: Double = 2.5
    static let alongRowDuplicateMetres: Double = 2.5

    enum Method: String, Sendable {
        case alongRow = "along_row"
        case rawDistance = "raw_distance"
    }

    struct Match: Sendable {
        let pin: VinePin
        let distance: Double
        let radius: Double
        let method: Method
    }

    struct Diagnostics: Sendable, CustomStringConvertible {
        let candidateKey: PinTypeIdentity
        let vineyardPinsInspected: Int
        let sameTypeCandidates: Int
        let method: Method?
        let matchedType: String?
        let distance: Double?
        let radius: Double
        let result: String

        var description: String {
            let distanceText = distance.map { String(format: "%.2f", $0) } ?? "none"
            return "candidate=\(candidateKey); inspected=\(vineyardPinsInspected); " +
                "same_type=\(sameTypeCandidates); method=\(method?.rawValue ?? "none"); " +
                "matched_type=\(matchedType ?? "none"); distance_m=\(distanceText); " +
                "radius_m=\(String(format: "%.2f", radius)); result=\(result)"
        }
    }

    struct Evaluation: Sendable {
        let match: Match?
        let diagnostics: Diagnostics
    }

    static func duplicateRadius(
        coordinate: CLLocationCoordinate2D,
        paddockId: UUID?,
        paddocks: [Paddock]
    ) -> Double {
        if let containing = RowGuidance.paddock(for: coordinate, in: paddocks),
           containing.rowWidth > 0 {
            return min(maxRadiusMeters, max(minRadiusMeters, containing.rowWidth / 2.0))
        }
        if let paddockId,
           let paddock = paddocks.first(where: { $0.id == paddockId }),
           paddock.rowWidth > 0 {
            return min(maxRadiusMeters, max(minRadiusMeters, paddock.rowWidth / 2.0))
        }
        return fallbackRadiusMeters
    }

    /// Runs along-row matching first, then the legacy raw-distance fallback.
    /// The source array is never sorted or mutated.
    static func evaluate(
        coordinate: CLLocationCoordinate2D,
        rawCoordinate: CLLocationCoordinate2D? = nil,
        vineyardId: UUID?,
        paddockId: UUID?,
        rowNumber: Int?,
        side: PinSide?,
        mode: PinMode,
        logicalType: String,
        in pins: [VinePin],
        paddocks: [Paddock]
    ) -> Evaluation {
        let candidateKey = PinTypeIdentity(mode: mode, logicalType: logicalType)
        let radius = duplicateRadius(coordinate: coordinate, paddockId: paddockId, paddocks: paddocks)
        guard let vineyardId else {
            return noMatchDiagnostics(
                candidateKey: candidateKey,
                inspected: 0,
                sameType: 0,
                radius: radius
            )
        }

        let vineyardPins = pins.filter { $0.vineyardId == vineyardId }
        let sameTypePins = vineyardPins.filter {
            !$0.isCompleted && PinTypeIdentity(existing: $0) == candidateKey
        }

        if let match = nearbyPinAlongRow(
            snappedCoordinate: coordinate,
            paddockId: paddockId,
            rowNumber: rowNumber,
            side: side,
            candidateKey: candidateKey,
            in: sameTypePins,
            paddocks: paddocks
        ) {
            return matchedEvaluation(
                match: match,
                candidateKey: candidateKey,
                inspected: vineyardPins.count,
                sameType: sameTypePins.count
            )
        }

        if let match = nearbyPinRawDistance(
            coordinate: rawCoordinate ?? coordinate,
            paddockId: paddockId,
            rowNumber: rowNumber,
            side: side,
            candidateKey: candidateKey,
            radius: radius,
            in: sameTypePins
        ) {
            return matchedEvaluation(
                match: match,
                candidateKey: candidateKey,
                inspected: vineyardPins.count,
                sameType: sameTypePins.count
            )
        }

        return noMatchDiagnostics(
            candidateKey: candidateKey,
            inspected: vineyardPins.count,
            sameType: sameTypePins.count,
            radius: radius
        )
    }

    private static func nearbyPinAlongRow(
        snappedCoordinate: CLLocationCoordinate2D,
        paddockId: UUID?,
        rowNumber: Int?,
        side: PinSide?,
        candidateKey: PinTypeIdentity,
        in pins: [VinePin],
        paddocks: [Paddock]
    ) -> Match? {
        guard let paddockId, let rowNumber,
              let paddock = paddocks.first(where: { $0.id == paddockId }),
              let snappedCandidate = RowGuidance.snapToRow(
                coordinate: snappedCoordinate,
                rowNumber: rowNumber,
                in: paddock
              ) else {
            return nil
        }

        var best: Match?
        for pin in pins {
            guard !pin.isCompleted else { continue }
            guard PinTypeIdentity(existing: pin) == candidateKey else { continue }
            guard pin.paddockId == paddockId else { continue }
            guard (pin.pinRowNumber ?? pin.rowNumber) == rowNumber else { continue }
            if let side, let existingSide = pin.pinSide ?? pin.side, existingSide != side { continue }
            guard let snappedExisting = RowGuidance.snapToRow(
                coordinate: pin.attachedCoordinate,
                rowNumber: rowNumber,
                in: paddock
            ) else { continue }

            let distance = abs(snappedCandidate.distanceAlongMetres - snappedExisting.distanceAlongMetres)
            guard distance <= alongRowDuplicateMetres else { continue }
            if best == nil || distance < best!.distance {
                best = Match(
                    pin: pin,
                    distance: distance,
                    radius: alongRowDuplicateMetres,
                    method: .alongRow
                )
            }
        }
        return best
    }

    private static func nearbyPinRawDistance(
        coordinate: CLLocationCoordinate2D,
        paddockId: UUID?,
        rowNumber: Int?,
        side: PinSide?,
        candidateKey: PinTypeIdentity,
        radius: Double,
        in pins: [VinePin]
    ) -> Match? {
        var best: Match?
        for pin in pins {
            guard !pin.isCompleted else { continue }
            guard PinTypeIdentity(existing: pin) == candidateKey else { continue }
            if let paddockId, let existingPaddockId = pin.paddockId,
               existingPaddockId != paddockId { continue }

            // Row-attached records belong exclusively to along-row matching.
            // This prevents an adjacent row from re-entering through raw GPS.
            if pin.snappedToRow || pin.pinRowNumber != nil || pin.alongRowDistanceM != nil { continue }
            if let side, let existingSide = pin.pinSide ?? pin.side, existingSide != side { continue }
            if let rowNumber, let existingRow = pin.rowNumber, existingRow != rowNumber { continue }

            let distance = RowGuidance.metresBetween(coordinate, pin.coordinate)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance {
                best = Match(pin: pin, distance: distance, radius: radius, method: .rawDistance)
            }
        }
        return best
    }

    private static func matchedEvaluation(
        match: Match,
        candidateKey: PinTypeIdentity,
        inspected: Int,
        sameType: Int
    ) -> Evaluation {
        let result = match.method == .alongRow
            ? "duplicate_same_type_along_row"
            : "duplicate_same_type_raw_distance"
        return Evaluation(
            match: match,
            diagnostics: Diagnostics(
                candidateKey: candidateKey,
                vineyardPinsInspected: inspected,
                sameTypeCandidates: sameType,
                method: match.method,
                matchedType: PinTypeIdentity(existing: match.pin).description,
                distance: match.distance,
                radius: match.radius,
                result: result
            )
        )
    }

    private static func noMatchDiagnostics(
        candidateKey: PinTypeIdentity,
        inspected: Int,
        sameType: Int,
        radius: Double
    ) -> Evaluation {
        Evaluation(
            match: nil,
            diagnostics: Diagnostics(
                candidateKey: candidateKey,
                vineyardPinsInspected: inspected,
                sameTypeCandidates: sameType,
                method: nil,
                matchedType: nil,
                distance: nil,
                radius: radius,
                result: "no_same_type_duplicate"
            )
        )
    }
}
