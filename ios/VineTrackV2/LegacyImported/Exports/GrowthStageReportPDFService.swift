import UIKit
import PDFKit

struct GrowthStageReportPDFService {

    struct BlockReport {
        let blockName: String
        let vintages: [Int]
        let stageCodes: [String]
        let entries: [Int: [String: Date]]
    }

    static func generatePDF(
        blocks: [BlockReport],
        vineyardName: String,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        vintageColors: [Int: UIColor],
        logoData: Data? = nil,
        timeZone: TimeZone = .current,
        dateFormat: String = "d MMM yyyy",
        localeIdentifier: String? = nil
    ) -> Data {
        let pageWidth: CGFloat = 595.0
        let pageHeight: CGFloat = 842.0
        let margin: CGFloat = 40.0
        let contentWidth = pageWidth - margin * 2

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let data = renderer.pdfData { context in
            let titleFont = UIFont.systemFont(ofSize: 20, weight: .bold)
            let subtitleFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
            let headerFont = UIFont.systemFont(ofSize: 9, weight: .bold)
            let bodyFont = UIFont.systemFont(ofSize: 9, weight: .regular)
            let bodyBoldFont = UIFont.systemFont(ofSize: 9, weight: .semibold)
            let captionFont = UIFont.systemFont(ofSize: 8, weight: .regular)
            let accentColor = VineyardTheme.uiOlive

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = dateFormat
            dateFormatter.timeZone = timeZone
            if let localeIdentifier {
                dateFormatter.locale = Locale(identifier: localeIdentifier)
            }

            var seasonCalendar = Calendar(identifier: .gregorian)
            seasonCalendar.timeZone = timeZone

            for block in blocks {
                drawTablePage(
                    context: context,
                    block: block,
                    vineyardName: vineyardName,
                    pageWidth: pageWidth,
                    pageHeight: pageHeight,
                    margin: margin,
                    contentWidth: contentWidth,
                    titleFont: titleFont,
                    subtitleFont: subtitleFont,
                    headerFont: headerFont,
                    bodyFont: bodyFont,
                    bodyBoldFont: bodyBoldFont,
                    captionFont: captionFont,
                    accentColor: accentColor,
                    dateFormatter: dateFormatter,
                    vintageColors: vintageColors,
                    logoData: logoData
                )

                drawGraphPage(
                    context: context,
                    block: block,
                    vineyardName: vineyardName,
                    pageWidth: pageWidth,
                    pageHeight: pageHeight,
                    margin: margin,
                    contentWidth: contentWidth,
                    titleFont: titleFont,
                    subtitleFont: subtitleFont,
                    headerFont: headerFont,
                    bodyFont: bodyFont,
                    captionFont: captionFont,
                    accentColor: accentColor,
                    dateFormatter: dateFormatter,
                    vintageColors: vintageColors,
                    seasonStartMonth: seasonStartMonth,
                    seasonStartDay: seasonStartDay,
                    logoData: logoData,
                    seasonCalendar: seasonCalendar
                )
            }
        }

        return data
    }

    private static func drawTablePage(
        context: UIGraphicsPDFRendererContext,
        block: BlockReport,
        vineyardName: String,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        margin: CGFloat,
        contentWidth: CGFloat,
        titleFont: UIFont,
        subtitleFont: UIFont,
        headerFont: UIFont,
        bodyFont: UIFont,
        bodyBoldFont: UIFont,
        captionFont: UIFont,
        accentColor: UIColor,
        dateFormatter: DateFormatter,
        vintageColors: [Int: UIColor],
        logoData: Data? = nil
    ) {
        context.beginPage()
        var y: CGFloat = margin

        PDFHeaderHelper.drawHeader(
            vineyardName: vineyardName,
            logoData: logoData,
            title: "Growth Stage Report",
            accentColor: accentColor,
            margin: margin,
            contentWidth: contentWidth,
            y: &y
        )

        let subAttrs: [NSAttributedString.Key: Any] = [.font: subtitleFont, .foregroundColor: UIColor.darkGray]
        (block.blockName as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: subAttrs)
        y += 22

        let sortedVintages = block.vintages.sorted(by: >)
        let stageColWidth: CGFloat = 160
        let vintageCount = sortedVintages.count
        let availableWidth = contentWidth - stageColWidth
        let vintageColWidth = vintageCount > 0 ? min(availableWidth / CGFloat(vintageCount), 130) : 100

        let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont, .foregroundColor: UIColor.white]
        let headerBgColor = accentColor

        let headerHeight: CGFloat = 22
        let headerRect = CGRect(x: margin, y: y, width: contentWidth, height: headerHeight)
        let headerPath = UIBezierPath(roundedRect: headerRect, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 4, height: 4))
        headerBgColor.setFill()
        headerPath.fill()

        ("GROWTH STAGE" as NSString).draw(
            in: CGRect(x: margin + 8, y: y + 5, width: stageColWidth - 16, height: headerHeight),
            withAttributes: headerAttrs
        )

        for (i, vintage) in sortedVintages.enumerated() {
            let x = margin + stageColWidth + CGFloat(i) * vintageColWidth
            ("VINTAGE \(vintage)" as NSString).draw(
                in: CGRect(x: x + 4, y: y + 5, width: vintageColWidth - 8, height: headerHeight),
                withAttributes: headerAttrs
            )
        }
        y += headerHeight

        let rowHeight: CGFloat = 20
        for (rowIndex, code) in block.stageCodes.enumerated() {
            if y + rowHeight > pageHeight - margin - 30 {
                context.beginPage()
                y = margin

                let contAttrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: UIColor.gray]
                ("\(block.blockName) — continued" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: contAttrs)
                y += 16

                let hRect = CGRect(x: margin, y: y, width: contentWidth, height: headerHeight)
                let hPath = UIBezierPath(roundedRect: hRect, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 4, height: 4))
                headerBgColor.setFill()
                hPath.fill()

                ("GROWTH STAGE" as NSString).draw(
                    in: CGRect(x: margin + 8, y: y + 5, width: stageColWidth - 16, height: headerHeight),
                    withAttributes: headerAttrs
                )
                for (i, vintage) in sortedVintages.enumerated() {
                    let x = margin + stageColWidth + CGFloat(i) * vintageColWidth
                    ("VINTAGE \(vintage)" as NSString).draw(
                        in: CGRect(x: x + 4, y: y + 5, width: vintageColWidth - 8, height: headerHeight),
                        withAttributes: headerAttrs
                    )
                }
                y += headerHeight
            }

            let bgColor = rowIndex % 2 == 0 ? UIColor(white: 0.96, alpha: 1) : UIColor.white
            let rowRect = CGRect(x: margin, y: y, width: contentWidth, height: rowHeight)
            bgColor.setFill()
            UIBezierPath(rect: rowRect).fill()

            let stageAttrs: [NSAttributedString.Key: Any] = [.font: bodyBoldFont, .foregroundColor: UIColor.black]
            let stage = GrowthStage.allStages.first { $0.code == code }
            let stageLabel = stage != nil ? "\(code) — \(stage!.description)" : code
            let truncatedLabel = truncateString(stageLabel, font: bodyBoldFont, maxWidth: stageColWidth - 16)
            (truncatedLabel as NSString).draw(
                in: CGRect(x: margin + 8, y: y + 4, width: stageColWidth - 16, height: rowHeight),
                withAttributes: stageAttrs
            )

            for (i, vintage) in sortedVintages.enumerated() {
                let x = margin + stageColWidth + CGFloat(i) * vintageColWidth
                let dateAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.black]
                let dashAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.lightGray]

                if let date = block.entries[vintage]?[code] {
                    let dateStr = dateFormatter.string(from: date)
                    (dateStr as NSString).draw(
                        in: CGRect(x: x + 4, y: y + 4, width: vintageColWidth - 8, height: rowHeight),
                        withAttributes: dateAttrs
                    )
                } else {
                    ("\u{2014}" as NSString).draw(
                        in: CGRect(x: x + 4, y: y + 4, width: vintageColWidth - 8, height: rowHeight),
                        withAttributes: dashAttrs
                    )
                }
            }

            y += rowHeight
        }

        let bottomLine = UIBezierPath()
        bottomLine.move(to: CGPoint(x: margin, y: y))
        bottomLine.addLine(to: CGPoint(x: pageWidth - margin, y: y))
        UIColor.lightGray.setStroke()
        bottomLine.lineWidth = 0.5
        bottomLine.stroke()

        y += 16
        let footerAttrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: UIColor.gray]
        let footerText = "Generated by VineTrack \u{2022} \(dateFormatter.string(from: Date()))"
        (footerText as NSString).draw(at: CGPoint(x: margin, y: min(y, pageHeight - margin - 12)), withAttributes: footerAttrs)
    }

    private static func drawGraphPage(
        context: UIGraphicsPDFRendererContext,
        block: BlockReport,
        vineyardName: String,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        margin: CGFloat,
        contentWidth: CGFloat,
        titleFont: UIFont,
        subtitleFont: UIFont,
        headerFont: UIFont,
        bodyFont: UIFont,
        captionFont: UIFont,
        accentColor: UIColor,
        dateFormatter: DateFormatter,
        vintageColors: [Int: UIColor],
        seasonStartMonth: Int,
        seasonStartDay: Int,
        logoData: Data? = nil,
        seasonCalendar: Calendar = Calendar.current
    ) {
        context.beginPage()
        var y: CGFloat = margin

        PDFHeaderHelper.drawHeader(
            vineyardName: vineyardName,
            logoData: logoData,
            title: "Growth Stage Timeline",
            accentColor: accentColor,
            margin: margin,
            contentWidth: contentWidth,
            y: &y
        )

        let subAttrs: [NSAttributedString.Key: Any] = [.font: subtitleFont, .foregroundColor: UIColor.darkGray]
        (block.blockName as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: subAttrs)
        y += 20

        let sortedVintages = block.vintages.sorted(by: >)

        let allStageCodesOrdered = GrowthStage.allStages.map { $0.code }
        let usedCodes = block.stageCodes.filter { code in
            sortedVintages.contains { block.entries[$0]?[code] != nil }
        }
        let orderedCodes = allStageCodesOrdered.filter { usedCodes.contains($0) }

        guard orderedCodes.count >= 2 else {
            let noDataAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.gray]
            ("Not enough data points to generate graph." as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: noDataAttrs)
            return
        }

        let graphLeft: CGFloat = margin + 50
        let graphRight: CGFloat = pageWidth - margin - 20
        let graphTop: CGFloat = y + 10
        let graphBottom: CGFloat = pageHeight - margin - 80
        let graphWidth = graphRight - graphLeft
        let graphHeight = graphBottom - graphTop

        let elIndices: [String: Int] = {
            var map: [String: Int] = [:]
            for (i, stage) in GrowthStage.allStages.enumerated() {
                map[stage.code] = i
            }
            return map
        }()

        let minIndex = orderedCodes.compactMap { elIndices[$0] }.min() ?? 0
        let maxIndex = orderedCodes.compactMap { elIndices[$0] }.max() ?? (GrowthStage.allStages.count - 1)
        let indexRange = max(maxIndex - minIndex, 1)

        UIColor(white: 0.95, alpha: 1).setFill()
        let graphBg = UIBezierPath(roundedRect: CGRect(x: graphLeft, y: graphTop, width: graphWidth, height: graphHeight), cornerRadius: 4)
        graphBg.fill()

        UIColor(white: 0.85, alpha: 1).setStroke()
        let axisBorder = UIBezierPath(rect: CGRect(x: graphLeft, y: graphTop, width: graphWidth, height: graphHeight))
        axisBorder.lineWidth = 0.5
        axisBorder.stroke()

        let yLabelFont = UIFont.systemFont(ofSize: 7, weight: .medium)
        let yLabelAttrs: [NSAttributedString.Key: Any] = [.font: yLabelFont, .foregroundColor: UIColor.darkGray]

        let stagesInRange = GrowthStage.allStages.filter { stage in
            guard let idx = elIndices[stage.code] else { return false }
            return idx >= minIndex && idx <= maxIndex
        }

        for stage in stagesInRange {
            guard let idx = elIndices[stage.code] else { continue }
            let yPos = graphBottom - (CGFloat(idx - minIndex) / CGFloat(indexRange)) * graphHeight

            let gridLine = UIBezierPath()
            gridLine.move(to: CGPoint(x: graphLeft, y: yPos))
            gridLine.addLine(to: CGPoint(x: graphRight, y: yPos))
            UIColor(white: 0.88, alpha: 1).setStroke()
            gridLine.lineWidth = 0.3
            gridLine.stroke()

            let labelSize = (stage.code as NSString).size(withAttributes: yLabelAttrs)
            (stage.code as NSString).draw(
                at: CGPoint(x: graphLeft - labelSize.width - 4, y: yPos - labelSize.height / 2),
                withAttributes: yLabelAttrs
            )
        }

        let cal = seasonCalendar
        let normalizedDates: [Int: [(String, Double)]] = {
            var result: [Int: [(String, Double)]] = [:]
            for vintage in sortedVintages {
                let startComps = DateComponents(year: vintage - 1, month: seasonStartMonth, day: seasonStartDay)
                guard let seasonStart = cal.date(from: startComps) else { continue }
                let endComps = DateComponents(year: vintage, month: seasonStartMonth, day: seasonStartDay)
                guard let seasonEnd = cal.date(from: endComps) else { continue }
                let totalDays = seasonEnd.timeIntervalSince(seasonStart)
                guard totalDays > 0 else { continue }

                var points: [(String, Double)] = []
                for code in orderedCodes {
                    if let date = block.entries[vintage]?[code] {
                        let dayOffset = date.timeIntervalSince(seasonStart)
                        let normalized = dayOffset / totalDays
                        points.append((code, normalized))
                    }
                }
                points.sort { $0.1 < $1.1 }
                result[vintage] = points
            }
            return result
        }()

        let monthLabels: [(String, Double)] = {
            var labels: [(String, Double)] = []
            let monthNames = ["Jul", "Aug", "Sep", "Oct", "Nov", "Dec", "Jan", "Feb", "Mar", "Apr", "May", "Jun"]
            for i in 0..<12 {
                let fraction = Double(i) / 12.0
                labels.append((monthNames[i], fraction))
            }
            return labels
        }()

        let xLabelFont = UIFont.systemFont(ofSize: 7, weight: .medium)
        let xLabelAttrs: [NSAttributedString.Key: Any] = [.font: xLabelFont, .foregroundColor: UIColor.darkGray]

        for (label, fraction) in monthLabels {
            let xPos = graphLeft + CGFloat(fraction) * graphWidth

            let tick = UIBezierPath()
            tick.move(to: CGPoint(x: xPos, y: graphBottom))
            tick.addLine(to: CGPoint(x: xPos, y: graphBottom + 4))
            UIColor.gray.setStroke()
            tick.lineWidth = 0.5
            tick.stroke()

            let gridLine = UIBezierPath()
            gridLine.move(to: CGPoint(x: xPos, y: graphTop))
            gridLine.addLine(to: CGPoint(x: xPos, y: graphBottom))
            UIColor(white: 0.90, alpha: 1).setStroke()
            gridLine.lineWidth = 0.2
            gridLine.stroke()

            let labelSize = (label as NSString).size(withAttributes: xLabelAttrs)
            (label as NSString).draw(
                at: CGPoint(x: xPos - labelSize.width / 2, y: graphBottom + 6),
                withAttributes: xLabelAttrs
            )
        }

        for vintage in sortedVintages {
            guard let points = normalizedDates[vintage], points.count >= 2 else { continue }
            let color = vintageColors[vintage] ?? UIColor.blue

            let linePath = UIBezierPath()
            var isFirst = true

            for (code, normalizedX) in points {
                guard let idx = elIndices[code] else { continue }
                let xPos = graphLeft + CGFloat(normalizedX) * graphWidth
                let yPos = graphBottom - (CGFloat(idx - minIndex) / CGFloat(indexRange)) * graphHeight

                if isFirst {
                    linePath.move(to: CGPoint(x: xPos, y: yPos))
                    isFirst = false
                } else {
                    linePath.addLine(to: CGPoint(x: xPos, y: yPos))
                }
            }

            color.setStroke()
            linePath.lineWidth = 2.0
            linePath.lineJoinStyle = .round
            linePath.lineCapStyle = .round
            linePath.stroke()

            for (code, normalizedX) in points {
                guard let idx = elIndices[code] else { continue }
                let xPos = graphLeft + CGFloat(normalizedX) * graphWidth
                let yPos = graphBottom - (CGFloat(idx - minIndex) / CGFloat(indexRange)) * graphHeight

                let dotRect = CGRect(x: xPos - 3, y: yPos - 3, width: 6, height: 6)
                color.setFill()
                UIBezierPath(ovalIn: dotRect).fill()
                UIColor.white.setFill()
                UIBezierPath(ovalIn: dotRect.insetBy(dx: 1.5, dy: 1.5)).fill()
                color.setFill()
                UIBezierPath(ovalIn: dotRect.insetBy(dx: 2, dy: 2)).fill()
            }
        }

        let legendY = pageHeight - margin - 40
        let legendFont = UIFont.systemFont(ofSize: 9, weight: .semibold)
        var legendX: CGFloat = margin

        for vintage in sortedVintages {
            let color = vintageColors[vintage] ?? UIColor.blue
            let dotRect = CGRect(x: legendX, y: legendY + 4, width: 10, height: 10)
            color.setFill()
            UIBezierPath(ovalIn: dotRect).fill()
            legendX += 14

            let label = "Vintage \(vintage)"
            let labelAttrs: [NSAttributedString.Key: Any] = [.font: legendFont, .foregroundColor: UIColor.darkGray]
            let labelSize = (label as NSString).size(withAttributes: labelAttrs)
            (label as NSString).draw(at: CGPoint(x: legendX, y: legendY + 3), withAttributes: labelAttrs)
            legendX += labelSize.width + 20
        }

        let footerAttrs: [NSAttributedString.Key: Any] = [.font: captionFont, .foregroundColor: UIColor.gray]
        let footerText = "Generated by VineTrack \u{2022} \(dateFormatter.string(from: Date()))"
        (footerText as NSString).draw(at: CGPoint(x: margin, y: pageHeight - margin - 12), withAttributes: footerAttrs)
    }

    private static func truncateString(_ string: String, font: UIFont, maxWidth: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (string as NSString).size(withAttributes: attrs)
        if size.width <= maxWidth { return string }
        var truncated = string
        while truncated.count > 3 {
            truncated = String(truncated.dropLast())
            let tSize = ((truncated + "...") as NSString).size(withAttributes: attrs)
            if tSize.width <= maxWidth {
                return truncated + "..."
            }
        }
        return truncated + "..."
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
