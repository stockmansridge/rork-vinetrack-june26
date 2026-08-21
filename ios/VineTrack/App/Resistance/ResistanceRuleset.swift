import Foundation

/// The versioned, data-driven representation of a published resistance-management
/// strategy.
///
/// Nothing in this file contains a published number. The numbers live in
/// `ResistanceRulesets`, which encodes a specific dated strategy from a specific
/// issuing body. That separation is the point: CropLife Australia reissues its
/// strategies annually, and a 2027 revision must be introducible as new DATA
/// rather than as a rewrite of the evaluation architecture.
///
/// Mirrors `ResistanceRuleset.kt` on Android.

// MARK: - Jurisdiction / crop / disease

/// The jurisdiction whose resistance strategy applies.
///
/// Resolved from the VINEYARD's stored country, never the phone locale — an
/// Australian operator can legitimately manage a New Zealand vineyard, and the
/// Australian maximum-use rules must not follow the phone across the Tasman.
nonisolated enum ResistanceJurisdiction: String, Codable, Sendable, Hashable, CaseIterable {
    case australia = "AU"
    case newZealand = "NZ"
    /// Country absent or unrecognised. Never receives a strategy by default.
    case unknown

    nonisolated var label: String {
        switch self {
        case .australia: return "Australia"
        case .newZealand: return "New Zealand"
        case .unknown: return "Unknown"
        }
    }

    /// Maps a stored vineyard country value onto a jurisdiction.
    nonisolated static func fromCountryCode(_ code: String?) -> ResistanceJurisdiction {
        let trimmed = (code ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.isEmpty { return .unknown }
        switch trimmed {
        case "AU", "AUS", "AUSTRALIA": return .australia
        case "NZ", "NZL", "NEW ZEALAND", "AOTEAROA": return .newZealand
        default: return .unknown
        }
    }
}

/// The crop a strategy is written for.
nonisolated enum ResistanceCrop: String, Codable, Sendable, Hashable, CaseIterable {
    case grape

    nonisolated var label: String { "Grape" }
}

/// A disease carrying its own strategy and therefore its own independent history.
///
/// `sprayTargetRaw` ties the disease to the persisted `spray_records.targets`
/// vocabulary (sql/193), so disease attribution comes from what the operator
/// declared the spray was FOR — never from the chemistry in the tank.
nonisolated enum ResistanceDisease: String, Codable, Sendable, Hashable, CaseIterable {
    case powderyMildew = "powdery_mildew"
    case downyMildew = "downy_mildew"

    nonisolated var label: String {
        switch self {
        case .powderyMildew: return "Powdery Mildew"
        case .downyMildew: return "Downy Mildew"
        }
    }

    nonisolated var sprayTargetRaw: String { rawValue }

    nonisolated static func fromSprayTargetRaw(_ raw: String?) -> ResistanceDisease? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        return ResistanceDisease(rawValue: trimmed)
    }
}

// MARK: - Group codes and signatures

/// Canonicalisation for activity group codes.
///
/// Free-text codes reach this engine from Chemical Intelligence, where they are
/// deliberately not constrained to a hard-coded list. Here they must be
/// comparable, without inventing groups nobody recorded.
nonisolated enum ResistanceGroupCode {
    /// FRAC renumbered several legacy "U" codes. CropLife still prints the legacy
    /// code alongside the number (`"Group 50 (U8)"`) and labels use either, so both
    /// must resolve to one key or a rotation can look compliant purely because two
    /// spellings never met.
    private static let aliases: [String: String] = ["U8": "50"]

    private static let schemePrefixes: [(String, ChemicalActivityGroupScheme)] = [
        ("FRAC", .frac), ("HRAC", .hrac), ("IRAC", .irac),
    ]

    /// Canonical form of a raw code, KEEPING the scheme when one was stated.
    ///
    /// `"HRAC 9"` normalises to `"HRAC:9"`, never to `"9"`. Discarding the scheme —
    /// which this used to do for every prefix it recognised — made HRAC 9
    /// (glyphosate) indistinguishable from FRAC 9 (anilinopyrimidines), so a
    /// herbicide line on a spray recorded against powdery mildew could consume a
    /// real anilinopyrimidine allowance and, worse, satisfy an alternation rule
    /// with chemistry that has no fungicidal activity at all.
    ///
    /// A code with NO stated scheme stays bare. That is an honest unknown and is
    /// resolved later against the ruleset doing the reading — see
    /// `ResistanceGroupSignature.projected(into:)`.
    nonisolated static func normalize(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !text.isEmpty else { return nil }
        var scheme: ChemicalActivityGroupScheme?
        for (prefix, candidate) in schemePrefixes where text.hasPrefix(prefix) {
            scheme = candidate
            text = String(text.dropFirst(prefix.count))
            break
        }
        if text.hasPrefix("GROUP") { text = String(text.dropFirst("GROUP".count)) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).trimmingCharacters(in: .whitespaces)
        // "50 (U8)" -> "50"
        if let open = text.firstIndex(of: "(") {
            text = String(text[text.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        }
        if text.isEmpty { return nil }
        let bare = aliases[text] ?? text
        guard let scheme else { return bare }
        return "\(scheme.rawValue.uppercased()):\(bare)"
    }

    /// The scheme a canonical code states, or nil when it states none.
    nonisolated static func scheme(of code: String) -> ChemicalActivityGroupScheme? {
        guard let separator = code.firstIndex(of: ":") else { return nil }
        return ChemicalActivityGroupScheme(
            rawValue: String(code[code.startIndex..<separator]).lowercased()
        )
    }

    /// The code without its scheme: `"HRAC:9"` -> `"9"`.
    nonisolated static func bare(_ code: String) -> String {
        guard let separator = code.firstIndex(of: ":") else { return code }
        return String(code[code.index(after: separator)...])
    }

    /// Numeric groups ascending, then alphanumeric codes (`U6`) after them, so a
    /// signature's key is stable regardless of the order products were recorded.
    /// Codes sharing a number sort by their scheme, keeping FRAC 3 and IRAC 3
    /// adjacent but distinct.
    nonisolated static func isOrderedBefore(_ lhs: String, _ rhs: String) -> Bool {
        let leftBare = bare(lhs)
        let rightBare = bare(rhs)
        if leftBare == rightBare { return lhs < rhs }
        let left = Int(leftBare)
        let right = Int(rightBare)
        switch (left, right) {
        case let (l?, r?): return l < r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return leftBare < rightBare
        }
    }
}

/// The set of activity groups carried by ONE product.
///
/// A co-formulated product with two actives has a signature of two codes. CropLife
/// gives certain co-formulations their own rule — Group `5+3` is restricted
/// differently from Group 5 and Group 3 — so the engine must know not just WHICH
/// groups were applied but which arrived in the same product.
nonisolated struct ResistanceGroupSignature: Codable, Sendable, Hashable {
    nonisolated var codes: [String]

    nonisolated init(codes: [String]) { self.codes = codes }

    /// Canonical key, e.g. `"3+11"`. Always ascending, never display order.
    nonisolated var key: String { codes.joined(separator: "+") }

    nonisolated var isCoformulation: Bool { codes.count > 1 }

    nonisolated func contains(_ code: String) -> Bool { codes.contains(code) }

    nonisolated static let empty = ResistanceGroupSignature(codes: [])

    nonisolated static func of(_ raw: [String]) -> ResistanceGroupSignature {
        var seen: Set<String> = []
        var result: [String] = []
        for value in raw {
            guard let code = ResistanceGroupCode.normalize(value), !seen.contains(code) else { continue }
            seen.insert(code)
            result.append(code)
        }
        // "3" and "FRAC:3" are one chemistry stated with and without its scheme.
        // Keeping both would fabricate a co-formulation out of a single active, so
        // the qualified form — the one carrying more information — absorbs the bare
        // one. "FRAC:3" and "IRAC:3" are NOT the same and both survive.
        let qualifiedBareCodes = Set(
            result
                .filter { ResistanceGroupCode.scheme(of: $0) != nil }
                .map { ResistanceGroupCode.bare($0) }
        )
        result.removeAll {
            ResistanceGroupCode.scheme(of: $0) == nil && qualifiedBareCodes.contains($0)
        }
        return ResistanceGroupSignature(codes: result.sorted(by: ResistanceGroupCode.isOrderedBefore))
    }

    nonisolated static func of(_ raw: String...) -> ResistanceGroupSignature { of(raw) }

    /// Scheme-qualified signature built from STRUCTURED Chemical Intelligence.
    ///
    /// This is the authoritative path: each group arrives with its own scheme
    /// recorded, so nothing has to be assumed from the product's category or from
    /// whichever ruleset happens to be reading it. Groups the classification marks
    /// as not resistance-relevant (adjuvants, straight nutrition) are excluded
    /// rather than stored as an empty code.
    nonisolated static func of(structured groups: [ChemicalActivityGroup]) -> ResistanceGroupSignature {
        of(
            groups
                .filter(\.isResistanceRelevant)
                .map { "\($0.scheme.rawValue.uppercased()):\($0.code)" }
        )
    }

    /// This signature as one classification scheme sees it.
    ///
    /// Codes stating a DIFFERENT scheme are dropped: HRAC 9 is not a FRAC 9 spray
    /// and must never consume a FRAC 9 allowance, nor count as the alternative
    /// mode of action that a FRAC rule demands.
    ///
    /// Codes matching the scheme are reduced to their bare form so published rules —
    /// written in one scheme's numbering — compare directly.
    ///
    /// Codes with NO stated scheme are KEPT. Legitimate VineTrack history stored
    /// bare codes long before schemes were recorded, and discarding those would
    /// shrink a rotation count, which is the one direction of error that
    /// manufactures a clean result. Counting a possible match is the safe way to
    /// be wrong; missing a real one is not.
    nonisolated func projected(into scheme: ChemicalActivityGroupScheme) -> ResistanceGroupSignature {
        var seen: Set<String> = []
        var result: [String] = []
        for code in codes {
            let codeScheme = ResistanceGroupCode.scheme(of: code)
            guard codeScheme == nil || codeScheme == scheme else { continue }
            let bare = ResistanceGroupCode.bare(code)
            if seen.insert(bare).inserted { result.append(bare) }
        }
        return ResistanceGroupSignature(codes: result.sorted(by: ResistanceGroupCode.isOrderedBefore))
    }
}

// MARK: - Selectors

/// What an application must contain for a rule to count it.
///
/// Published strategies address groups in several distinct shapes, and flattening
/// them loses meaning:
/// - `"Group 11 (inc. 11 + 3)"` — any application containing group 11. `.containsGroup`.
/// - `"Group 5+3"` — specifically the co-formulated product. `.coformulation`.
/// - `"Group 5+3, 7+12"` — one shared table column. `.anyCoformulation`.
/// - `"Group 3, 5, 13, ..."` — one sentence, many groups, each needing its own
///   stable rule ID, so it expands to separate rules rather than one `.anyGroup`.
nonisolated enum ResistanceGroupSelector: Codable, Sendable, Hashable {
    case containsGroup(String)
    case coformulation(ResistanceGroupSignature)
    case anyCoformulation([ResistanceGroupSignature])
    case anyGroup([String])

    /// Group codes this selector is about, for result reporting.
    nonisolated var describedGroups: [String] {
        switch self {
        case .containsGroup(let code): return [code]
        case .coformulation(let signature): return signature.codes
        case .anyCoformulation(let signatures):
            var seen: Set<String> = []
            var result: [String] = []
            for signature in signatures {
                for code in signature.codes where !seen.contains(code) {
                    seen.insert(code)
                    result.append(code)
                }
            }
            return result.sorted(by: ResistanceGroupCode.isOrderedBefore)
        case .anyGroup(let codes): return codes
        }
    }

    /// Stable text used in the ruleset fingerprint.
    nonisolated var fingerprint: String {
        switch self {
        case .containsGroup(let code): return "contains:\(code)"
        case .coformulation(let signature): return "coformulation:\(signature.key)"
        case .anyCoformulation(let signatures):
            return "anyCoformulation:" + signatures.map(\.key).sorted().joined(separator: ",")
        case .anyGroup(let codes): return "anyGroup:" + codes.sorted().joined(separator: ",")
        }
    }

    nonisolated func matches(_ event: ResistanceApplicationEvent) -> Bool {
        switch self {
        case .containsGroup(let code):
            return event.componentGroups.contains(code)
        case .coformulation(let signature):
            return event.coformulationSignatures.contains { $0.key == signature.key }
        case .anyCoformulation(let signatures):
            let keys = Set(signatures.map(\.key))
            return event.coformulationSignatures.contains { keys.contains($0.key) }
        case .anyGroup(let codes):
            return codes.contains { event.componentGroups.contains($0) }
        }
    }
}

// MARK: - Rule kinds

/// The kinds of restriction a published strategy can express.
///
/// A closed set of DATA-shaped cases rather than code branches, so a new strategy
/// revision changes numbers and rule lists, not the engine.
nonisolated enum ResistanceRuleKind: Codable, Sendable, Hashable {
    /// "Do not apply more than N consecutive sprays of ...".
    case maxConsecutiveApplications(Int)

    /// "Do not apply Group 11 consecutively." Semantically a limit of 1, kept
    /// distinct because the published sentence is a prohibition, not a ceiling.
    case noConsecutiveApplications

    /// "Apply a maximum of N sprays per season of ...".
    case maxApplicationsPerSeason(Int)

    /// "Do not apply more than N ... per crop." CropLife uses "per crop" for the
    /// Powdery Group 21 ceiling; named separately to keep the wording traceable.
    case maxApplicationsPerCrop(Int)

    /// "... a maximum of 33% of total applications."
    ///
    /// Held as an exact rational, never a rounded percentage, so 2-of-6 compares as
    /// 2×3 ≤ 6×1 rather than as "33.33% ≤ 33%".
    case maxFractionOfDiseaseSprays(numerator: Int, denominator: Int)

    /// "Only apply ... a maximum of one in every three sprays."
    ///
    /// NOT the same as a 33% cap: this is spacing. 2 of 6 satisfies 33% but
    /// violates one-in-three if both fall inside the same window of three.
    case maxOneInEveryNSprays(Int)

    /// "... must be followed by at least N applications of a different group(s)."
    case minInterveningDifferentGroupApplications(Int)

    /// "Always apply ... in mixtures" / "only in mixtures with effective fungicides
    /// applied at an effective rate from a different cross resistance group."
    case mixtureRequired

    /// A mixture required only when the application is consecutive with another of
    /// the same selector — CropLife's Powdery Group 7 and 11 handling.
    case mixtureRequiredWhenConsecutive

    /// "Max. number of solo sprays: 2" — a ceiling applying only to applications
    /// carrying no alternative mode of action.
    case maxSoloApplicationsPerSeason(Int)

    /// "Do not apply a spray containing Group 40 as the last spray of the season."
    case notLastSprayOfSeason

    /// The maximum varies with the total number of disease-targeting sprays —
    /// CropLife's Powdery table.
    case maxFromTotalSprayCountTable(columnKey: String)

    /// Non-numeric published guidance, e.g. "apply all these preventatively".
    case preventativeApplicationGuidance

    nonisolated var fingerprint: String {
        switch self {
        case .maxConsecutiveApplications(let limit): return "maxConsecutive:\(limit)"
        case .noConsecutiveApplications: return "noConsecutive"
        case .maxApplicationsPerSeason(let limit): return "maxPerSeason:\(limit)"
        case .maxApplicationsPerCrop(let limit): return "maxPerCrop:\(limit)"
        case .maxFractionOfDiseaseSprays(let numerator, let denominator):
            return "maxFraction:\(numerator)/\(denominator)"
        case .maxOneInEveryNSprays(let window): return "oneInEvery:\(window)"
        case .minInterveningDifferentGroupApplications(let count): return "minIntervening:\(count)"
        case .mixtureRequired: return "mixtureRequired"
        case .mixtureRequiredWhenConsecutive: return "mixtureRequiredWhenConsecutive"
        case .maxSoloApplicationsPerSeason(let limit): return "maxSoloPerSeason:\(limit)"
        case .notLastSprayOfSeason: return "notLastSprayOfSeason"
        case .maxFromTotalSprayCountTable(let columnKey): return "maxFromTable:\(columnKey)"
        case .preventativeApplicationGuidance: return "preventativeGuidance"
        }
    }
}

// MARK: - Rules

/// One published restriction, addressable by a stable ID.
///
/// `id` must survive rewording. It ends up stored in plans and warnings, so a
/// later editorial change to `sourceText` must not orphan them.
nonisolated struct ResistanceRule: Codable, Sendable, Hashable {
    nonisolated var id: String
    nonisolated var selector: ResistanceGroupSelector
    nonisolated var kind: ResistanceRuleKind
    /// Which published clause this came from, e.g. `"Guideline 4"`.
    nonisolated var sourceReference: String
    /// The published sentence, verbatim, so a warning can always be justified.
    nonisolated var sourceText: String
    /// Whether the sequence continues across the season boundary.
    ///
    /// CropLife's Powdery strategy states that consecutive applications include
    /// from the end of one season to the start of the next, so two at the end of
    /// last season plus one now is a run of three.
    nonisolated var crossSeason: Bool

    nonisolated init(
        id: String,
        selector: ResistanceGroupSelector,
        kind: ResistanceRuleKind,
        sourceReference: String,
        sourceText: String,
        crossSeason: Bool = false
    ) {
        self.id = id
        self.selector = selector
        self.kind = kind
        self.sourceReference = sourceReference
        self.sourceText = sourceText
        self.crossSeason = crossSeason
    }

    nonisolated var fingerprint: String {
        "\(id)|\(selector.fingerprint)|\(kind.fingerprint)|crossSeason=\(crossSeason)|\(sourceReference)"
    }
}

// MARK: - Maximum-use table

/// One column of a maximum-use table — a group or group set with its own ceiling.
nonisolated struct ResistanceMaxUseColumn: Codable, Sendable, Hashable {
    nonisolated var key: String
    nonisolated var displayName: String
    nonisolated var selector: ResistanceGroupSelector
}

/// One row: the ceiling for every column at a given total spray count.
///
/// `isOrMore` marks the open-ended final row (CropLife's `9+`).
nonisolated struct ResistanceMaxUseRow: Codable, Sendable, Hashable {
    nonisolated var totalSprays: Int
    nonisolated var isOrMore: Bool
    nonisolated var maxByColumn: [String: Int]
}

/// A published table relating total disease-targeting sprays to the maximum
/// permitted applications of each group.
///
/// Never flattened to a single maximum per group: at 3 total Powdery sprays Group 3
/// allows 2, and at 9 it allows 3. A flattened "3" would licence a rotation the
/// strategy forbids in a short season.
nonisolated struct ResistanceMaxUseTable: Codable, Sendable, Hashable {
    nonisolated var id: String
    nonisolated var rowKeyLabel: String
    nonisolated var columns: [ResistanceMaxUseColumn]
    nonisolated var rows: [ResistanceMaxUseRow]
    nonisolated var sourceReference: String
    nonisolated var notes: [String]

    nonisolated init(
        id: String,
        rowKeyLabel: String,
        columns: [ResistanceMaxUseColumn],
        rows: [ResistanceMaxUseRow],
        sourceReference: String,
        notes: [String] = []
    ) {
        self.id = id
        self.rowKeyLabel = rowKeyLabel
        self.columns = columns
        self.rows = rows
        self.sourceReference = sourceReference
        self.notes = notes
    }

    nonisolated func column(_ key: String) -> ResistanceMaxUseColumn? {
        columns.first { $0.key == key }
    }

    /// The ceiling for `columnKey` at `totalSprays`, or nil when the table cannot
    /// speak to that total. A total of 0 has no ceiling to breach.
    nonisolated func maxFor(_ columnKey: String, totalSprays: Int) -> Int? {
        guard totalSprays > 0 else { return nil }
        if let exact = rows.first(where: { !$0.isOrMore && $0.totalSprays == totalSprays }) {
            return exact.maxByColumn[columnKey]
        }
        if let openEnded = rows.first(where: { $0.isOrMore }), totalSprays >= openEnded.totalSprays {
            return openEnded.maxByColumn[columnKey]
        }
        if let smallest = rows.min(by: { $0.totalSprays < $1.totalSprays }),
           totalSprays < smallest.totalSprays {
            return smallest.maxByColumn[columnKey]
        }
        return nil
    }

    nonisolated var fingerprint: String {
        var text = "\(id)|\(rowKeyLabel)|"
        for column in columns.sorted(by: { $0.key < $1.key }) {
            text += "\(column.key)=\(column.selector.fingerprint);"
        }
        text += "|"
        for row in rows.sorted(by: { $0.totalSprays < $1.totalSprays }) {
            text += "\(row.totalSprays)\(row.isOrMore ? "+" : ""):"
            for key in row.maxByColumn.keys.sorted() {
                text += "\(key)=\(row.maxByColumn[key].map(String.init) ?? "null"),"
            }
            text += ";"
        }
        return text
    }
}

// MARK: - Group listing

/// A group the strategy covers, with the chemistry name the source prints.
nonisolated struct ResistanceGroupListing: Codable, Sendable, Hashable {
    nonisolated var displayName: String
    nonisolated var signature: ResistanceGroupSignature
    nonisolated var modeOfActionName: String
}

// MARK: - Ruleset

/// A complete, dated, attributable strategy for one jurisdiction/crop/disease.
///
/// The evaluation result records the ruleset that produced it. A warning that
/// cannot name its strategy and its date is not auditable, and resistance advice
/// that cannot be audited cannot be defended to a grower.
nonisolated struct ResistanceRuleset: Codable, Sendable, Hashable {
    nonisolated var id: String
    nonisolated var jurisdiction: ResistanceJurisdiction
    nonisolated var crop: ResistanceCrop
    nonisolated var disease: ResistanceDisease
    /// The classification scheme this strategy's group numbers are written in.
    ///
    /// Stated rather than implied so the engine can reject chemistry from another
    /// scheme instead of matching on the bare number. Every strategy VineTrack
    /// carries today is a fungicide strategy, hence the default — but "Group 9"
    /// means nothing until this says which body numbered it.
    nonisolated var scheme: ChemicalActivityGroupScheme = .frac
    nonisolated var strategyName: String
    nonisolated var sourceOrganisation: String
    /// Canonical public location of the strategy.
    nonisolated var sourceReference: String
    /// ISO date the published advice is valid as at, e.g. `"2026-07-22"`.
    nonisolated var validFrom: String
    nonisolated var validFromEpochMs: Int64
    nonisolated var rulesetVersion: String
    nonisolated var rules: [ResistanceRule]
    nonisolated var groups: [ResistanceGroupListing]
    nonisolated var maxUseTable: ResistanceMaxUseTable?
    /// ID of the ruleset that replaced this one; nil while current.
    nonisolated var supersededBy: String?
    /// ID of the ruleset this one replaced.
    nonisolated var supersedes: String?
    /// Ambiguities and judgement calls in the published source, recorded so they
    /// are visible to whoever maintains the next revision.
    nonisolated var sourceNotes: [String]

    nonisolated init(
        id: String,
        jurisdiction: ResistanceJurisdiction,
        crop: ResistanceCrop,
        disease: ResistanceDisease,
        scheme: ChemicalActivityGroupScheme = .frac,
        strategyName: String,
        sourceOrganisation: String,
        sourceReference: String,
        validFrom: String,
        validFromEpochMs: Int64,
        rulesetVersion: String,
        rules: [ResistanceRule],
        groups: [ResistanceGroupListing],
        maxUseTable: ResistanceMaxUseTable? = nil,
        supersededBy: String? = nil,
        supersedes: String? = nil,
        sourceNotes: [String] = []
    ) {
        self.id = id
        self.jurisdiction = jurisdiction
        self.crop = crop
        self.disease = disease
        self.scheme = scheme
        self.strategyName = strategyName
        self.sourceOrganisation = sourceOrganisation
        self.sourceReference = sourceReference
        self.validFrom = validFrom
        self.validFromEpochMs = validFromEpochMs
        self.rulesetVersion = rulesetVersion
        self.rules = rules
        self.groups = groups
        self.maxUseTable = maxUseTable
        self.supersededBy = supersededBy
        self.supersedes = supersedes
        self.sourceNotes = sourceNotes
    }

    nonisolated var isSuperseded: Bool { supersededBy != nil }

    nonisolated func rule(_ id: String) -> ResistanceRule? { rules.first { $0.id == id } }

    /// Order-independent digest of every rule, threshold and table cell.
    ///
    /// Exists so the iOS and Android encodings of the same strategy can be asserted
    /// identical. Two platforms that each "look right" in isolation is precisely how
    /// the Android Powdery table and the iOS Powdery table drift apart, and a
    /// rotation that is compliant on one phone and exceeded on the other destroys
    /// trust in both.
    ///
    /// FNV-1a rather than a platform digest API, so the arithmetic is guaranteed
    /// identical on both platforms with no dependency.
    nonisolated func fingerprint() -> String {
        var canonical = ""
        canonical += id + "\n"
        canonical += jurisdiction.rawValue + "\n"
        canonical += crop.rawValue + "\n"
        canonical += disease.rawValue + "\n"
        canonical += strategyName + "\n"
        canonical += sourceOrganisation + "\n"
        canonical += validFrom + "\n"
        canonical += rulesetVersion + "\n"
        canonical += (supersededBy ?? "-") + "\n"
        canonical += (supersedes ?? "-") + "\n"
        for entry in groups.map({ "\($0.displayName)=\($0.signature.key)" }).sorted() {
            canonical += entry + "\n"
        }
        for entry in rules.map(\.fingerprint).sorted() {
            canonical += entry + "\n"
        }
        canonical += (maxUseTable?.fingerprint ?? "-") + "\n"
        return Self.fnv1a64Hex(canonical)
    }

    /// 64-bit FNV-1a over UTF-16 code units, lower-case hex.
    nonisolated static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x1000_0000_01b3
        for unit in text.utf16 {
            hash ^= UInt64(unit)
            hash = hash &* prime
        }
        return String(format: "%016lx", hash)
    }
}

// MARK: - Registry

/// Holds every known ruleset — current and historical — and answers which one
/// governs a given evaluation.
///
/// Superseded rulesets are retained rather than deleted so a 2026 spray can still
/// be explained by the strategy that was in force when it was applied.
nonisolated struct ResistanceRulesetRegistry: Sendable {
    nonisolated var rulesets: [ResistanceRuleset]

    nonisolated init(_ rulesets: [ResistanceRuleset]) { self.rulesets = rulesets }

    /// The current (non-superseded) ruleset for this jurisdiction/crop/disease.
    nonisolated func current(
        jurisdiction: ResistanceJurisdiction,
        crop: ResistanceCrop,
        disease: ResistanceDisease
    ) -> ResistanceRuleset? {
        rulesets
            .filter {
                $0.jurisdiction == jurisdiction && $0.crop == crop && $0.disease == disease
                    && !$0.isSuperseded
            }
            .max { $0.validFromEpochMs < $1.validFromEpochMs }
    }

    /// The ruleset in force at `atEpochMs` — for reconstructing why a historical
    /// spray was assessed the way it was.
    ///
    /// Not used by v1 planning, which always asks for `current`; the contract exists
    /// now so future reporting does not require an engine change.
    nonisolated func inForce(
        jurisdiction: ResistanceJurisdiction,
        crop: ResistanceCrop,
        disease: ResistanceDisease,
        atEpochMs: Int64
    ) -> ResistanceRuleset? {
        rulesets
            .filter {
                $0.jurisdiction == jurisdiction && $0.crop == crop && $0.disease == disease
                    && $0.validFromEpochMs <= atEpochMs
            }
            .max { $0.validFromEpochMs < $1.validFromEpochMs }
    }

    nonisolated func byId(_ id: String) -> ResistanceRuleset? { rulesets.first { $0.id == id } }
}
