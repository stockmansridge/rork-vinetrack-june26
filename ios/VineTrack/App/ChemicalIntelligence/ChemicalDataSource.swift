import Foundation

/// Where a piece of chemical information came from, ranked by how much weight
/// it may carry.
///
/// The ordering IS the source hierarchy: an official register outranks a
/// manufacturer label, which outranks an authoritative activity-group
/// classification for identity purposes, and AI/search interpretation sits at
/// the bottom. `authoritativeClassification` is the highest authority for the
/// activity group specifically — that is the one thing FRAC/HRAC/IRAC define.
nonisolated enum ChemicalDataSourceKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// A national regulator's registered-product record: APVMA (AU),
    /// ACVM/EPA (NZ). The strongest statement of "this exact product exists".
    case officialRegister = "official_register"
    /// The registrant's own approved label document.
    case manufacturerLabel = "manufacturer_label"
    /// FRAC / HRAC / IRAC classification of an active ingredient. Authoritative
    /// for activity group and nothing else.
    case authoritativeClassification = "authoritative_classification"
    /// A viticulture body's spray guide (e.g. an industry agrichemical manual)
    /// used to cross-check that a product is actually used on grapes.
    case viticultureReference = "viticulture_reference"
    /// A language model's reading of search results. Useful for FINDING a
    /// candidate; never sufficient on its own to call anything Verified.
    case aiInterpretation = "ai_interpretation"
    /// Typed by the operator.
    case manualEntry = "manual_entry"
    /// Read out of a pre-Chemical-Intelligence free-text field. Candidate data
    /// for the audit only.
    case legacyRecord = "legacy_record"

    /// Whether this source can, by itself, support a Verified claim.
    ///
    /// This single property is what stops AI confidence from being laundered
    /// into authority.
    nonisolated var isAuthoritative: Bool {
        switch self {
        case .officialRegister, .manufacturerLabel, .authoritativeClassification:
            return true
        case .viticultureReference, .aiInterpretation, .manualEntry, .legacyRecord:
            return false
        }
    }

    /// Whether this source is the record telling us about itself rather than
    /// anything outside VineTrack having been consulted.
    ///
    /// A manually typed value and a value read out of an old free-text column are
    /// both statements by the operator's own installation. Neither is proof of
    /// anything, which is why a hand-entered registration number cannot make a
    /// product's identity authoritative.
    nonisolated var isSelfReported: Bool {
        self == .manualEntry || self == .legacyRecord
    }

    /// Higher wins when two sources disagree about the same field.
    nonisolated var precedence: Int {
        switch self {
        case .officialRegister: return 100
        case .manufacturerLabel: return 90
        case .authoritativeClassification: return 80
        case .viticultureReference: return 50
        case .aiInterpretation: return 20
        case .manualEntry: return 15
        case .legacyRecord: return 10
        }
    }

    nonisolated var label: String {
        switch self {
        case .officialRegister: return "Official register"
        case .manufacturerLabel: return "Product label"
        case .authoritativeClassification: return "Activity group classification"
        case .viticultureReference: return "Viticulture reference"
        case .aiInterpretation: return "AI/search interpretation"
        case .manualEntry: return "Manually entered"
        case .legacyRecord: return "Existing VineTrack record"
        }
    }
}

/// One cited source behind a chemical's information.
nonisolated struct ChemicalDataSource: Codable, Sendable, Hashable, Identifiable {
    let kind: ChemicalDataSourceKind
    /// Human-readable name of the source, e.g. `"APVMA PUBCRIS"`,
    /// `"FRAC Code List 2025"`.
    let name: String
    /// URL or document identifier, where one exists.
    let reference: String?
    /// When this source was consulted.
    let retrievedAt: Date?

    nonisolated var id: String { "\(kind.rawValue)|\(name)|\(reference ?? "")" }

    init(
        kind: ChemicalDataSourceKind,
        name: String,
        reference: String? = nil,
        retrievedAt: Date? = nil
    ) {
        self.kind = kind
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = reference?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reference = (ref?.isEmpty ?? true) ? nil : ref
        self.retrievedAt = retrievedAt
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case kind, name, reference
        case retrievedAt = "retrieved_at"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        // An unknown source kind from a newer build must never be READ AS
        // authoritative. Falling back to AI interpretation is the safe
        // direction: it can only lower a verification claim, never raise one.
        kind = ChemicalDataSourceKind(rawValue: raw) ?? .aiInterpretation
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let ref = try c.decodeIfPresent(String.self, forKey: .reference)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        reference = (ref?.isEmpty ?? true) ? nil : ref
        retrievedAt = try c.decodeIfPresent(Date.self, forKey: .retrievedAt)
    }
}

extension Array where Element == ChemicalDataSource {
    /// Whether any cited source can support a Verified claim.
    var containsAuthoritative: Bool { contains { $0.kind.isAuthoritative } }

    /// The strongest source cited.
    var strongest: ChemicalDataSource? {
        self.max { $0.kind.precedence < $1.kind.precedence }
    }
}
