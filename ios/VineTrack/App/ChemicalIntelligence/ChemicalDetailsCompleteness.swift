import Foundation

/// Customer-facing field coverage. Evidence confidence remains in ChemicalVerification.
nonisolated struct ChemicalDetailsCompleteness: Sendable {
    let missing: [String]
    let hasConflict: Bool

    var title: String { hasConflict ? "Review required" : (missing.isEmpty ? "Complete details" : "Basic details") }
    var missingText: String? { missing.isEmpty ? nil : "Missing: \(missing.joined(separator: ", "))" }

    static func assess(
        name: String, category: String, form: String,
        intelligence: ChemicalIntelligence, labelURL: String,
        hasDefaultRate: Bool, hasLabelRate: Bool
    ) -> Self {
        var missing: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("product name") }
        let kind = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if kind.isEmpty { missing.append("product category") }
        if ChemicalReviewMerge.formDescription(form).isEmpty { missing.append("product form") }
        let tokens = kind.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let categoryWords = Set(tokens + [tokens.joined()])
        let protectionCategories: Set<String> = ["fungicide", "herbicide", "insecticide", "miticide", "acaricide", "nematicide"]
        let isRegulator = categoryWords.contains("pgr") || categoryWords.contains("growthregulator")
            || (categoryWords.contains("growth") && categoryWords.contains("regulator"))
        let canonicalCategory = protectionCategories.first(where: categoryWords.contains) ?? (isRegulator ? "growthregulator" : kind)
        let scheme = ChemicalActivityGroupScheme.implied(byProductCategory: canonicalCategory)
        // Only crop-protection categories need active chemistry and label directions.
        let isProtection = protectionCategories.contains(canonicalCategory) || isRegulator
        if isProtection {
            let actives = intelligence.activeIngredients.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if actives.isEmpty { missing.append("active ingredients") }
            if !actives.isEmpty && actives.contains(where: { !$0.hasConcentration }) { missing.append("active concentration") }
            if let scheme, scheme != .notApplicable,
               (actives.isEmpty || actives.contains(where: { $0.activityGroup?.scheme != scheme || $0.activityGroup?.isResistanceRelevant != true })) {
                missing.append("\(scheme.label) group")
            }
            if !hasLabelRate { missing.append("label rate") }
        }
        if !hasDefaultRate { missing.append("operational default rate") }
        if ![labelURL, intelligence.registration?.manufacturerLabelURL ?? "", intelligence.registration?.regulatorLabelURL ?? "", intelligence.registration?.labelReference ?? ""].contains(where: {
            guard let url = URL(string: $0), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme == "https" || scheme == "http") && url.host != nil
        }) { missing.append("product label link") }
        return Self(missing: missing, hasConflict: !ChemicalVerificationConflict.customerVisible(intelligence.verification.conflicts).isEmpty)
    }

    static func assess(_ chemical: SavedChemical) -> Self {
        let intel = chemical.resolvedIntelligence
        let details = assess(
            name: chemical.name, category: chemical.productCategory, form: chemical.productForm,
            intelligence: intel, labelURL: chemical.labelURL,
            hasDefaultRate: ChemicalDefaultRateBasis.allCases.contains {
                ChemicalDefaultRateValidity.validSlot(chemical.defaultRates, basis: $0) != nil
            },
            hasLabelRate: intel.registeredUses.filter(\.isViticultural).flatMap(\.rates).contains(where: ChemicalSaveContract.isUsable)
        )
        return Self(missing: details.missing, hasConflict: details.hasConflict ||
                    !ChemicalVerificationConflict.customerVisible(chemical.chemicalIntelligence?.verification.conflicts ?? []).isEmpty)
    }
}
