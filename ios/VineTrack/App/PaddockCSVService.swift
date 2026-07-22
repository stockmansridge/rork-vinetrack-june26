import Foundation

/// Local CSV import / export for paddocks (blocks).
///
/// CSV columns:
///   id, name, vineSpacing, rowSpacing, rowDirection, plantingYear,
///   areaHectares, rowCount, vineCount, totalRowLengthMetres,
///   notes, polygonPoints, rows, varietyAllocations
///
/// `polygonPoints`, `rows`, and `varietyAllocations` are JSON-encoded blobs
/// so a round-trip preserves geometry. `areaHectares`, `vineCount`, and
/// `totalRowLengthMetres` are computed/derived columns and are ignored on
/// import.
enum PaddockCSVService {

    nonisolated struct ImportSummary: Sendable {
        var created: Int = 0
        var updated: Int = 0
        var skipped: Int = 0
        var errors: [String] = []
    }

    nonisolated enum ImportError: LocalizedError {
        case wrongFileType
        case emptyFile
        case missingHeader
        case noRows

        var errorDescription: String? {
            switch self {
            case .wrongFileType: return "This file does not appear to be a CSV. Please use a .csv file."
            case .emptyFile: return "The selected CSV file is empty."
            case .missingHeader: return "The CSV is missing a recognisable header row."
            case .noRows: return "The CSV did not contain any data rows."
            }
        }
    }

    private static let headers: [String] = [
        "id",
        "name",
        "vineSpacing",
        "rowSpacing",
        "rowDirection",
        "plantingYear",
        "areaHectares",
        "rowCount",
        "vineCount",
        "totalRowLengthMetres",
        "notes",
        "polygonPoints",
        "rows",
        "varietyAllocations"
    ]

    // MARK: - Export

    static func generateCSV(paddocks: [Paddock]) -> Data {
        var csv = headers.joined(separator: ",") + "\n"
        let encoder = JSONEncoder()
        for paddock in paddocks {
            let polygonJSON = (try? encoder.encode(paddock.polygonPoints))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let rowsJSON = (try? encoder.encode(paddock.rows))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let allocationsJSON = (try? encoder.encode(paddock.varietyAllocations))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            let row: [String] = [
                paddock.id.uuidString,
                paddock.name,
                String(format: "%.3f", paddock.vineSpacing),
                String(format: "%.3f", paddock.rowWidth),
                String(format: "%.2f", paddock.rowDirection),
                paddock.plantingYear.map { String($0) } ?? "",
                String(format: "%.4f", paddock.areaHectares),
                String(paddock.rows.count),
                String(paddock.effectiveVineCount),
                String(format: "%.1f", paddock.effectiveTotalRowLength),
                "",
                polygonJSON,
                rowsJSON,
                allocationsJSON
            ]
            csv += row.map(escapeField).joined(separator: ",") + "\n"
        }
        return Data(csv.utf8)
    }

    static func saveCSVToTemp(data: Data, fileName: String) -> URL {
        let safeName = fileName.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        try? data.write(to: url)
        return url
    }

    // MARK: - Import

    static func parseCSV(data: Data, vineyardId: UUID, existing: [Paddock]) throws -> (paddocks: [Paddock], summary: ImportSummary) {
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.wrongFileType
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.emptyFile }

        let lines = parseCSVLines(trimmed)
        guard let headerRow = lines.first, !headerRow.isEmpty else {
            throw ImportError.missingHeader
        }
        let headerMap: [String: Int] = Dictionary(uniqueKeysWithValues: headerRow.enumerated().map { ($1.lowercased(), $0) })
        guard headerMap["name"] != nil else {
            throw ImportError.missingHeader
        }

        let dataRows = Array(lines.dropFirst())
        guard !dataRows.isEmpty else { throw ImportError.noRows }

        let decoder = JSONDecoder()
        let existingById: [UUID: Paddock] = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var summary = ImportSummary()
        var resultPaddocks: [Paddock] = []

        for (lineIndex, row) in dataRows.enumerated() {
            let lineNumber = lineIndex + 2
            func field(_ key: String) -> String {
                guard let idx = headerMap[key.lowercased()], idx < row.count else { return "" }
                return row[idx].trimmingCharacters(in: .whitespaces)
            }

            let name = field("name")
            guard !name.isEmpty else {
                summary.skipped += 1
                summary.errors.append("Row \(lineNumber): missing name")
                continue
            }

            let idString = field("id")
            let parsedId = UUID(uuidString: idString)
            let existingMatch = parsedId.flatMap { existingById[$0] }
            var paddock = existingMatch ?? Paddock(
                id: parsedId ?? UUID(),
                vineyardId: vineyardId,
                name: name
            )
            paddock.vineyardId = vineyardId
            paddock.name = name

            if let v = Double(field("vineSpacing")), v > 0 { paddock.vineSpacing = v }
            if let v = Double(field("rowSpacing")), v > 0 { paddock.rowWidth = v }
            if let v = Double(field("rowDirection")) { paddock.rowDirection = v }
            let plantingYearStr = field("plantingYear")
            if !plantingYearStr.isEmpty, let y = Int(plantingYearStr) { paddock.plantingYear = y }

            let polygonStr = field("polygonPoints")
            if !polygonStr.isEmpty,
               let polygonData = polygonStr.data(using: .utf8),
               let points = try? decoder.decode([CoordinatePoint].self, from: polygonData) {
                paddock.polygonPoints = points
            }

            let rowsStr = field("rows")
            if !rowsStr.isEmpty,
               let rowsData = rowsStr.data(using: .utf8),
               let rows = try? decoder.decode([PaddockRow].self, from: rowsData) {
                paddock.rows = rows
            }

            let allocationsStr = field("varietyAllocations")
            if !allocationsStr.isEmpty,
               let allocData = allocationsStr.data(using: .utf8),
               let allocations = try? decoder.decode([PaddockVarietyAllocation].self, from: allocData) {
                paddock.varietyAllocations = allocations
            }

            if existingMatch != nil {
                summary.updated += 1
            } else {
                summary.created += 1
            }
            resultPaddocks.append(paddock)
        }

        return (resultPaddocks, summary)
    }

    // MARK: - CSV helpers

    private static func escapeField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func parseCSVLines(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = content.makeIterator()

        while let ch = iterator.next() {
            if inQuotes {
                if ch == "\"" {
                    // peek next
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else if next == "," {
                            current.append(field); field = ""; inQuotes = false
                        } else if next == "\n" {
                            current.append(field); field = ""; inQuotes = false
                            rows.append(current); current = []
                        } else if next == "\r" {
                            // ignore, will handle \n next
                            current.append(field); field = ""; inQuotes = false
                        } else {
                            inQuotes = false
                            field.append(next)
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",":
                    current.append(field); field = ""
                case "\n":
                    current.append(field); field = ""
                    rows.append(current); current = []
                case "\r":
                    continue
                default:
                    field.append(ch)
                }
            }
        }
        if !field.isEmpty || !current.isEmpty {
            current.append(field)
            rows.append(current)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
