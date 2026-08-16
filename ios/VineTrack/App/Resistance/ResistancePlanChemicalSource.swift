import Foundation

/// Builds Planner product candidates from the vineyard's Chemical Store.
///
/// Unlike historical reads, this deliberately DOES use today's Chemical Store: the
/// operator is choosing a product to spray in the future, so the current record is the
/// correct source. The ban on re-reading live chemistry applies to reconstructing what
/// a past application contained, which is a different question.
///
/// Mirrors `ResistancePlanChemicalSource.kt` on Android.
nonisolated enum ResistancePlanChemicalSource {

    /// Candidates for planning, from saved chemicals.
    ///
    /// Products with no structured group are omitted, because a product whose FRAC
    /// identity is unknown cannot be offered as an option for a chosen group — doing so
    /// would be presenting a guess as a match. They remain visible in the Chemical
    /// Store itself, where they can be verified.
    nonisolated static func candidates(
        from chemicals: [SavedChemical],
        disease: ResistanceDisease,
        vineyardCountry: String?
    ) -> [ResistancePlanChemicalCandidate] {
        chemicals.compactMap { chemical in
            let signature = ResistanceGroupSignature.of(chemical.activityGroupCodes)
            guard !signature.codes.isEmpty else { return nil }
            return ResistancePlanChemicalCandidate(
                savedChemicalId: chemical.id.uuidString,
                productName: chemical.name,
                groups: signature,
                availability: ChemicalIntelligenceAvailability.from(status: chemical.verificationStatus),
                registeredForDisease: registeredUse(chemical: chemical, disease: disease),
                countryCode: vineyardCountry
            )
        }
    }

    /// Whether structured registered-use evidence covers this disease.
    ///
    /// Returns nil — UNKNOWN — when the product carries no registered-use evidence at
    /// all. That is the honest answer and it is not the same as `false`: "the label was
    /// never captured" and "the label does not cover this disease" would lead an
    /// operator to opposite conclusions.
    ///
    /// Group membership is never consulted. A Group 7 product is not registered for
    /// powdery mildew on grapes by virtue of being Group 7, and inferring efficacy from
    /// a resistance classification is exactly the overstatement to avoid.
    nonisolated static func registeredUse(
        chemical: SavedChemical,
        disease: ResistanceDisease
    ) -> Bool? {
        let intelligence = chemical.resolvedIntelligence
        guard !intelligence.registeredUses.isEmpty else { return nil }
        let targets = intelligence.registeredUses.viticulturalTargets
        guard !targets.isEmpty else { return nil }
        return targets.contains { ResistanceDisease.fromSprayTargetRaw($0.rawValue) == disease }
    }
}
