import Foundation

/// Pure contract for the unified "Manual Pin / Repair / Observation"
/// composer, shared by the composer UI, sync layer and tests. Mirrors `UnifiedPinContract` in
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

    /// Customer-facing Quick Action label — EXACT wording on iOS/Android/portal.
    static let quickActionTitle = "Manual Pin / Repair / Observation"

    /// Quick Action supporting text — identical on every platform.
    static let quickActionSubtitle = "Either by Pin, Row or Block"

    /// Shared semantic blue for the Quick Action card. `VineyardTheme.actionBlue`
    /// (iOS) and `VineColors.ActionBlue` (Android) are both defined from this exact
    /// value so the platforms cannot drift. Saved pin colours are unaffected.
    static let quickActionColorHex = "#1565C0"

    /// Darker companion used only as the card gradient's second stop.
    static let quickActionColorDarkHex = "#0D47A1"

    /// Minimum height (pt on iOS, dp on Android) of each of the three
    /// location-choice controls — approximately double the original ~64 card.
    static let methodButtonMinHeight: CGFloat = 128

    /// Location-choice titles in canonical order — identical on both platforms.
    static let methodTitles: [String] = ["Drop a pin manually", "Select a row", "Select a block"]

    /// Location-choice subtitles, index-aligned with `methodTitles`.
    static let methodSubtitles: [String] = [
        "Tap a point on the map — no block selection needed",
        "Tap rows or row sections — the block is detected automatically",
        "Flag a whole block",
    ]

    /// The Growth tab's Growth Stage launcher — rendered exactly once, first.
    static let growthStageButton = "Growth Stage"

    /// Colour token stored on growth-stage pins (matches the existing pins).
    static let growthStagePinColor = "darkgreen"

    /// Shared validation wording — asserted verbatim by tests on both platforms.
    static let errorSelectType = "Select a pin type."
    static let errorLocationRequired = "A map location is required."
    static let errorTapMap = "Tap the map to place the pin."
    static let errorSelectRow = "Select at least one row."
    static let errorSelectBlock = "Select a block."

    /// Safe message when selected row geometry can't be associated with a block.
    static let errorRowBlock = "Couldn't match the selected row to a block."

    /// Title/button name stored on a growth-stage pin — the SAME identifier the
    /// existing growth-stage pin workflow stores (`Growth Stage {E-L code}`).
    static func growthStagePinTitle(stageCode: String) -> String {
        "\(growthStageButton) \(stageCode)"
    }

    /// Dedupe key for Repair/Growth catalogue tiles (left/right duplicates collapse).
    static func catalogueKey(name: String, color: String?) -> String {
        name + "|" + (color ?? "")
    }

    /// The Growth tab's ordered items: Growth Stage exactly once (first), then
    /// the existing catalogue names deduplicated — never a second stage list.
    static func growthTabItems(existingNames: [String]) -> [String] {
        var seen = Set<String>()
        let rest = existingNames
            .filter { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(growthStageButton) != .orderedSame }
            .filter { seen.insert($0).inserted }
        return [growthStageButton] + rest
    }

    /// Row-first selection: the user taps rows directly and the block is DERIVED
    /// from the tapped row's geometry — never chosen through a block dropdown.
    /// Tapping a row in a different block switches the derived block and starts a
    /// fresh selection (a pin belongs to exactly one block); tapping within the
    /// current block toggles the tapped segments.
    static func applyRowTap(
        currentBlockId: UUID?,
        tappedBlockId: UUID,
        currentSegments: Set<ManualIssueSegment>,
        tappedSegments: Set<ManualIssueSegment>
    ) -> (blockId: UUID, segments: Set<ManualIssueSegment>) {
        if currentBlockId != tappedBlockId { return (tappedBlockId, tappedSegments) }
        let allSelected = !tappedSegments.isEmpty && tappedSegments.isSubset(of: currentSegments)
        return (tappedBlockId, allSelected ? currentSegments.subtracting(tappedSegments) : currentSegments.union(tappedSegments))
    }

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
        if !hasSelectedType { return errorSelectType }
        guard latitude != nil, longitude != nil else { return errorLocationRequired }
        switch scope {
        case scopePoint:
            return nil
        case scopeRow:
            if ManualIssueContract.canonicalSegments(segments).isEmpty { return errorSelectRow }
            if paddockId == nil { return errorRowBlock }
            return nil
        case scopeBlock:
            return paddockId == nil ? errorSelectBlock : nil
        default:
            return errorLocationRequired
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
