import Foundation

/// Resolved placement for one pin under the canonical assignment rules
/// (sql/171 `pin_placements`). Produced by `PinPlacementContract.resolve` —
/// the client mirror of the server-authoritative contract, used for offline
/// caches and optimistic records where the server fields aren't present yet.
nonisolated struct PinPlacement: Equatable, Sendable {
    /// Effective location scope: "point" / "row" / "block", or nil when the
    /// pin has genuinely no usable location. Derived for legacy pins that
    /// were saved before `location_scope` existed.
    let locationScope: String?
    /// One of the `PinPlacementContract.basis*` values.
    let basis: String
    /// True unless the basis is `basisUnassigned`.
    let isAssigned: Bool
    /// nil for any valid point / row / block assignment;
    /// `warningMetadataIncomplete` when a stored scope's structured data is
    /// missing but a safe fallback assignment exists (never the amber
    /// warning); `warningUnassigned` only when nothing usable exists.
    let warningCode: String?
    /// Segment-derived display summary ("Rows 41–43"), nil without segments.
    let rowSummary: String?
    let hasRowSegments: Bool
}

/// Pure client mirror of the sql/171 canonical pin placement contract.
/// Shared by lists, detail screens, map callouts and exports so the same pin
/// always resolves to the same placement everywhere. Mirrors
/// `PinPlacementContract` in the Android app — outputs must match exactly.
nonisolated enum PinPlacementContract {

    // Assignment basis (sql/171 `location_assignment_basis`).
    static let basisPointCoordinates = "point_coordinates"
    static let basisSnappedPoint = "snapped_point"
    static let basisRowSegments = "row_segments"
    static let basisBlock = "block"
    static let basisLegacyBlock = "legacy_block"
    static let basisUnassigned = "unassigned"

    // Warning codes (sql/171 `location_warning_code`).
    static let warningUnassigned = "unassigned_location"
    static let warningMetadataIncomplete = "location_metadata_incomplete"

    /// Wording for the strong amber state — shown ONLY when a pin genuinely
    /// has no usable location (`warningUnassigned`).
    static let unassignedLocationLabel = "Unassigned location"
    /// Wording for a valid point assignment that has no block association.
    static let pointLocationLabel = "Point location"

    /// Resolves the canonical placement. Must stay logic-identical to the
    /// sql/171 `pin_placements` view and the Kotlin mirror.
    ///
    /// - Parameters:
    ///   - storedScope: the pin's stored `location_scope`, if any.
    ///   - hasBlock: `paddock_id` present.
    ///   - segments: live row segments (`pin_row_segments`).
    ///   - hasCoordinates: a valid marker coordinate exists.
    ///   - snappedToRow: confident row snap recorded.
    ///   - hasRowValues: any of pin_row_number / driving_row_number /
    ///     legacy row_number present on the base pin row.
    static func resolve(
        storedScope: String?,
        hasBlock: Bool,
        segments: [ManualIssueSegment],
        hasCoordinates: Bool,
        snappedToRow: Bool,
        hasRowValues: Bool
    ) -> PinPlacement {
        let hasSegments = !segments.isEmpty
        let scopeStored = storedScope == "point" || storedScope == "row" || storedScope == "block"

        let effectiveScope: String?
        if scopeStored {
            effectiveScope = storedScope
        } else if hasSegments {
            effectiveScope = "row"
        } else if hasBlock && hasRowValues {
            effectiveScope = "point"
        } else if hasBlock {
            effectiveScope = "block"
        } else if hasCoordinates {
            effectiveScope = "point"
        } else {
            effectiveScope = nil
        }

        let basis: String
        switch effectiveScope {
        case "row":
            if hasBlock && hasSegments {
                basis = basisRowSegments
            } else if hasCoordinates && (snappedToRow || hasRowValues) {
                basis = basisSnappedPoint
            } else if hasCoordinates {
                basis = basisPointCoordinates
            } else if hasBlock {
                basis = basisBlock
            } else {
                basis = basisUnassigned
            }
        case "block":
            if hasBlock {
                basis = scopeStored ? basisBlock : basisLegacyBlock
            } else if hasCoordinates {
                basis = basisPointCoordinates
            } else {
                basis = basisUnassigned
            }
        case "point":
            if hasCoordinates {
                basis = (snappedToRow || (hasBlock && hasRowValues)) ? basisSnappedPoint : basisPointCoordinates
            } else {
                basis = basisUnassigned
            }
        default:
            basis = basisUnassigned
        }

        let warning: String?
        if basis == basisUnassigned {
            warning = warningUnassigned
        } else if scopeStored && effectiveScope == "row" && basis != basisRowSegments {
            warning = warningMetadataIncomplete
        } else if scopeStored && effectiveScope == "block" && basis != basisBlock {
            warning = warningMetadataIncomplete
        } else {
            warning = nil
        }

        let summary = hasSegments ? ManualIssueContract.rowSelectionSummary(segments) : nil
        return PinPlacement(
            locationScope: effectiveScope,
            basis: basis,
            isAssigned: basis != basisUnassigned,
            warningCode: warning,
            rowSummary: (summary?.isEmpty == false) ? summary : nil,
            hasRowSegments: hasSegments
        )
    }

    /// Convenience resolution from a local pin. `VinePin` always carries a
    /// marker coordinate, so only remote/fixture records can be coordinate-less.
    static func placement(for pin: VinePin) -> PinPlacement {
        resolve(
            storedScope: pin.locationScope,
            hasBlock: pin.paddockId != nil,
            segments: pin.rowSegments ?? [],
            hasCoordinates: true,
            snappedToRow: pin.snappedToRow,
            hasRowValues: pin.pinRowNumber != nil || pin.drivingRowNumber != nil || pin.rowNumber != nil
        )
    }

    /// The block/row context line shown under a pin in lists, detail panels
    /// and callouts. A known block is NEVER hidden because a row value is
    /// absent; `unassignedLocationLabel` appears only for a genuinely
    /// unassigned record. Must produce byte-identical output to the Kotlin
    /// mirror.
    ///
    /// - Parameters:
    ///   - blockName: resolved block display name, nil when unknown.
    ///   - placement: canonical placement for the pin.
    ///   - attachedRowText: pre-formatted attached row ("15" / "19.5"), nil
    ///     when the pin has no row attachment.
    static func blockContextLine(
        blockName: String?,
        placement: PinPlacement,
        attachedRowText: String?
    ) -> String {
        let block = blockName.flatMap { $0.isEmpty ? nil : $0 }
        switch placement.basis {
        case basisRowSegments:
            let summary = placement.rowSummary ?? "Rows"
            return block.map { "\($0) — \(summary)" } ?? summary
        case basisSnappedPoint:
            if let block {
                return attachedRowText.map { "\(block) row \($0)" } ?? block
            }
            return attachedRowText.map { "Row \($0)" } ?? pointLocationLabel
        case basisBlock, basisLegacyBlock:
            return block ?? "Block"
        case basisPointCoordinates:
            // A point pin may still carry an inferred block — show it.
            return block ?? pointLocationLabel
        default:
            return unassignedLocationLabel
        }
    }

    /// Formats an attached row for display, trimming whole values (15) and
    /// preserving exact fractional path rows (19.5) — never rounding.
    static func attachedRowText(pinRowNumber: Int?, drivingRowNumber: Double?, legacyRowNumber: Int?) -> String? {
        if let pinRowNumber { return "\(pinRowNumber)" }
        if let drivingRowNumber {
            return drivingRowNumber == drivingRowNumber.rounded()
                ? "\(Int(drivingRowNumber))"
                : "\(drivingRowNumber)"
        }
        if let legacyRowNumber { return "\(legacyRowNumber).5" }
        return nil
    }
}
