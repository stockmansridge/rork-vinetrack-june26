import Foundation

/// Local-only port of Portal targetNutrient.ts at c7be056. No persistence or product mutation.
nonisolated enum TargetNutrient {
    static let nutrients: [(key: String, name: String)] = [("N", "Nitrogen"), ("P", "Phosphorus"), ("K", "Potassium"), ("Ca", "Calcium"), ("Mg", "Magnesium"), ("S", "Sulfur"), ("Fe", "Iron"), ("Mn", "Manganese"), ("Zn", "Zinc"), ("Cu", "Copper"), ("B", "Boron"), ("Mo", "Molybdenum"), ("Cl", "Chlorine"), ("Si", "Silicon"), ("Co", "Cobalt"), ("other", "Other")]
    static let oxideKeys: Set<String> = ["P", "K", "Ca", "Mg", "S", "Si", "B", "Fe", "Mn", "Zn", "Cu", "Mo", "Co", "other"]
    static func canPreview(isSystemAdmin: Bool) -> Bool { isSystemAdmin }
    static func canSave(mode: String) -> Bool { ["perHectare", "perVine"].contains(mode) }
    static func number(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
        return value
    }

    struct Draft: Equatable {
        var nutrient: String = "N"
        var otherName: String = ""
        var percent: String = ""
        var target: String = ""
        var perVine: Bool = true
        var analysisBasis: String = "elemental"
        var concentrationBasis: String = "unknown"
        var density: String = ""
        var densityReference: String = ""
        mutating func selectNutrient(_ key: String) {
            nutrient = key
            analysisBasis = TargetNutrient.oxideKeys.contains(key) ? "unknown" : "elemental"
        }
    }

    struct Result: Equatable {
        let rate: Double?
        let rateUnit: String
        let totalProduct: Double?
        let productUnit: String
        let totalNutrientKg: Double?
        let issues: [String]
    }

    /// Oxide/unknown bases block elemental outputs. Missing density retains honest mass, never a fabricated volume.
    static func calculate(_ draft: Draft, liquid: Bool, vines: Int?, areaHa: Double?) -> Result {
        var issues: [String] = []
        let percent = number(draft.percent) ?? 0
        let target = number(draft.target) ?? 0
        if percent <= 0 || percent > 100 { issues.append("Enter a nutrient percentage greater than 0 and no more than 100.") }
        if target <= 0 { issues.append("Enter a target nutrient quantity greater than zero.") }
        if draft.nutrient == "other" && draft.otherName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Enter the nutrient name.") }
        if draft.analysisBasis != "elemental" { issues.append("Confirm an elemental percentage. Oxide-labelled analysis is not converted to actual nutrient in this preview.") }
        if liquid && !["w/w", "w/v"].contains(draft.concentrationBasis) { issues.append("Confirm w/w or w/v from the product label. Legacy percentages have no verified concentration basis.") }
        if !liquid && draft.concentrationBasis == "w/v" { issues.append("Weight/volume analysis requires a liquid product.") }
        let valid = issues.isEmpty
        let density = number(draft.density).flatMap { $0 > 0 && !draft.densityReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0 : nil }
        let volume = liquid && (draft.concentrationBasis == "w/v" || density != nil)
        let missingDensity = liquid && draft.concentrationBasis == "w/w" && density == nil
        if missingDensity { issues.append("Documented density (kg/L) and its label or technical-sheet source are needed to show litres. Required product mass is shown instead.") }
        let quantity: Double? = draft.perVine ? vines.flatMap { $0 > 0 ? Double($0) / 1000 : nil } : areaHa.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if quantity == nil { issues.append(draft.perVine ? "Select blocks with available vine counts or enter a positive whole vine count." : "Select blocks with usable area or enter a positive treated area.") }
        let nutrient = valid ? quantity.map { target * $0 } : nil
        let divisor = percent / 100 * (volume && draft.concentrationBasis == "w/w" ? density ?? 1 : 1)
        let rate = valid && !missingDensity ? target / divisor : nil
        let total = valid ? nutrient.map { $0 / divisor } : nil
        func rounded(_ value: Double?) -> Double? { value.flatMap { ($0 * 1000).isFinite ? ($0 * 1000).rounded() / 1000 : nil } }
        return Result(rate: rounded(rate), rateUnit: draft.perVine ? (liquid ? "mL/vine" : "g/vine") : (liquid ? "L/ha" : "kg/ha"), totalProduct: rounded(total), productUnit: volume ? "L" : "kg", totalNutrientKg: rounded(nutrient), issues: issues)
    }
}
