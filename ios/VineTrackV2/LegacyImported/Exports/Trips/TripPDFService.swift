import UIKit
import PDFKit
import MapKit
import CoreLocation

struct TripPDFService {

    /// A grouping of planned paths by paddock used for the Rows / Paths
    /// Covered section of the report. Pass an empty array to render a
    /// single un-grouped list using the trip's paddockName.
    struct PaddockCoverage {
        let name: String
        /// Subset of `trip.rowSequence` that lives in this paddock.
        let plannedPaths: [Double]
    }

    static func generatePDF(
        trip: Trip,
        vineyardName: String,
        paddockName: String,
        pinCount: Int,
        mapSnapshot: UIImage?,
        logoData: Data? = nil,
        fuelCost: Double = 0,
        chemicalCosts: [(String, Double)] = [],
        operatorCost: Double = 0,
        operatorCategoryName: String? = nil,
        includeCostings: Bool = true,
        timeZone: TimeZone = .current,
        tripFunctionLabel: String? = nil,
        paddockGroups: [PaddockCoverage] = [],
        tripCostResult: TripCostService.Result? = nil,
        formatter: RegionFormatter = .australian
    ) -> Data {
        let pageWidth: CGFloat = 595.0
        let pageHeight: CGFloat = 842.0
        let margin: CGFloat = 40.0
        let contentWidth = pageWidth - margin * 2

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let resolvedFunctionLabel = tripFunctionLabel ?? defaultFunctionLabel(for: trip)
        let reportTitle: String = {
            if let label = resolvedFunctionLabel, !label.isEmpty {
                return "Trip Report — \(label)"
            }
            return "Trip Report"
        }()

        let manuallyMarkedComplete: [Double] = parseEndReviewCompleted(trip.manualCorrectionEvents)
        let rowResults: [RowCompletionResult] = RowCompletionDeriver.results(for: trip)
        let rowResultByPath: [Double: RowCompletionResult] = Dictionary(uniqueKeysWithValues: rowResults.map { ($0.path, $0) })

        let data = renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = margin

            let headerFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
            let bodyFont = UIFont.systemFont(ofSize: 11, weight: .regular)
            let bodyBoldFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
            let captionFont = UIFont.systemFont(ofSize: 9, weight: .regular)
            let accentColor = VineyardTheme.uiOlive

            func checkPageBreak(needed: CGFloat) {
                if y + needed > pageHeight - margin {
                    context.beginPage()
                    y = margin
                }
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
                let labelAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.darkGray]
                let valueAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: UIColor.black]
                (label as NSString).draw(in: CGRect(x: margin + indent, y: y, width: labelWidth, height: rowHeight), withAttributes: labelAttrs)
                (value as NSString).draw(in: CGRect(x: margin + indent + labelWidth, y: y, width: contentWidth - labelWidth - indent, height: rowHeight), withAttributes: valueAttrs)
                y += rowHeight
            }

            func drawWrappedRow(label: String, value: String, indent: CGFloat = 0) {
                let labelWidth: CGFloat = 180
                let labelAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.darkGray]
                let valueAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: UIColor.black]
                let valueWidth = contentWidth - labelWidth - indent
                let size = (value as NSString).boundingRect(
                    with: CGSize(width: valueWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: valueAttrs,
                    context: nil
                )
                let rowHeight = max(18, size.height + 2)
                checkPageBreak(needed: rowHeight)
                (label as NSString).draw(in: CGRect(x: margin + indent, y: y, width: labelWidth, height: 18), withAttributes: labelAttrs)
                (value as NSString).draw(in: CGRect(x: margin + indent + labelWidth, y: y, width: valueWidth, height: rowHeight), withAttributes: valueAttrs)
                y += rowHeight
            }

            func drawSubHeader(_ text: String, indent: CGFloat = 0) {
                checkPageBreak(needed: 22)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: accentColor,
                ]
                (text as NSString).draw(in: CGRect(x: margin + indent, y: y, width: contentWidth - indent, height: 18), withAttributes: attrs)
                y += 20
            }

            func drawSectionHeader(_ text: String) {
                y += 12
                checkPageBreak(needed: 28)
                let rect = CGRect(x: margin, y: y, width: contentWidth, height: 24)
                UIColor(white: 0.95, alpha: 1.0).setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 4).fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: accentColor]
                (text as NSString).draw(in: CGRect(x: margin + 8, y: y + 4, width: contentWidth - 16, height: 20), withAttributes: attrs)
                y += 30
            }

            PDFHeaderHelper.drawHeader(
                vineyardName: vineyardName,
                logoData: logoData,
                title: reportTitle,
                accentColor: accentColor,
                margin: margin,
                contentWidth: contentWidth,
                y: &y
            )

            // ── Trip Details ─────────────────────────────────────────────
            drawSectionHeader("Trip Details")

            if !vineyardName.isEmpty {
                drawRow(label: "Vineyard", value: vineyardName)
            }

            // Block(s)
            let allPaddockNames: [String] = {
                if !paddockGroups.isEmpty {
                    return paddockGroups.map(\.name).filter { !$0.isEmpty }
                }
                if !paddockName.isEmpty { return [paddockName] }
                if !trip.paddockName.isEmpty { return [trip.paddockName] }
                return []
            }()
            if allPaddockNames.count > 1 {
                drawWrappedRow(label: formatter.blockTermPluralCapitalised, value: allPaddockNames.joined(separator: ", "))
            } else if let only = allPaddockNames.first {
                drawRow(label: formatter.blockTermCapitalised, value: only)
            }

            if let label = resolvedFunctionLabel, !label.isEmpty {
                drawRow(label: "Trip type", value: label)
            }
            if let title = trip.tripTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty,
               title != resolvedFunctionLabel {
                drawWrappedRow(label: "Trip details", value: title)
            }
            if !trip.personName.isEmpty {
                drawRow(label: "Operator", value: trip.personName)
            }

            // Date / start time / finish time on separate lines (operator request).
            // Date uses the region date format; time-of-day presentation stays
            // identical for AU (matching the SprayRecordPDFService reference).
            drawRow(label: "Date", value: formatter.formatDate(trip.startTime))
            drawRow(label: "Start time", value: trip.startTime.formattedTZ(date: .omitted, time: .shortened, in: timeZone))
            if let endTime = trip.endTime {
                drawRow(label: "Finish time", value: endTime.formattedTZ(date: .omitted, time: .shortened, in: timeZone))
            }
            drawRow(label: "Duration", value: formatDuration(trip))
            drawRow(label: "Distance", value: formatter.formatDistance(metres: trip.totalDistance))
            drawRow(label: "Average speed", value: formatAverageSpeed(trip, formatter: formatter))
            drawRow(label: "Pattern", value: trip.trackingPattern.title)
            drawRow(label: "Pins logged", value: "\(pinCount)")

            // ── Seeding Details ──────────────────────────────────────────
            if (trip.tripFunction == "seeding"),
               let details = trip.seedingDetails,
               details.hasAnyValue {
                drawSectionHeader("Seeding Details")
                if let depth = details.sowingDepthCm {
                    drawRow(label: "Sowing depth", value: "\(formatNumber(depth)) cm")
                }
                let frontUsed = details.frontBox?.hasAnyValue == true
                let backUsed = details.backBox?.hasAnyValue == true
                drawRow(label: "Front box used", value: frontUsed ? "Yes" : "No")
                drawRow(label: "Rear box used", value: backUsed ? "Yes" : "No")

                if frontUsed, let front = details.frontBox {
                    y += 4
                    drawSubHeader("Front Box")
                    drawSeedingBox(front, drawRow: drawRow)
                }
                if backUsed, let back = details.backBox {
                    y += 4
                    drawSubHeader("Rear Box")
                    drawSeedingBox(back, drawRow: drawRow)
                }
                if let lines = details.mixLines?.filter({ $0.hasAnyValue }), !lines.isEmpty {
                    y += 4
                    drawSubHeader("Mix Lines")
                    for (idx, line) in lines.enumerated() {
                        let title: String
                        if let n = line.name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                            title = "Line \(idx + 1) — \(n)"
                        } else {
                            title = "Line \(idx + 1)"
                        }
                        drawRow(label: title, value: "")
                        if let pct = line.percentOfMix {
                            drawRow(label: "  % of mix", value: "\(formatNumber(pct))%", indent: 12)
                        }
                        if let box = line.seedBox, !box.isEmpty {
                            drawRow(label: "  Seed box", value: box, indent: 12)
                        }
                        if let kg = line.kgPerHa {
                            drawRow(label: "  Kg/ha", value: "\(formatNumber(kg)) kg/ha", indent: 12)
                        }
                        if let supplier = line.supplierManufacturer?.trimmingCharacters(in: .whitespacesAndNewlines), !supplier.isEmpty {
                            drawRow(label: "  Supplier", value: supplier, indent: 12)
                        }
                    }
                }
            }

            // ── Rows / Paths Covered ─────────────────────────────────────
            if !trip.rowSequence.isEmpty {
                drawSectionHeader("Rows / Paths")

                let groups: [PaddockCoverage] = {
                    if !paddockGroups.isEmpty { return paddockGroups }
                    return [PaddockCoverage(
                        name: paddockName.isEmpty ? trip.paddockName : paddockName,
                        plannedPaths: trip.rowSequence
                    )]
                }()

                for (gIdx, group) in groups.enumerated() {
                    if groups.count > 1 || !(group.name.isEmpty) {
                        if gIdx > 0 { y += 4 }
                        drawSubHeader(group.name.isEmpty ? "Block \(gIdx + 1)" : group.name)
                    }
                    let groupResults = group.plannedPaths.compactMap { rowResultByPath[$0] }
                    let completeCount = groupResults.filter { $0.status == .complete }.count
                    let partialCount = groupResults.filter { $0.status == .partial }.count
                    let notDoneCount = groupResults.filter { $0.status == .notComplete }.count

                    drawRow(
                        label: "Total planned",
                        value: "\(group.plannedPaths.count)  (✅ \(completeCount)  ⚠️ \(partialCount)  ❌ \(notDoneCount))",
                        indent: 12
                    )

                    // Row-by-row simple list — the operational record.
                    for result in groupResults {
                        drawRow(
                            label: "\(result.status.emoji)  \(result.formattedPath)",
                            value: result.statusAndSourceLabel,
                            indent: 12
                        )
                    }
                }
                _ = manuallyMarkedComplete // retained for backwards compatibility; sources now embedded per row
            }

            // ── Tank Sessions (existing) ─────────────────────────────────
            if !trip.tankSessions.isEmpty {
                drawSectionHeader("Tank Sessions")
                for session in trip.tankSessions {
                    let status = session.endTime != nil ? "Complete" : "Active"
                    drawRow(label: "Tank \(session.tankNumber)", value: status)
                    if !session.rowRange.isEmpty {
                        drawRow(label: "  Rows", value: session.rowRange, indent: 12)
                    }
                    if let end = session.endTime {
                        let dur = end.timeIntervalSince(session.startTime)
                        drawRow(label: "  Duration", value: formatDurationSeconds(dur), indent: 12)
                    }
                    if let fillDur = session.fillDuration {
                        drawRow(label: "  Fill Duration", value: formatDurationSeconds(fillDur), indent: 12)
                    }
                    y += 4
                }
            }

            // ── Completion Notes ─────────────────────────────────────────
            if let notes = trip.completionNotes?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !notes.isEmpty {
                drawSectionHeader("Completion Notes")
                drawWrappedRow(label: "Notes", value: notes)
            }

            // Manual Corrections section intentionally omitted from the
            // exported customer/operator PDF. Internal correction events
            // (auto_sequence_recover, end_review_completed, end_review_finalised, …)
            // are still stored on the trip for diagnostics and remain visible
            // in the in-app Trip Detail view.

            // ── Estimated Trip Cost ──────────────────────────────────────
            // Gated entirely on `includeCostings` — caller must pass `false`
            // for non-owner/manager roles so supervisors and operators never
            // see pricing in exported PDFs.
            if includeCostings, let r = tripCostResult {
                drawSectionHeader("Estimated Trip Cost")

                // Labour
                if let w = r.labour.warning {
                    drawRow(label: "Labour", value: "—")
                    drawWrappedRow(label: "  Note", value: w, indent: 12)
                } else {
                    let detail: String = {
                        if let name = r.labour.categoryName, let rate = r.labour.costPerHour, rate > 0 {
                            return "\(name) · \(formatter.formatCurrency(rate))/hr × \(String(format: "%.2f", r.labour.hours)) hr"
                        }
                        return "\(String(format: "%.2f", r.labour.hours)) hr"
                    }()
                    drawRow(label: "Labour", value: formatter.formatCurrency(r.labour.cost))
                    drawRow(label: "  \(detail)", value: "", indent: 12)
                }

                // Fuel
                if let w = r.fuel.warning {
                    drawRow(label: "Fuel", value: "—")
                    drawWrappedRow(label: "  Note", value: w, indent: 12)
                } else {
                    drawRow(label: "Fuel used (est.)", value: formatter.formatFuel(litres: r.fuel.litres))
                    if let perL = r.fuel.costPerLitre {
                        drawRow(label: "Fuel cost per \(formatter.fuelUnitAbbreviation)", value: "\(formatter.formatCurrency(perL))/\(formatter.fuelUnitAbbreviation)")
                    }
                    drawRow(label: "Fuel cost", value: formatter.formatCurrency(r.fuel.cost))
                }

                // Chemical
                if let chem = r.chemical {
                    if let w = chem.warning, chem.cost <= 0 {
                        drawRow(label: "Chemical/Input", value: "—")
                        drawWrappedRow(label: "  Note", value: w, indent: 12)
                    } else {
                        drawRow(label: "Chemical/Input", value: formatter.formatCurrency(chem.cost))
                        if let w = chem.warning {
                            drawWrappedRow(label: "  Note", value: w, indent: 12)
                        }
                    }
                }

                // Seeding/Input cost or warning if relevant
                if let s = r.seeding {
                    if s.cost > 0 {
                        drawRow(label: "Seed/Input", value: formatter.formatCurrency(s.cost))
                        if let w = s.warning {
                            drawWrappedRow(label: "  Note", value: w, indent: 12)
                        }
                    } else if let w = s.warning {
                        drawWrappedRow(label: "Seed/Input", value: w)
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

                // Treated area / cost per ha
                if let ha = r.treatedAreaHa {
                    drawRow(label: "Treated area", value: formatter.formatArea(hectares: ha))
                } else {
                    drawRow(label: "Treated area", value: "—")
                }
                if let cph = r.costPerHa {
                    // r.costPerHa is canonical cost-per-hectare; convert the area
                    // denominator so US/CA reports read e.g. "$x.xx/ac".
                    let perArea = cph / formatter.areaValue(hectares: 1)
                    drawRow(label: "Cost per \(formatter.areaUnitAbbreviation)", value: "\(formatter.formatCurrency(perArea))/\(formatter.areaUnitAbbreviation)")
                } else {
                    drawRow(label: "Cost per \(formatter.areaUnitAbbreviation)", value: "—")
                    if let w = r.areaWarning {
                        drawWrappedRow(label: "  Note", value: w, indent: 12)
                    }
                }

                // Yield / cost per tonne
                if let y = r.yieldTonnes {
                    drawRow(label: "Yield", value: String(format: "%.2f t", y))
                } else {
                    drawRow(label: "Yield", value: "—")
                }
                if let cpt = r.costPerTonne {
                    drawRow(label: "Cost per tonne", value: "\(formatter.formatCurrency(cpt))/t")
                } else {
                    drawRow(label: "Cost per tonne", value: "—")
                    if let w = r.yieldWarning {
                        drawWrappedRow(label: "  Note", value: w, indent: 12)
                    }
                }
            } else {
                // Legacy fallback: render a flat cost table from the explicit
                // numeric parameters when no structured cost result was supplied.
                let hasChemCosts = !chemicalCosts.isEmpty
                let hasCosts = hasChemCosts || fuelCost > 0 || operatorCost > 0
                if hasCosts && includeCostings {
                    drawSectionHeader("Costs")
                    let totalChemCost = chemicalCosts.reduce(0.0) { $0 + $1.1 }
                    for (name, cost) in chemicalCosts {
                        drawRow(label: name, value: formatter.formatCurrency(cost))
                    }
                    if hasChemCosts {
                        y += 4
                        drawRow(label: "Chemical Subtotal", value: formatter.formatCurrency(totalChemCost))
                    }
                    if fuelCost > 0 {
                        drawRow(label: "Fuel Cost", value: formatter.formatCurrency(fuelCost))
                    }
                    if operatorCost > 0 {
                        drawRow(label: operatorCategoryName ?? "Operator", value: formatter.formatCurrency(operatorCost))
                    }
                    y += 4
                    let grandTotal = totalChemCost + fuelCost + operatorCost
                    drawRow(label: "Total Cost", value: formatter.formatCurrency(grandTotal))
                }
            }

            // ── Map ──────────────────────────────────────────────────────
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

            y += 16
            checkPageBreak(needed: 30)
            let footerTime = Date().formattedTZ(date: .omitted, time: .shortened, in: timeZone)
            let tzAbbrev = timeZone.abbreviation() ?? timeZone.identifier
            drawText("Generated \(formatter.formatDate(Date())) \(footerTime) (\(tzAbbrev)) • VineTrack", font: captionFont, color: .gray)
        }

        return data
    }

    // MARK: - Helpers

    private static func defaultFunctionLabel(for trip: Trip) -> String? {
        if let raw = trip.tripFunction, !raw.isEmpty {
            if let f = TripFunction(rawValue: raw) {
                return f.displayName
            }
            if raw.hasPrefix("custom:") {
                let title = trip.tripTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !title.isEmpty { return title }
                return String(raw.dropFirst("custom:".count)).replacingOccurrences(of: "-", with: " ").capitalized
            }
            return raw.capitalized
        }
        return nil
    }

    private static func drawSeedingBox(_ box: SeedingBox, drawRow: (String, String, CGFloat) -> Void) {
        if let mix = box.mixName, !mix.isEmpty {
            drawRow("  Mix", mix, 12)
        }
        if let rate = box.ratePerHa {
            drawRow("  Rate/ha", "\(formatNumber(rate)) kg/ha", 12)
        }
        if let s = box.shutterSlide, !s.isEmpty {
            drawRow("  Shutter slide", s, 12)
        }
        if let f = box.bottomFlap, !f.isEmpty {
            drawRow("  Bottom flap", f, 12)
        }
        if let w = box.meteringWheel, !w.isEmpty {
            drawRow("  Metering wheel", w, 12)
        }
        if let v = box.seedVolumeKg {
            drawRow("  Seed volume", "\(formatNumber(v)) kg", 12)
        }
        if let g = box.gearboxSetting {
            drawRow("  Gearbox setting", formatNumber(g), 12)
        }
    }

    private static func parseEndReviewCompleted(_ events: [String]) -> [Double] {
        var paths: [Double] = []
        let marker = "end_review_completed: ["
        for event in events {
            guard let range = event.range(of: marker),
                  let endRange = event.range(of: "]", range: range.upperBound..<event.endIndex) else { continue }
            let inner = event[range.upperBound..<endRange.lowerBound]
            for piece in inner.split(separator: ",") {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if let v = Double(trimmed) { paths.append(v) }
            }
        }
        return paths
    }

    struct CorrectionLine {
        let time: String
        let description: String
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func formatCorrectionEvent(_ event: String, timeZone: TimeZone) -> CorrectionLine {
        // Expected shape: "<ISO8601> <note>"
        let parts = event.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        var timeStr = ""
        var note = event
        if parts.count == 2, let date = isoParser.date(from: String(parts[0])) {
            timeStr = date.formattedTZ(date: .omitted, time: .shortened, in: timeZone)
            note = String(parts[1])
        }
        return CorrectionLine(time: timeStr.isEmpty ? "—" : timeStr, description: humaniseCorrectionNote(note))
    }

    static func humaniseCorrectionNote(_ note: String) -> String {
        if note == "manual_next_path" { return "Operator advanced to next row" }
        if note.hasPrefix("manual_back_path: ") {
            let v = String(note.dropFirst("manual_back_path: ".count))
            return "Stepped back to row \(v)"
        }
        if note.hasPrefix("manual_complete: ") {
            let v = String(note.dropFirst("manual_complete: ".count))
            return "Row \(v) manually marked complete"
        }
        if note.hasPrefix("manual_skip: ") {
            let v = String(note.dropFirst("manual_skip: ".count))
            return "Row \(v) manually skipped"
        }
        if note.hasPrefix("confirm_locked_path: ") {
            let v = String(note.dropFirst("confirm_locked_path: ".count))
            return "Operator confirmed current row \(v)"
        }
        if note.hasPrefix("snap_to_live_path: ") {
            let v = String(note.dropFirst("snap_to_live_path: ".count))
            return "Snapped planned sequence to live row \(v)"
        }
        if note.hasPrefix("auto_realign_accepted: ") {
            let v = String(note.dropFirst("auto_realign_accepted: ".count))
            return "Auto-realign accepted for row \(v)"
        }
        if note.hasPrefix("auto_realign_ignored: ") {
            let v = String(note.dropFirst("auto_realign_ignored: ".count))
            return "Auto-realign ignored for row \(v)"
        }
        if note.hasPrefix("paddocks_added: ") {
            let v = String(note.dropFirst("paddocks_added: ".count))
            return "Added blocks: \(v)"
        }
        if note.hasPrefix("end_review_completed: ") {
            let v = String(note.dropFirst("end_review_completed: ".count))
            return "End-review manually marked complete: \(v)"
        }
        if note == "end_review_finalised" {
            return "End-trip review finalised"
        }
        return note
    }

    private static func pathListText(_ paths: [Double]) -> String {
        paths.map { formatPath($0) }.joined(separator: ", ")
    }

    private static func formatPath(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%g", value)
    }

    static func captureMapSnapshot(trip: Trip) async -> UIImage? {
        let coords = trip.pathPoints.map { $0.coordinate }
        guard coords.count >= 2 else {
            return nil
        }

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
                    let r = CGFloat(1.0 - progress)
                    let g = CGFloat(progress)
                    ctx.setStrokeColor(UIColor(red: r, green: g, blue: 0, alpha: 1.0).cgColor)

                    ctx.move(to: p1)
                    ctx.addLine(to: p2)
                    ctx.strokePath()
                }

                if let firstCoord = coords.first, let lastCoord = coords.last {
                    let startPoint = snapshot.point(for: firstCoord)
                    let endPoint = snapshot.point(for: lastCoord)

                    ctx.setFillColor(UIColor.systemGreen.cgColor)
                    ctx.fillEllipse(in: CGRect(x: startPoint.x - 8, y: startPoint.y - 8, width: 16, height: 16))
                    ctx.setFillColor(UIColor.white.cgColor)
                    ctx.fillEllipse(in: CGRect(x: startPoint.x - 4, y: startPoint.y - 4, width: 8, height: 8))

                    ctx.setFillColor(UIColor.systemRed.cgColor)
                    ctx.fillEllipse(in: CGRect(x: endPoint.x - 8, y: endPoint.y - 8, width: 16, height: 16))
                    ctx.setFillColor(UIColor.white.cgColor)
                    ctx.fillEllipse(in: CGRect(x: endPoint.x - 4, y: endPoint.y - 4, width: 8, height: 8))
                }
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

    private static func formatDuration(_ trip: Trip) -> String {
        formatDurationSeconds(trip.activeDuration)
    }

    private static func formatDurationSeconds(_ seconds: TimeInterval) -> String {
        RegionFormatter.formatDuration(seconds: seconds)
    }

    private static func formatAverageSpeed(_ trip: Trip, formatter: RegionFormatter) -> String {
        let durationSeconds = trip.activeDuration
        guard durationSeconds > 0 && trip.totalDistance > 0 else { return "—" }
        let speedMps = trip.totalDistance / durationSeconds
        let speedKmh = speedMps * 3.6
        return formatter.formatSpeed(kmh: speedKmh)
    }
}
