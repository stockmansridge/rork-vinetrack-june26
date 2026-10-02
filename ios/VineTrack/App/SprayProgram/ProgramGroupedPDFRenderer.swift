import Foundation
import UIKit

/// A4 landscape spreadsheet renderer. Only this reference PDF uses grouped cells.
@MainActor enum ProgramGroupedPDFRenderer {
    private struct Line {
        let text: String
        let font: UIFont
        let y: CGFloat
    }
    private struct Cell {
        let column: ProgramPDFColumn
        let x: CGFloat
        let width: CGFloat
        let lines: [Line]
    }
    static func write(rows: [SprayProgramReferenceRow], vineyard: String, logo: Data?) throws -> URL {
        let blocks = ProgramStepExportBlock.grouped(rows)
        let columns = ProgramPDFLayout.columns(blocks)
        let widths = ProgramPDFLayout.widths(columns).map { CGFloat($0) }
        let font = UIFont.systemFont(ofSize: 8)
        let secondary = UIFont.systemFont(ofSize: 7)
        let bold = UIFont.boldSystemFont(ofSize: 8)
        let green = UIColor(red: 0.16, green: 0.29, blue: 0.22, alpha: 1)
        func lines(_ text: String, width: CGFloat, font: UIFont, y: CGFloat) -> [Line] {
            ProgramPDFLayout.wrap(text, width: Double(width - 8)) { Double(($0 as NSString).size(withAttributes: [.font: font]).width) }
                .enumerated().map { Line(text: $0.element, font: font, y: y + CGFloat($0.offset) * 10) }
        }
        let titleX: CGFloat = logo == nil ? 36 : 76
        let title = lines("\(vineyard) — Spray Program", width: 806 - titleX, font: UIFont.boldSystemFont(ofSize: 17), y: 26)
        let headerTop = 50 + CGFloat(title.count) * 20
        let bodyTop = headerTop + 24
        guard bodyTop < 508 else { throw NSError(domain: "ProgramPDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "The vineyard heading is too long to fit this report."]) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 842, height: 595))
        let data = renderer.pdfData { context in
            var page = 0
            var y: CGFloat = bodyTop
            func text(_ value: String, x: CGFloat, y: CGFloat, font: UIFont, color: UIColor = .black) {
                (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
            }
            func rule(_ x: CGFloat, _ y: CGFloat, _ right: CGFloat, _ bottom: CGFloat, strong: Bool = false) {
                let cg = context.cgContext
                cg.setStrokeColor((strong ? green : UIColor(white: 0.75, alpha: 1)).cgColor)
                cg.setLineWidth(strong ? 1 : 0.35)
                cg.move(to: CGPoint(x: x, y: y)); cg.addLine(to: CGPoint(x: right, y: bottom)); cg.strokePath()
            }
            @MainActor func newPage() {
                context.beginPage(); page += 1; y = bodyTop
                if let logo, let image = UIImage(data: logo) {
                    let scale = min(32 / image.size.width, 32 / image.size.height)
                    image.draw(in: CGRect(x: 36, y: 27, width: image.size.width * scale, height: image.size.height * scale))
                }
                for (index, line) in title.enumerated() { text(line.text, x: titleX, y: 26 + CGFloat(index) * 20, font: line.font, color: green) }
                text("VineTrack · Program reference", x: titleX, y: headerTop - 17, font: secondary, color: green)
                green.setFill(); context.cgContext.fill(CGRect(x: 36, y: headerTop, width: 770, height: 24))
                var x: CGFloat = 36
                for (index, column) in columns.enumerated() {
                    for line in lines(column.title, width: widths[index], font: bold, y: headerTop + 4) {
                        text(line.text, x: x + 4, y: line.y, font: line.font, color: .white)
                    }
                    x += widths[index]
                }
                for line in lines(SprayProgramReferenceDataset.footer, width: 708, font: secondary, y: 559) {
                    text(line.text, x: 36, y: line.y, font: line.font)
                }
                text("Page \(page)", x: 765, y: 559, font: secondary)
            }
            newPage()
            for block in blocks {
                let row = block.reference
                var cells: [Cell] = []
                var boundaries: [CGFloat] = []
                var productTop: CGFloat = 0
                var sharedHeight: CGFloat = 0
                var sharedX: CGFloat = 36
                for (i, column) in columns.enumerated() {
                    if column.isShared {
                        var contents: [Line] = []
                        switch column {
                        case .timing:
                            contents = lines(block.timing, width: widths[i], font: bold, y: 4)
                            let stageY = CGFloat(contents.count) * 10 + 4
                            contents += lines(block.stage, width: widths[i], font: secondary, y: stageY)
                            contents += lines(block.growthDescription, width: widths[i], font: secondary, y: CGFloat(contents.count) * 10 + 4)
                        case .targets: contents = lines(row.targets, width: widths[i], font: font, y: 4)
                        case .method:
                            contents = lines(row.method, width: widths[i], font: bold, y: 4)
                            contents += lines(row.equipment, width: widths[i], font: secondary, y: CGFloat(contents.count) * 10 + 4)
                        case .comments: contents = lines(block.comments, width: widths[i], font: font, y: 4)
                        default: break
                        }
                        sharedHeight = max(sharedHeight, CGFloat(contents.count) * 10 + 10)
                        cells.append(Cell(column: column, x: sharedX, width: widths[i], lines: contents))
                    }
                    sharedX += widths[i]
                }
                for product in block.products {
                    var x: CGFloat = 36
                    var rowHeight: CGFloat = 20
                    var productCells: [Cell] = []
                    for (i, column) in columns.enumerated() {
                        if !column.isShared {
                            let value: String
                            switch column {
                            case .product: value = product.name.isEmpty ? "No product configured" : product.name
                            case .per100L: value = product.per100L
                            case .perHa: value = product.perHa
                            case .moa: value = product.moa
                            case .cost: value = product.estimatedCost
                            default: value = ""
                            }
                            var contents = lines(value, width: widths[i], font: column == .product ? bold : font, y: productTop + 4)
                            if column == .product && product.unknownRate {
                                contents += lines(SprayProgramReferenceDataset.unplannedRate, width: widths[i], font: secondary, y: productTop + 4 + CGFloat(contents.count) * 10)
                            }
                            rowHeight = max(rowHeight, CGFloat(contents.count) * 10 + 10)
                            productCells.append(Cell(column: column, x: x, width: widths[i], lines: contents))
                        }
                        x += widths[i]
                    }
                    cells += productCells
                    productTop += rowHeight; boundaries.append(productTop)
                }
                let height = max(sharedHeight, productTop)
                if ProgramPDFLayout.needsFreshPage(height: Double(height), y: Double(y), top: Double(bodyTop)) { newPage() }
                var offset: CGFloat = 0
                while offset < height {
                    if offset > 0 {
                        newPage()
                        let heading = lines("\(block.stage) (continued)\n\(block.timing)", width: 770, font: secondary, y: y + 2)
                        for line in heading.prefix(3) { text(line.text, x: 40, y: line.y, font: line.font, color: green) }
                        y += CGFloat(min(3, heading.count)) * 10 + 8
                    }
                    let available = 548 - y
                    let slice = CGFloat(ProgramPDFLayout.slice(height: Double(height), offset: Double(offset), available: Double(available), boundaries: boundaries.map { Double($0) }))
                    let cg = context.cgContext
                    for cell in cells where cell.column.isShared {
                        if cell.column == .method {
                            let fill: UIColor = switch ProgramPDFLayout.methodStyle(row.method) {
                            case "gold": UIColor(red: 1, green: 0.91, blue: 0.55, alpha: 1)
                            case "green": UIColor(red: 0.75, green: 0.89, blue: 0.68, alpha: 1)
                            default: UIColor(white: 0.95, alpha: 1)
                            }
                            fill.setFill(); cg.fill(CGRect(x: cell.x, y: y, width: cell.width, height: slice))
                        }
                    }
                    for cell in cells {
                        cg.saveGState()
                        cg.clip(to: CGRect(x: cell.x + 2, y: y, width: cell.width - 4, height: slice))
                        for line in cell.lines where line.y + 8 > offset && line.y < offset + slice {
                            text(line.text, x: cell.x + 4, y: y + line.y - offset, font: line.font)
                        }
                        cg.restoreGState()
                    }
                    var x: CGFloat = 36
                    rule(x, y, x, y + slice)
                    for width in widths { x += width; rule(x, y, x, y + slice) }
                    for boundary in boundaries where boundary > offset && boundary < offset + slice {
                        for cell in cells where !cell.column.isShared {
                            rule(cell.x, y + boundary - offset, cell.x + cell.width, y + boundary - offset)
                        }
                    }
                    rule(36, y, 806, y, strong: true)
                    rule(36, y + slice, 806, y + slice, strong: true)
                    y += slice; offset += slice
                }
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(SprayProgramReferenceExport.filename(vineyard: vineyard, extension: "pdf"))
        try data.write(to: url)
        return url
    }
}
