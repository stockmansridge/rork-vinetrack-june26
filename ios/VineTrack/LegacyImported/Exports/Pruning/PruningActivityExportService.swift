import Foundation
import OSLog
import UIKit

/// Writes and shares the Pruning Activity Report as CSV or PDF, mirroring the
/// Android `PruningActivityExportService`.
///
/// Both formats are built from `PruningActivityExport`, so the allocation
/// breakdown, the allocated-share maths, the partial-activity marker and the
/// labour authority order are identical on the two platforms and identical
/// between the two formats.
///
/// The caller passes the report's ALREADY filtered and sorted rows, so an export
/// always reflects exactly what is on screen — same date range, season, block,
/// worker, method, linked/unlinked and reversed options, same search, same sort.
/// It ALSO passes the canonical (unfiltered) rows, which supply the parent
/// activity context and the allocation-share denominator so a filtered extract
/// never hands one block 100% of a multi-block activity's cost.
///
/// `includeCost = false` (supervisor/operator) removes BOTH the whole-activity
/// and the allocated cost columns from the CSV and the cost lines from the PDF
/// entirely; hours stay visible.
///
/// ## Identifiers
///
/// The CSV keeps the full activity and allocation ids — it exists to be
/// reconciled. The PDF does not print them in its body: it shows the activity's
/// name and an eight-character short reference, and retains the full ids in the
/// document metadata plus, on request, a technical-references appendix.
///
/// Files are written to the app's temporary directory and shared with the system
/// share sheet. Nothing is uploaded.
nonisolated enum PruningActivityExportService {

    // A4 portrait — the grouped layout reads as a document, not a spreadsheet.
    private static let pageWidth: CGFloat = 595
    private static let pageHeight: CGFloat = 842
    private static let margin: CGFloat = 36

    private static let accent = UIColor(red: 85 / 255, green: 107 / 255, blue: 47 / 255, alpha: 1)
    private static let warning = UIColor(red: 0.6, green: 0.15, blue: 0.15, alpha: 1)

    private static let log = Logger(subsystem: "com.vinetrack.app", category: "PruningActivityExport")

    /// Parent-context conflicts go to the log with the activity id and the
    /// competing values — never silently swallowed.
    private static func logConflicts(_ model: PruningActivityAllocationModel) {
        guard model.hasConflicts else { return }
        log.warning(
            "\(model.conflicts.count) parent-context conflict(s) across \(model.conflictedActivityIds.count) activity(ies)"
        )
        for conflict in model.conflicts {
            log.warning("\(conflict.description, privacy: .public)")
        }
    }

    /// Writes the CSV and returns its file URL for sharing.
    static func csvURL(
        rows: [PruningActivityRow],
        vineyardName: String,
        seasonLabel: String,
        includeCost: Bool,
        canonicalRows: [PruningActivityRow]? = nil,
        canonicalParents: [UUID: PruningActivityParentSource] = [:],
        calendar: Calendar = .current
    ) throws -> URL {
        logConflicts(
            PruningActivityAllocationModel.build(
                canonicalRows ?? rows,
                includeCost: includeCost,
                canonicalParents: canonicalParents
            )
        )
        let csv = PruningActivityExport.csv(
            rows,
            includeCost: includeCost,
            canonicalRows: canonicalRows,
            calendar: calendar
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(vineyardName: vineyardName, seasonLabel: seasonLabel, extension: "csv"))
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Renders the grouped PDF and returns its file URL for sharing.
    ///
    /// - Parameter includeTechnicalReferences: appends a "Technical references"
    ///   section listing the full activity and allocation ids. Off by default:
    ///   the body of the report is for people, and a UUID in it is noise. The
    ///   full ids are in the document metadata either way.
    static func pdfURL(
        rows: [PruningActivityRow],
        vineyardName: String,
        seasonLabel: String,
        includeCost: Bool,
        canonicalRows: [PruningActivityRow]? = nil,
        canonicalParents: [UUID: PruningActivityParentSource] = [:],
        includeTechnicalReferences: Bool = false,
        calendar: Calendar = .current
    ) throws -> URL {
        let model = PruningActivityAllocationModel.build(
            canonicalRows ?? rows,
            includeCost: includeCost,
            canonicalParents: canonicalParents
        )
        logConflicts(model)
        let groups = PruningActivityExport.groups(
            rows,
            includeCost: includeCost,
            model: model,
            calendar: calendar
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName(vineyardName: vineyardName, seasonLabel: seasonLabel, extension: "pdf"))
        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let format = UIGraphicsPDFRendererFormat()
        // Full ids are RETAINED here rather than printed: searchable metadata
        // for whoever needs to reconcile, invisible to whoever is just reading.
        format.documentInfo = [
            kCGPDFContextTitle as String: "Pruning Activity Report",
            kCGPDFContextSubject as String: [vineyardName, seasonLabel]
                .filter { !$0.isEmpty }
                .joined(separator: " — "),
            kCGPDFContextKeywords as String: groups.map(\.activityId).joined(separator: " ")
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

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
            let allocationCount = groups.reduce(0) { $0 + $1.includedAllocationCount }
            let partialCount = groups.filter(\.isPartialActivity).count
            var counts = "\(groups.count) \(groups.count == 1 ? "activity" : "activities"), \(allocationCount) allocations"
            if partialCount > 0 { counts += "  •  \(partialCount) partially shown" }
            cursor += draw(counts, x: margin, font: .systemFont(ofSize: 10), colour: .darkGray) + 2

            // Data-quality warning, before any figure it might affect.
            let conflicted = groups.filter { !model.conflicts($0.id).isEmpty }.count
            if let notice = PruningActivityExport.conflictNotice(conflictedActivities: conflicted) {
                cursor += draw(notice, x: margin, font: .boldSystemFont(ofSize: 10), colour: warning) + 2
            }
            cursor += 10

            for group in groups {
                // Header + labour block + the allocation list must not be split
                // across a page break: the allocations are meaningless without
                // the activity totals they belong to.
                let needed = 52 + CGFloat(group.allocations.count) * 26
                    + (group.isPartialActivity ? 14 : 0)
                    + (group.notes == nil ? 0 : 28)
                ensure(min(needed, pageHeight - 2 * margin))

                context.cgContext.setStrokeColor(UIColor(white: 0.86, alpha: 1).cgColor)
                context.cgContext.setLineWidth(0.5)
                context.cgContext.move(to: CGPoint(x: margin, y: cursor))
                context.cgContext.addLine(to: CGPoint(x: pageWidth - margin, y: cursor))
                context.cgContext.strokePath()
                cursor += 8

                // The activity's NAME is the label. The eight-character
                // reference follows it in small grey type; the full UUID never
                // appears in the body of the document.
                let heading = "\(group.activityLabel) — \(group.dateDisplay)"
                    + (group.isReversed ? "   REVERSED" : "")
                cursor += draw(
                    heading,
                    x: margin,
                    font: .boldSystemFont(ofSize: 12.5),
                    colour: group.isReversed ? warning : accent
                ) + 1
                if let reference = PruningActivityExport.referenceLine(group, includeShortReferences: true) {
                    cursor += draw(
                        reference,
                        x: margin,
                        font: .systemFont(ofSize: 8),
                        colour: UIColor(white: 0.55, alpha: 1)
                    ) + 3
                }

                let groupConflicts = model.conflicts(group.id)
                if !groupConflicts.isEmpty {
                    ensure(14)
                    let fields = groupConflicts.map { $0.field.label.lowercased() }.joined(separator: ", ")
                    cursor += draw(
                        "Conflicting source records — \(fields)",
                        x: margin + 6,
                        font: .boldSystemFont(ofSize: 10),
                        colour: warning
                    ) + 2
                }

                // A partial activity says so BEFORE its totals, so the
                // whole-activity figures below can never be mistaken for the
                // filtered block's.
                if let partial = group.partialLabel {
                    ensure(14)
                    cursor += draw(
                        partial,
                        x: margin + 6,
                        font: .boldSystemFont(ofSize: 10),
                        colour: UIColor(red: 0.69, green: 0.42, blue: 0.08, alpha: 1)
                    ) + 2
                }

                // Whole-activity values, stated exactly once.
                for line in activityLines(group, includeCost: includeCost) {
                    ensure(14)
                    cursor += draw(line, x: margin + 6, font: .systemFont(ofSize: 10.5)) + 2
                }

                cursor += 4
                ensure(14)
                let allocationHeading: String
                if group.isPartialActivity {
                    allocationHeading = "Allocations shown (\(group.includedAllocationCount) of \(group.fullAllocationCount))"
                } else if group.isMultiBlock {
                    allocationHeading = "Allocations (\(group.includedAllocationCount))"
                } else {
                    allocationHeading = "Allocation"
                }
                cursor += draw(allocationHeading, x: margin + 6, font: .boldSystemFont(ofSize: 10.5)) + 2

                for allocation in group.allocations {
                    ensure(14)
                    cursor += draw(
                        "\(allocation.allocationNumber). \(allocationLine(allocation))",
                        x: margin + 14,
                        font: .systemFont(ofSize: 10.5)
                    ) + 2
                    // This block's proportional slice, on its own indented line so
                    // it is never confused with the whole-activity totals above.
                    if let allocated = allocatedLine(allocation, includeCost: includeCost) {
                        ensure(13)
                        cursor += draw(
                            allocated,
                            x: margin + 26,
                            font: .systemFont(ofSize: 9.5),
                            colour: .darkGray
                        ) + 2
                    }
                }

                if group.isPartialActivity, let subtotal = allocatedSubtotal(group, includeCost: includeCost) {
                    ensure(14)
                    cursor += draw(subtotal, x: margin + 14, font: .boldSystemFont(ofSize: 10)) + 2
                }

                if let notes = group.notes {
                    cursor += 3
                    ensure(16)
                    cursor += draw("Notes: \(notes)", x: margin + 6, font: .systemFont(ofSize: 10), colour: .darkGray) + 2
                }

                cursor += 10
            }

            // Full ids live here and nowhere else in the visible document, and
            // only when the reader asked for them.
            if includeTechnicalReferences, !groups.isEmpty {
                ensure(40)
                cursor += draw(
                    PruningActivityExport.technicalReferencesHeading,
                    x: margin,
                    font: .boldSystemFont(ofSize: 12.5),
                    colour: accent
                ) + 4
                for group in groups {
                    for (index, line) in PruningActivityExport.technicalReferenceLines(group).enumerated() {
                        ensure(13)
                        cursor += draw(
                            line,
                            x: margin + (index == 0 ? 0 : 10),
                            font: index == 0 ? .boldSystemFont(ofSize: 9.5) : .systemFont(ofSize: 8.5),
                            colour: index == 0 ? .black : .darkGray
                        ) + 1
                    }
                    cursor += 4
                }
            }
        }

        return url
    }

    /// The WHOLE activity's values — worker, hours, cost, task, timing. Blank
    /// values are omitted rather than printed as zero.
    ///
    /// On a partial activity these are explicitly labelled "Whole activity", so
    /// a reader can never take them for the filtered block's cost.
    private static func activityLines(_ group: PruningActivityExport.Group, includeCost: Bool) -> [String] {
        let partial = group.isPartialActivity
        var lines: [String] = []
        if let worker = group.worker { lines.append("Worker: \(worker)") }
        lines.append("Method: \(group.method)")
        if let hours = group.activityOperationalHours {
            lines.append(partial ? "Whole activity operational hours: \(trim(hours))"
                                 : "Operational hours: \(trim(hours))")
        }
        if let personHours = group.activityPersonHours {
            lines.append(partial ? "Whole activity person-hours: \(trim(personHours))"
                                 : "Person-hours: \(trim(personHours))")
        }
        if includeCost, let cost = group.activityLabourCost {
            let amount = PruningActivityExport.number(cost, decimals: 2)
            lines.append(partial ? "Whole activity labour cost: $\(amount)" : "Labour cost: $\(amount)")
        }
        if let title = group.workTaskTitle {
            let status = group.workTaskStatus.map { " (\($0))" } ?? ""
            lines.append("Work Task: \(title)\(status)")
        }
        if group.startTime != nil || group.finishTime != nil {
            let span = [group.startTime, group.finishTime].compactMap { $0 }.joined(separator: " – ")
            let duration = group.activityDurationHours.map { " (\(trim($0)) h)" } ?? ""
            lines.append("Times: \(span)\(duration)")
        }
        return lines
    }

    /// "20.0% of the activity · 2.6 person-hours · $91.00".
    private static func allocatedLine(_ row: PruningActivityExport.Row, includeCost: Bool) -> String? {
        var parts: [String] = []
        if let share = row.allocationShare {
            parts.append("\(PruningActivityExport.number(share * 100, decimals: 1))% of the activity")
        }
        if let hours = row.allocatedPersonHours { parts.append("\(trim(hours)) person-hours") }
        if includeCost, let cost = row.allocatedLabourCost {
            parts.append("$\(PruningActivityExport.number(cost, decimals: 2))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The shown blocks' combined slice, printed only when blocks are missing.
    private static func allocatedSubtotal(_ group: PruningActivityExport.Group, includeCost: Bool) -> String? {
        var parts: [String] = []
        if let hours = group.allocatedPersonHours { parts.append("\(trim(hours)) person-hours") }
        if includeCost, let cost = group.allocatedLabourCost {
            parts.append("$\(PruningActivityExport.number(cost, decimals: 2))")
        }
        return parts.isEmpty ? nil : "Allocated to shown blocks: \(parts.joined(separator: " · "))"
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
