import UIKit

struct SprayProgramExportService {

    /// Region-aware spray program exports, following the reference pattern
    /// established in `SprayRecordPDFService`:
    /// - Pass `store.settings.regionFormatter`; default `.australian` keeps every
    ///   existing call site and AU/NZ user identical.
    /// - Route dates, the spray-rate area denominator, water volume and currency
    ///   through `formatter`. Records are never mutated.
    /// - Chemical product amounts keep their native manufacturer unit (L/Kg/g/mL).
    /// - Weather and carrier water use regional dimensions; registered chemical-rate bases remain authoritative.
    static func generateProgramPDF(
        records: [SprayRecord],
        trips: [Trip],
        paddocks: [Paddock],
        vineyardName: String,
        logoData: Data? = nil,
        tractors: [Tractor] = [],
        machines: [VineyardMachine] = [],
        sprayEquipment: [SprayEquipmentItem] = [],
        seasonFuelCostPerLitre: Double = 0,
        operatorCategories: [OperatorCategory] = [],
        vineyardUsers: [VineyardUser] = [],
        tankActuals: [SprayTankActual] = [],
        includeCostings: Bool = true,
        timeZone: TimeZone = .current,
        formatter: RegionFormatter = .australian,
        canonicalReports: [UUID: SprayReportPayloadV1] = [:],
        chemicalPrices: ChemicalSeasonPriceBatch? = nil
    ) -> URL {
        // Prefer stable equipment links when present; fall back to text snapshots.
        // Routed through the shared `EquipmentResolver` so spray-equipment naming
        // matches the rest of the app (display-only; never mutates records).
        let equipmentResolver = EquipmentResolver(
            vineyardMachines: machines,
            tractors: tractors,
            sprayEquipment: sprayEquipment,
            equipmentItems: []
        )
        func resolvedEquipmentName(_ record: SprayRecord) -> String {
            equipmentResolver.sprayEquipmentName(record)
        }
        let pageWidth: CGFloat = 842.0
        let pageHeight: CGFloat = 595.0
        let margin: CGFloat = 36.0
        let contentWidth = pageWidth - margin * 2

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let data = renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = margin
            var pageNumber: Int = 1
            let officialLogo = UIImage(named: "vinetrack_logo")

            let headerFont = UIFont.systemFont(ofSize: 8, weight: .bold)
            let bodyFont = UIFont.systemFont(ofSize: 8, weight: .regular)
            let bodyBoldFont = UIFont.systemFont(ofSize: 8, weight: .semibold)
            let captionFont = UIFont.systemFont(ofSize: 7, weight: .regular)
            let accentColor = VineyardTheme.uiOlive

            func drawPageFooter() {
                let footerY = pageHeight - 27
                if let officialLogo {
                    let scale = min(72 / officialLogo.size.width, 16 / officialLogo.size.height)
                    officialLogo.draw(in: CGRect(x: margin, y: footerY, width: officialLogo.size.width * scale, height: officialLogo.size.height * scale))
                }
                let text = "Page \(pageNumber)"
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 7), .foregroundColor: UIColor.gray]
                let width = (text as NSString).size(withAttributes: attrs).width
                (text as NSString).draw(at: CGPoint(x: pageWidth - margin - width, y: footerY + 3), withAttributes: attrs)
            }
            func checkPageBreak(needed: CGFloat) {
                if y + needed > pageHeight - margin - 18 {
                    drawPageFooter()
                    context.beginPage()
                    pageNumber += 1
                    y = margin
                }
            }

            PDFHeaderHelper.drawHeader(
                vineyardName: vineyardName,
                logoData: logoData,
                title: "Spray Program",
                accentColor: accentColor,
                margin: margin,
                contentWidth: contentWidth,
                y: &y
            )

            let genAttrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: UIColor.gray]
            let reportZone = formatter.settings.resolvedTimeZone
            let tzAbbrev = reportZone.abbreviation() ?? reportZone.identifier
            let genText = "Generated: \(formatter.formatDate(Date())) \(formatter.formatTime(Date())) (\(tzAbbrev)) \u{2022} \(records.count) record\(records.count == 1 ? "" : "s")"
            (genText as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: genAttrs)
            y += 14

            let columns: [(String, CGFloat, CGFloat)] = [
                ("DATE", margin, 68),
                ("NAME", margin + 68, 80),
                ("BLOCK", margin + 148, 80),
                ("CHEMICALS", margin + 228, 160),
                ("TANKS", margin + 388, 40),
                ("RATE (\(formatter.volumePerAreaUnit))", margin + 428, 60),
                ("TEMP", margin + 488, 42),
                ("WIND", margin + 530, 50),
                ("EQUIP.", margin + 580, 60),
                ("OPERATOR", margin + 640, 70),
                ("STATUS", margin + 710, 52),
            ]

            // Set when any listed application predates block attribution, so the
            // footnote explaining "Not recorded" appears only when it is relevant.
            var hasUnrecordedBlocks = false

            let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: UIColor.white]
            let headerBg = UIBezierPath(rect: CGRect(x: margin, y: y, width: contentWidth, height: 18))
            accentColor.setFill()
            headerBg.fill()

            for (title, x, _) in columns {
                (title as NSString).draw(at: CGPoint(x: x + 3, y: y + 4), withAttributes: headerAttrs)
            }
            y += 18

            for (index, record) in records.enumerated() {
                checkPageBreak(needed: 22)

                let trip = trips.first { $0.id == record.canonicalTripId }
                let canonical = trip.flatMap { canonicalReports[$0.id] }

                if index % 2 == 0 {
                    let bg = UIBezierPath(rect: CGRect(x: margin, y: y, width: contentWidth, height: 20))
                    UIColor(white: 0.96, alpha: 1.0).setFill()
                    bg.fill()
                }

                let rowY = y + 5
                let rowAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.black]
                let rowBoldAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: UIColor.black]

                let dateStr = formatter.formatDate(record.date)
                (dateStr as NSString).draw(at: CGPoint(x: columns[0].1 + 3, y: rowY), withAttributes: rowAttrs)

                let name = record.sprayReference.isEmpty ? "–" : record.sprayReference
                (name as NSString).draw(in: CGRect(x: columns[1].1 + 3, y: rowY, width: columns[1].2 - 6, height: 14), withAttributes: rowBoldAttrs)

                // BLOCK column: the AUTHORITATIVE sql/195 attribution — which
                // blocks this application treated — rather than the linked trip's
                // label, which only says where the machine drove.
                //
                // Kept to the existing column so the program stays one line per
                // application. "Not recorded" is the compact form of
                // `SprayBlockAttributionDisplay.notRecorded`, explained in the
                // footnote; the vineyard's current blocks are never substituted.
                let treatedBlocks = record.applicationGeometry?.blocks
                let blockCell: String = {
                    if let canonical, let blocks = canonical.blocks, !blocks.isEmpty {
                        let names = blocks.map(\.name).joined(separator: ", ")
                        let rows = canonical.rows.map { String(format: "%g", $0.rowNumber) }.joined(separator: ", ")
                        return rows.isEmpty ? names : "\(names) · rows \(rows)"
                    }
                    guard let resolved = SprayBlockAttributionDisplay.resolve(treatedBlocks, paddocks: paddocks) else {
                        hasUnrecordedBlocks = true
                        return "Not recorded"
                    }
                    return resolved.map(\.name).joined(separator: ", ")
                }()
                (blockCell as NSString).draw(in: CGRect(x: columns[2].1 + 3, y: rowY, width: columns[2].2 - 6, height: 14), withAttributes: rowAttrs)

                let chemicals = record.tanks.flatMap { $0.chemicals }.map { $0.name }.filter { !$0.isEmpty }.joined(separator: ", ")
                let chemDisplay = chemicals.isEmpty ? "–" : chemicals
                (chemDisplay as NSString).draw(in: CGRect(x: columns[3].1 + 3, y: rowY, width: columns[3].2 - 6, height: 14), withAttributes: rowAttrs)

                ("\(record.tanks.count)" as NSString).draw(at: CGPoint(x: columns[4].1 + 3, y: rowY), withAttributes: rowAttrs)

                let avgRate = record.tanks.isEmpty ? 0.0 : record.tanks.map(\.sprayRatePerHa).reduce(0, +) / Double(record.tanks.count)
                let rateStr = avgRate > 0 ? String(format: "%.0f", formatter.volumePerAreaValue(litresPerHectare: avgRate)) : "–"
                (rateStr as NSString).draw(at: CGPoint(x: columns[5].1 + 3, y: rowY), withAttributes: rowAttrs)

                let canonicalWeather = canonical?.weather.first(where: { $0.sourceKind == "observed" || $0.sourceKind == "manual" })
                let tempStr = (canonicalWeather?.temperatureC ?? record.temperature).map { formatter.formatTemperature(celsius: $0, fractionDigits: 0) } ?? "–"
                (tempStr as NSString).draw(at: CGPoint(x: columns[6].1 + 3, y: rowY), withAttributes: rowAttrs)

                let windStr = (canonicalWeather?.windSpeedKmh ?? record.windSpeed).map { formatter.formatSpeed(kmh: $0, fractionDigits: 0) } ?? "–"
                (windStr as NSString).draw(at: CGPoint(x: columns[7].1 + 3, y: rowY), withAttributes: rowAttrs)

                let equipName = resolvedEquipmentName(record)
                let equipStr = equipName.isEmpty ? "–" : equipName
                (equipStr as NSString).draw(in: CGRect(x: columns[8].1 + 3, y: rowY, width: columns[8].2 - 6, height: 14), withAttributes: rowAttrs)

                let operator_ = trip?.personName ?? "–"
                (operator_ as NSString).draw(in: CGRect(x: columns[9].1 + 3, y: rowY, width: columns[9].2 - 6, height: 14), withAttributes: rowAttrs)

                let resolvedStatus = SprayCompletionResolver.status(record: record, trip: trip)
                let status = resolvedStatus == .completed ? "Done" : resolvedStatus == .inProgress ? "Active" : "Upcoming"
                let statusColor = resolvedStatus == .completed ? accentColor : UIColor.systemRed
                let statusAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: statusColor]
                (status as NSString).draw(at: CGPoint(x: columns[10].1 + 3, y: rowY), withAttributes: statusAttrs)

                y += 20
            }

            y += 16
            checkPageBreak(needed: 60)

            let allChemicals = records.flatMap { $0.tanks.flatMap { $0.chemicals } }
            let grouped = Dictionary(grouping: allChemicals, by: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            let totals = grouped.compactMap { (key, chems) -> (String, Double, ChemicalUnit)? in
                guard !key.isEmpty else { return nil }
                let displayName = chems.first?.name ?? key
                let unit = chems.first?.unit ?? .litres
                let totalBase = chems.reduce(0.0) { $0 + $1.volumePerTank }
                return (displayName, totalBase, unit)
            }.sorted { $0.0.lowercased() < $1.0.lowercased() }

            if !totals.isEmpty {
                let summaryLine = UIBezierPath()
                summaryLine.move(to: CGPoint(x: margin, y: y))
                summaryLine.addLine(to: CGPoint(x: pageWidth - margin, y: y))
                accentColor.withAlphaComponent(0.3).setStroke()
                summaryLine.lineWidth = 0.5
                summaryLine.stroke()
                y += 10

                let summaryTitleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: accentColor]
                ("Chemical Totals (All Records)" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: summaryTitleAttrs)
                y += 16

                for (name, totalBase, unit) in totals {
                    checkPageBreak(needed: 16)
                    let displayTotal = unit.fromBase(totalBase)
                    let unitAbbrev = unit == .litres ? "L" : unit == .kilograms ? "Kg" : unit.rawValue
                    let nameAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.black]
                    let valAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: UIColor.black]
                    (name as NSString).draw(at: CGPoint(x: margin + 8, y: y), withAttributes: nameAttrs)
                    (String(format: "%.2f%@", displayTotal, unitAbbrev) as NSString).draw(at: CGPoint(x: margin + 200, y: y), withAttributes: valAttrs)
                    y += 14
                }
            }

            y += 8
            checkPageBreak(needed: 30)
            let actualCount = tankActuals.filter { actual in records.contains { $0.id == actual.sprayRecordId } }.count
            let actualWater = tankActuals.filter { actual in records.contains { $0.id == actual.sprayRecordId } }.compactMap(\.waterVolumeL).reduce(0, +)
            let actualSummaryAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: UIColor.black]
            ("Actual tanks recorded: \(actualCount) • Actual water used: \(formatter.formatVolume(litres: actualWater, fractionDigits: 2))" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: actualSummaryAttrs)
            y += 16

            let allActualsComplete = !records.isEmpty && records.allSatisfy { record in
                areSprayTankActualsComplete(
                    plannedTanks: record.tanks,
                    actuals: tankActuals.filter { $0.sprayRecordId == record.id },
                    vineyardId: record.vineyardId,
                    sprayRecordId: record.id,
                    tripId: record.tripId
                )
            }
            let chemicalResults: [(String, TripCostService.ChemicalBreakdown?)] = includeCostings ? records.map { record in
                guard let trip = trips.first(where: { $0.id == record.canonicalTripId }) else {
                    return (record.sprayReference, nil)
                }
                let result = TripCostService.estimate(
                    trip: trip, operatorCategory: nil, tractor: nil, fuelPurchases: [], sprayRecord: record,
                    tankActuals: tankActuals.filter { $0.tripId == trip.id && $0.sprayRecordId == record.id },
                    chemicalPrices: chemicalPrices
                )
                return (record.sprayReference, result.chemical)
            } : []
            let chemCosts: [(String, Double)] = chemicalResults.compactMap { name, chemical in
                guard let chemical else { return nil }
                return (name, chemical.cost)
            }
            let chemicalComplete = chemicalResults.allSatisfy { $0.1 != nil && $0.1?.warning == nil }
                && Set(chemicalPrices?.prices.compactMap(\.currency) ?? []).count <= 1
            let totalChemCost = chemCosts.reduce(0.0) { $0 + $1.1 }

            var totalFuelCost: Double = 0
            var totalOperatorCost: Double = 0
            for record in records {
                guard let trip = trips.first(where: { $0.id == record.canonicalTripId }) else { continue }
                let tractor = tractors.first(where: { $0.displayName == record.tractor || $0.name == record.tractor })
                if let tractor, tractor.fuelUsageLPerHour > 0, seasonFuelCostPerLitre > 0 {
                    let end = trip.endTime ?? Date()
                    let durationHours = end.timeIntervalSince(trip.startTime) / 3600.0
                    totalFuelCost += seasonFuelCostPerLitre * tractor.fuelUsageLPerHour * durationHours
                }
                if !trip.personName.isEmpty,
                   let user = vineyardUsers.first(where: { $0.name.lowercased() == trip.personName.lowercased() }),
                   let catId = user.operatorCategoryId,
                   let cat = operatorCategories.first(where: { $0.id == catId }),
                   cat.costPerHour > 0 {
                    let end = trip.endTime ?? Date()
                    let durationHours = end.timeIntervalSince(trip.startTime) / 3600.0
                    totalOperatorCost += cat.costPerHour * durationHours
                }
            }

            let hasCostData = !records.isEmpty
            if hasCostData && includeCostings {
                y += 8
                checkPageBreak(needed: 40)
                let costTitleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: accentColor]
                ("Cost Summary (All Records) — \(allActualsComplete ? "Actual chemicals" : "Estimated chemicals")" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: costTitleAttrs)
                y += 16

                let nameAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.black]
                let valAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: UIColor.black]

                for (name, chemical) in chemicalResults {
                    checkPageBreak(needed: 44)
                    (name as NSString).draw(in: CGRect(x: margin + 8, y: y, width: 180, height: 14), withAttributes: nameAttrs)
                    let value = chemical.map { $0.warning == nil || $0.pricingBases == ["legacy_stored_spray_snapshot"] ? formatter.formatCurrency($0.cost) : "Unavailable / incomplete" } ?? "Unavailable / incomplete"
                    (value as NSString).draw(at: CGPoint(x: margin + 200, y: y), withAttributes: valAttrs)
                    y += 14
                    let basis = chemical?.pricingBases.joined(separator: ", ") ?? "season_purchase_cost_unavailable"
                    (basis as NSString).draw(in: CGRect(x: margin + 8, y: y, width: pageWidth - margin * 2 - 16, height: 28), withAttributes: nameAttrs)
                    y += 28
                }
                for (name, chemical) in chemicalResults where chemical == nil || chemical?.warning != nil {
                    checkPageBreak(needed: 28)
                    ((name + ": " + (chemical?.warning ?? "Season purchase cost unavailable / incomplete")) as NSString).draw(at: CGPoint(x: margin + 8, y: y), withAttributes: nameAttrs)
                    y += 28
                }
                if !chemCosts.isEmpty {
                    checkPageBreak(needed: 14)
                    ("Chemical Subtotal" as NSString).draw(at: CGPoint(x: margin + 8, y: y), withAttributes: nameAttrs)
                    ((chemicalComplete ? formatter.formatCurrency(totalChemCost) : "Unavailable / incomplete") as NSString).draw(at: CGPoint(x: margin + 200, y: y), withAttributes: valAttrs)
                    y += 14
                }
                if totalFuelCost > 0 {
                    checkPageBreak(needed: 14)
                    ("Fuel Cost" as NSString).draw(at: CGPoint(x: margin + 8, y: y), withAttributes: nameAttrs)
                    (formatter.formatCurrency(totalFuelCost) as NSString).draw(at: CGPoint(x: margin + 200, y: y), withAttributes: valAttrs)
                    y += 14
                }
                if totalOperatorCost > 0 {
                    checkPageBreak(needed: 14)
                    ("Operator Cost" as NSString).draw(at: CGPoint(x: margin + 8, y: y), withAttributes: nameAttrs)
                    (formatter.formatCurrency(totalOperatorCost) as NSString).draw(at: CGPoint(x: margin + 200, y: y), withAttributes: valAttrs)
                    y += 14
                }
                y += 4
                checkPageBreak(needed: 14)
                let grandTotal = totalChemCost + totalFuelCost + totalOperatorCost
                let totalAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: UIColor.black]
                ("Total Cost" as NSString).draw(at: CGPoint(x: margin + 8, y: y), withAttributes: totalAttrs)
                ((chemicalComplete ? formatter.formatCurrency(grandTotal) : "Incomplete — chemical pricing unresolved") as NSString).draw(at: CGPoint(x: margin + 200, y: y), withAttributes: totalAttrs)
                y += 16
            }

            y += 12
            checkPageBreak(needed: 20)
            let footerLine = UIBezierPath()
            footerLine.move(to: CGPoint(x: margin, y: y))
            footerLine.addLine(to: CGPoint(x: pageWidth - margin, y: y))
            UIColor.separator.setStroke()
            footerLine.lineWidth = 0.25
            footerLine.stroke()
            y += 6
            let footerAttrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: UIColor.gray]
            if hasUnrecordedBlocks {
                let note = "\(formatter.blockTermCapitalised) “Not recorded” — treated " +
                    "\(formatter.blockTerm)s were not captured for this application. " +
                    "Not the same as none treated."
                (note as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: footerAttrs)
                y += 10
            }
            let footerText = "Generated by VineTrack \u{2022} \(formatter.formatDate(Date())) (\(tzAbbrev))"
            (footerText as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: footerAttrs)
            drawPageFooter()
        }

        let tempDir = FileManager.default.temporaryDirectory
        let safeName = vineyardName.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
        let url = tempDir.appendingPathComponent("SprayProgram_\(safeName).pdf")
        try? data.write(to: url)
        return url
    }

    /// Human-readable spray program CSV (a report, not the re-importable
    /// template). Region-aware via `formatter` following the reference pattern;
    /// Chemical-rate bases stay native; carrier volume and weather are regional. The import template is separate and canonical.
    static func generateProgramCSV(
        records: [SprayRecord],
        trips: [Trip],
        vineyardName: String,
        // Needed only to resolve a treated block's CURRENT display name (sql/195).
        // Defaulted so existing callers keep compiling: with no paddocks the stored
        // `blockName` snapshot is used, which is still correct — just not refreshed
        // for a block renamed since the spray.
        paddocks: [Paddock] = [],
        timeZone: TimeZone = .current,
        formatter: RegionFormatter = .australian
    ) -> URL {
        let volumeUnit = formatter.volumeUnitAbbreviation
        var csv = "Date,Name,Block,Chemicals,Tanks,Avg Rate (\(formatter.volumePerAreaUnit)),Water Vol (\(volumeUnit)),CF,Temp (\(formatter.temperatureUnitAbbreviation)),Wind (\(formatter.speedUnitAbbreviation)),Wind Dir,Humidity (%),Equipment,Tractor,Gear,Operator,Notes,Status\n"

        for record in records {
            let trip = trips.first { $0.id == record.canonicalTripId }

            let date = formatter.formatDate(record.date)
            let name = escapeCSV(record.sprayReference)
            // Authoritative attribution, empty when never recorded. Never the
            // linked trip's label and never the current vineyard blocks.
            let block = escapeCSV(
                SprayBlockAttributionDisplay.namesCell(
                    record.applicationGeometry?.blocks,
                    paddocks: paddocks
                )
            )
            // Each line states its rate on the basis it was RECORDED on. The
            // old form hard-coded the per-area denominator, so a per-100 L line
            // exported as "0.00 L/ha".
            // Registered chemical bases are not carrier units: keep the recorded /ha or /100 L basis.
            let chemicals = escapeCSV(
                record.tanks
                    .flatMap { $0.chemicals }
                    .map { "\($0.name) (\($0.reportedRateText(formatter: .australian)))" }
                    .filter { !$0.isEmpty }
                    .joined(separator: "; ")
            )
            let tanks = "\(record.tanks.count)"
            let avgRate = record.tanks.isEmpty ? "" : String(format: "%.1f", formatter.volumePerAreaValue(litresPerHectare: record.tanks.map(\.sprayRatePerHa).reduce(0, +) / Double(record.tanks.count)))
            let avgWater = record.tanks.isEmpty ? "" : String(format: "%.0f", formatter.volumeValue(litres: record.tanks.map(\.waterVolume).reduce(0, +) / Double(record.tanks.count)))
            let avgCF = record.tanks.isEmpty ? "" : String(format: "%.2f", record.tanks.map(\.concentrationFactor).reduce(0, +) / Double(record.tanks.count))
            let temp = record.temperature.map { String(format: "%.1f", formatter.temperatureValue(celsius: $0)) } ?? ""
            let wind = record.windSpeed.map { String(format: "%.1f", formatter.speedValue(kmh: $0)) } ?? ""
            let windDir = record.windDirection
            let humidity = record.humidity.map { String(format: "%.0f", $0) } ?? ""
            let equipment = escapeCSV(record.equipmentType)
            let tractor = escapeCSV(record.tractor)
            let gear = escapeCSV(record.tractorGear)
            let operator_ = escapeCSV(trip?.personName ?? "")
            let notes = escapeCSV(record.notes)
            let resolvedStatus = SprayCompletionResolver.status(record: record, trip: trip)
            let status = resolvedStatus == .completed ? "Completed" : resolvedStatus == .inProgress ? "In Progress" : "Upcoming"

            csv += "\(date),\(name),\(block),\(chemicals),\(tanks),\(avgRate),\(avgWater),\(avgCF),\(temp),\(wind),\(windDir),\(humidity),\(equipment),\(tractor),\(gear),\(operator_),\(notes),\(status)\n"
        }

        let tempDir = FileManager.default.temporaryDirectory
        let safeName = vineyardName.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
        let url = tempDir.appendingPathComponent("SprayProgram_\(safeName).csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func escapeCSV(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(",") || trimmed.contains("\"") || trimmed.contains("\n") {
            return "\"\(trimmed.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return trimmed
    }
}
