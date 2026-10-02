import Foundation
import UIKit

/// Configuration-only rows shared by Program PDF and CSV; no operational fields.
nonisolated struct SprayProgramReferenceRow: Equatable, Sendable {
    let stage: String
    let description: String
    let name: String
    let targets: String
    let method: String
    let equipment: String
    let product: String
    let rate: String
    let notes: String
    var pdfStepID: String = ""
    var pdfProduct: ProgramPDFProduct? = nil
    var cells: [String] { [stage, description, name, targets, method, equipment, product, rate, notes] }
}

nonisolated enum SprayProgramReferenceDataset {
    static let unplannedRate = "Rate set when planning"
    static let footer = "Program reference only. Always follow the current product label and registration. Application quantities are determined when the spray is planned."
    static let headers = ["E-L stage", "Growth-stage description", "Program Step", "Targets / purpose", "Application method", "Spray unit", "Product", "Programmed / registered rate", "Program notes / instructions"]

    static func rateNumber(_ value: Double) -> String {
        let text = NSDecimalNumber(string: String(value)).stringValue
        if text.lowercased().contains("e") { return text }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 1 { return text + ".00" }
        if parts[1].count == 1 { return text + "0" }
        return text
    }

    static func rate(_ product: SprayChemical, step: SprayProgramStep, chemicals: [SavedChemical]) -> String {
        if product.reportedRateBaseValue.isFinite, product.reportedRateBaseValue > 0 {
            let suffix = product.reportedRateBasis == .treatedArea ? "/treated ha" : product.reportedRateBasis.rateSuffix
            let unit = product.unit == .litres ? "L" : product.unit == .kilograms ? "kg" : product.unitLabel
            return "\(rateNumber(product.displayReportedRate)) \(unit)\(suffix)"
        }
        let matches = chemicals.filter { chemical in
            if let id = product.savedChemicalId { return chemical.id == id }
            return SprayProgramProgression.normalizedName(chemical.name) == SprayProgramProgression.normalizedName(product.name)
        }
        guard matches.count == 1, let chemical = matches.first else { return unplannedRate }
        let targets = Set(step.targetTags().map { SprayProgramProgression.normalizedName($0.label) })
        guard !targets.isEmpty else { return unplannedRate }
        let applicable = SprayRegisteredUseRates.vineyardRates(for: chemical).filter { rate in
            rate.origin == .registeredUse && rate.preset == nil && rate.isSelectable &&
            SprayRegisteredUseRates.registeredUse(for: chemical, rateId: rate.id)?.isViticultural == true &&
            targets.contains(SprayProgramProgression.normalizedName(rate.targetRaw ?? ""))
        }.map { "\($0.targetRaw ?? "")\($0.label.isEmpty ? "" : " — " + $0.label): \($0.labelRangeText ?? $0.displayText) (registered)" }
        return applicable.isEmpty ? unplannedRate : Array(Set(applicable)).sorted().joined(separator: "; ")
    }

    static func rows(steps: [SprayProgramStep], chemicals: [SavedChemical], unitNames: [UUID: String] = [:]) -> [SprayProgramReferenceRow] {
        let sorted = steps.sorted {
            let left = SprayProgramProgression.stage($0) ?? Int.max
            let right = SprayProgramProgression.stage($1) ?? Int.max
            return left == right ? $0.name < $1.name : left < right
        }
        return sorted.flatMap { step in
            var seen = Set<String>()
            let products = step.products.filter { product in
                let key = "\(product.savedChemicalId?.uuidString ?? "")|\(product.name)|\(product.unitLabel)|\(product.reportedRateBasis)|\(product.reportedRateBaseValue)"
                return !product.name.isEmpty && seen.insert(key).inserted
            }
            let lines: [SprayChemical?] = products.isEmpty ? [nil] : products.map { Optional($0) }
            return lines.map { product in
                let stage = SprayProgramProgression.stage(step)
                return SprayProgramReferenceRow(stage: stage.map { "EL\($0)" } ?? "Other Program Steps",
                    description: stage.flatMap { number in GrowthStage.allStages.first { ELStageParser.stageNumber(fromCode: $0.code) == number }?.description } ?? "",
                    name: step.name, targets: step.targetDisplay ?? "", method: step.operationType.rawValue,
                    equipment: step.record.sprayEquipmentId.flatMap { unitNames[$0] } ?? step.record.equipmentType,
                    product: product?.name ?? "", rate: product.map { rate($0, step: step, chemicals: chemicals) } ?? unplannedRate, notes: step.notes,
                    pdfStepID: step.id.uuidString,
                    pdfProduct: product.map { ProgramPDFProduct.make($0, step: step, chemicals: chemicals) })
            }
        }
    }

    static func csv(_ rows: [SprayProgramReferenceRow]) -> String {
        ([headers] + rows.map(\.cells)).map { row in
            row.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }
}

nonisolated enum SprayProgramReferenceExport {
    static func filename(vineyard: String, extension ext: String) -> String {
        vineyard.replacingOccurrences(of: "/", with: "-") + " - Spray Program." + ext
    }

    @MainActor static func csv(rows: [SprayProgramReferenceRow], vineyard: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename(vineyard: vineyard, extension: "csv"))
        try SprayProgramReferenceDataset.csv(rows).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor static func pdf(rows: [SprayProgramReferenceRow], vineyard: String, logo: Data?) throws -> URL {
        return try ProgramGroupedPDFRenderer.write(rows: rows, vineyard: vineyard, logo: logo)
    }
}
