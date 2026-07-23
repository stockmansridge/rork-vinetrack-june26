import UIKit
import PDFKit
import MapKit
import CoreLocation
import UniformTypeIdentifiers

struct PinsPDFService {
    struct PinReport {
        let pin: VinePin
        let paddockName: String
    }

    static func generatePDF(pins: [PinReport], vineyardName: String, mapSnapshot: UIImage?, logoData: Data? = nil, timeZone: TimeZone = .current, formatter: RegionFormatter = .australian) -> Data {
        let pageWidth: CGFloat = 595.0
        let pageHeight: CGFloat = 842.0
        let margin: CGFloat = 40.0
        let contentWidth = pageWidth - margin * 2

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let data = renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = margin

            let titleFont = UIFont.systemFont(ofSize: 22, weight: .bold)
            let headerFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
            let bodyFont = UIFont.systemFont(ofSize: 11, weight: .regular)
            let bodyBoldFont = UIFont.systemFont(ofSize: 11, weight: .semibold)
            let captionFont = UIFont.systemFont(ofSize: 9, weight: .regular)
            let smallFont = UIFont.systemFont(ofSize: 9, weight: .regular)
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

            func drawDivider() {
                checkPageBreak(needed: 8)
                UIColor(white: 0.82, alpha: 1.0).setStroke()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: margin, y: y))
                path.addLine(to: CGPoint(x: margin + contentWidth, y: y))
                path.lineWidth = 0.5
                path.stroke()
                y += 8
            }

            func headingText(for heading: Double?) -> String {
                guard let heading else { return "\u{2014}" }
                return PinAttachmentFormatter.fullCompassName(degrees: heading)
            }

            PDFHeaderHelper.drawHeader(
                vineyardName: vineyardName,
                logoData: logoData,
                title: "Pins Report",
                accentColor: accentColor,
                margin: margin,
                contentWidth: contentWidth,
                y: &y
            )

            let dateStr = formatter.formatDateTime(Date())
            drawText(dateStr, font: captionFont, color: .darkGray)
            y += 4

            drawSectionHeader("Summary")
            drawRow(label: "Vineyard", value: vineyardName)
            drawRow(label: "Total Pins", value: "\(pins.count)")

            let repairCount = pins.filter { $0.pin.mode == .repairs }.count
            let growthCount = pins.filter { $0.pin.mode == .growth }.count
            let completedCount = pins.filter { $0.pin.isCompleted }.count
            let activeCount = pins.count - completedCount

            drawRow(label: "Repair Pins", value: "\(repairCount)")
            drawRow(label: "Growth Pins", value: "\(growthCount)")
            drawRow(label: "Active", value: "\(activeCount)")
            drawRow(label: "Completed", value: "\(completedCount)")

            if let snapshot = mapSnapshot {
                drawSectionHeader("Pin Map")

                let maxMapHeight: CGFloat = 280
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

            drawSectionHeader("Pin Details")

            let colType: CGFloat = margin
            let colName: CGFloat = margin + 50
            let colBlock: CGFloat = margin + 180
            let colRow: CGFloat = margin + 280
            let colSide: CGFloat = margin + 320
            let colStatus: CGFloat = margin + 380
            let colDate: CGFloat = margin + 440

            let tableHeaderHeight: CGFloat = 18
            checkPageBreak(needed: tableHeaderHeight + 4)
            let headerAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: UIColor.darkGray]
            ("Type" as NSString).draw(at: CGPoint(x: colType, y: y), withAttributes: headerAttrs)
            ("Name" as NSString).draw(at: CGPoint(x: colName, y: y), withAttributes: headerAttrs)
            (formatter.blockTermCapitalised as NSString).draw(at: CGPoint(x: colBlock, y: y), withAttributes: headerAttrs)
            ("Row" as NSString).draw(at: CGPoint(x: colRow, y: y), withAttributes: headerAttrs)
            ("Side" as NSString).draw(at: CGPoint(x: colSide, y: y), withAttributes: headerAttrs)
            ("Status" as NSString).draw(at: CGPoint(x: colStatus, y: y), withAttributes: headerAttrs)
            ("Date" as NSString).draw(at: CGPoint(x: colDate, y: y), withAttributes: headerAttrs)
            y += tableHeaderHeight

            UIColor(white: 0.82, alpha: 1.0).setStroke()
            let headerLine = UIBezierPath()
            headerLine.move(to: CGPoint(x: margin, y: y))
            headerLine.addLine(to: CGPoint(x: margin + contentWidth, y: y))
            headerLine.lineWidth = 0.5
            headerLine.stroke()
            y += 4

            let cellAttrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: UIColor.black]
            let cellSecAttrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: UIColor.darkGray]

            for report in pins {
                let pin = report.pin
                let rowHeight: CGFloat = 32
                checkPageBreak(needed: rowHeight)

                let typeStr = pin.mode == .repairs ? "R" : "G"
                let typeColor = pin.mode == .repairs ? UIColor.systemRed : UIColor.systemGreen
                let typeAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: typeColor]
                (typeStr as NSString).draw(at: CGPoint(x: colType, y: y), withAttributes: typeAttrs)

                (pin.buttonName as NSString).draw(in: CGRect(x: colName, y: y, width: 125, height: 12), withAttributes: cellAttrs)

                (report.paddockName as NSString).draw(in: CGRect(x: colBlock, y: y, width: 95, height: 12), withAttributes: cellAttrs)

                let rowStr = pin.rowNumber != nil ? "\(pin.rowNumber!).5" : "—"
                (rowStr as NSString).draw(at: CGPoint(x: colRow, y: y), withAttributes: cellAttrs)

                let sideStr = "\(pin.side.rawValue) hand side"
                (sideStr as NSString).draw(in: CGRect(x: colSide, y: y, width: 60, height: 12), withAttributes: cellAttrs)

                let statusStr = pin.isCompleted ? "Done" : "Active"
                let statusColor = pin.isCompleted ? UIColor.systemGreen : UIColor.systemOrange
                let statusAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: statusColor]
                (statusStr as NSString).draw(at: CGPoint(x: colStatus, y: y), withAttributes: statusAttrs)

                let dateString = formatter.formatDateTime(pin.timestamp)
                (dateString as NSString).draw(at: CGPoint(x: colDate, y: y), withAttributes: cellSecAttrs)

                let detailY = y + 13
                let heading = headingText(for: pin.heading)
                var detail = "\(pin.side.rawValue) hand side facing \(heading)"
                if let createdBy = pin.createdBy, !createdBy.isEmpty {
                    detail += " • by \(createdBy)"
                }
                if pin.isCompleted, let completedBy = pin.completedBy {
                    detail += " • completed by \(completedBy)"
                }
                let detailAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8, weight: .regular), .foregroundColor: UIColor.gray]
                (detail as NSString).draw(in: CGRect(x: colName, y: detailY, width: contentWidth - 50, height: 11), withAttributes: detailAttrs)

                y += rowHeight

                UIColor(white: 0.90, alpha: 1.0).setStroke()
                let rowLine = UIBezierPath()
                rowLine.move(to: CGPoint(x: margin, y: y - 4))
                rowLine.addLine(to: CGPoint(x: margin + contentWidth, y: y - 4))
                rowLine.lineWidth = 0.25
                rowLine.stroke()
            }

            y += 16
            checkPageBreak(needed: 30)
            let footerDate = Date().formattedTZ(date: .abbreviated, time: .shortened, in: timeZone)
            let tzAbbrev = timeZone.abbreviation() ?? timeZone.identifier
            drawText("Generated \(footerDate) (\(tzAbbrev)) • VineTrack", font: captionFont, color: .gray)
        }

        return data
    }

    static func captureMapSnapshot(pins: [VinePin]) async -> UIImage? {
        let coords = pins.map { $0.coordinate }
        guard !coords.isEmpty else { return nil }

        var minLat = coords.map(\.latitude).min() ?? 0
        var maxLat = coords.map(\.latitude).max() ?? 0
        var minLon = coords.map(\.longitude).min() ?? 0
        var maxLon = coords.map(\.longitude).max() ?? 0

        let latPadding = max((maxLat - minLat) * 0.15, 0.001)
        let lonPadding = max((maxLon - minLon) * 0.15, 0.001)
        minLat -= latPadding
        maxLat += latPadding
        minLon -= lonPadding
        maxLon += lonPadding

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(maxLat - minLat, 0.002),
            longitudeDelta: max(maxLon - minLon, 0.002)
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
                for pin in pins {
                    let point = snapshot.point(for: pin.coordinate)
                    let dotSize: CGFloat = 16
                    let color: UIColor = pin.mode == .repairs ? .systemRed : .systemGreen

                    ctx.setFillColor(color.cgColor)
                    ctx.fillEllipse(in: CGRect(x: point.x - dotSize / 2, y: point.y - dotSize / 2, width: dotSize, height: dotSize))

                    ctx.setFillColor(UIColor.white.cgColor)
                    ctx.fillEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))

                    if pin.isCompleted {
                        ctx.setStrokeColor(UIColor.white.cgColor)
                        ctx.setLineWidth(2)
                        ctx.move(to: CGPoint(x: point.x - 3, y: point.y))
                        ctx.addLine(to: CGPoint(x: point.x - 1, y: point.y + 3))
                        ctx.addLine(to: CGPoint(x: point.x + 4, y: point.y - 3))
                        ctx.strokePath()
                    }
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

    static func generateCSV(pins: [PinReport], vineyardName: String, timeZone: TimeZone = .current) -> Data {
        var csv = "Type,Name,Block,Row,Side,Heading,Status,Created By,Completed By,Completed At,Latitude,Longitude,Date\n"

        for report in pins {
            let pin = report.pin
            let typeStr = pin.mode == .repairs ? "Repair" : "Growth"
            let rowStr = pin.rowNumber != nil ? "\(pin.rowNumber!).5" : ""
            let heading = headingText(for: pin.heading)
            let statusStr = pin.isCompleted ? "Completed" : "Active"
            let createdBy = pin.createdBy ?? ""
            let completedBy = pin.completedBy ?? ""
            let completedAt = pin.completedAt?.formattedTZ(date: .numeric, time: .shortened, in: timeZone) ?? ""
            let dateStr = pin.timestamp.formattedTZ(date: .numeric, time: .shortened, in: timeZone)

            let row = [
                escapeCSV(typeStr),
                escapeCSV(pin.buttonName),
                escapeCSV(report.paddockName),
                escapeCSV(rowStr),
                escapeCSV("\(pin.side.rawValue) hand side"),
                escapeCSV(pin.heading.map { "\(heading) (\(Int($0))°)" } ?? "\u{2014}"),
                escapeCSV(statusStr),
                escapeCSV(createdBy),
                escapeCSV(completedBy),
                escapeCSV(completedAt),
                String(format: "%.6f", pin.latitude),
                String(format: "%.6f", pin.longitude),
                escapeCSV(dateStr)
            ].joined(separator: ",")
            csv += row + "\n"
        }

        return csv.data(using: .utf8) ?? Data()
    }

    static func saveCSVToTemp(data: Data, fileName: String) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let sanitized = fileName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = tempDir.appendingPathComponent("\(sanitized).csv")
        try? data.write(to: url)
        return url
    }

    private static func headingText(for heading: Double?) -> String {
        guard let heading else { return "\u{2014}" }
        return PinAttachmentFormatter.fullCompassName(degrees: heading)
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
