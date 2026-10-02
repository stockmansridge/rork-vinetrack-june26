import Foundation

/// One PDF visual group per template identity, preserving source encounter order.
nonisolated struct ProgramStepExportBlock: Equatable, Sendable {
    let reference: SprayProgramReferenceRow
    var products: [ProgramPDFProduct]
    private var stagePattern: String { "(?i)\\bE-?L\\s*(?:Stage\\s*)?-?\\s*([0-9]+(?:\\s*[-–]\\s*[0-9]+)?)" }
    var stage: String {
        guard let range = reference.name.range(of: stagePattern, options: .regularExpression) else {
            return reference.stage.replacingOccurrences(of: "EL", with: "E-L Stage ")
        }
        let token = String(reference.name[range])
        return "E-L Stage " + token.replacingOccurrences(of: "(?i)^E-?L\\s*(?:Stage\\s*)?-?\\s*", with: "", options: .regularExpression)
    }
    var timing: String {
        let name = reference.name.replacingOccurrences(of: stagePattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–-/()")))
        return name.isEmpty ? reference.name : name
    }
    var growthDescription: String { reference.description }
    var comments: String { ProgramPDFLayout.comments(reference.notes) }

    static func grouped(_ rows: [SprayProgramReferenceRow]) -> [Self] {
        var blocks: [Self] = []
        for row in rows {
            let product = row.pdfProduct ?? ProgramPDFProduct(name: row.product)
            if !row.pdfStepID.isEmpty, let index = blocks.firstIndex(where: { $0.reference.pdfStepID == row.pdfStepID }) {
                blocks[index].products.append(product)
            } else { blocks.append(Self(reference: row, products: [product])) }
        }
        return blocks
    }
}

nonisolated enum ProgramPDFColumn: String, CaseIterable, Sendable {
    case timing, targets, product, per100L, moa, cost, method, perHa, comments
    var title: String {
        switch self {
        case .timing: "TIMING"
        case .targets: "TARGET / PURPOSE"
        case .product: "PRODUCT"
        case .per100L: "RATE /100 L"
        case .moa: "MOA"
        case .cost: "EST $/HA"
        case .method: "APPLICATION METHOD"
        case .perHa: "RATE /HA"
        case .comments: "COMMENTS"
        }
    }
    var weight: Double {
        switch self {
        case .timing: 15
        case .targets: 20
        case .product: 12
        case .per100L: 9
        case .moa: 6
        case .cost: 7
        case .method, .perHa: 8
        case .comments: 15
        }
    }
    var reclaim: Double {
        switch self {
        case .timing, .product: 2
        case .targets, .comments: 3
        default: 0
        }
    }
    var isShared: Bool { [.timing, .targets, .method, .comments].contains(self) }
}

nonisolated enum ProgramPDFLayout {
    static func columns(_ blocks: [ProgramStepExportBlock]) -> [ProgramPDFColumn] {
        let products = blocks.flatMap(\.products)
        return ProgramPDFColumn.allCases.filter { column in
            switch column {
            case .timing, .product: true
            case .targets: blocks.contains { !$0.reference.targets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            case .method: blocks.contains { !$0.reference.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            case .comments: blocks.contains { !$0.comments.isEmpty }
            case .per100L: products.contains { !$0.per100L.isEmpty }
            case .perHa: products.contains { !$0.perHa.isEmpty }
            case .moa: products.contains { !$0.moa.isEmpty }
            case .cost: products.contains { !$0.estimatedCost.isEmpty }
            }
        }
    }
    static func widths(_ columns: [ProgramPDFColumn], total: Double = 770) -> [Double] {
        let freed = 100 - columns.reduce(0) { $0 + $1.weight }
        let reclaim = columns.reduce(0) { $0 + $1.reclaim }
        return columns.map { total * ($0.weight + freed * $0.reclaim / max(1, reclaim)) / 100 }
    }
    static func needsFreshPage(height: Double, y: Double, top: Double, bottom: Double = 548) -> Bool {
        y > top && y + height > bottom
    }
    static func slice(height: Double, offset: Double, available: Double, boundaries: [Double]) -> Double {
        if height - offset <= available { return height - offset }
        if let end = boundaries.map({ $0 + 4 }).last(where: { $0 > offset && $0 <= offset + available }) { return end - offset }
        return floor((offset + available - 4) / 10) * 10 + 4 - offset
    }
    static func methodStyle(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "foliar": "gold"
        case "banded": "green"
        default: "neutral"
        }
    }
    /// Only recognised metadata fragments in legacy detail sections are removed.
    /// Unrecognised text and operational restrictions remain verbatim; storage is untouched.
    static func comments(_ raw: String) -> String {
        let marker = "(?i)product details\\s*[-–—]\\s*([^:\\n]+):"
        let marked = raw.replacingOccurrences(of: marker, with: "\u{001F}$1:\u{001E}", options: .regularExpression)
        let parts = marked.components(separatedBy: "\u{001F}")
        var output: [String] = []
        for (index, part) in parts.enumerated() {
            var text = part
            if index > 0 {
                let fields = "(?i)^(?:rate\\s*(?:/\\s*100\\s*l|/\\s*ha|per\\s*100\\s*l|per\\s*ha)?|moa|est\\s*\\$\\s*/\\s*ha)\\s*[:=]?\\s*[MU$]?[0-9][0-9.,–+MU\\- /]*\\s*(?:kg|g|ml|l)?\\s*(?:/\\s*(?:100\\s*l|treated\\s*ha|ha))?$"
                let heading = text.components(separatedBy: "\u{001E}")
                let body = heading.dropFirst().joined(separator: "\u{001E}")
                let instructions = body.components(separatedBy: CharacterSet(charactersIn: ";|\n"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0.range(of: fields, options: .regularExpression) == nil }
                if instructions.isEmpty { continue }
                text = (heading.first ?? "") + " " + instructions.joined(separator: "\n")
            }
            output.append(contentsOf: text.components(separatedBy: .newlines).filter {
                !["", "rate set when planning", "no data", "n/a", "none", "unknown", "-"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            })
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Break within a token only when that token itself exceeds the column.
    static func wrap(_ text: String, width: Double, measure: (String) -> Double) -> [String] {
        if text.isEmpty { return [] }
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                if !line.isEmpty && measure(line + " " + word) > width { lines.append(line); line = "" }
                if measure(word) <= width { line += (line.isEmpty ? "" : " ") + word }
                else {
                    if !line.isEmpty { lines.append(line); line = "" }
                    for character in word {
                        if !line.isEmpty && measure(line + String(character)) > width { lines.append(line); line = "" }
                        line.append(character)
                    }
                }
            }
            lines.append(line)
        }
        return lines
    }
}
