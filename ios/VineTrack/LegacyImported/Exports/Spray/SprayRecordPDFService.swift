import UIKit
import PDFKit
import MapKit

struct SprayRecordPDFService {
    /// REFERENCE IMPLEMENTATION for region-aware exports.
    ///
    /// This is the first export wired to `RegionFormatter`. Other export
    /// services should follow the same pattern:
    /// 1. Accept a `formatter: RegionFormatter` parameter (default `.australian`
    ///    so existing call sites and AU users are unaffected).
    /// 2. Pass `store.settings.regionFormatter` from the view.
    /// 3. Never read raw stored values for display — route every area, volume,
    ///    fuel, spray-rate, currency and terminology string through `formatter`
    ///    so units are always explicitly and correctly labelled.
    /// 4. Records are NOT mutated — the formatter only affects display strings.
    ///
    /// With Australian defaults the numeric values are identical to before;
    /// only unit-label casing is normalised (e.g. "Ha" → "ha"), currency gains
    /// locale grouping, and dates render in the configured DD/MM/YYYY order.
    static func generatePDF(payload: SprayReportPayloadV1, record: SprayRecord, trip: Trip?, vineyardName: String, paddockName: String, personName: String, paddocks: [Paddock] = [], mapSnapshot: UIImage? = nil, logoData: Data? = nil, fuelCost: Double = 0, operatorCost: Double = 0, operatorCategoryName: String? = nil, includeCostings: Bool = true, timeZone: TimeZone = .current, formatter: RegionFormatter = .australian, resolvedTractorName: String? = nil, resolvedEquipmentName: String? = nil, tripCostResult: TripCostService.Result? = nil) -> Data {
        // Prefer stable-link resolved names when provided; fall back to the
        // record's text snapshots so old records still render unchanged.
        let tractorName = (resolvedTractorName?.isEmpty == false) ? resolvedTractorName! : record.tractor
        let equipmentName = (resolvedEquipmentName?.isEmpty == false) ? resolvedEquipmentName! : record.equipmentType
        let pageWidth: CGFloat = 595.0
        let pageHeight: CGFloat = 842.0
        let margin: CGFloat = 40.0
        let contentWidth = pageWidth - margin * 2
        let isManualEntry = payload.provenance?.isManualEntry == true || record.isManualEntry

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let data = renderer.pdfData { context in
            func drawManualWatermark() {
                guard isManualEntry else { return }
                let graphics = context.cgContext
                graphics.saveGState()
                graphics.translateBy(x: pageWidth / 2, y: pageHeight / 2)
                graphics.rotate(by: -.pi / 5)
                let text = "MANUAL ENTRY" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 58, weight: .bold),
                    .foregroundColor: UIColor.systemPurple.withAlphaComponent(0.09)
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attributes)
                graphics.restoreGState()
            }
            context.beginPage()
            drawManualWatermark()
            var y: CGFloat = margin
            var pageNumber: Int = 1
            let officialLogo = UIImage(named: "vinetrack_logo")

            let titleFont = UIFont.systemFont(ofSize: 22, weight: .bold)
            let headerFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
            let bodyFont = UIFont.systemFont(ofSize: 11, weight: .regular)
            let bodyBoldFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
            let captionFont = UIFont.systemFont(ofSize: 9, weight: .regular)
            let accentColor = VineyardTheme.uiOlive

            func drawPageFooter() {
                let footerY = pageHeight - 30
                if let officialLogo {
                    let maxSize = CGSize(width: 78, height: 18)
                    let scale = min(maxSize.width / officialLogo.size.width, maxSize.height / officialLogo.size.height)
                    officialLogo.draw(in: CGRect(x: margin, y: footerY, width: officialLogo.size.width * scale, height: officialLogo.size.height * scale))
                }
                let pageText = "Page \(pageNumber)"
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]
                let width = (pageText as NSString).size(withAttributes: attrs).width
                (pageText as NSString).draw(at: CGPoint(x: pageWidth - margin - width, y: footerY + 4), withAttributes: attrs)
            }

            func beginContinuationPage() {
                drawPageFooter()
                context.beginPage()
                drawManualWatermark()
                pageNumber += 1
                y = margin
            }

            func checkPageBreak(needed: CGFloat) {
                if y + needed > pageHeight - margin - 18 { beginContinuationPage() }
            }

            func drawText(_ text: String, font: UIFont, color: UIColor = .black, x: CGFloat = margin, maxWidth: CGFloat? = nil) {
                let w = maxWidth ?? contentWidth
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = (text as NSString).boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
                checkPageBreak(needed: size.height + 4)
                (text as NSString).draw(in: CGRect(x: x, y: y, width: w, height: size.height), withAttributes: attrs)
                y += size.height + 4
            }

            func drawRow(label: String, value: String, indent: CGFloat = 0) {
                let labelWidth: CGFloat = 180
                let rowHeight: CGFloat = 18
                checkPageBreak(needed: rowHeight)
                let labelAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.black]
                let valueAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: UIColor.black]
                (label as NSString).draw(in: CGRect(x: margin + indent, y: y, width: labelWidth, height: rowHeight), withAttributes: labelAttrs)
                (value as NSString).draw(in: CGRect(x: margin + indent + labelWidth, y: y, width: contentWidth - labelWidth - indent, height: rowHeight), withAttributes: valueAttrs)
                y += rowHeight
            }

            func drawPlannedActualTable(_ tank: SprayReportPayloadV1.Tank) {
                let itemWidth: CGFloat = 285
                let valueWidth: CGFloat = (contentWidth - itemWidth) / 2
                let headerHeight: CGFloat = 20
                func header() {
                    checkPageBreak(needed: headerHeight)
                    let attrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: UIColor.darkGray]
                    ("ITEM" as NSString).draw(in: CGRect(x: margin, y: y, width: itemWidth, height: headerHeight), withAttributes: attrs)
                    ("PLANNED" as NSString).draw(in: CGRect(x: margin + itemWidth, y: y, width: valueWidth, height: headerHeight), withAttributes: attrs)
                    ("ACTUAL" as NSString).draw(in: CGRect(x: margin + itemWidth + valueWidth, y: y, width: valueWidth, height: headerHeight), withAttributes: attrs)
                    y += headerHeight
                }
                func tableRow(item: String, planned: String, actual: String) {
                    let itemAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.black]
                    let valueAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: UIColor.black]
                    let itemHeight = (item as NSString).boundingRect(with: CGSize(width: itemWidth - 8, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: itemAttrs, context: nil).height
                    let rowHeight = max(24, itemHeight + 10)
                    if y + rowHeight > pageHeight - margin - 18 { beginContinuationPage(); header() }
                    (item as NSString).draw(in: CGRect(x: margin, y: y + 4, width: itemWidth - 8, height: rowHeight - 8), withAttributes: itemAttrs)
                    (planned as NSString).draw(in: CGRect(x: margin + itemWidth, y: y + 4, width: valueWidth - 6, height: rowHeight - 8), withAttributes: valueAttrs)
                    (actual as NSString).draw(in: CGRect(x: margin + itemWidth + valueWidth, y: y + 4, width: valueWidth - 6, height: rowHeight - 8), withAttributes: valueAttrs)
                    y += rowHeight
                    drawDivider()
                }
                header()
                tableRow(item: "Water", planned: tank.plannedWaterLitres.map { formatter.formatVolume(litres: $0) } ?? "Not planned", actual: tank.actualWaterLitres.map { $0 == 0 ? "0 L" : formatter.formatVolume(litres: $0) } ?? "Not recorded")
                for chemical in tank.chemicals {
                    let unit = ChemicalUnit(rawValue: chemical.unit) ?? .litres
                    let planned = chemical.plannedAmountBase.map { String(format: "%.3f %@", unit.fromBase($0), unit.rawValue) } ?? "—"
                    let actual = chemical.actualAmountBase.map { $0 == 0 ? "Not added" : String(format: "%.3f %@", unit.fromBase($0), unit.rawValue) } ?? "Not recorded"
                    let prefix = chemical.usageKind == "substitution" ? "Substitution: " : chemical.usageKind == "additional" ? "Additional: " : ""
                    tableRow(item: prefix + chemical.name, planned: planned, actual: actual)
                }
            }

            func drawSectionHeader(_ text: String) {
                y += 12
                checkPageBreak(needed: 28)
                let attrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: accentColor]
                (text as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
                y += 20
                let linePath = UIBezierPath()
                linePath.move(to: CGPoint(x: margin, y: y))
                linePath.addLine(to: CGPoint(x: pageWidth - margin, y: y))
                accentColor.withAlphaComponent(0.3).setStroke()
                linePath.lineWidth = 0.5
                linePath.stroke()
                y += 6
            }

            func drawDivider() {
                let linePath = UIBezierPath()
                linePath.move(to: CGPoint(x: margin + 10, y: y))
                linePath.addLine(to: CGPoint(x: pageWidth - margin - 10, y: y))
                UIColor.separator.setStroke()
                linePath.lineWidth = 0.25
                linePath.stroke()
                y += 4
            }

            func formatPath(_ value: Double) -> String {
                if value.truncatingRemainder(dividingBy: 1) == 0 {
                    return String(format: "%.0f", value)
                }
                return String(format: "%.1f", value)
            }

            PDFHeaderHelper.drawHeader(
                vineyardName: vineyardName,
                logoData: logoData,
                title: "Spray Report",
                accentColor: accentColor,
                margin: margin,
                contentWidth: contentWidth,
                y: &y
            )

            if isManualEntry {
                drawText("Manual entry", font: headerFont, color: .systemPurple)
            }

            if !record.sprayReference.isEmpty {
                let sprayNameFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
                drawText(record.sprayReference, font: sprayNameFont, color: .darkGray)
            }

            if !paddockName.isEmpty {
                drawText("\(formatter.blockTermCapitalised): \(paddockName)", font: bodyFont, color: .black)
            }

            // Blocks Treated — the AUTHORITATIVE sql/195 attribution.
            //
            // Deliberately separate from the line above, which is the linked
            // TRIP's block label and describes where the machine drove. This
            // section states which blocks the APPLICATION treated, which is what a
            // compliance reader and a resistance strategy need.
            //
            // A record whose attribution was never recorded says exactly that. It
            // never falls back to the vineyard's current blocks: naming a block
            // that may never have been sprayed would be worse than admitting the
            // record is silent.
            drawSectionHeader("\(formatter.blockTermCapitalised)s Treated")
            if let treatedBlocks = payload.blocks {
                for block in treatedBlocks { drawText("\u{2022} \(block.name)", font: bodyFont, color: .black) }
            } else {
                drawText(SprayBlockAttributionDisplay.notRecorded, font: bodyFont, color: .darkGray)
            }

            // Trip Info
            if let trip = trip {
                drawSectionHeader("Trip Information")

                // Date portion via the region formatter (DD/MM/YYYY for AU);
                // time-of-day keeps the existing localised short style so AU
                // output is unchanged.
                let timeFormatter = DateFormatter()
                timeFormatter.timeStyle = .short
                timeFormatter.timeZone = timeZone

                drawRow(label: "Start Time", value: "\(formatter.formatDate(trip.startTime)) \(timeFormatter.string(from: trip.startTime))")
                if let endTime = trip.endTime {
                    drawRow(label: "End Time", value: "\(formatter.formatDate(endTime)) \(timeFormatter.string(from: endTime))")
                }
                if let duration = payload.trip.activeDurationSeconds {
                    drawRow(label: "Active Duration", value: RegionFormatter.formatDuration(seconds: TimeInterval(duration)))
                } else {
                    drawRow(label: "Active Duration", value: "Not recorded")
                }
                if !trip.pauseTimestamps.isEmpty {
                    drawRow(label: "Pauses", value: "\(trip.pauseTimestamps.count)")
                }
                drawRow(label: "Operator", value: payload.trip.operatorName ?? "Not recorded")
                if let elapsed = payload.trip.elapsedDurationSeconds { drawRow(label: "Elapsed Duration", value: RegionFormatter.formatDuration(seconds: TimeInterval(elapsed))) }
                if let paused = payload.trip.pausedDurationSeconds { drawRow(label: "Paused Duration", value: RegionFormatter.formatDuration(seconds: TimeInterval(paused))) }
                if let distance = payload.trip.distanceMetres {
                    drawRow(label: "Total Distance", value: formatter.formatDistance(metres: distance))
                } else {
                    drawRow(label: "Total Distance", value: "Not recorded")
                }
                drawRow(label: "Tracking Pattern", value: trip.trackingPattern.rawValue.capitalized)
                drawRow(label: "Total Rows", value: "\(trip.rowSequence.count)")
                drawRow(label: "Completed", value: "\(trip.completedPaths.count)")
                if !trip.skippedPaths.isEmpty {
                    drawRow(label: "Skipped", value: "\(trip.skippedPaths.count)")
                }

                if let sessions = payload.tankSessions, !sessions.isEmpty {
                    y += 6
                    drawText("Tank Sessions", font: bodyBoldFont, color: .black)
                    for session in sessions {
                        drawRow(label: "Tank \(session.tankNumber)", value: session.status)
                        if let start = session.startRow, let end = session.endRow { drawRow(label: "  Recorded range", value: "\(formatPath(start))–\(formatPath(end))", indent: 12) }
                        drawRow(label: "  Assignment evidence", value: session.assignmentSource.replacingOccurrences(of: "_", with: " ").capitalized, indent: 12)
                    }
                }
            }

            drawSectionHeader("Hourly Weather")
            let weatherTimeFormatter = DateFormatter()
            weatherTimeFormatter.timeStyle = .short
            weatherTimeFormatter.timeZone = timeZone
            let isoFormatter = ISO8601DateFormatter()
            if payload.weather.isEmpty {
                drawText("No hourly observations recorded.", font: bodyFont, color: .darkGray)
            } else {
                for observation in payload.weather {
                    let time = isoFormatter.date(from: observation.sampleSlot).map(weatherTimeFormatter.string) ?? observation.sampleSlot
                    let temperature = observation.temperatureC.map { formatter.formatTemperature(celsius: $0) } ?? "—"
                    let humidity = observation.humidityPct.map { String(format: "%.0f%%", $0) } ?? "—"
                    let wind = observation.windSpeedKmh.map { formatter.formatSpeed(kmh: $0) } ?? "—"
                    let gust = observation.windGustKmh.map { formatter.formatSpeed(kmh: $0) } ?? "—"
                    let rain = observation.rainMm.map { formatter.formatRainfall(mm: $0) } ?? "—"
                    drawText("\(time)  \(temperature)  RH \(humidity)  Wind \(wind)  Gust \(gust)  Rain \(rain)", font: bodyFont)
                    drawText("\(observation.source) · \(observation.sourceKind)\(observation.isStale ? " · stale" : "")", font: captionFont, color: .darkGray)
                }
            }

            // Equipment
            let hasEquipment = payload.equipment.tractorName != nil || payload.equipment.sprayUnitName != nil || payload.equipment.startEngineHours != nil || payload.equipment.endEngineHours != nil || !record.tractorGear.isEmpty || !record.numberOfFansJets.isEmpty || record.averageSpeed != nil
            if hasEquipment {
                drawSectionHeader("Equipment")
                drawRow(label: "Tractor", value: payload.equipment.tractorName ?? "Not recorded")
                drawRow(label: "Engine hours start", value: payload.equipment.startEngineHours.map { String(format: "%.1f h", $0) } ?? "Not recorded")
                drawRow(label: "Engine hours end", value: payload.equipment.endEngineHours.map { String(format: "%.1f h", $0) } ?? "Not recorded")
                drawRow(label: "Engine hours used", value: payload.equipment.engineHoursUsed.map { String(format: "%.1f h", $0) } ?? "Not recorded")
                drawRow(label: "Spray Unit", value: payload.equipment.sprayUnitName ?? "Not recorded")
                if !equipmentName.isEmpty && payload.equipment.sprayUnitName == nil {
                    drawRow(label: "Equipment Type", value: equipmentName)
                }
                if let gear = payload.equipment.tractorGear, !gear.isEmpty { drawRow(label: "Tractor Gear", value: gear) }
                if let jets = payload.equipment.numberOfFansJets, !jets.isEmpty { drawRow(label: "No. Fans/Jets", value: jets) }
                if let avgSpeed = payload.equipment.averageSpeedKmh {
                    drawRow(label: "Average Speed", value: formatter.formatSpeed(kmh: avgSpeed))
                }
            }

            if let application = payload.application {
                drawSectionHeader("Application")
                drawRow(label: "Operation", value: application.operationType ?? "Not recorded")
                drawRow(label: "Application mode", value: application.applicationMode?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Not recorded")
                drawRow(label: "Treated area", value: application.treatedAreaHa.map { formatter.formatArea(hectares: $0) } ?? "Not recorded")
                drawRow(label: "Carrier total", value: application.totalCarrierLitres.map { formatter.formatVolume(litres: $0) } ?? "Not recorded")
                if let notes = application.notes { drawText("Notes: \(notes)", font: bodyFont) }
            }
            if let step = payload.programStep {
                drawSectionHeader("Program / Step")
                drawRow(label: "Link", value: step.linkState.replacingOccurrences(of: "_", with: " ").capitalized)
                drawRow(label: "Step", value: step.name ?? "Not recorded")
                if let target = step.target { drawRow(label: "Target", value: target) }
            }

            // Canonical one-table-per-tank worksheet. Values are base quantities
            // converted exactly once for display; missing and explicit zero differ.
            for reportTank in payload.tanks.sorted(by: { $0.tankNumber < $1.tankNumber }) {
                drawSectionHeader("Tank \(reportTank.tankNumber) — Planned / Actual")
                drawPlannedActualTable(reportTank)
                if let plannedTank = record.tanks.first(where: { $0.tankNumber == reportTank.tankNumber }) {
                    drawText("Rate / basis", font: bodyBoldFont)
                    for chemical in plannedTank.chemicals {
                        drawText("\(chemical.name): \(chemical.reportedRateText(formatter: formatter))", font: captionFont, color: .darkGray)
                    }
                }
            }

            if !payload.amendments.isEmpty {
                drawSectionHeader("Amendment History")
                for amendment in payload.amendments {
                    let oldValue = amendment.previousValue?.displayText ?? "Not recorded"
                    let newValue = amendment.newValue?.displayText ?? "Not recorded"
                    drawText("Tank \(amendment.tankNumber) · \(amendment.field): \(oldValue) → \(newValue)", font: bodyFont)
                    drawText("Updated by \(amendment.editorName) · \(amendment.editedAt) (\(payload.identity.vineyardTimeZone))", font: captionFont, color: .darkGray)
                }
            }

            let canonicalPlannedTotals = payload.plannedChemicalTotals ?? {
                let lines = payload.tanks.flatMap(\.chemicals).filter { $0.plannedAmountBase != nil }
                return Dictionary(grouping: lines) { $0.savedChemicalId?.uuidString ?? "\($0.name.lowercased())|\($0.unit)" }.map { key, values in
                    SprayReportPayloadV1.ChemicalTotal(identityKey: key, name: values.first?.name ?? "Unnamed chemical", unit: values.first?.unit ?? "Litres", actualAmountBase: values.compactMap(\.plannedAmountBase).reduce(0, +))
                }
            }()
            if !canonicalPlannedTotals.isEmpty {
                drawSectionHeader("Planned Chemical Totals (All Tanks)")
                for total in canonicalPlannedTotals {
                    let unit = ChemicalUnit(rawValue: total.unit) ?? .litres
                    drawRow(label: total.name, value: String(format: "%.3f %@", unit.fromBase(total.actualAmountBase), unit.rawValue))
                }
            }
            if !payload.actualChemicalTotals.isEmpty {
                drawSectionHeader("Actual Chemical Totals (All Tanks)")
                for total in payload.actualChemicalTotals {
                    let unit = ChemicalUnit(rawValue: total.unit) ?? .litres
                    drawRow(label: total.name, value: String(format: "%.3f %@", unit.fromBase(total.actualAmountBase), unit.rawValue))
                }
            }

            let costItems: [(String, Double)] = record.tanks.flatMap { tank in
                tank.chemicals.compactMap { chemical -> (String, Double)? in
                    let cost = chemical.costPerUnit * chemical.volumePerTank
                    guard cost > 0 else { return nil }
                    return (chemical.name.isEmpty ? "Unnamed" : chemical.name, cost)
                }
            }
            let costGrouped = Dictionary(grouping: costItems, by: { $0.0.lowercased() })
            let chemCosts = costGrouped.compactMap { (key, items) -> (String, Double)? in
                guard !key.isEmpty else { return nil }
                let displayName = items.first?.0 ?? key
                let totalCost = items.reduce(0.0) { $0 + $1.1 }
                return (displayName, totalCost)
            }.sorted { $0.0.lowercased() < $1.0.lowercased() }
            let totalSprayCost = chemCosts.reduce(0.0) { $0 + $1.1 }

            // Costing is gated entirely on `includeCostings` — the caller MUST
            // pass `false` for supervisors and operators so they never receive
            // pricing in exported spray PDFs.
            if includeCostings, let canonicalCost = payload.cost {
                drawSectionHeader("Authorized Cost Summary")
                drawRow(label: "Fuel used", value: canonicalCost.fuelLitres.map { formatter.formatVolume(litres: $0) } ?? "Not recorded")
                drawRow(label: "Fuel cost", value: canonicalCost.fuelCost.map { formatter.formatCurrency($0) } ?? "Not recorded")
                drawRow(label: "Chemical cost", value: canonicalCost.chemicalCost.map { formatter.formatCurrency($0) } ?? "Not recorded")
                drawRow(label: "Labour cost", value: canonicalCost.labourCost.map { formatter.formatCurrency($0) } ?? "Not recorded")
                drawRow(label: "Total", value: canonicalCost.totalCost.map { formatter.formatCurrency($0) } ?? "Incomplete")
                if !canonicalCost.isComplete { drawText(canonicalCost.basis, font: captionFont, color: .darkGray) }
            }
            if includeCostings, payload.cost == nil, let r = tripCostResult {
                drawSectionHeader(r.chemical?.basis == .actual ? "Trip Cost — Actual Chemicals" : "Estimated Trip Cost")

                if let w = r.labour.warning {
                    drawRow(label: "Labour", value: "—")
                    drawRow(label: "  Note: \(w)", value: "", indent: 12)
                } else {
                    if let name = r.labour.categoryName, let rate = r.labour.costPerHour, rate > 0 {
                        drawRow(label: "Labour (\(name))", value: formatter.formatCurrency(r.labour.cost))
                        drawRow(label: "  \(formatter.formatCurrency(rate))/hr × \(String(format: "%.2f", r.labour.hours)) hr", value: "", indent: 12)
                    } else {
                        drawRow(label: "Labour", value: formatter.formatCurrency(r.labour.cost))
                    }
                }

                if let w = r.fuel.warning {
                    drawRow(label: "Fuel", value: "—")
                    drawRow(label: "  Note: \(w)", value: "", indent: 12)
                } else {
                    drawRow(label: "Fuel used (est.)", value: formatter.formatFuel(litres: r.fuel.litres))
                    if let perL = r.fuel.costPerLitre {
                        drawRow(label: "Fuel cost per \(formatter.fuelUnitAbbreviation)", value: "\(formatter.formatCurrency(perL))/\(formatter.fuelUnitAbbreviation)")
                    }
                    drawRow(label: "Fuel cost", value: formatter.formatCurrency(r.fuel.cost))
                }

                if let chem = r.chemical {
                    if let w = chem.warning, chem.cost <= 0 {
                        drawRow(label: "Chemical/Input", value: "—")
                        drawRow(label: "  Note: \(w)", value: "", indent: 12)
                    } else {
                        drawRow(label: "Chemical/Input", value: formatter.formatCurrency(chem.cost))
                        if let w = chem.warning {
                            drawRow(label: "  Note: \(w)", value: "", indent: 12)
                        }
                    }
                }

                if let s = r.seeding {
                    if s.cost > 0 {
                        drawRow(label: "Seed/Input", value: formatter.formatCurrency(s.cost))
                        if let w = s.warning {
                            drawRow(label: "  Note: \(w)", value: "", indent: 12)
                        }
                    } else if let w = s.warning {
                        drawRow(label: "Seed/Input", value: w)
                    }
                }

                y += 4
                drawRow(label: "Total estimated cost", value: formatter.formatCurrency(r.totalCost))
                let statusLabel: String = {
                    switch r.completeness {
                    case .complete: return "Complete"
                    case .partial: return "Partial"
                    case .unavailable: return "Unavailable"
                    }
                }()
                drawRow(label: "Costing status", value: statusLabel)

                if let ha = r.treatedAreaHa {
                    drawRow(label: "Treated area", value: formatter.formatArea(hectares: ha))
                } else {
                    drawRow(label: "Treated area", value: "—")
                }
                if let cph = r.costPerHa {
                    // `costPerHa` is canonical $/hectare. Convert the per-area
                    // denominator to the configured spray/area unit for display.
                    let perArea = formatter.sprayRateValue(perHectare: cph)
                    drawRow(label: "Cost per \(formatter.areaUnitAbbreviation)", value: "\(formatter.formatCurrency(perArea))/\(formatter.areaUnitAbbreviation)")
                } else {
                    drawRow(label: "Cost per \(formatter.areaUnitAbbreviation)", value: "—")
                    if let w = r.areaWarning {
                        drawRow(label: "  Note: \(w)", value: "", indent: 12)
                    }
                }
                if let yt = r.yieldTonnes {
                    drawRow(label: "Yield", value: String(format: "%.2f t", yt))
                } else {
                    drawRow(label: "Yield", value: "—")
                }
                if let cpt = r.costPerTonne {
                    drawRow(label: "Cost per tonne", value: "\(formatter.formatCurrency(cpt))/t")
                } else {
                    drawRow(label: "Cost per tonne", value: "—")
                    if let w = r.yieldWarning {
                        drawRow(label: "  Note: \(w)", value: "", indent: 12)
                    }
                }
            } else {
                let hasCosts = !chemCosts.isEmpty || fuelCost > 0 || operatorCost > 0
                if hasCosts && includeCostings {
                    drawSectionHeader("Costs")
                    for (name, cost) in chemCosts {
                        drawRow(label: name, value: formatter.formatCurrency(cost))
                    }
                    if !chemCosts.isEmpty {
                        y += 4
                        drawRow(label: "Chemical Subtotal", value: formatter.formatCurrency(totalSprayCost))
                    }
                    if fuelCost > 0 {
                        drawRow(label: "Fuel Cost", value: formatter.formatCurrency(fuelCost))
                    }
                    if operatorCost > 0 {
                        drawRow(label: operatorCategoryName ?? "Operator", value: formatter.formatCurrency(operatorCost))
                    }
                    y += 4
                    let grandTotal = totalSprayCost + fuelCost + operatorCost
                    drawRow(label: "Total Cost", value: formatter.formatCurrency(grandTotal))
                }
            }

            if !payload.warnings.isEmpty {
                drawSectionHeader("Completeness")
                for warning in payload.warnings { drawText("• \(warning)", font: captionFont, color: .darkGray) }
            }

            if let snapshot = mapSnapshot {
                drawSectionHeader("Route Map")

                let maxMapHeight: CGFloat = 320
                let aspectRatio = snapshot.size.height / snapshot.size.width
                let mapHeight = min(contentWidth * aspectRatio, maxMapHeight)

                checkPageBreak(needed: mapHeight + 16)

                let mapRect = CGRect(x: margin, y: y, width: contentWidth, height: mapHeight)
                let clipPath = UIBezierPath(roundedRect: mapRect, cornerRadius: 8)
                context.cgContext.saveGState()
                clipPath.addClip()
                snapshot.draw(in: mapRect)
                context.cgContext.restoreGState()

                UIColor(white: 0.82, alpha: 1.0).setStroke()
                let borderPath = UIBezierPath(roundedRect: mapRect, cornerRadius: 8)
                borderPath.lineWidth = 1
                borderPath.stroke()

                y += mapHeight + 12
            }

            let actualNotes = record.notes
                .components(separatedBy: "\n")
                .filter { !$0.hasPrefix("Paddocks:") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !actualNotes.isEmpty {
                drawSectionHeader("Notes")
                drawText(actualNotes, font: bodyFont)
            }

            if let trip = trip, !trip.rowSequence.isEmpty {
                beginContinuationPage()

                drawSectionHeader("Row Summary")

                let colRowX: CGFloat = margin + 8
                let colBlockX: CGFloat = margin + 70
                let colStatusX: CGFloat = margin + 190
                let colSourceX: CGFloat = margin + 285
                let colTankX: CGFloat = margin + 405
                let tableHeaderAttrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: UIColor.black]
                checkPageBreak(needed: 16)
                ("ROW" as NSString).draw(at: CGPoint(x: colRowX, y: y), withAttributes: tableHeaderAttrs)
                (formatter.blockTerm.uppercased() as NSString).draw(at: CGPoint(x: colBlockX, y: y), withAttributes: tableHeaderAttrs)
                ("STATUS" as NSString).draw(at: CGPoint(x: colStatusX, y: y), withAttributes: tableHeaderAttrs)
                ("SOURCE" as NSString).draw(at: CGPoint(x: colSourceX, y: y), withAttributes: tableHeaderAttrs)
                ("TANK" as NSString).draw(at: CGPoint(x: colTankX, y: y), withAttributes: tableHeaderAttrs)
                y += 14

                for row in payload.rows {
                    checkPageBreak(needed: 18)
                    let rowLabel = "Row \(formatPath(row.rowNumber))"
                    let status = row.status
                    let statusColor: UIColor = status == "Complete" ? VineyardTheme.uiOlive : (status == "Skipped/Not complete" ? UIColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1.0) : UIColor.darkGray)
                    let tankLabel = row.tank?.displayText ?? "Not recorded"
                    let blockName = row.blockName ?? "Not recorded"

                    let rowAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.black]
                    let blockAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.black]
                    let statusAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: statusColor]
                    let sourceAttrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: UIColor.darkGray]
                    let tankAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.black]
                    (rowLabel as NSString).draw(at: CGPoint(x: colRowX, y: y), withAttributes: rowAttrs)
                    (blockName as NSString).draw(at: CGPoint(x: colBlockX, y: y), withAttributes: blockAttrs)
                    (status as NSString).draw(at: CGPoint(x: colStatusX, y: y), withAttributes: statusAttrs)
                    (row.source as NSString).draw(at: CGPoint(x: colSourceX, y: y), withAttributes: sourceAttrs)
                    (tankLabel as NSString).draw(at: CGPoint(x: colTankX, y: y), withAttributes: tankAttrs)
                    y += 18
                }
            }

            y += 20
            checkPageBreak(needed: 30)
            drawDivider()
            let tzAbbrev = timeZone.abbreviation() ?? timeZone.identifier
            let footerText = "Generated by VineTrack \u{2022} \(formatter.formatDate(Date())) (\(tzAbbrev))"
            drawText(footerText, font: captionFont, color: .darkGray)
            drawPageFooter()
        }

        return data
    }

    private static func blockNameForPath(_ path: Double, paddocks: [Paddock]) -> String {
        let adjacentRows = [Int(floor(path)), Int(ceil(path))]
        for paddock in paddocks {
            let paddockRowNumbers = Set(paddock.rows.map { $0.number })
            for rowNum in adjacentRows {
                if paddockRowNumbers.contains(rowNum) {
                    return paddock.name
                }
            }
        }
        return "–"
    }

    static func captureMapSnapshot(trip: Trip) async -> UIImage? {
        let coords = trip.pathPoints.map { $0.coordinate }
        guard coords.count >= 2 else { return nil }

        var minLat = coords.map(\.latitude).min() ?? 0
        var maxLat = coords.map(\.latitude).max() ?? 0
        var minLon = coords.map(\.longitude).min() ?? 0
        var maxLon = coords.map(\.longitude).max() ?? 0

        let latPadding = (maxLat - minLat) * 0.15
        let lonPadding = (maxLon - minLon) * 0.15
        minLat -= latPadding
        maxLat += latPadding
        minLon -= lonPadding
        maxLon += lonPadding

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(maxLat - minLat, 0.001),
            longitudeDelta: max(maxLon - minLon, 0.001)
        )

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = CGSize(width: 1030, height: 700)
        options.mapType = .hybrid

        let snapshotter = MKMapSnapshotter(options: options)

        do {
            let snapshot = try await snapshotter.start()
            let image = snapshot.image
            UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)
            image.draw(at: .zero)

            if let ctx = UIGraphicsGetCurrentContext() {
                ctx.setLineWidth(4.0)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)

                for i in 0..<(coords.count - 1) {
                    let p1 = snapshot.point(for: coords[i])
                    let p2 = snapshot.point(for: coords[i + 1])
                    let progress = Double(i) / Double(max(coords.count - 1, 1))
                    let routeColors: [UIColor] = [
                        UIColor(red: 0.86, green: 0.10, blue: 0.10, alpha: 1),
                        UIColor(red: 0.96, green: 0.32, blue: 0.06, alpha: 1),
                        UIColor(red: 0.98, green: 0.68, blue: 0.05, alpha: 1),
                        UIColor(red: 0.65, green: 0.76, blue: 0.08, alpha: 1),
                        UIColor(red: 0.10, green: 0.62, blue: 0.22, alpha: 1)
                    ]
                    let colorIndex = min(Int(progress * Double(routeColors.count)), routeColors.count - 1)
                    ctx.setStrokeColor(routeColors[colorIndex].cgColor)
                    ctx.move(to: p1)
                    ctx.addLine(to: p2)
                    ctx.strokePath()
                }

                let startPoint = snapshot.point(for: coords.first!)
                let endPoint = snapshot.point(for: coords.last!)

                ctx.setFillColor(UIColor.systemRed.cgColor)
                ctx.fillEllipse(in: CGRect(x: startPoint.x - 8, y: startPoint.y - 8, width: 16, height: 16))
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fillEllipse(in: CGRect(x: startPoint.x - 4, y: startPoint.y - 4, width: 8, height: 8))

                ctx.setFillColor(UIColor.systemGreen.cgColor)
                ctx.fillEllipse(in: CGRect(x: endPoint.x - 8, y: endPoint.y - 8, width: 16, height: 16))
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fillEllipse(in: CGRect(x: endPoint.x - 4, y: endPoint.y - 4, width: 8, height: 8))
            }

            let finalImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            return finalImage
        } catch {
            return nil
        }
    }

    static func savePDFToTemp(data: Data, fileName: String) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let sanitized = fileName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = tempDir.appendingPathComponent("\(sanitized).pdf")
        try? data.write(to: url)
        return url
    }
}
