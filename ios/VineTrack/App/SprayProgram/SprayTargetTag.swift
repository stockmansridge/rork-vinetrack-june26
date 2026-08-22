import Foundation

/// ONE selected spray target — a built-in VineTrack target or a vineyard's own.
///
/// # Why a tag rather than a string or an enum case
///
/// The Program Step target used to be a punctuation-delimited sentence the
/// operator maintained by hand ("Eutypa Dieback · Botryosphaeria Dieback"),
/// which is unselectable, unsearchable and un-reusable. Narrowing it to
/// `SprayTarget` instead would have been worse: the enum has six cases and a
/// vineyard routinely sprays for Phomopsis, Black Spot, Eutypa or Light Brown
/// Apple Moth, none of which VineTrack has a word for. Deleting those from a
/// step that is genuinely for them is not an acceptable trade for tidiness.
///
/// So a tag carries BOTH halves:
///
///   * `identifier` — the stable machine value that goes into the
///     `spray_jobs.targets` / `spray_records.targets` `text[]` columns
///     (sql/193). Built-ins use their `SprayTarget.rawValue`; a custom target
///     uses a deterministic slug of its wording. This is what the Resistance
///     Planner's `targets && array[...]` containment query matches on, which
///     is exactly why the wording must never be the stored value.
///   * `label` — what the operator actually wrote, verbatim.
///
/// sql/193 deliberately put NO value CHECK on those columns ("the target
/// vocabulary is expected to expand often and per-region"), so custom targets
/// need no migration to store — the contract was written for them.
nonisolated struct SprayTargetTag: Sendable, Hashable, Identifiable, Codable {
    /// Stable machine identifier. Never displayed.
    let identifier: String
    /// Display wording. Verbatim for a custom target.
    let label: String

    nonisolated var id: String { identifier }

    /// The typed target this tag IS, when VineTrack has a case for it.
    var builtIn: SprayTarget? { SprayTarget(rawValue: identifier) }

    /// True for a vineyard-created target the calculator has no typed case for.
    var isCustom: Bool { builtIn == nil }

    init(identifier: String, label: String) {
        self.identifier = identifier
        self.label = label
    }

    init(_ target: SprayTarget) {
        self.identifier = target.rawValue
        self.label = target.label
    }
}

/// The rules for turning target WORDING into stable identifiers and back.
///
/// Pure, so every rule here — slugging, de-duplication, legacy splitting,
/// display projection — is provable without a store, a network or a view.
nonisolated enum SprayTargetVocabulary {

    // MARK: - Identifiers

    /// The stable identifier for a piece of target wording, or `nil` when the
    /// wording carries no usable characters.
    ///
    /// Deterministic and case-insensitive, which is what makes de-duplication
    /// work: "Eutypa Dieback", "eutypa dieback" and "  EUTYPA   DIEBACK  " all
    /// slug to `eutypa_dieback`, so a vineyard cannot end up with three tags
    /// that mean one thing.
    static func identifier(for wording: String) -> String? {
        let lowered = wording.lowercased()
        var out = ""
        var pendingSeparator = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                if pendingSeparator, !out.isEmpty { out.append("_") }
                pendingSeparator = false
                out.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Build a tag from operator-entered wording.
    ///
    /// Wording that names a target VineTrack already knows resolves to the
    /// BUILT-IN tag rather than creating a near-duplicate custom one — typing
    /// "powdery mildew" by hand must not produce a second Powdery Mildew that
    /// the calculator then fails to recognise.
    ///
    /// Returns `nil` for wording that is empty or has no letters/digits.
    static func tag(wording: String) -> SprayTargetTag? {
        let trimmed = wording.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let identifier = identifier(for: trimmed) else { return nil }
        if let builtIn = SprayTarget(rawValue: identifier) ?? SprayTarget.from(trimmed) {
            return SprayTargetTag(builtIn)
        }
        return SprayTargetTag(identifier: identifier, label: trimmed)
    }

    /// The tag for a stored identifier.
    ///
    /// `labels` is the vineyard's target library (identifier -> wording), the
    /// authoritative source for how a custom target is written. When it has no
    /// entry — a library row that has not synced yet — the identifier is
    /// de-slugged so the operator still reads "Eutypa Dieback" rather than a
    /// raw `eutypa_dieback`. A readable approximation beats a database value on
    /// screen, and the library corrects it as soon as it arrives.
    static func tag(identifier: String, labels: [String: String] = [:]) -> SprayTargetTag? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let builtIn = SprayTarget(rawValue: trimmed) { return SprayTargetTag(builtIn) }
        let label = labels[trimmed] ?? deslugged(trimmed)
        return SprayTargetTag(identifier: trimmed, label: label)
    }

    /// `eutypa_dieback` -> `Eutypa Dieback`.
    static func deslugged(_ identifier: String) -> String {
        identifier
            .split(separator: "_")
            .map { part -> String in
                guard let first = part.first else { return "" }
                return String(first).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    // MARK: - Legacy wording

    /// Separators an existing free-text target line may have used.
    ///
    /// Deliberately CONSERVATIVE. `/`, `&`, `+` and the word "and" are NOT
    /// separators here, because "Nutrition / Biostimulant" is a single target's
    /// own name and splitting it would invent two targets that do not exist.
    /// Losing a split is recoverable by the operator; inventing one silently
    /// changes what the step says it is for.
    private static let wordingSeparators = CharacterSet(charactersIn: ",;\u{00B7}\u{2022}\n")

    /// Split an existing target line into individual wordings, trimmed and
    /// de-duplicated case-insensitively.
    static func wordings(from raw: String?) -> [String] {
        guard let raw else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for part in raw.components(separatedBy: wordingSeparators) {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let key = identifier(for: trimmed) else { continue }
            if seen.insert(key).inserted { out.append(trimmed) }
        }
        return out
    }

    // MARK: - Loading a step's selection

    /// Resolve a Program Step's stored target state into ordered tags.
    ///
    /// - Parameters:
    ///   - identifiers: the structured `targets` values. The SOURCE OF TRUTH
    ///     for *which* targets are selected whenever it is non-empty.
    ///   - wording: the legacy free-text target line. Two jobs: it supplies the
    ///     verbatim WORDING for identifiers that have one (so
    ///     "Light Brown Apple Moth (LBAM)" survives a round trip through its
    ///     slug), and it is the whole selection for a step written before this
    ///     feature, which has no `targets` at all.
    ///   - labels: the vineyard target library.
    ///
    /// The fallback is what preserves existing data: a step that only ever had
    /// "Eutypa Dieback, Botryosphaeria Dieback" loads as two tags, not as one
    /// unparsed sentence and not as nothing.
    static func tags(
        identifiers: [String],
        wording: String?,
        labels: [String: String] = [:]
    ) -> [SprayTargetTag] {
        let parsedWordings = wordings(from: wording)
        var wordingByIdentifier: [String: String] = [:]
        for text in parsedWordings {
            guard let key = identifier(for: text) else { continue }
            wordingByIdentifier[key] = text
        }

        guard !identifiers.isEmpty else {
            return normalised(parsedWordings.compactMap { tag(wording: $0) })
        }

        let resolved = identifiers.compactMap { raw -> SprayTargetTag? in
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            if let builtIn = SprayTarget(rawValue: key) { return SprayTargetTag(builtIn) }
            // The step's own wording wins over the library: it is what this
            // step said, and it is the only place a bracket or a slash in a
            // custom name survives the slug.
            if let text = wordingByIdentifier[key] { return SprayTargetTag(identifier: key, label: text) }
            return tag(identifier: key, labels: labels)
        }
        return normalised(resolved)
    }

    // MARK: - Normalisation

    /// De-duplicate by identifier and put the selection in a stable order:
    /// built-ins first in `SprayTarget.presentationOrder`, then custom targets
    /// in the order they were added.
    ///
    /// Stable ordering is not cosmetic — it means two operators who tapped the
    /// same targets in a different sequence write the same array, so a diff
    /// between the portal and mobile is a real change rather than a reshuffle.
    static func normalised(_ tags: [SprayTargetTag]) -> [SprayTargetTag] {
        var seen = Set<String>()
        var unique: [SprayTargetTag] = []
        for tag in tags where seen.insert(tag.identifier).inserted {
            unique.append(tag)
        }
        let builtIns = SprayTarget.presentationOrder.compactMap { target in
            unique.first { $0.identifier == target.rawValue }
        }
        let customs = unique.filter(\.isCustom)
        return builtIns + customs
    }

    // MARK: - Projections

    /// The identifiers to store, in normalised order.
    static func identifiers(_ tags: [SprayTargetTag]) -> [String] {
        normalised(tags).map(\.identifier)
    }

    /// The typed targets the calculator understands. Custom tags contribute
    /// nothing rather than being forced onto a target they are not.
    static func builtIns(_ tags: [SprayTargetTag]) -> [SprayTarget] {
        normalised(tags).compactMap(\.builtIn)
    }

    /// The custom tags, which travel as wording because there is no typed case
    /// to carry them.
    static func customs(_ tags: [SprayTargetTag]) -> [SprayTargetTag] {
        normalised(tags).filter(\.isCustom)
    }

    /// The display line written back to the legacy free-text `target` column.
    ///
    /// A COMPATIBILITY PROJECTION, not the source of truth: existing portal and
    /// report readers still read that column, and it is also how a custom
    /// target's exact wording reaches a client whose library has not synced.
    /// `targets` remains what "which targets" means.
    static func displayString(_ tags: [SprayTargetTag]) -> String? {
        let normalised = normalised(tags)
        guard !normalised.isEmpty else { return nil }
        return normalised.map(\.label).joined(separator: " \u{00B7} ")
    }
}
