import Foundation

/// Canonical pin-category colour contract, shared verbatim with Android
/// (`PinCategoryCatalog.kt`). Pin colours are derived deterministically from
/// the pin's *stable category id* — never from the vineyard's editable button
/// configuration, a translated/display label comparison, or an arbitrary
/// colour token stored on the row. This guarantees two pins of the same
/// category always render identically on every device and platform.
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

extension VinePin {
    /// The colour token every display surface should render this pin with.
    ///
    /// Repairs pins follow the canonical category contract (deterministic
    /// from the stable category id, Android parity); growth observations keep
    /// their observation accent (stored colour → dark green) and manual
    /// issues keep the amber accent. Unknown/missing categories render as
    /// the neutral unassigned gray.
    var displayColorToken: String {
        switch mode {
        case .manualIssue:
            return "orange"
        case .growth:
            return buttonColor.isEmpty ? "darkgreen" : buttonColor
        case .repairs:
            return PinCategoryCatalog.colorToken(forRaw: buttonName.isEmpty ? nil : buttonName)
        }
    }

    /// Human label shown for pins whose category/name never synced — keeps
    /// historical records visible (as "Unassigned") instead of a blank row.
    var displayNameOrUnassigned: String {
        buttonName.isEmpty ? "Unassigned" : buttonName
    }
}
