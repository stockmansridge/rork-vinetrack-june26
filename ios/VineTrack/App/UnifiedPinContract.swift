import Foundation

/// Pure contract for the unified "Add Pin / Action" composer, shared by the
/// composer UI, sync layer and tests. Mirrors `UnifiedPinContract` in
/// `CustomPinType.kt` on Android exactly — parity tests on both platforms
/// assert the same values.
///
/// The composer is location-first (point / row / block), then one of three
/// tabs in this exact order on every platform: Repair | Growth | Custom.
/// Left/Right side selection is not part of this workflow.
nonisolated enum UnifiedPinContract {

    /// Tab ids in canonical display order — identical wording on iOS/Android/portal.
    static let tabs: [String] = ["Repair", "Growth", "Custom"]

    /// Location methods reuse the established scope ids from sql/169.
    static let scopePoint = ManualIssueLocationScope.point.rawValue
    static let scopeRow = ManualIssueLocationScope.row.rawValue
    static let scopeBlock = ManualIssueLocationScope.block.rawValue

    /// Validation shared by all three tabs. Point never requires a block; row
    /// requires a block plus at least one segment; block requires a block.
    /// Identical rules across iOS, Android and the portal contract.
    static func validationError(
        scope: String,
        hasSelectedType: Bool,
        latitude: Double?,
        longitude: Double?,
        paddockId: UUID?,
        segments: [ManualIssueSegment]
    ) -> String? {
        if !hasSelectedType { return "Select a pin type." }
        guard latitude != nil, longitude != nil else { return "A map location is required." }
        switch scope {
        case scopePoint:
            return nil
        case scopeRow:
            if paddockId == nil { return "Select the block that owns the rows." }
            if ManualIssueContract.canonicalSegments(segments).isEmpty { return "Select at least one row." }
            return nil
        case scopeBlock:
            return paddockId == nil ? "Select a block." : nil
        default:
            return "A map location is required."
        }
    }

    /// Trimmed custom item name; nil when blank (blank names are rejected).
    static func normalizeCustomTypeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when `name` duplicates an existing ACTIVE item using trimmed,
    /// case-insensitive comparison — the same rule the server enforces.
    static func isDuplicateCustomTypeName(_ name: String, existing: [CustomPinTypeRecord]) -> Bool {
        guard let normalized = normalizeCustomTypeName(name)?.lowercased() else { return false }
        return existing.contains {
            $0.isActive && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }
}
