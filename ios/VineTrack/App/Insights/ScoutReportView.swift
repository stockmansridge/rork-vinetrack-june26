import MapKit
import SwiftUI
import UIKit

struct ScoutReportView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(VineyardInsightsService.self) private var insights
    @Environment(GrowthStageRecordSyncService.self) private var growthSync
    @Environment(\.dismiss) private var dismiss
    let visit: ScoutVisit
    @State private var shareItem: ScoutReportShareItem?
    @State private var selectedMarker: ScoutReportMarker?
    @State private var exportError: String?

    private var fmt: RegionFormatter {
        var settings = store.settings.regionSettings
        settings.timezone = insights.calendar(vineyardID: visit.vineyardID).timeZone.identifier
        return RegionFormatter(settings: settings)
    }
    private var vineyard: Vineyard? { store.vineyards.first { $0.id == visit.vineyardID } }
    private var blocks: [Paddock] { store.paddocks.filter { block in visit.assessments.contains { $0.paddockID == block.id } } }
    private var locations: ScoutReportPresentation.Locations {
        ScoutReportPresentation.locations(visit: visit, blocks: store.paddocks, records: growthSync.records, pins: store.pins)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    weather
                    ScoutReportMap(blocks: blocks, markers: locations.markers, selectedMarker: $selectedMarker)
                        .frame(height: 280).clipShape(.rect(cornerRadius: 16))
                    ScoutLocationReferences(locations: locations, selectedMarker: $selectedMarker)
                    ForEach(visit.orderedStops) { assessment in assessmentSection(assessment) }
                    reportText("Visit summary", visit.visitSummary)
                }.padding(16)
            }
            .navigationTitle("Scout report").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { exportPDF() } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                }
            }
            .sheet(item: $shareItem) { item in ScoutReportShareSheet(items: [item.url]) }
            .sheet(item: $selectedMarker) { marker in ScoutMarkerDetail(marker: marker) }
            .alert("Could not create report", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK") { exportError = nil }
            } message: { Text(exportError ?? "Please try again.") }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            if let data = vineyard?.logoData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(vineyard?.name ?? "Vineyard").font(.title2.bold())
                Text(visit.status == .draft ? "DRAFT SCOUT REPORT" : "SCOUT REPORT")
                    .font(.caption.bold()).foregroundStyle(visit.status == .draft ? .orange : VineyardTheme.leafGreen)
                Text(fmt.formatDate(insights.scoutDay(visit)))
                Text("Vintage \(VintageYearText.format(visit.vintageYear)) • \(visit.scoutNameSnapshot ?? "Observer unavailable")").foregroundStyle(.secondary)
                Text(insights.syncStatus(for: visit)).font(.caption).foregroundStyle(.secondary)
                if insights.deletionPending(visitID: visit.id) {
                    Text(insights.syncStatus(for: visit)).font(.caption.bold()).foregroundStyle(.orange)
                    if let error = insights.lastSyncError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }

    private var weather: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Weather").font(.headline)
            let value = visit.weather
            LabeledContent("Temp", value: value?.temperatureCelsius.map { fmt.formatTemperature(celsius: $0) } ?? "Unavailable")
            LabeledContent("Humidity", value: value?.humidityPercent.map { "\(Int($0.rounded()))%" } ?? "Unavailable")
            LabeledContent("Wind", value: value?.windSpeedKph.map { fmt.formatSpeed(kmh: $0) } ?? "Unavailable")
            LabeledContent("Source", value: value?.source ?? "Unavailable")
            Text(value?.observedAt.map { "Observed " + fmt.formatDateTime($0) } ?? "Observation time unavailable").font(.caption).foregroundStyle(.secondary)
            if value?.isUnavailable == true { Text("Unavailable at observation time").font(.caption).foregroundStyle(.orange) }
            if value?.isStale == true { Text("Stale reading").font(.caption.bold()).foregroundStyle(.orange) }
        }
    }

    private func assessmentSection(_ assessment: ScoutBlockAssessment) -> some View {
        let block = store.paddocks.first { $0.id == assessment.paddockID }
        return VStack(alignment: .leading, spacing: 10) {
            Text(block?.name ?? "Block \(assessment.paddockID.uuidString)").font(.title3.bold())
            Text(assessment.stopReference + " • " + (assessment.stopContext?.capturedAt.map { fmt.formatDateTime($0) } ?? "Legacy capture time unavailable")).font(.subheadline.bold())
            Text(assessment.stopContext?.observer_name ?? "Legacy stop observer unavailable").font(.caption)
            Text(ScoutReportPDFService.weatherText(assessment.stopContext?.weatherSnapshot, formatter: fmt)).font(.caption)
            if assessment.stopContext?.is_draft == true { Text("UNFINISHED OBSERVATION DRAFT").font(.caption.bold()).foregroundStyle(.orange) }
            let varieties = block?.varietyAllocations.compactMap(\.name).filter { !$0.isEmpty } ?? []
            Text(varieties.isEmpty ? "Variety details unavailable" : varieties.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            ForEach(ScoutItem.allCases) { item in
                let observation = assessment.observation(item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label).font(.subheadline.bold())
                    Text(observationValue(observation))
                    if !item.isFreeText, let notes = observation?.notes, !notes.isEmpty { Text(notes).font(.callout) }
                    if let photos = observation?.photos, !photos.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(photos) { photo in
                                    VStack(alignment: .leading) {
                                        Color(.secondarySystemBackground).frame(width: 110, height: 82).overlay {
                                            if let image = insights.localImage(photo) { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                                            else { VStack { Image(systemName: "photo"); Text("Not downloaded").font(.caption2) } }
                                        }.clipShape(.rect(cornerRadius: 8))
                                        Text(locations.photoReferences[photo.id] ?? "Photograph").font(.caption2)
                                    }
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                }
            }
        }.padding(14).background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
    }

    private func observationValue(_ observation: ScoutObservation?) -> String {
        guard let observation else { return "Not assessed" }
        if observation.item == .growthStage { return ScoutReportPresentation.growthValue(observation, vineyardID: visit.vineyardID, records: growthSync.records) }
        if observation.item.isFreeText { return observation.notes?.isEmpty == false ? observation.notes! : "Not assessed" }
        return observation.valueLabel ?? "Not assessed"
    }
    private func reportText(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(value?.isEmpty == false ? value! : "Not assessed") }
    }
    private func exportPDF() {
        let images = Dictionary(uniqueKeysWithValues: visit.assessments.flatMap(\.observations).flatMap(\.photos).compactMap { photo in insights.localImage(photo).map { (photo.id, $0) } })
        guard let url = ScoutReportPDFService.export(visit: visit, vineyard: vineyard, blocks: blocks, images: images,
            growthRecords: growthSync.records, locations: locations, scoutDay: insights.scoutDay(visit),
            formatter: fmt, deletionStatus: insights.deletionPending(visitID: visit.id) ? insights.syncStatus(for: visit) : nil) else {
            exportError = "The PDF could not be written to this device. Check available storage and try again."
            return
        }
        shareItem = ScoutReportShareItem(url: url)
    }
}

struct ScoutReportMarker: Identifiable {
    let id: String
    let reference: String
    let observationID: UUID
    let title: String
    let subtitle: String
    let source: String
    let coordinate: CLLocationCoordinate2D
    let photo: ScoutPhoto?
    var label: String { reference + " • " + subtitle + " • " + source }
    var color: Color { photo != nil ? .orange : (reference.hasPrefix("E") ? .green : .blue) }
}

struct ScoutWorkspaceMap: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(GrowthStageRecordSyncService.self) private var growthSync
    let visit: ScoutVisit
    @Binding var selectedBlockID: UUID?
    @State private var selectedMarker: ScoutReportMarker?
    init(visit: ScoutVisit, selectedBlockID: Binding<UUID?> = .constant(nil)) {
        self.visit = visit
        self._selectedBlockID = selectedBlockID
    }
    var body: some View {
        let blocks = store.paddocks
        let locations = ScoutReportPresentation.locations(visit: visit, blocks: store.paddocks, records: growthSync.records, pins: store.pins)
        VStack(alignment: .leading, spacing: 6) {
            ScoutReportMap(blocks: blocks, markers: locations.markers, selectedMarker: $selectedMarker,
                onSelectBlock: { selectedBlockID = $0 }, showsUserLocation: true)
                .frame(height: 380).clipShape(.rect(cornerRadius: 14))
            if let block = blocks.first(where: { $0.id == selectedBlockID }) {
                Text(block.name + " • " + block.varietyAllocations.compactMap(\.name).joined(separator: ", ")).font(.subheadline.bold())
            }
            Text("Tap a block label to select it. Boundaries remain usable without imagery; GPS permission is optional.").font(.caption).foregroundStyle(.secondary)
            ScoutLocationReferences(locations: locations, selectedMarker: $selectedMarker)
        }.sheet(item: $selectedMarker) { marker in ScoutMarkerDetail(marker: marker) }
    }
}

private struct ScoutLocationReferences: View {
    let locations: ScoutReportPresentation.Locations
    @Binding var selectedMarker: ScoutReportMarker?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ScoutReportPresentation.legend).font(.caption2).foregroundStyle(.secondary)
            ForEach(locations.boundaryUnavailable, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            ForEach(locations.markers) { marker in
                Button(marker.label) { selectedMarker = marker }.font(.caption).frame(minHeight: 44, alignment: .leading)
            }
            if !locations.unavailable.isEmpty {
                Text("Location unavailable").font(.headline)
                ForEach(locations.unavailable, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct ScoutMarkerDetail: View {
    @Environment(VineyardInsightsService.self) private var insights
    let marker: ScoutReportMarker
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(marker.reference + " • " + marker.title).font(.headline)
            Text(marker.subtitle).foregroundStyle(.secondary)
            Text(marker.source).font(.subheadline)
            if let photo = marker.photo {
                if let image = insights.localImage(photo) { Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 12)) }
                else { ContentUnavailableView("Photograph unavailable", systemImage: "photo", description: Text("The saved photograph is not available on this device.")) }
            }
            Text(marker.coordinate.latitude.formatted() + ", " + marker.coordinate.longitude.formatted()).font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
}

private struct ScoutReportMap: View {
    let blocks: [Paddock]
    let markers: [ScoutReportMarker]
    @Binding var selectedMarker: ScoutReportMarker?
    var onSelectBlock: ((UUID) -> Void)? = nil
    var showsUserLocation: Bool = false
    @State private var position: MapCameraPosition = .automatic
    private var points: [CLLocationCoordinate2D] {
        blocks.flatMap(\.polygonPoints).compactMap { ScoutReportPresentation.coordinate($0.latitude, $0.longitude) } + markers.map(\.coordinate)
    }
    private var boundsKey: String { points.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";") }
    var body: some View {
        Map(position: $position) {
            ForEach(blocks) { block in
                let polygon = block.polygonPoints.compactMap { ScoutReportPresentation.coordinate($0.latitude, $0.longitude) }
                if polygon.count >= 3 && polygon.count == block.polygonPoints.count {
                    MapPolygon(coordinates: polygon).foregroundStyle(VineyardTheme.leafGreen.opacity(0.18)).stroke(VineyardTheme.leafGreen, lineWidth: 2)
                    Annotation(block.name, coordinate: CLLocationCoordinate2D(
                        latitude: polygon.map(\.latitude).reduce(0, +) / Double(polygon.count),
                        longitude: polygon.map(\.longitude).reduce(0, +) / Double(polygon.count))) {
                        Button { onSelectBlock?(block.id) } label: {
                            VStack(spacing: 2) {
                                Text(block.name).font(.caption.bold())
                                Text(block.varietyAllocations.compactMap(\.name).joined(separator: ", ")).font(.caption2)
                            }.padding(6).foregroundStyle(.primary).background(.regularMaterial, in: .rect(cornerRadius: 8))
                        }.frame(minHeight: 44)
                    }
                }
            }
            if showsUserLocation { UserAnnotation() }
            ForEach(markers) { marker in
                Annotation(marker.reference + " • " + marker.title, coordinate: marker.coordinate) {
                    Button { selectedMarker = marker } label: {
                        Image(systemName: marker.photo != nil ? "camera.fill" : (marker.reference.hasPrefix("E") ? "leaf.fill" : "mappin"))
                            .foregroundStyle(.white).frame(width: 44, height: 44).background(marker.color, in: .circle)
                    }.accessibilityLabel(marker.label)
                }
            }
        }.mapStyle(.hybrid)
            .overlay(alignment: .topTrailing) {
                VStack {
                    Button("Recenter") { fitAllLocations() }.buttonStyle(.borderedProminent)
                    if showsUserLocation { Button("My location") { position = .userLocation(fallback: .automatic) }.buttonStyle(.bordered) }
                }.padding(10)
            }
            .onAppear { fitAllLocations() }.onChange(of: boundsKey) { _, _ in fitAllLocations() }
    }
    private func fitAllLocations() {
        var rect = MKMapRect.null
        for coordinate in points {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        guard !rect.isNull else { return }
        position = .rect(rect.insetBy(dx: -max(rect.width * 0.15, 100), dy: -max(rect.height * 0.15, 100)))
    }
}

private struct ScoutReportShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
private struct ScoutReportShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum ScoutReportPDFService {
    static func export(visit: ScoutVisit, vineyard: Vineyard?, blocks: [Paddock], images: [UUID: UIImage],
                       growthRecords: [GrowthStageRecord] = [], locations: ScoutReportPresentation.Locations? = nil,
                       scoutDay: String? = nil, formatter fmt: RegionFormatter = .australian, deletionStatus: String? = nil) -> URL? {
        let locations = locations ?? ScoutReportPresentation.locations(visit: visit, blocks: blocks, records: growthRecords, pins: [])
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            var y: CGFloat = 42
            func page(_ needed: CGFloat) { if y + needed > 800 { context.beginPage(); y = 42 } }
            func wrappedLines(_ value: String, font: UIFont) -> [String] {
                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                var lines: [String] = []
                var line = ""
                for paragraph in value.components(separatedBy: .newlines) {
                    for word in paragraph.split(separator: " ").map(String.init) {
                        let candidate = line.isEmpty ? word : line + " " + word
                        if (candidate as NSString).size(withAttributes: attrs).width > 511, !line.isEmpty { lines.append(line); line = "" }
                        if !line.isEmpty { line += " " }
                        for character in word {
                            let candidate = line + String(character)
                            if (candidate as NSString).size(withAttributes: attrs).width > 511, !line.isEmpty { lines.append(line); line = "" }
                            line += String(character)
                        }
                    }
                    lines.append(line); line = ""
                }
                return lines
            }
            func text(_ value: String, font: UIFont = .systemFont(ofSize: 10), color: UIColor = .black, gap: CGFloat = 6) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let lineHeight = font.lineHeight + 2
                for line in wrappedLines(value, font: font) {
                    page(lineHeight); (line as NSString).draw(at: CGPoint(x: 42, y: y), withAttributes: attrs); y += lineHeight
                }
                y += gap
            }
            context.beginPage()
            if let logo = vineyard?.logoData.flatMap(UIImage.init(data:)) {
                let scale = min(64 / logo.size.width, 64 / logo.size.height)
                let size = CGSize(width: logo.size.width * scale, height: logo.size.height * scale)
                logo.draw(in: CGRect(x: 553 - size.width, y: 38, width: size.width, height: size.height))
            }
            text(vineyard?.name ?? "Vineyard", font: .boldSystemFont(ofSize: 22)); y = max(y, 108)
            text(visit.status == .draft ? "DRAFT SCOUT REPORT" : "SCOUT REPORT", font: .boldSystemFont(ofSize: 12), color: visit.status == .draft ? .systemOrange : .systemGreen)
            if let deletionStatus { text(deletionStatus, color: .systemOrange) }
            text("Visit: \(fmt.formatDate(scoutDay ?? visit.scoutDateOnly ?? VineyardInsightsSyncRepository.day(visit.scoutDate)))   Vintage: \(VintageYearText.format(visit.vintageYear))   Observer: \(visit.scoutNameSnapshot ?? "Unavailable")")
            text(weatherText(visit.weather, formatter: fmt)); text("Visit summary", font: .boldSystemFont(ofSize: 14)); text(visit.visitSummary ?? "Not assessed")
            page(192); drawDiagram(blocks: blocks, markers: locations.markers, context: context.cgContext, rect: CGRect(x: 42, y: y, width: 511, height: 180)); y += 192
            text("Offline location diagram — not aerial imagery", color: .darkGray)
            text(ScoutReportPresentation.legend, color: .darkGray)
            for row in locations.boundaryUnavailable { text(row, color: .darkGray) }
            for marker in locations.markers { text(marker.label + String(format: " • %.6f, %.6f", marker.coordinate.latitude, marker.coordinate.longitude)) }
            if !locations.unavailable.isEmpty {
                text("Location unavailable", font: .boldSystemFont(ofSize: 12))
                for row in locations.unavailable { text(row, color: .darkGray) }
            }
            for assessment in visit.orderedStops {
                let block = blocks.first { $0.id == assessment.paddockID }
                let blockName = block?.name ?? "Block \(assessment.paddockID.uuidString)"
                text(blockName, font: .boldSystemFont(ofSize: 16))
                text(assessment.stopReference + " • " + (assessment.stopContext?.capturedAt.map { fmt.formatDateTime($0) } ?? "Legacy capture time unavailable"), font: .boldSystemFont(ofSize: 12))
                text("Observer: " + (assessment.stopContext?.observer_name ?? "Legacy stop observer unavailable"))
                text(weatherText(assessment.stopContext?.weatherSnapshot, formatter: fmt))
                if assessment.stopContext?.is_draft == true { text("UNFINISHED OBSERVATION DRAFT", color: .systemOrange) }
                let varieties = block?.varietyAllocations.compactMap(\.name).filter { !$0.isEmpty } ?? []
                text(varieties.isEmpty ? "Variety details unavailable" : varieties.joined(separator: ", "), color: .darkGray)
                for item in ScoutItem.allCases {
                    let observation = assessment.observation(item)
                    text(item.label, font: .boldSystemFont(ofSize: 11))
                    let value = item == .growthStage ? ScoutReportPresentation.growthValue(observation, vineyardID: visit.vineyardID, records: growthRecords) : (item.isFreeText ? observation?.notes : observation?.valueLabel)
                    text(value?.isEmpty == false ? value! : "Not assessed")
                    for marker in locations.markers where marker.observationID == observation?.id && marker.photo == nil { text("Location: " + marker.reference, color: .darkGray) }
                    if !item.isFreeText, let notes = observation?.notes, !notes.isEmpty { text(notes) }
                    for photo in observation?.photos ?? [] {
                        let caption = "\(locations.photoReferences[photo.id] ?? "Photograph") • \(blockName) • \(item.label)"
                        let captionFont = UIFont.systemFont(ofSize: 10)
                        page(CGFloat(wrappedLines(caption, font: captionFont).count) * (captionFont.lineHeight + 2) + 6 + 126)
                        text(caption, color: .darkGray)
                        page(126)
                        if let image = images[photo.id] {
                            let scale = min(160 / image.size.width, 110 / image.size.height)
                            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                            image.draw(in: CGRect(x: 42, y: y, width: size.width, height: size.height)); y += 118
                        } else { text("Photograph not downloaded to this device", color: .darkGray) }
                    }
                }
            }
        }
        let name = "Scout-\(scoutDay ?? visit.scoutDateOnly ?? VineyardInsightsSyncRepository.day(visit.scoutDate))-\(visit.id.uuidString.prefix(8)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
    static func weatherText(_ weather: ScoutWeatherSnapshot?, formatter fmt: RegionFormatter = .australian) -> String {
        guard let weather else { return "Weather: Not captured" }
        if weather.isUnavailable { return "Weather: Unavailable at observation time (\(weather.source ?? "source unavailable"))" }
        var values = [String]()
        values.append("Temp: " + (weather.temperatureCelsius.map { fmt.formatTemperature(celsius: $0) } ?? "Unavailable"))
        values.append("Humidity: " + (weather.humidityPercent.map { "\(Int($0.rounded()))%" } ?? "Unavailable"))
        values.append("Wind: " + (weather.windSpeedKph.map { fmt.formatSpeed(kmh: $0) } ?? "Unavailable"))
        values.append("Source: \(weather.source ?? "Unavailable")")
        values.append(weather.observedAt.map { "observed " + fmt.formatDateTime($0) } ?? "observation time unavailable")
        if weather.isStale { values.append("STALE") }
        return "Weather: " + values.joined(separator: " • ")
    }
    private static func drawDiagram(blocks: [Paddock], markers: [ScoutReportMarker], context: CGContext, rect: CGRect) {
        context.saveGState(); defer { context.restoreGState() }
        context.setFillColor(UIColor(white: 0.95, alpha: 1).cgColor); context.fill(rect)
        let points = blocks.flatMap(\.polygonPoints).filter { ScoutReportPresentation.coordinate($0.latitude, $0.longitude) != nil }
            + markers.map { CoordinatePoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
        guard let minLat = points.map(\.latitude).min(), let maxLat = points.map(\.latitude).max(),
              let minLon = points.map(\.longitude).min(), let maxLon = points.map(\.longitude).max() else {
            ("No valid boundaries or recorded locations available" as NSString).draw(at: CGPoint(x: rect.minX + 12, y: rect.midY), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray]); return
        }
        let latitudeSpan = max(maxLat - minLat, 0.0002) * 1.3
        let longitudeSpan = max(maxLon - minLon, 0.0002) * 1.3
        let bottom = (minLat + maxLat - latitudeSpan) / 2
        let left = (minLon + maxLon - longitudeSpan) / 2
        func point(_ coordinate: CoordinatePoint) -> CGPoint { CGPoint(x: rect.minX + CGFloat((coordinate.longitude - left) / longitudeSpan) * rect.width, y: rect.maxY - CGFloat((coordinate.latitude - bottom) / latitudeSpan) * rect.height) }
        context.setStrokeColor(UIColor.systemGreen.cgColor); context.setFillColor(UIColor.systemGreen.withAlphaComponent(0.15).cgColor); context.setLineWidth(1.5)
        for block in blocks {
            let polygon = block.polygonPoints.filter { ScoutReportPresentation.coordinate($0.latitude, $0.longitude) != nil }
            guard polygon.count >= 3, polygon.count == block.polygonPoints.count else { continue }
            let path = CGMutablePath(); path.move(to: point(polygon[0])); polygon.dropFirst().forEach { path.addLine(to: point($0)) }; path.closeSubpath(); context.addPath(path); context.drawPath(using: .fillStroke)
        }
        for marker in markers {
            let p = point(CoordinatePoint(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude))
            let color: UIColor = marker.photo != nil ? .systemOrange : (marker.reference.hasPrefix("E") ? .systemGreen : .systemBlue)
            context.setFillColor(color.cgColor); context.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 8), .foregroundColor: UIColor.black]
            let width = (marker.reference as NSString).size(withAttributes: attrs).width
            (marker.reference as NSString).draw(at: CGPoint(x: min(p.x + 6, rect.maxX - width - 2), y: max(rect.minY, p.y - 10)), withAttributes: attrs)
        }
    }
}
