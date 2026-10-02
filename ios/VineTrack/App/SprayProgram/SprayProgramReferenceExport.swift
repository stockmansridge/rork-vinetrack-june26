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
                    product: product?.name ?? "", rate: product.map { rate($0, step: step, chemicals: chemicals) } ?? unplannedRate, notes: step.notes)
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
        let bounds = CGRect(x: 0, y: 0, width: 842, height: 595)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let font = UIFont.systemFont(ofSize: 10)
        let widths: [CGFloat] = [74, 290, 178, 228]
        func wrap(_ text: String, width: CGFloat) -> [String] {
            var lines: [String] = []
            for paragraph in text.components(separatedBy: "\n") {
                var line = ""
                for character in paragraph {
                    let next = line + String(character)
                    if !line.isEmpty && (next as NSString).size(withAttributes: [.font: font]).width > width - 12 {
                        lines.append(line); line = String(character)
                    } else { line = next }
                }
                lines.append(line)
            }
            return lines
        }
        let data = renderer.pdfData { context in
            var y: CGFloat = 108
            var page = 0
            func newPage() {
                context.beginPage(); page += 1; y = 108
                ("\(vineyard) — Spray Program" as NSString).draw(at: CGPoint(x: 36, y: 32), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18)])
                ("VineTrack · Program reference" as NSString).draw(at: CGPoint(x: 36, y: 57), withAttributes: [.font: font])
                if let logo, let image = UIImage(data: logo) { image.draw(in: CGRect(x: 766, y: 28, width: 40, height: 40)) }
                var x: CGFloat = 36
                for (i, title) in ["E-L STAGE", "PROGRAM STEP / PURPOSE / INSTRUCTIONS", "PRODUCT", "RATE / RANGE"].enumerated() {
                    (title as NSString).draw(in: CGRect(x: x + 6, y: 83, width: widths[i] - 12, height: 23), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 9)])
                    x += widths[i]
                }
                (SprayProgramReferenceDataset.footer as NSString).draw(in: CGRect(x: 36, y: 551, width: 705, height: 32), withAttributes: [.font: UIFont.systemFont(ofSize: 8)])
                ("Page \(page)" as NSString).draw(at: CGPoint(x: 764, y: 554), withAttributes: [.font: font])
            }
            newPage()
            for row in rows {
                let detail = [row.name, row.description, row.targets, row.method, row.equipment, row.notes].filter { !$0.isEmpty }.joined(separator: "\n")
                let columns = [row.stage, detail, row.product, row.rate].enumerated().map { wrap($0.element, width: widths[$0.offset]) }
                let count = columns.map(\.count).max() ?? 1
                for line in 0..<count {
                    if y + 14 > 536 { newPage() }
                    var x: CGFloat = 36
                    for column in 0..<4 {
                        if line < columns[column].count {
                            (columns[column][line] as NSString).draw(at: CGPoint(x: x + 6, y: y), withAttributes: [.font: font])
                        }
                        x += widths[column]
                    }
                    y += 14
                }
                y += 12
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename(vineyard: vineyard, extension: "pdf"))
        try data.write(to: url)
        return url
    }
}
