import Foundation
import UniformTypeIdentifiers

struct SprayProgramCSVService {

    static let maxChemicals = 6

    static let descriptionRow = "VineTrack Spray Program Import Template — Row 1 is this description (ignored on import). Row 2 contains column headers. Enter one spray record per row starting from Row 3. Dates must be DD/MM/YYYY. Chemical units: Litres, mL, Kg, or g. Growth Stage uses E-L codes (e.g. EL12). Operation Type: Foliar Spray, Banded Spray, or Spreader. Delete the example row before importing. Up to 6 chemicals per record."

    static let templateHeaders: [String] = {
        var headers = [
            "Spray Name", "Date (DD/MM/YYYY)", "Block", "Operator",
            "Equipment", "Tractor", "Gear", "Fans/Jets",
            "Water Volume (L)", "Spray Rate (L/Ha)", "Concentration Factor",
            "Growth Stage",
            "Temperature (°C)", "Wind Speed (km/h)", "Wind Direction", "Humidity (%)",
            "Notes", "Template (Yes/No)", "Operation Type"
        ]
        for i in 1...maxChemicals {
            headers.append("Chemical \(i) Name")
            headers.append("Chemical \(i) Amount Per Tank")
            headers.append("Chemical \(i) Rate Per Ha")
            headers.append("Chemical \(i) Rate Per 100L")
            headers.append("Chemical \(i) Unit (Litres/mL/Kg/g)")
            headers.append("Chemical \(i) Cost Per Unit")
        }
        return headers
    }()

    static func generateTemplate() -> URL {
        var csv = escapeCSV(descriptionRow) + String(repeating: ",", count: templateHeaders.count - 1) + "\n"
        csv += templateHeaders.map { escapeCSV($0) }.joined(separator: ",") + "\n"

        csv += "\"Spray 1\",\"15/01/2025\",\"Block A\",\"John\","
        csv += "\"Air Blast Sprayer\",\"John Deere 5075\",\"3\",\"12\","
        csv += "\"2000\",\"1000\",\"1.5\","
        csv += "\"EL12\","
        csv += "\"22\",\"10\",\"NW\",\"65\","
        csv += "\"Example row - delete before importing\",\"No\",\"Foliar Spray\","
        csv += "\"Mancozeb 750 WG\",\"600\",\"200\",\"20\",\"g\",\"0.02\","
        csv += "\"Copper Oxychloride\",\"2250\",\"150\",\"15\",\"mL\",\"0.01\","
        for _ in 3...maxChemicals {
            csv += ",,,,,,"
        }
        csv += "\n"

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("SprayProgram_Template.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func exportRecords(
        records: [SprayRecord],
        trips: [Trip],
        vineyardName: String,
        growthStageLookup: ((SprayRecord) -> String?)? = nil,
        timeZone: TimeZone = .current,
        includeCostings: Bool = false,
        tractors: [Tractor] = [],
        fuelPurchases: [FuelPurchase] = [],
        operatorCategories: [OperatorCategory] = [],
        operatorCategoryForName: ((String) -> OperatorCategory?)? = nil,
        savedChemicals: [SavedChemical] = [],
        paddocks: [Paddock] = [],
        historicalYieldRecords: [HistoricalYieldRecord] = []
    ) -> URL {
        // Cost columns are only emitted when the caller explicitly opts in
        // (owner/manager). Supervisors and operators MUST receive
        // `includeCostings: false` so cost data never leaves the app for them.
        var headers = templateHeaders
        if includeCostings {
            headers.append(contentsOf: [
                "active_hours",
                "labour_cost",
                "fuel_litres_estimated",
                "fuel_cost",
                "chemical_cost",
                "total_estimated_cost",
                "costing_status",
                "treated_area_ha",
                "cost_per_ha",
                "yield_tonnes",
                "cost_per_tonne",
            ])
        }
        var csv = headers.map { escapeCSV($0) }.joined(separator: ",") + "\n"

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM/yyyy"
        dateFormatter.timeZone = timeZone

        for record in records {
            let trip = trips.first { $0.id == record.tripId }

            var row: [String] = []
            row.append(escapeCSV(record.sprayReference))
            row.append(dateFormatter.string(from: record.date))
            row.append(escapeCSV(trip?.paddockName ?? ""))
            row.append(escapeCSV(trip?.personName ?? ""))
            row.append(escapeCSV(record.equipmentType))
            row.append(escapeCSV(record.tractor))
            row.append(escapeCSV(record.tractorGear))
            row.append(escapeCSV(record.numberOfFansJets))

            let avgWater = record.tanks.isEmpty ? 0 : record.tanks.map(\.waterVolume).reduce(0, +) / Double(record.tanks.count)
            let avgRate = record.tanks.isEmpty ? 0 : record.tanks.map(\.sprayRatePerHa).reduce(0, +) / Double(record.tanks.count)
            let avgCF = record.tanks.isEmpty ? 0 : record.tanks.map(\.concentrationFactor).reduce(0, +) / Double(record.tanks.count)

            row.append(avgWater > 0 ? String(format: "%.0f", avgWater) : "")
            row.append(avgRate > 0 ? String(format: "%.0f", avgRate) : "")
            row.append(avgCF > 0 ? String(format: "%.2f", avgCF) : "")

            row.append(escapeCSV(growthStageLookup?(record) ?? ""))

            row.append(record.temperature.map { String(format: "%.1f", $0) } ?? "")
            row.append(record.windSpeed.map { String(format: "%.1f", $0) } ?? "")
            row.append(record.windDirection)
            row.append(record.humidity.map { String(format: "%.0f", $0) } ?? "")
            row.append(escapeCSV(record.notes))
            row.append(record.isTemplate ? "Yes" : "No")
            row.append(escapeCSV(record.operationType.rawValue))

            let allChemicals = record.tanks.flatMap { $0.chemicals }
            let uniqueChemicals = consolidateChemicals(allChemicals)

            for i in 0..<maxChemicals {
                if i < uniqueChemicals.count {
                    let chem = uniqueChemicals[i]
                    row.append(escapeCSV(chem.name))
                    row.append(String(format: "%.2f", chem.displayVolume))
                    row.append(String(format: "%.2f", chem.displayRate))
                    row.append(chem.ratePer100L > 0 ? String(format: "%.2f", chem.displayRatePer100L) : "")
                    row.append(chem.unit.rawValue)
                    row.append(chem.costPerUnit > 0 ? String(format: "%.4f", chem.costPerUnit) : "")
                } else {
                    row.append(contentsOf: ["", "", "", "", "", ""])
                }
            }

            if includeCostings {
                if let trip = trip {
                    let category: OperatorCategory? = {
                        if let cid = trip.operatorCategoryId,
                           let c = operatorCategories.first(where: { $0.id == cid }) {
                            return c
                        }
                        if !trip.personName.isEmpty, let lookup = operatorCategoryForName {
                            return lookup(trip.personName)
                        }
                        return nil
                    }()
                    let tractor: Tractor? = {
                        if let tid = trip.tractorId {
                            return tractors.first { $0.id == tid }
                        }
                        return tractors.first { $0.displayName == record.tractor || $0.name == record.tractor }
                    }()
                    let vineyardFuelPurchases = fuelPurchases.filter { $0.vineyardId == trip.vineyardId }
                    var areasById: [UUID: Double] = [:]
                    let tripPaddockIds: [UUID] = !trip.paddockIds.isEmpty ? trip.paddockIds : (trip.paddockId.map { [$0] } ?? [])
                    for pid in tripPaddockIds {
                        if let p = paddocks.first(where: { $0.id == pid }) {
                            areasById[pid] = p.areaHectares
                        }
                    }
                    let r = TripCostService.estimate(
                        trip: trip,
                        operatorCategory: category,
                        tractor: tractor,
                        fuelPurchases: vineyardFuelPurchases,
                        sprayRecord: record,
                        savedChemicals: savedChemicals,
                        paddockAreasById: areasById,
                        historicalYieldRecords: historicalYieldRecords
                    )
                    row.append(String(format: "%.2f", r.activeHours))
                    row.append(r.labour.warning == nil ? String(format: "%.2f", r.labour.cost) : "")
                    row.append(r.fuel.warning == nil ? String(format: "%.2f", r.fuel.litres) : "")
                    row.append(r.fuel.warning == nil ? String(format: "%.2f", r.fuel.cost) : "")
                    row.append({
                        guard let c = r.chemical else { return "" }
                        if let w = c.warning, c.cost <= 0, !w.isEmpty { return "" }
                        return String(format: "%.2f", c.cost)
                    }())
                    row.append(String(format: "%.2f", r.totalCost))
                    row.append(r.completeness.rawValue)
                    row.append((r.treatedAreaHa.map { String(format: "%.2f", $0) }) ?? "")
                    row.append((r.costPerHa.map { String(format: "%.2f", $0) }) ?? "")
                    row.append((r.yieldTonnes.map { String(format: "%.2f", $0) }) ?? "")
                    row.append((r.costPerTonne.map { String(format: "%.2f", $0) }) ?? "")
                } else {
                    row.append(contentsOf: ["", "", "", "", "", "", "", "", "", "", ""])
                }
            }

            csv += row.joined(separator: ",") + "\n"
        }

        let tempDir = FileManager.default.temporaryDirectory
        let safeName = vineyardName.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
        let url = tempDir.appendingPathComponent("SprayProgram_Export_\(safeName).csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func consolidateChemicals(_ chemicals: [SprayChemical]) -> [SprayChemical] {
        var seen: [String: SprayChemical] = [:]
        for chem in chemicals {
            let key = chem.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            if seen[key] == nil {
                seen[key] = chem
            }
        }
        return seen.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Import

    nonisolated struct ImportedSprayRow: Sendable {
        let sprayName: String
        let date: Date
        let blockName: String
        let operatorName: String
        let equipment: String
        let tractor: String
        let gear: String
        let fansJets: String
        let waterVolume: Double
        let sprayRate: Double
        let concentrationFactor: Double
        let growthStage: String
        let temperature: Double?
        let windSpeed: Double?
        let windDirection: String
        let humidity: Double?
        let notes: String
        let isTemplate: Bool
        let operationType: OperationType
        let chemicals: [ImportedChemical]
    }

    nonisolated struct ImportedChemical: Sendable {
        let name: String
        let amountPerTank: Double
        let ratePerHa: Double
        let ratePer100L: Double
        let unit: ChemicalUnit
        let costPerUnit: Double
    }

    nonisolated struct ImportWarning: Sendable {
        let row: Int
        let message: String
    }

    nonisolated struct ImportResult: Sendable {
        let rows: [ImportedSprayRow]
        let warnings: [ImportWarning]
    }

    nonisolated enum ImportError: Error, LocalizedError, Sendable {
        case emptyFile
        case noDataRows
        case missingHeaders(missing: [String])
        case invalidDate(row: Int, value: String)
        case parseError(row: Int, detail: String)
        case tooManyErrors(count: Int)
        case wrongFileType

        var errorDescription: String? {
            switch self {
            case .emptyFile: return "The file is empty or could not be read."
            case .noDataRows: return "No data rows found after the header. Ensure data starts from row 3 (row 1 is the description, row 2 is headers)."
            case .missingHeaders(let missing): return "Required headers missing: \(missing.joined(separator: ", ")). Please use the provided template."
            case .invalidDate(let row, let value): return "Row \(row): Invalid date '\(value)'. Use DD/MM/YYYY format."
            case .parseError(let row, let detail): return "Row \(row): \(detail)"
            case .tooManyErrors(let count): return "Too many row errors (\(count)). Please check the file matches the template format."
            case .wrongFileType: return "This file does not appear to be a CSV. Please use a .csv file."
            }
        }
    }

    static func parseCSV(data: Data) throws -> ImportResult {
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw ImportError.emptyFile
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.emptyFile }

        if trimmed.hasPrefix("PK") || trimmed.hasPrefix("%PDF") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            throw ImportError.wrongFileType
        }

        let lines = parseCSVLines(content)
        guard !lines.isEmpty else { throw ImportError.emptyFile }

        let headerLineIndex = findHeaderLine(in: lines)
        guard let headerIdx = headerLineIndex else {
            throw ImportError.missingHeaders(missing: ["Spray Name", "Date (DD/MM/YYYY)"])
        }

        let headers = lines[headerIdx].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        var missingRequired: [String] = []
        if !headers.contains(where: { $0.contains("spray name") }) { missingRequired.append("Spray Name") }
        if !headers.contains(where: { $0.contains("date") }) { missingRequired.append("Date (DD/MM/YYYY)") }
        if !missingRequired.isEmpty {
            throw ImportError.missingHeaders(missing: missingRequired)
        }

        let dataStartIndex = headerIdx + 1
        guard dataStartIndex < lines.count else { throw ImportError.noDataRows }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd/MM/yyyy"

        let altDateFormatter = DateFormatter()
        altDateFormatter.dateFormat = "d/M/yyyy"

        var rows: [ImportedSprayRow] = []
        var warnings: [ImportWarning] = []
        var skippedCount = 0

        for lineIndex in dataStartIndex..<lines.count {
            let fields = lines[lineIndex]
            guard fields.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { continue }

            let rowNum = lineIndex + 1

            func field(_ partialHeader: String) -> String {
                guard let idx = headers.firstIndex(where: { $0.contains(partialHeader) }) else { return "" }
                return idx < fields.count ? fields[idx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }

            let sprayName = field("spray name")
            if sprayName.isEmpty {
                warnings.append(ImportWarning(row: rowNum, message: "Spray Name is empty"))
            }

            let dateStr = field("date")
            let date: Date
            if let d = dateFormatter.date(from: dateStr) {
                date = d
            } else if let d = altDateFormatter.date(from: dateStr) {
                date = d
                warnings.append(ImportWarning(row: rowNum, message: "Date '\(dateStr)' parsed but DD/MM/YYYY format is recommended"))
            } else {
                if dateStr.isEmpty {
                    warnings.append(ImportWarning(row: rowNum, message: "Date is empty — row skipped"))
                } else {
                    warnings.append(ImportWarning(row: rowNum, message: "Invalid date '\(dateStr)' — row skipped. Use DD/MM/YYYY"))
                }
                skippedCount += 1
                if skippedCount >= 10 {
                    throw ImportError.tooManyErrors(count: skippedCount)
                }
                continue
            }

            if date > Date() {
                warnings.append(ImportWarning(row: rowNum, message: "Date is in the future"))
            }

            let blockName = field("block")
            if blockName.isEmpty {
                warnings.append(ImportWarning(row: rowNum, message: "Block name is empty"))
            }

            let waterVolumeStr = field("water volume")
            let waterVolume = Double(waterVolumeStr) ?? 0
            if !waterVolumeStr.isEmpty && waterVolume <= 0 {
                warnings.append(ImportWarning(row: rowNum, message: "Water Volume '\(waterVolumeStr)' is not a valid number"))
            }

            let sprayRateStr = field("spray rate")
            let sprayRate = Double(sprayRateStr) ?? 0
            if !sprayRateStr.isEmpty && sprayRate <= 0 {
                warnings.append(ImportWarning(row: rowNum, message: "Spray Rate '\(sprayRateStr)' is not a valid number"))
            }

            let cfStr = field("concentration")
            let concentrationFactor = Double(cfStr) ?? 1.0
            if !cfStr.isEmpty && concentrationFactor <= 0 {
                warnings.append(ImportWarning(row: rowNum, message: "Concentration Factor '\(cfStr)' is not a valid number"))
            }

            var chemicals: [ImportedChemical] = []
            for i in 1...maxChemicals {
                let prefix = "chemical \(i)"
                let name = field("\(prefix) name")
                guard !name.isEmpty else { continue }
                let amountStr = field("\(prefix) amount")
                let amount = Double(amountStr) ?? 0
                let rateHaStr = field("\(prefix) rate per ha")
                let rateHa = Double(rateHaStr) ?? 0
                let rate100LStr = field("\(prefix) rate per 100l")
                let rate100L = Double(rate100LStr) ?? 0
                let unitStr = field("\(prefix) unit")
                let unit = parseUnit(unitStr)
                let cost = Double(field("\(prefix) cost")) ?? 0

                if !amountStr.isEmpty && amount <= 0 {
                    warnings.append(ImportWarning(row: rowNum, message: "Chemical \(i) '\(name)' has invalid amount"))
                }
                if !rateHaStr.isEmpty && rateHa <= 0 {
                    warnings.append(ImportWarning(row: rowNum, message: "Chemical \(i) '\(name)' has invalid rate per ha"))
                }
                if !rate100LStr.isEmpty && rate100L <= 0 {
                    warnings.append(ImportWarning(row: rowNum, message: "Chemical \(i) '\(name)' has invalid rate per 100L"))
                }
                if unitStr.isEmpty {
                    warnings.append(ImportWarning(row: rowNum, message: "Chemical \(i) '\(name)' has no unit — defaulting to Litres"))
                }

                chemicals.append(ImportedChemical(
                    name: name,
                    amountPerTank: amount,
                    ratePerHa: rateHa,
                    ratePer100L: rate100L,
                    unit: unit,
                    costPerUnit: cost
                ))
            }

            if chemicals.isEmpty {
                warnings.append(ImportWarning(row: rowNum, message: "No chemicals listed"))
            }

            let notesValue = field("notes")
            if notesValue.localizedStandardContains("example row") || notesValue.localizedStandardContains("delete before importing") {
                warnings.append(ImportWarning(row: rowNum, message: "This looks like the example row from the template — consider removing it"))
            }

            let templateStr = field("template").lowercased()
            let isTemplate = templateStr == "yes" || templateStr == "true" || templateStr == "1"

            let operationTypeStr = field("operation type").trimmingCharacters(in: .whitespacesAndNewlines)
            let operationType = parseOperationType(operationTypeStr)

            let row = ImportedSprayRow(
                sprayName: sprayName,
                date: date,
                blockName: blockName,
                operatorName: field("operator"),
                equipment: field("equipment"),
                tractor: field("tractor"),
                gear: headers.firstIndex(where: { $0 == "gear" || $0 == "fans/jets" }).flatMap({ _ in field("gear") }) ?? {
                    if let idx = headers.firstIndex(where: { $0 == "gear" }) {
                        return idx < fields.count ? fields[idx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    }
                    return ""
                }(),
                fansJets: field("fans"),
                waterVolume: waterVolume,
                sprayRate: sprayRate,
                concentrationFactor: concentrationFactor,
                growthStage: field("growth stage"),
                temperature: Double(field("temperature")),
                windSpeed: Double(field("wind speed")),
                windDirection: field("wind direction"),
                humidity: Double(field("humidity")),
                notes: notesValue,
                isTemplate: isTemplate,
                operationType: operationType,
                chemicals: chemicals
            )
            rows.append(row)
        }

        guard !rows.isEmpty else { throw ImportError.noDataRows }
        return ImportResult(rows: rows, warnings: warnings)
    }

    static func importRows(_ rows: [ImportedSprayRow], into store: MigratedDataStore, paddocks: [Paddock]) -> Int {
        guard let vid = store.selectedVineyardId else { return 0 }
        var imported = 0

        for row in rows {
            let tripId = UUID()
            let paddock = paddocks.first(where: { $0.name.localizedStandardContains(row.blockName) || row.blockName.localizedStandardContains($0.name) })

            let trip = Trip(
                id: tripId,
                vineyardId: vid,
                paddockId: paddock?.id,
                paddockName: row.blockName,
                paddockIds: paddock.map { [$0.id] } ?? [],
                startTime: row.date,
                endTime: row.date,
                isActive: false,
                personName: row.operatorName
            )
            store.startTrip(trip)
            var endedTrip = trip
            endedTrip.isActive = false
            endedTrip.endTime = row.date
            store.updateTrip(endedTrip)

            let sprayChemicals = row.chemicals.map { chem in
                SprayChemical(
                    name: chem.name,
                    volumePerTank: chem.unit.toBase(chem.amountPerTank),
                    ratePerHa: chem.unit.toBase(chem.ratePerHa),
                    ratePer100L: chem.unit.toBase(chem.ratePer100L),
                    costPerUnit: chem.costPerUnit,
                    unit: chem.unit
                )
            }

            let tank = SprayTank(
                tankNumber: 1,
                waterVolume: row.waterVolume,
                sprayRatePerHa: row.sprayRate,
                concentrationFactor: row.concentrationFactor,
                chemicals: sprayChemicals
            )

            let record = SprayRecord(
                id: UUID(),
                tripId: tripId,
                vineyardId: vid,
                date: row.date,
                startTime: row.date,
                endTime: row.isTemplate ? nil : row.date,
                temperature: row.temperature,
                windSpeed: row.windSpeed,
                windDirection: row.windDirection,
                humidity: row.humidity,
                sprayReference: row.sprayName,
                tanks: [tank],
                notes: row.notes,
                numberOfFansJets: row.fansJets,
                equipmentType: row.equipment,
                tractor: row.tractor,
                tractorGear: row.gear,
                isTemplate: row.isTemplate,
                operationType: row.operationType
            )
            store.addSprayRecord(record)
            imported += 1
        }

        return imported
    }

    // MARK: - Helpers

    private static func findHeaderLine(in lines: [[String]]) -> Int? {
        for (index, line) in lines.enumerated() {
            let joined = line.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if joined.contains(where: { $0.contains("spray name") }) && joined.contains(where: { $0.contains("date") }) {
                return index
            }
        }
        return nil
    }

    private static func parseOperationType(_ value: String) -> OperationType {
        let lower = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lower {
        case "foliar spray", "foliar": return .foliarSpray
        case "banded spray", "banded": return .bandedSpray
        case "spreader": return .spreader
        default: return .foliarSpray
        }
    }

    private static func parseUnit(_ value: String) -> ChemicalUnit {
        let lower = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lower {
        case "litres", "litre", "l", "ltr": return .litres
        case "ml", "millilitres", "millilitre": return .millilitres
        case "kg", "kilograms", "kilogram": return .kilograms
        case "g", "grams", "gram": return .grams
        default: return .litres
        }
    }

    private static func parseCSVLines(_ content: String) -> [[String]] {
        var result: [[String]] = []
        var currentField = ""
        var currentRow: [String] = []
        var inQuotes = false
        let chars = Array(content)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    currentRow.append(currentField)
                    currentField = ""
                } else if c == "\n" || c == "\r" {
                    if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" {
                        i += 1
                    }
                    currentRow.append(currentField)
                    currentField = ""
                    if !currentRow.allSatisfy({ $0.isEmpty }) {
                        result.append(currentRow)
                    }
                    currentRow = []
                } else {
                    currentField.append(c)
                }
            }
            i += 1
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            if !currentRow.allSatisfy({ $0.isEmpty }) {
                result.append(currentRow)
            }
        }

        return result
    }

    private static func escapeCSV(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(",") || trimmed.contains("\"") || trimmed.contains("\n") {
            return "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return trimmed
    }
}
