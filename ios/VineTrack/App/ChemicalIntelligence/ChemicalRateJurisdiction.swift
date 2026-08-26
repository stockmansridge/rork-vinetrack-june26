import Foundation

/// A state/territory a registered rate is conditioned on.
///
/// # Why the jurisdiction is read out of the condition text
///
/// Australian labels condition rates BY STATE, and the state IS the condition
/// that distinguishes `2 L/100 L` from `3 L/100 L` on one product. The
/// manufacturer-label parser already binds that STATE column into each rate's
/// condition (`ingestion/manufacturer_label.ts`), and it deliberately adds no
/// new rate field for it — the condition string is the contract.
///
/// So this reads what the server wrote, and never invents a restriction. A
/// rate whose condition names no state is not "restricted to nowhere"; it is
/// simply unrestricted, and must stay eligible everywhere.
nonisolated enum ChemicalRateJurisdiction: String, Sendable, Hashable, CaseIterable {
    case nsw = "NSW"
    case vic = "VIC"
    case qld = "QLD"
    case sa = "SA"
    case wa = "WA"
    case tas = "TAS"
    case nt = "NT"
    case act = "ACT"

    /// How a grower says it: `"NSW"`, `"Tasmania"`.
    nonisolated var displayName: String {
        switch self {
        case .nsw: return "NSW"
        case .vic: return "Vic"
        case .qld: return "Qld"
        case .sa: return "SA"
        case .wa: return "WA"
        case .tas: return "Tasmania"
        case .nt: return "NT"
        case .act: return "ACT"
        }
    }

    /// The country whose register conditions rates on this jurisdiction.
    nonisolated var countryCode: String { "AU" }

    /// Full names as labels print them, lower-cased for matching.
    private static let fullNames: [String: ChemicalRateJurisdiction] = [
        "new south wales": .nsw,
        "victoria": .vic,
        "queensland": .qld,
        "south australia": .sa,
        "western australia": .wa,
        "tasmania": .tas,
        "northern territory": .nt,
        "australian capital territory": .act,
    ]

    /// Abbreviations, including the punctuated forms labels use.
    private static let abbreviations: [String: ChemicalRateJurisdiction] = [
        "NSW": .nsw, "VIC": .vic, "QLD": .qld, "SA": .sa,
        "WA": .wa, "TAS": .tas, "TASSIE": .tas, "NT": .nt, "ACT": .act,
    ]

    /// Read the vineyard's own jurisdiction from free text.
    ///
    /// Returns `nil` for anything it cannot recognise, which is the correct
    /// answer: an unrecognised jurisdiction must never silently become a
    /// different one, because that would recommend another state's rate.
    static func parse(_ raw: String?) -> ChemicalRateJurisdiction? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let full = fullNames[trimmed.lowercased()] { return full }
        let squashed = trimmed.uppercased().filter { $0.isLetter }
        return abbreviations[squashed]
    }

    /// Every jurisdiction a rate condition names.
    ///
    /// An EMPTY result means the condition named none — the rate is not
    /// state-restricted. That is emphatically different from "applies
    /// nowhere", and conflating the two would hide every unconditioned rate
    /// on the label.
    ///
    /// Matching is whole-token so `WA` is never found inside `WATER` and `SA`
    /// is never found inside `SEASON`; the multi-word full names are matched
    /// against the whole string separately.
    static func mentioned(in text: String?) -> [ChemicalRateJurisdiction] {
        guard let text, !text.isEmpty else { return [] }
        var found: [ChemicalRateJurisdiction] = []
        var seen = Set<ChemicalRateJurisdiction>()

        func note(_ jurisdiction: ChemicalRateJurisdiction) {
            guard seen.insert(jurisdiction).inserted else { return }
            found.append(jurisdiction)
        }

        let lowered = text.lowercased()
        for (name, jurisdiction) in fullNames where lowered.contains(name) {
            note(jurisdiction)
        }

        // Whole tokens only. `/`, `,`, `&`, `.` and spaces all separate the
        // state list a label prints in one cell ("NSW, Vic, Qld / SA & WA").
        let tokens = text.uppercased().split { !$0.isLetter }
        for token in tokens {
            if let jurisdiction = abbreviations[String(token)] { note(jurisdiction) }
        }

        // Deterministic order so a condition summary reads the same every
        // time it is drawn.
        return ChemicalRateJurisdiction.allCases.filter(seen.contains)
    }
}
