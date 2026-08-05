import Foundation
import UIKit

/// Writes and shares the Pruning Activity Report as CSV or PDF, mirroring the
/// Android `PruningActivityExportService`.
///
/// Both formats are built from `PruningActivityExport`, so the allocation
/// breakdown, the "activity totals on the first allocation row only" rule and the
/// labour authority order are identical on the two platforms and identical
/// between the two formats.
///
/// The caller passes the report's ALREADY filtered and sorted rows, so an export
/// always reflects exactly what is on screen — same date range, season, block,
/// worker, method, linked/unlinked and reversed options, same search, same sort.
///
/// `includeCost = false` (supervisor/operator) removes the labour cost column
/// from the CSV and the cost line from the PDF entirely; hours stay visible.
///
/// Files are written to the app's temporary directory and shared with the system
/// share sheet. Nothing is uploaded.
nonisolated enum PruningActivityExportService {

    // A4 portrait — the grouped layout reads as a document, not a spreadsheet.
    private static let pageWidth: CGFloat = 595
    private static let pageHeight: CGFloat = 842
    private static let margin: CGFloat = 36

    private static let accent = UIColor(red: 85 / 255, green: 107 / 255, blue: 47 / 255, alpha: 1)

    /// Writes the CSV and returns its file URL for sharing.
    static func csvURL(
        rows: [PruningActivityRow],
        vineyardName: String,
        seasonLabel: String,
        includeCost: Bool,
        calendar: Calendar = .current
    ) throws -> URL {
        let csv = PruningActivityExport.csv(rows, includeCost: includeCost, calendar: calendar)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(vineyardName: vineyardName, seasonLabel: seasonLabel, extension: "csv"))
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Renders the grouped PDF and returns its file URL for sharing.
    static func pdfURL(
        rows: [PruningActivityRow],
        vineyardName: String,
        seasonLabel: String,
        includeCost: Bool,
        calendar: Calendar = .current
    ) throws -> URL {
        let groups = PruningActivityExport.groups(rows, includeCost: includeCost, calendar: calendar)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(vineyardName: vineyardName, seasonLabel: seasonLabel, extension: "pdf"))
        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        try renderer.writePDF(to: url) { context in
            var cursor = margin
            context.beginPage()

            /// Starts a new page when the next block would cross the bottom margin.
            func ensure(_ needed: CGFloat) {
                if cursor + needed > pageHeight - margin {
                    context.beginPage()
                    cursor = margin
                }
            }

            func draw(_ text: String, x: CGFloat, font: UIFont, colour: UIColor = .black) -> CGFloat {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
                let width = pageWidth - margin - x
                let rect = CGRect(x: x, y: cursor, width: width, height: .greatestFiniteMagnitude)
                let bounding = (text as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                )
                (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
                return ceil(bounding.height)
            }

            cursor += draw("Pruning Activity Report", x: margin, font: .boldSystemFont(ofSize: 19)) + 6
            let subtitle = [vineyardName, seasonLabel].filter { !$0.isEmpty }.joined(separator: "  •  ")
            if !subtitle.isEmpty {
                cursor += draw(subtitle, x: margin, font: .systemFont(ofSize: 10), colour: .darkGray) + 2
            }
            let allocationCount = groups.reduce(0) { $0 + $1.allocationCount }
            cursor += draw(
                "\(groups.count) \(groups.count == 1 ? "activity" : "activities"), \(allocationCount) allocations",
                x: margin,
                font: .systemFont(ofSize: 10),
                colour: .darkGray
            ) + 12

            for group in groups {
                // Header + labour block + the allocation list must not be split
                // across a page break: the allocations are meaningless without
                // the activity totals they belong to.
                let needed = 52 + CGFloat(group.allocations.count) * 14 + (group.notes == nil ? 0 : 28)
                ensure(min(needed, pageHeight - 2 * margin))

                context.cgContext.setStrokeColor(UIColor(white: 0.86, alpha: 1).cgColor)
                context.cgContext.setLineWidth(0.5)
                context.cgContext.move(to: CGPoint(x: margin, y: cursor))
                context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: cursor))
                context.cgContext.strokePath()
                cursor += 8

                let heading = "\(group.activityLabel) — \(group.dateDisplay)"
                    + (group.isReversed ? "   REVERSED" : "")
                cursor += draw(
                    heading,
                    x: margin,
                    font: .boldSystemFont(ofSize: 12.5),
                    colour: group.isReversed ? UIColor(red: 0.6, green: 0.15, blue: 0.15, alpha: 1) : accent
                ) + 4

                // Activity-level values, stated exactly once.
                for line in activityLines(group, includeCost: includeCost) {
                    ensure(14)
                    cursor += draw(line, x: margin + 6, font: .systemFont(ofSize: 10.5)) + 2
                }

                cursor += 4
                ensure(14)
                cursor += draw(
                    group.isMultiBlock ? "Allocations (\(group.allocationCount))" : "Allocation",
                    x: margin + 6,
                    font: .boldSystemFont(ofSize: 10.5)
                ) + 2

                for allocation in group.allocations {
                    ensure(14)
                    cursor += draw(
                        "\(allocation.allocationNumber). \(allocationLine(allocation))",
                        x: margin + 14,
                        font: .systemFont(ofSize: 10.5)
                    ) + 2
                }

                if let notes = group.notes {
                    cursor += 3
                    ensure(16)
                    cursor += draw("Notes: \(notes)", x: margin + 6, font: .systemFont(ofSize: 10), colour: .darkGray) + 2
                }

                cursor += 10
            }
        }

        return url
    }

    /// The activity's own values — worker, hours, cost, task, timing. Blank
    /// values are omitted rather than printed as zero.
    private static func activityLines(_ group: PruningActivityExport.Group, includeCost: Bool) -> [String] {
        var lines: [String] = []
        if let worker = group.worker { lines.append("Worker: \(worker)") }
        lines.append("Method: \(group.method)")
        if let hours = group.operationalHours { lines.append("Operational hours: \(trim(hours))") }
        if let personHours = group.personHours { lines.append("Person-hours: \(trim(personHours))") }
        if includeCost, let cost = group.labourCost {
            lines.append("Labour cost: $\(PruningActivityExport.number(cost, decimals: 2))")
        }
        if let title = group.workTaskTitle {
            let status = group.workTaskStatus.map { " (\($0))" } ?? ""
            lines.append("Work Task: \(title)\(status)")
        }
        if group.startTime != nil || group.finishTime != nil {
            let span = [group.startTime, group.finishTime].compactMap { $0 }.joined(separator: " – ")
            let duration = group.durationHours.map { " (\(trim($0)) h)" } ?? ""
            lines.append("Times: \(span)\(duration)")
        }
        return lines
    }

    /// "Pinot Noir — rows 90–108 · 4 quarters · 1.0 row eq · 210 vines".
    private static func allocationLine(_ row: PruningActivityExport.Row) -> String {
        var parts: [String] = [row.variety.map { "\(row.blockName) (\($0))" } ?? row.blockName]
        if let rowRange = row.rowRange { parts.append("rows \(rowRange)") }
        if row.quarters > 0 { parts.append("\(row.quarters) quarters") }
        if row.rowEquivalents > 0 {
            parts.append("\(PruningActivityExport.number(row.rowEquivalents, decimals: 2)) row eq")
        }
        if let vines = row.estimatedVines {
            parts.append("\(PruningActivityExport.number(vines, decimals: 0)) vines")
        }
        return parts.joined(separator: " · ")
    }

    /// Drops a trailing ".0" so "6.0 h" reads as "6 h" where exact.
    private static func trim(_ value: Double) -> String {
        var text = PruningActivityExport.number(value, decimals: 2)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }

    private static func fileName(vineyardName: String, seasonLabel: String, extension ext: String) -> String {
        let today = PruningActivityExport.isoDate(Date())
        let raw = "\(vineyardName.isEmpty ? "Vineyard" : vineyardName)_\(seasonLabel.isEmpty ? today : seasonLabel)"
        let safe = raw
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").inverted)
            .joined()
        return "PruningActivityReport_\(safe).\(ext)"
    }
}
