import Foundation

/// Canonical repair-category identities and fallback colours shared with Android.
/// Vineyard button configuration is authoritative; these colours are used only
/// when no current configured button can be safely matched.
///
/// Stable ids and their canonical colour tokens:
///  - `irrigation`  → blue
///  - `broken_post` → brown
///  - `vine_issue`  → green
///  - `broken_wire` → orange
///  - `other`       → gray
///  - unknown / missing category → gray ("Unassigned")
///
/// Historical rows store the category as free text (e.g. "Vine Issue"), so
/// `canonicalId` normalises the stored value structurally (case, whitespace,
/// punctuation) into the stable id. Unrecognised values resolve to `nil`
/// (unknown) and render as the neutral unassigned gray — they never crash and
/// never inherit another category's colour.
nonisolated enum PinCategoryCatalog {

    static let irrigation = "irrigation"
    static let brokenPost = "broken_post"
    static let vineIssue = "vine_issue"
    static let brokenWire = "broken_wire"
    static let other = "other"

    /// Neutral colour token used for unknown/unassigned categories.
    static let unassignedColor = "gray"

    /// Every stable id the catalogue recognises.
    static let allIds: Set<String> = [irrigation, brokenPost, vineIssue, brokenWire, other]

    /// Normalise a stored category/button value into its stable canonical id.
    /// Returns `nil` for blank or unrecognised values (unknown category). The
    /// normalisation is structural only (lowercase, punctuation/whitespace
    /// folded to `_`) — it never compares translated display labels.
    static func canonicalId(forRaw raw: String?) -> String? {
        guard let raw else { return nil }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return nil }
        var normalized = ""
        var lastWasSeparator = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                normalized.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                normalized.append("_")
                lastWasSeparator = true
            }
        }
        while normalized.hasSuffix("_") { normalized.removeLast() }
        guard !normalized.isEmpty else { return nil }
        return allIds.contains(normalized) ? normalized : nil
    }

    /// Canonical colour token for a stable category id. Unknown or missing
    /// ids resolve to `unassignedColor` so historical records without a
    /// category always display as neutral gray, never a misleading category
    /// colour.
    static func colorToken(forCanonicalId id: String?) -> String {
        switch id {
        case irrigation: return "blue"
        case brokenPost: return "brown"
        case vineIssue: return "green"
        case brokenWire: return "orange"
        case other: return unassignedColor
        default: return unassignedColor
        }
    }

    /// Convenience: raw stored value → canonical colour token in one step.
    static func colorToken(forRaw raw: String?) -> String {
        colorToken(forCanonicalId: canonicalId(forRaw: raw))
    }
}

nonisolated enum PinColorTokenContract {
    static let hexByToken: [String: UInt32] = [
        "red": 0xFF3B30, "orange": 0xFF9500, "yellow": 0xFFCC00,
        "green": 0x34C759, "darkgreen": 0x1B7F3B, "mint": 0x00C7BE,
        "teal": 0x30B0C7, "cyan": 0x32ADE6, "blue": 0x007AFF,
        "indigo": 0x5856D6, "purple": 0xAF52DE, "pink": 0xFF2D55,
        "brown": 0xA2845E, "gray": 0x8E8E93, "black": 0x000000,
        "white": 0xFFFFFF,
    ]

    static func normalized(_ token: String?) -> String? {
        guard var value = token?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        if value == "grey" { value = "gray" }
        return hexByToken[value] == nil ? nil : value
    }
}

nonisolated enum PinColorResolver {
    static func token(for pin: VinePin, repairButtons: [ButtonConfig], growthButtons: [ButtonConfig]) -> String {
        if pin.mode == .manualIssue { return PinColorTokenContract.normalized(pin.buttonColor) ?? "orange" }
        let buttons = (pin.mode == .growth ? growthButtons : repairButtons)
            .filter { $0.vineyardId == pin.vineyardId && $0.mode == pin.mode }
        if let stableID = pin.launcherButtonId,
           let match = buttons.first(where: { $0.id == stableID }),
           let color = PinColorTokenContract.normalized(match.color) { return color }
        let canonical = PinCategoryCatalog.canonicalId(forRaw: pin.buttonName)
        if let canonical,
           let match = buttons.first(where: { PinCategoryCatalog.canonicalId(forRaw: $0.name) == canonical }),
           let color = PinColorTokenContract.normalized(match.color) { return color }
        let normalizedName = pin.buttonName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedName.isEmpty,
           let match = buttons.first(where: {
               $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
           }), let color = PinColorTokenContract.normalized(match.color) { return color }
        if let stored = PinColorTokenContract.normalized(pin.buttonColor) { return stored }
        if pin.mode == .repairs { return PinCategoryCatalog.colorToken(forCanonicalId: canonical) }
        return pin.mode == .growth ? "darkgreen" : "gray"
    }
}

extension VinePin {
    /// Legacy fallback for contexts that genuinely have no vineyard config.
    var displayColorToken: String {
        PinColorResolver.token(for: self, repairButtons: [], growthButtons: [])
    }

    /// Human label shown for pins whose category/name never synced — keeps
    /// historical records visible (as "Unassigned") instead of a blank row.
    var displayNameOrUnassigned: String {
        buttonName.isEmpty ? "Unassigned" : buttonName
    }
}
