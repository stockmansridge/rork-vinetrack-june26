import Foundation

/// Evidence tiers the server resolver records against stored values, and the
/// display rules for showing them.
///
/// Everything here reads STORED provenance verbatim. Nothing derives a tier
/// from a value, upgrades an AI or operator value to label/register standing,
/// or invents provenance for records saved before the server published it —
/// absence always means "unknown", which displays as nothing at all.

/// An authoritative evidence tier, parsed from a raw stored string.
///
/// `ai_interpretation`, `unresolved`, unknown strings and absent values all
/// deliberately have NO case: they can never be presented as authority.
nonisolated enum ChemicalProvenanceTier: String, Sendable, Hashable, CaseIterable {
    case officialRegister = "official_register"
    case manufacturerLabel = "manufacturer_label"
    case authoritativeClassification = "authoritative_classification"
    case masterCatalogue = "master_catalogue"

    /// The authoritative tier a raw stored string proves, or `nil` for
    /// AI-supplied, unresolved, unknown or absent provenance. Fails closed:
    /// a tier string this build does not recognise is NOT authority.
    static func authoritative(fromRaw raw: String?) -> ChemicalProvenanceTier? {
        guard let raw else { return nil }
        return ChemicalProvenanceTier(rawValue: raw)
    }

    var displayLabel: String {
        switch self {
        case .officialRegister: return "Official register"
        case .manufacturerLabel: return "Official label"
        case .authoritativeClassification: return "Authoritative classification"
        case .masterCatalogue: return "Master catalogue"
        }
    }

    var symbolName: String {
        switch self {
        case .officialRegister: return "checkmark.seal"
        case .manufacturerLabel: return "doc.text"
        case .authoritativeClassification: return "shield.lefthalf.filled"
        case .masterCatalogue: return "books.vertical"
        }
    }
}

/// The per-use facts that can carry provenance and appear in the UI.
/// Raw values are the exact wire keys of `registered_uses[].provenance`.
nonisolated enum ChemicalUseProvenanceFact: String, Sendable, Hashable, CaseIterable {
    case rates
    case withholdingPeriod = "withholding_period"
    case reEntry = "re_entry"
    case restrictions
}

/// A tag the UI may attach to a displayed fact: a proven tier, or an explicit
/// "Unresolved" for a value present without authoritative backing (the
/// contract treats AI-supplied values as present-but-unresolved).
nonisolated enum ChemicalProvenanceBadge: Sendable, Hashable {
    case authoritative(ChemicalProvenanceTier)
    case unresolved

    var text: String {
        switch self {
        case .authoritative(let tier): return tier.displayLabel
        case .unresolved: return "Unresolved"
        }
    }

    var symbolName: String {
        switch self {
        case .authoritative(let tier): return tier.symbolName
        case .unresolved: return "questionmark.circle"
        }
    }
}

/// Which provenance tags a registered-use card shows — chosen to stay
/// lightweight instead of stamping every row:
///
/// - No stored provenance (legacy, manual, pre-provenance servers) → nothing.
/// - Every displayed fact proves the SAME authoritative tier → one compact
///   badge for the whole card.
/// - Mixed trust (e.g. label-backed restrictions carrying an AI withholding
///   period) → a badge per fact, with "Unresolved" on the unproven ones —
///   the one case where per-row tags earn their space.
/// - Nothing authoritative at all → nothing; the verification banner already
///   says the record is unverified, so repeating it per row is clutter.
nonisolated enum ChemicalUseProvenancePlan: Sendable, Hashable {
    case hidden
    case uniform(ChemicalProvenanceTier)
    case mixed([ChemicalUseProvenanceFact: ChemicalProvenanceBadge])

    static func make(
        provenance: [String: String]?,
        displayedFacts: [ChemicalUseProvenanceFact]
    ) -> ChemicalUseProvenancePlan {
        guard let provenance, !provenance.isEmpty, !displayedFacts.isEmpty else {
            return .hidden
        }
        var proven: [ChemicalUseProvenanceFact: ChemicalProvenanceTier] = [:]
        for fact in displayedFacts {
            if let tier = ChemicalProvenanceTier.authoritative(fromRaw: provenance[fact.rawValue]) {
                proven[fact] = tier
            }
        }
        guard !proven.isEmpty else { return .hidden }
        let distinct = Set(proven.values)
        if proven.count == displayedFacts.count, distinct.count == 1, let tier = distinct.first {
            return .uniform(tier)
        }
        var badges: [ChemicalUseProvenanceFact: ChemicalProvenanceBadge] = [:]
        for fact in displayedFacts {
            badges[fact] = proven[fact].map(ChemicalProvenanceBadge.authoritative) ?? .unresolved
        }
        return .mixed(badges)
    }

    /// The single card-level badge, when every displayed fact shares a tier.
    var headerBadge: ChemicalProvenanceBadge? {
        if case .uniform(let tier) = self { return .authoritative(tier) }
        return nil
    }

    /// The per-fact badge in the mixed-trust case, `nil` otherwise.
    func badge(for fact: ChemicalUseProvenanceFact) -> ChemicalProvenanceBadge? {
        if case .mixed(let badges) = self { return badges[fact] }
        return nil
    }
}

extension ChemicalRegisteredUse {
    /// The provenance-bearing facts this use's card actually displays, in
    /// display order. Rates are shown product-level, not per card — see
    /// `Array.uniformRatesBadge`.
    var displayedProvenanceFacts: [ChemicalUseProvenanceFact] {
        var facts: [ChemicalUseProvenanceFact] = []
        if withholdingPeriodDays != nil { facts.append(.withholdingPeriod) }
        if reEntryPeriodHours != nil { facts.append(.reEntry) }
        if let restrictions, !restrictions.isEmpty { facts.append(.restrictions) }
        return facts
    }

    /// Tag plan for this use's card.
    var provenancePlan: ChemicalUseProvenancePlan {
        ChemicalUseProvenancePlan.make(
            provenance: provenance,
            displayedFacts: displayedProvenanceFacts
        )
    }
}

extension Array where Element == ChemicalRegisteredUse {
    /// One aggregate badge for the product-level label-rates section, shown
    /// only when EVERY rate-owning use proves the SAME authoritative tier for
    /// its rates. Anything less — any use without stored provenance, any
    /// AI-carried rate, any disagreement — renders nothing: silence, never a
    /// guess.
    var uniformRatesBadge: ChemicalProvenanceBadge? {
        let owners = filter { !$0.rates.isEmpty }
        guard !owners.isEmpty else { return nil }
        var tiers = Set<ChemicalProvenanceTier>()
        for use in owners {
            guard let tier = ChemicalProvenanceTier.authoritative(
                fromRaw: use.provenance?[ChemicalUseProvenanceFact.rates.rawValue]
            ) else { return nil }
            tiers.insert(tier)
        }
        guard tiers.count == 1, let tier = tiers.first else { return nil }
        return .authoritative(tier)
    }
}
