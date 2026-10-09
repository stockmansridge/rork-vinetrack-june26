import Foundation
import UIKit

/// Offline exports from one immutable saved revision. DOCX is an OOXML ZIP, not renamed text.
@MainActor enum VintageReportExport {
    static let headings: Set<String> = ["Season opening and winter conditions", "Pruning and early vineyard activity", "Budburst, frost and spring development", "Flowering, fruit set and canopy development", "Summer weather, water and disease pressure", "Veraison and ripening", "Harvest timing, yield and fruit condition", "Overall vintage summary", "Key-event timeline", "Sources and coverage"]
    static func timestamp(_ value: String, formatter: RegionFormatter) -> String {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date.map { formatter.formatDateTime($0) } ?? value
    }
    static func lines(_ revision: VintageReportRevision, vineyard: String, vintage: Int, formatter: RegionFormatter) -> [String] {
        [vineyard, "Vintage \(VintageYearText.format(vintage)) — \(revision.evidence.seasonToDate == true ? "Season to date" : "Vintage Report")",
         "Season \(formatter.formatDate(revision.evidence.seasonStart)) to \(formatter.formatDate(revision.evidence.seasonEnd)); report through \(formatter.formatDate(revision.reportThrough))",
         "Revision \(revision.revision) • saved \(timestamp(revision.createdAt, formatter: formatter)) • evidence collected \(timestamp(revision.collectedAt, formatter: formatter))"]
        + revision.content.narrative.components(separatedBy: "\n")
        + ["Key-event timeline"] + revision.content.timeline
        + ["Sources and coverage"] + revision.content.appendix
    }
    static func export(_ revision: VintageReportRevision, vineyard: String, vintage: Int, logo: Data?, word: Bool, account: UUID, formatter: RegionFormatter) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("VintageReports/\(account.uuidString)/exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Vintage-\(vintage)-\(revision.id.uuidString).\(word ? "docx" : "pdf")")
        let text = lines(revision, vineyard: vineyard, vintage: vintage, formatter: formatter)
        if word {
            let image = logo.flatMap(UIImage.init(data:))
            let jpeg = image?.jpegData(compressionQuality: 0.85)
            var drawing = ""
            if let image, jpeg != nil {
                let factor = min(64 / max(image.size.width, 1), 64 / max(image.size.height, 1))
                let width = Int(image.size.width * factor * 12700), height = Int(image.size.height * factor * 12700)
                drawing = "<w:p><w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(width)\" cy=\"\(height)\"/><wp:docPr id=\"1\" name=\"Vineyard logo\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"1\" name=\"Logo\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"rId1\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
            }
            let paragraphs = text.enumerated().map { index, line in
                let heading = index < 2 || headings.contains(line) || line.hasPrefix("Seasonal update —")
                return "<w:p><w:pPr>\(heading ? "<w:keepNext/>" : "")<w:spacing w:after=\"120\"/></w:pPr><w:r><w:rPr>\(heading ? "<w:b/><w:sz w:val=\"28\"/>" : "<w:sz w:val=\"22\"/>")</w:rPr><w:t xml:space=\"preserve\">\(escape(line))</w:t></w:r></w:p>"
            }.joined()
            let document = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>\(drawing)\(paragraphs)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\"/></w:sectPr></w:body></w:document>"
            var entries: [(String, Data)] = [
                ("[Content_Types].xml", Data("<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"jpg\" ContentType=\"image/jpeg\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>".utf8)),
                ("_rels/.rels", Data("<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".utf8)),
                ("word/document.xml", Data(document.utf8))]
            if let jpeg {
                entries.append(("word/media/logo.jpg", jpeg))
                entries.append(("word/_rels/document.xml.rels", Data("<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/logo.jpg\"/></Relationships>".utf8)))
            }
            try archive(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
            try renderer.writePDF(to: url) { context in
                var y: CGFloat = 40; var page: Int = 0
                func newPage() {
                    context.beginPage(); page += 1; y = 40
                    let footer = "\(vineyard) • Vintage \(vintage) • Revision \(revision.revision) • Page \(page)"
                    (footer as NSString).draw(at: CGPoint(x: 40, y: 809), withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray])
                }
                newPage()
                if let image = logo.flatMap(UIImage.init(data:)) {
                    let scale = min(64 / max(image.size.width, 1), 64 / max(image.size.height, 1))
                    image.draw(in: CGRect(x: 40, y: y, width: image.size.width * scale, height: image.size.height * scale)); y += 74
                }
                for (index, paragraph) in text.enumerated() {
                    let heading = headings.contains(paragraph) || paragraph.hasPrefix("Seasonal update —")
                    let font = UIFont.systemFont(ofSize: index < 2 ? 18 : heading ? 14 : 11, weight: index < 2 || heading ? .bold : .regular)
                    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style, .foregroundColor: UIColor.black]
                    // Wrap as small fragments, so even a long evidence paragraph crosses pages safely.
                    let lineHeight = ceil(font.lineHeight) + 3
                    var fragments: [String] = []
                    for token in paragraph.components(separatedBy: " ") {
                        var fragment = ""
                        for character in token {
                            if !fragment.isEmpty, ((fragment + String(character)) as NSString).size(withAttributes: attrs).width > 515 {
                                fragments.append(fragment); fragment = ""
                            }
                            fragment.append(character)
                        }
                        fragments.append(fragment)
                    }
                    var line = ""
                    for word in fragments {
                        let proposed = line.isEmpty ? word : line + " " + word
                        if (proposed as NSString).size(withAttributes: attrs).width > 515, !line.isEmpty {
                            if y + lineHeight > 785 { newPage() }
                            (line as NSString).draw(in: CGRect(x: 40, y: y, width: 515, height: lineHeight), withAttributes: attrs); y += lineHeight; line = word
                        } else { line = proposed }
                    }
                    if y + lineHeight > 785 { newPage() }
                    (line as NSString).draw(in: CGRect(x: 40, y: y, width: 515, height: lineHeight), withAttributes: attrs); y += lineHeight + 8
                }
            }
        }
        return url
    }
    private static func escape(_ text: String) -> String {
        let safe = text.unicodeScalars.map { scalar in
            scalar.value < 32 && scalar.value != 9 && scalar.value != 10 && scalar.value != 13 ? "\u{FFFD}" : String(scalar)
        }.joined()
        return safe.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    /// Uncompressed ZIP writer with CRC32 and central directory; Foundation-only, no dependency.
    private static func archive(_ entries: [(String, Data)]) -> Data {
        var out = Data(), directory = Data()
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        for (name, bytes) in entries {
            let filename = Data(name.utf8), offset = UInt32(out.count)
            var crc: UInt32 = 0xffffffff
            for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) } }
            crc ^= 0xffffffff
            append(UInt32(0x04034b50), to: &out); append(UInt16(20), to: &out)
            for value in [UInt16(0), 0, 0, 33] { append(value, to: &out) }
            append(crc, to: &out); append(UInt32(bytes.count), to: &out); append(UInt32(bytes.count), to: &out); append(UInt16(filename.count), to: &out); append(UInt16(0), to: &out); out.append(filename); out.append(bytes)
            append(UInt32(0x02014b50), to: &directory); append(UInt16(20), to: &directory); append(UInt16(20), to: &directory)
            for value in [UInt16(0), 0, 0, 33] { append(value, to: &directory) }
            append(crc, to: &directory); append(UInt32(bytes.count), to: &directory); append(UInt32(bytes.count), to: &directory); append(UInt16(filename.count), to: &directory)
            for _ in 0..<4 { append(UInt16(0), to: &directory) }
            append(UInt32(0), to: &directory); append(offset, to: &directory); directory.append(filename)
        }
        let offset = UInt32(out.count); out.append(directory)
        append(UInt32(0x06054b50), to: &out); append(UInt16(0), to: &out); append(UInt16(0), to: &out); append(UInt16(entries.count), to: &out); append(UInt16(entries.count), to: &out); append(UInt32(directory.count), to: &out); append(offset, to: &out); append(UInt16(0), to: &out)
        return out
    }
}
