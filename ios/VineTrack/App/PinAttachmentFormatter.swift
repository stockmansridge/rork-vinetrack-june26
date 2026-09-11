import Foundation

/// Customer-facing wording for "this pin is on row/path X — Side".
///
/// New attachment model:
///   * `pin_row_number` is the actual vine row the issue is attached to
///     (e.g. 14 or 15). Display as `Row 14`.
///   * `driving_row_number` is the driving path / mid-row the tractor was
///     on (e.g. 14.5). Display as `Row 14.5 — {Side} hand side facing {Dir}`.
///   * `pin_side` is the operator's-POV side. Display as `Left/Right hand side`.
///
/// The legacy integer `rowNumber` is NEVER turned into an attached row or into
/// a driving path by adding 0.5 — its meaning is ambiguous across historical
/// records, so it is surfaced only as an explicitly labelled recorded value
/// (`legacyRecordedRowLine`), never as a confirmed location.
nonisolated enum PinAttachmentFormatter {

    /// Full compass name for a heading in degrees (e.g. 45 → "Northeast").
    static func fullCompassName(degrees: Double) -> String {
        let h = degrees.truncatingRemainder(dividingBy: 360)
        let n = h < 0 ? h + 360 : h
        switch n {
        case 337.5..<360, 0..<22.5: return "North"
        case 22.5..<67.5: return "Northeast"
        case 67.5..<112.5: return "East"
        case 112.5..<157.5: return "Southeast"
        case 157.5..<202.5: return "South"
        case 202.5..<247.5: return "Southwest"
        case 247.5..<292.5: return "West"
        case 292.5..<337.5: return "Northwest"
        default: return "North"
        }
    }

    /// Eight-point compass abbreviation for compact live context labels.
    static func compassAbbreviation(degrees: Double) -> String {
        let fullName = fullCompassName(degrees: degrees)
        switch fullName {
        case "North": return "N"
        case "Northeast": return "NE"
        case "East": return "E"
        case "Southeast": return "SE"
        case "South": return "S"
        case "Southwest": return "SW"
        case "West": return "W"
        case "Northwest": return "NW"
        default: return "—"
        }
    }

    /// Preferred attachment line. Side is intentionally NOT included here —
    /// Left/Right belongs with the driving path/operator view, not the
    /// attached vine row.
    ///
    /// Returns "Row 14" ONLY from a confirmed `pin_row_number`. An unconfirmed
    /// capture returns nil rather than inventing a row from the legacy field.
    static func attachmentLine(_ pin: VinePin) -> String? {
        pin.pinRowNumber.map { "Row \($0)" }
    }

    /// Honest wording for a record that carries only the legacy integer row.
    /// The stored value is preserved and shown, but it is never presented as a
    /// confirmed attached row or as an aisle.
    static func legacyRecordedRowLine(_ pin: VinePin) -> String? {
        guard pin.pinRowNumber == nil, pin.drivingRowNumber == nil,
              let legacy = pin.rowNumber
        else { return nil }
        return "Recorded row \(legacy)"
    }

    /// Explicit label for a capture whose attached vine row was never
    /// established. Used so a pin can never look located when it is not.
    static let unconfirmedRowLabel = "Not confirmed"

    /// Explicit label for an absent driving path / aisle.
    static let unrecordedDrivingPathLabel = "Not recorded"

    /// Optional second line for the driving path, e.g.
    /// "Row 14.5 — Left hand side facing North".
    /// Returns nil when no driving_row_number is recorded.
    static func drivingPathLine(_ pin: VinePin) -> String? {
        guard let path = pin.drivingRowNumber else { return nil }
        let formatted = formatPath(path)
        // Honest optional side: composer-created pins have no Left/Right,
        // so the phrase is omitted rather than invented.
        let sidePhrase = (pin.pinSide ?? pin.side).map { " — \($0.rawValue) hand side" } ?? ""
        // Only claim a facing direction when one was actually recorded.
        guard let heading = pin.heading else {
            return "Row \(formatted)\(sidePhrase)"
        }
        let facing = fullCompassName(degrees: heading)
        return "Row \(formatted)\(sidePhrase) facing \(facing)"
    }

    /// Subtitle for confirmation toasts after a pin is dropped during a
    /// trip. Prefers the resolved attached-row wording.
    static func toastSubtitle(
        attachment: PinAttachmentResolver.Attachment,
        fallbackSide: PinSide,
        heading: Double? = nil
    ) -> String {
        let facing = heading.map { fullCompassName(degrees: $0) }
        func appendFacing(_ s: String) -> String {
            guard let facing else { return s }
            return "\(s) facing \(facing)"
        }
        if attachment.snappedToRow, let row = attachment.pinRowNumber {
            var line = "On Row \(row)"
            if let path = attachment.drivingRowNumber {
                let side = attachment.pinSide ?? fallbackSide
                line += " • Row \(formatPath(path)) — " + appendFacing("\(side.rawValue) hand side")
            }
            return line
        }
        if let path = attachment.drivingRowNumber {
            return "Row \(formatPath(path)) — " + appendFacing("\(fallbackSide.rawValue) hand side")
        }
        return appendFacing("\(fallbackSide.rawValue) hand side")
    }

    /// Short attached-to subtitle for inline labels (e.g. growth-stage toast).
    static func attachmentSubtitle(
        attachment: PinAttachmentResolver.Attachment,
        heading: Double? = nil
    ) -> String? {
        let facing = heading.map { fullCompassName(degrees: $0) }
        if attachment.snappedToRow, let row = attachment.pinRowNumber {
            return "On Row \(row)"
        }
        if let path = attachment.drivingRowNumber {
            if let side = attachment.pinSide {
                var s = "Row \(formatPath(path)) — \(side.rawValue) hand side"
                if let facing { s += " facing \(facing)" }
                return s
            }
            return "Row \(formatPath(path))"
        }
        return nil
    }

    /// Legacy formatter kept for places that still pass raw rowNumber/side
    /// (e.g. older export paths). The recorded integer is shown as-is; it is
    /// never promoted to an aisle by appending ".5".
    static func rowAndSide(rowNumber: Int?, side: PinSide?) -> String? {
        guard let rowNumber else { return nil }
        let row = "Row \(rowNumber)"
        guard let side else { return row }
        return "\(row) — \(side.rawValue) hand side"
    }

    /// Legacy "on row" wording for cases without a VinePin instance.
    static func attachedTo(rowNumber: Int?, side: PinSide?) -> String {
        if let label = rowAndSide(rowNumber: rowNumber, side: side) {
            return "On \(label)"
        }
        return "Pin location not snapped to a row"
    }

    private static func formatPath(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.1f", value)
        }
        // Trim trailing zeros while keeping at least one decimal for X.5 paths.
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
