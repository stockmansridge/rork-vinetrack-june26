import Foundation
import UIKit

/// Builds the Growth Stage vintage-timeline PDF.
///
/// Extracted from the old report screen so the export can be triggered
/// directly from the toolbar. The share control is only worth keeping if it
/// actually exports something; routing it through a report popup just to reach
/// this code was the reason it looked like a navigation control.
///
/// Read-only: it reads pins and paddocks and writes a temporary file. It never
/// touches the Growth Stage write or sync path.
nonisolated enum GrowthStageReportExport {

    nonisolated enum ExportError: LocalizedError {
        case noData

        var errorDescription: String? {
            switch self {
            case .noData: return "No growth stage data available to export."
            }
        }
    }

    /// Season-relative vintage for a timestamp.
    static func vintageYear(
        for date: Date,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        timeZone: TimeZone
    ) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 2000
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        // A season that opens late in the calendar year belongs to the next
        // vintage, matching `ELRipenessSeason`.
        if month > seasonStartMonth || (month == seasonStartMonth && day >= seasonStartDay) {
            return year + 1
        }
        return year
    }

    private static func palette(_ index: Int) -> UIColor {
        let colors: [UIColor] = [
            .systemGreen, .systemBlue, .systemOrange, .systemPurple,
            .systemTeal, .systemPink, .systemIndigo, .systemBrown
        ]
        return colors[index % colors.count]
    }

    /// Assembles the per-block report rows the PDF service expects.
    static func blockReports(
        pins: [VinePin],
        paddocks: [Paddock],
        seasonStartMonth: Int,
        seasonStartDay: Int,
        timeZone: TimeZone
    ) -> [GrowthStageReportPDFService.BlockReport] {
        paddocks.compactMap { paddock in
            let blockPins = pins.filter { $0.paddockId == paddock.id && $0.growthStageCode != nil }
            guard !blockPins.isEmpty else { return nil }

            let vintages = Set(
                blockPins.map {
                    vintageYear(
                        for: $0.timestamp,
                        seasonStartMonth: seasonStartMonth,
                        seasonStartDay: seasonStartDay,
                        timeZone: timeZone
                    )
                }
            ).sorted(by: >)

            let usedCodes = Set(blockPins.compactMap { $0.growthStageCode })
            let stageCodes = GrowthStage.allStages.map(\.code).filter { usedCodes.contains($0) }

            var entries: [Int: [String: Date]] = [:]
            for vintage in vintages {
                var codeMap: [String: Date] = [:]
                for pin in blockPins {
                    let pinVintage = vintageYear(
                        for: pin.timestamp,
                        seasonStartMonth: seasonStartMonth,
                        seasonStartDay: seasonStartDay,
                        timeZone: timeZone
                    )
                    guard pinVintage == vintage, let code = pin.growthStageCode else { continue }
                    // First observation of each stage wins.
                    if let existing = codeMap[code] {
                        if pin.timestamp < existing { codeMap[code] = pin.timestamp }
                    } else {
                        codeMap[code] = pin.timestamp
                    }
                }
                entries[vintage] = codeMap
            }

            return GrowthStageReportPDFService.BlockReport(
                blockName: paddock.name,
                vintages: vintages,
                stageCodes: stageCodes,
                entries: entries
            )
        }
    }

    /// Renders the simple visible-record report and returns a shareable file.
    static func export(
        records: [GrowthStageRecord],
        paddocks: [Paddock],
        vineyardName: String,
        logoData: Data?,
        timeZone: TimeZone,
        dateFormat: String,
        localeIdentifier: String?
    ) throws -> URL {
        let names = Dictionary(uniqueKeysWithValues: paddocks.map { ($0.id, $0.name) })
        let entries = records.compactMap { record -> GrowthStageReportPDFService.RecordEntry? in
            guard !record.stageCode.isEmpty else { return nil }
            return GrowthStageReportPDFService.RecordEntry(
                observedAt: record.observedAt,
                blockName: record.paddockId.flatMap { names[$0] } ?? "—",
                stage: record.stageCode,
                recorder: record.recordedByName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? record.recordedByName!
                    : "—"
            )
        }
        guard !entries.isEmpty else { throw ExportError.noData }
        let data = GrowthStageReportPDFService.generateRecordPDF(
            records: entries,
            vineyardName: vineyardName,
            logoData: logoData,
            timeZone: timeZone,
            dateFormat: dateFormat,
            localeIdentifier: localeIdentifier
        )
        let fileName = "GrowthStageRecords_\(Date().formatted(.iso8601.year().month().day()))"
        return GrowthStageReportPDFService.savePDFToTemp(data: data, fileName: fileName)
    }

    /// Legacy timeline renderer retained for existing report callers.
    static func export(
        pins: [VinePin],
        paddocks: [Paddock],
        vineyardName: String,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        timeZone: TimeZone,
        dateFormat: String,
        localeIdentifier: String?
    ) throws -> URL {
        let blocks = blockReports(
            pins: pins,
            paddocks: paddocks,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            timeZone: timeZone
        )
        guard !blocks.isEmpty else { throw ExportError.noData }

        var vintageColors: [Int: UIColor] = [:]
        for (index, vintage) in Array(Set(blocks.flatMap(\.vintages))).sorted(by: >).enumerated() {
            vintageColors[vintage] = palette(index)
        }

        let data = GrowthStageReportPDFService.generatePDF(
            blocks: blocks,
            vineyardName: vineyardName,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            vintageColors: vintageColors,
            logoData: nil,
            timeZone: timeZone,
            dateFormat: dateFormat,
            localeIdentifier: localeIdentifier
        )
        let fileName = "GrowthStageReport_\(Date().formatted(.iso8601.year().month().day()))"
        return GrowthStageReportPDFService.savePDFToTemp(data: data, fileName: fileName)
    }
}
