import Foundation

/// Which resistance-classification scheme an activity group code belongs to.
///
/// A bare code like `"3"` is ambiguous on its own — FRAC 3 (DMI fungicides)
/// and IRAC 3 (sodium channel modulators) are unrelated chemistries. The
/// scheme travels with the code so the future Resistance Engine can never
/// compare a fungicide group against an insecticide group.
nonisolated enum ChemicalActivityGroupScheme: String, Codable, Sendable, CaseIterable, Hashable {
    /// Fungicide Resistance Action Committee.
    case frac
    /// Herbicide Resistance Action Committee.
    case hrac
    /// Insecticide Resistance Action Committee.
    case irac
    /// The product has no resistance classification by design — adjuvants,
    /// surfactants, straight fertilisers, biostimulants. Distinct from
    /// "we don't know yet", which is simply the absence of a group.
    case notApplicable = "not_applicable"

    nonisolated var label: String {
        switch self {
        case .frac: return "FRAC"
        case .hrac: return "HRAC"
        case .irac: return "IRAC"
        case .notApplicable: return "Not applicable"
        }
    }

    /// The scheme implied by a product category, used only as a hint when an
    /// authoritative source states a bare code without naming its scheme.
    static func implied(byProductCategory category: String) -> ChemicalActivityGroupScheme? {
        switch category.lowercased() {
        case "fungicide": return .frac
        case "herbicide": return .hrac
        case "insecticide", "miticide", "acaricide", "nematicide": return .irac
        case "adjuvant", "surfactant", "wetter", "foliarnutrient",
             "granularfertiliser", "liquidfertiliser", "fertigation",
             "seaweed", "humicfulvic", "biostimulant":
            return .notApplicable
        default: return nil
        }
    }
}

/// A single resistance/activity group: a scheme plus its code.
///
/// This is the machine-readable unit the Resistance Engine will consume. It
/// deliberately has no free-text field — a display string like
/// `"11 (QoI / Strobilurin)"` is built for the UI on demand and is never the
/// stored source of truth.
nonisolated struct ChemicalActivityGroup: Codable, Sendable, Hashable, Identifiable, Comparable {
    /// The classification scheme this code belongs to.
    let scheme: ChemicalActivityGroupScheme
    /// The normalised code, e.g. `"3"`, `"11"`, `"M5"`, `"4A"`, `"G"`.
    /// Upper-cased and stripped of the word "Group" and any trailing name.
    let code: String
    /// Optional human name for the chemistry, e.g. `"QoI / Strobilurin"`.
    /// Display sugar only — never parsed, never compared.
    let commonName: String?

    nonisolated var id: String { "\(scheme.rawValue):\(code)" }

    init(scheme: ChemicalActivityGroupScheme, code: String, commonName: String? = nil) {
        self.scheme = scheme
        self.code = ChemicalActivityGroup.normaliseCode(code)
        let trimmed = commonName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.commonName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case scheme, code, commonName = "common_name"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawScheme = try c.decodeIfPresent(String.self, forKey: .scheme) ?? ""
        // An unrecognised scheme from a newer build must not fail the whole
        // chemical — degrade to FRAC only when the code shape says fungicide,
        // otherwise treat the group as unusable by dropping to notApplicable.
        scheme = ChemicalActivityGroupScheme(rawValue: rawScheme) ?? .notApplicable
        code = ChemicalActivityGroup.normaliseCode(try c.decodeIfPresent(String.self, forKey: .code) ?? "")
        let name = try c.decodeIfPresent(String.self, forKey: .commonName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        commonName = (name?.isEmpty ?? true) ? nil : name
    }

    /// `"FRAC 11"` — for display only.
    nonisolated var displayLabel: String {
        guard scheme != .notApplicable else { return "No resistance group" }
        if let commonName { return "\(scheme.label) \(code) (\(commonName))" }
        return "\(scheme.label) \(code)"
    }

    /// `"11"` — the bare code, for compact chips.
    nonisolated var shortLabel: String { code }

    /// A group is usable by the Resistance Engine only when it names a real
    /// scheme and carries a code.
    nonisolated var isResistanceRelevant: Bool {
        scheme != .notApplicable && !code.isEmpty
    }

    /// Ordering for stable presentation and stable persistence: scheme first,
    /// then numeric prefix, then the full code. `3` sorts before `11`, and
    /// `11` before `M5`, regardless of the order the operator entered them.
    nonisolated static func < (lhs: ChemicalActivityGroup, rhs: ChemicalActivityGroup) -> Bool {
        if lhs.scheme != rhs.scheme {
            return lhs.scheme.rawValue < rhs.scheme.rawValue
        }
        let l = lhs.numericPrefix
        let r = rhs.numericPrefix
        if l != r {
            // Codes without a numeric prefix (M5, G) sort after numbered ones.
            return (l ?? Int.max) < (r ?? Int.max)
        }
        return lhs.code < rhs.code
    }

    private var numericPrefix: Int? {
        let digits = code.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: - Normalisation

    /// Strips the noise humans and AI put around a code so `"Group 3"`,
    /// `"group3"`, `" 3 "` and `"3"` all become `"3"`.
    static func normaliseCode(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for prefix in ["GROUP ", "GROUP", "FRAC ", "HRAC ", "IRAC ", "MOA ", "CODE "] {
            if value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Drop a trailing parenthetical name: "11 (QoI)" -> "11".
        if let paren = value.firstIndex(of: "(") {
            value = String(value[value.startIndex..<paren])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Legacy text

    /// Best-effort reading of a legacy free-text `chemical_group` value such as
    /// `"3 + 11"`, `"11 (QoI / Strobilurin)"` or `"Group 3/11"`.
    ///
    /// The result is explicitly a CANDIDATE, never authoritative. A chemical
    /// whose groups came only from this parser stays `.unverified` — the whole
    /// point of Chemical Intelligence is that resistance decisions never rest
    /// on a string somebody typed. Use it to seed the audit and to pre-fill the
    /// verification screen, nothing more.
    static func parseLegacyText(
        _ raw: String,
        assumedScheme: ChemicalActivityGroupScheme?
    ) -> [ChemicalActivityGroup] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let scheme = assumedScheme, scheme != .notApplicable else {
            return []
        }
        // Split on the separators people actually use between mixed groups.
        let separators = CharacterSet(charactersIn: "+/,&;")
        let parts = trimmed.components(separatedBy: separators)
        var seen = Set<String>()
        var out: [ChemicalActivityGroup] = []
        for part in parts {
            let code = normaliseCode(part)
            guard isPlausibleCode(code), seen.insert(code).inserted else { continue }
            out.append(ChemicalActivityGroup(scheme: scheme, code: code))
        }
        return out
    }

    /// A code is plausible when it looks like a resistance code rather than a
    /// chemistry name. `"3"`, `"11"`, `"M5"`, `"4A"` and `"G"` pass;
    /// `"STROBILURIN"` and `"BIOSTIMULANT - AMINO ACID"` do not, so a legacy
    /// value that only ever held a chemistry name yields no false groups.
    static func isPlausibleCode(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= 4 else { return false }
        guard code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        // Pure letters are only plausible as single-letter HRAC codes (A-Z).
        if code.allSatisfy({ $0.isLetter }) { return code.count == 1 }
        return code.contains(where: { $0.isNumber })
    }
}

extension Array where Element == ChemicalActivityGroup {
    /// De-duplicated, deterministically ordered groups.
    ///
    /// This is the collection the Resistance Engine reads. A two-active mix of
    /// FRAC 3 and FRAC 11 always yields `["3", "11"]` in that order, whichever
    /// order the actives were entered, so two identical products never persist
    /// as two different-looking histories.
    var canonicalised: [ChemicalActivityGroup] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }.sorted()
    }

    /// Bare codes for storage in a queryable `text[]` column, e.g. `["3", "11"]`.
    ///
    /// NEVER `["3 + 11"]`. A mixture counts as every one of its groups
    /// independently.
    var codes: [String] {
        canonicalised.filter(\.isResistanceRelevant).map(\.code)
    }

    /// Scheme-qualified identifiers, e.g. `["frac:3", "frac:11"]`, for cases
    /// where the bare code would be ambiguous across schemes.
    var qualifiedCodes: [String] {
        canonicalised.filter(\.isResistanceRelevant).map(\.id)
    }

    /// The legacy `chemical_group` display projection, e.g. `"3 + 11"`.
    ///
    /// Derived FROM the structured groups for backwards compatibility with old
    /// app builds and the existing API surface. It is an output, never an
    /// input: nothing in VineTrack may calculate from this string.
    var legacyGroupProjection: String {
        codes.joined(separator: " + ")
    }
}
