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
/// Legacy fallback: when only the legacy integer `rowNumber` is stored,
/// it represented the driving path floor and is shown as `Row X.5`.
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

    /// Preferred attachment line. Side is intentionally NOT included here —
    /// Left/Right belongs with the driving path/operator view, not the
    /// attached vine row.
    /// Returns "Row 14" when the new model is populated, otherwise the
    /// legacy "Row 14.5" wording.
    static func attachmentLine(_ pin: VinePin) -> String? {
        if let pinRow = pin.pinRowNumber {
            return "Row \(pinRow)"
        }
        if let legacy = pin.rowNumber {
            return "Row \(legacy).5"
        }
        return nil
    }

    /// Optional second line for the driving path, e.g.
    /// "Row 14.5 — Left hand side facing North".
    /// Returns nil when no driving_row_number is recorded.
    static func drivingPathLine(_ pin: VinePin) -> String? {
        guard let path = pin.drivingRowNumber else { return nil }
        let formatted = formatPath(path)
        let side = pin.pinSide ?? pin.side
        let facing = fullCompassName(degrees: pin.heading)
        return "Row \(formatted) — \(side.rawValue) hand side facing \(facing)"
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
    /// (e.g. older export paths). Prefer `attachmentLine(_:)` for new code.
    static func rowAndSide(rowNumber: Int?, side: PinSide?) -> String? {
        guard let rowNumber else { return nil }
        let row = "Row \(rowNumber).5"
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
