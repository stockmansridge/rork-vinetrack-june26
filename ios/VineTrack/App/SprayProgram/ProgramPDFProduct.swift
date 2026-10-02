import Foundation

/// PDF-only product evidence. No doses, carrier volumes or operational costs.
nonisolated struct ProgramPDFProduct: Equatable, Sendable {
    let name: String
    var per100L: String = ""
    var perHa: String = ""
    var moa: String = ""
    var estimatedCost: String = ""
    var unknownRate: Bool { per100L.isEmpty && perHa.isEmpty && !name.isEmpty }

    static func make(_ product: SprayChemical, step: SprayProgramStep, chemicals: [SavedChemical]) -> Self {
        let matches = chemicals.filter {
            if let id = product.savedChemicalId { return $0.id == id }
            return SprayProgramProgression.normalizedName($0.name) == SprayProgramProgression.normalizedName(product.name)
        }
        let chemical = matches.count == 1 ? matches.first : nil
        var result = Self(name: product.name)
        if let chemical {
            // Never use resolvedIntelligence: its legacy seed parses free text.
            let codes = chemical.backendActivityGroups.isEmpty
                ? chemical.chemicalIntelligence?.activityGroupCodes ?? [] : chemical.backendActivityGroups
            result.moa = codes.filter { !$0.isEmpty }.joined(separator: " + ")
        }
        if product.reportedRateBaseValue.isFinite && product.reportedRateBaseValue > 0 {
            let text = SprayProgramReferenceDataset.rate(product, step: step, chemicals: chemicals)
            if product.reportedRateBasis == .per100Litres { result.per100L = text }
            else { result.perHa = text }
            return result
        }
        guard let chemical else { return result }
        let targets = Set(step.targetTags().map { SprayProgramProgression.normalizedName($0.label) })
        let applicable = SprayRegisteredUseRates.vineyardRates(for: chemical).filter {
            $0.origin == .registeredUse && $0.preset == nil && $0.isSelectable &&
            SprayRegisteredUseRates.registeredUse(for: chemical, rateId: $0.id)?.isViticultural == true &&
            targets.contains(SprayProgramProgression.normalizedName($0.targetRaw ?? ""))
        }
        func text(_ basis: ChemicalRateBasis) -> String {
            Array(Set(applicable.filter { $0.basis == basis }.map {
                return "\($0.targetRaw ?? "")\($0.label.isEmpty ? "" : " — " + $0.label): \($0.labelRangeText ?? $0.displayText) (registered)"
            })).sorted().joined(separator: "\n")
        }
        result.per100L = text(.per100Litres)
        result.perHa = text(.perHectare)
        // Existing costing needs planned amount and area; neither belongs in a Program reference.
        return result
    }
}
