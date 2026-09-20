import MapKit
import SwiftUI
import UIKit

struct ScoutReportView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(VineyardInsightsService.self) private var insights
    @Environment(\.dismiss) private var dismiss

    let visit: ScoutVisit
    @State private var shareItem: ScoutReportShareItem?
    @State private var selectedMarker: ScoutReportMarker?
    @State private var exportError: String?

    private var vineyard: Vineyard? { store.vineyards.first { $0.id == visit.vineyardID } }
    private var blocks: [Paddock] {
        visit.assessments.compactMap { assessment in store.paddocks.first { $0.id == assessment.paddockID } }
    }
    private var markers: [ScoutReportMarker] {
        visit.assessments.flatMap { assessment in
            let blockName = store.paddocks.first { $0.id == assessment.paddockID }?.name ?? "Block"
            return assessment.observations.flatMap { observation -> [ScoutReportMarker] in
                var result = observation.photos.compactMap { photo -> ScoutReportMarker? in
                    guard let latitude = photo.latitude, let longitude = photo.longitude,
                          photo.locationStatus == .gpsConfirmed else { return nil }
                    return ScoutReportMarker(id: photo.id, title: observation.item.label,
                        subtitle: blockName, coordinate: .init(latitude: latitude, longitude: longitude), photo: photo)
                }
                if observation.item == .growthStage, let pinID = observation.linkedPinID,
                   let pin = store.pins.first(where: { $0.id == pinID }) {
                    result.append(ScoutReportMarker(id: observation.id, title: observation.valueLabel ?? "E-L observation",
                        subtitle: blockName, coordinate: .init(latitude: pin.latitude, longitude: pin.longitude), photo: nil))
                }
                return result
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    weather
                    ScoutReportMap(blocks: blocks, markers: markers, selectedMarker: $selectedMarker)
                        .frame(height: 280)
                        .clipShape(.rect(cornerRadius: 16))
                    locationUnavailable
                    ForEach(visit.assessments) { assessment in assessmentSection(assessment) }
                    reportText("Visit summary", visit.visitSummary)
                }
                .padding(16)
            }
            .navigationTitle("Scout report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { exportPDF() } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                }
            }
            .sheet(item: $shareItem) { item in ScoutReportShareSheet(items: [item.url]) }
            .sheet(item: $selectedMarker) { marker in ScoutMarkerDetail(marker: marker) }
            .alert("Could not create report", isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } }
            )) { Button("OK") { exportError = nil } } message: { Text(exportError ?? "Please try again.") }
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
                Text(visit.scoutDate, format: .dateTime.day().month().year())
                Text("Vintage \(VintageYearText.format(visit.vintageYear)) • \(visit.scoutNameSnapshot ?? "Observer unavailable")")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var weather: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Weather").font(.headline)
            if let value = visit.weather {
                if value.isUnavailable { Text("Unavailable at observation time").foregroundStyle(.orange) }
                HStack { weatherValue(value.temperatureCelsius, "°C"); weatherValue(value.humidityPercent, "% RH"); weatherValue(value.windSpeedKph, " km/h wind") }
                Text(value.source ?? "Source unavailable").font(.caption).foregroundStyle(.secondary)
                Text(value.observedAt.map { "Observed " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Observation time unavailable")
                    .font(.caption).foregroundStyle(value.isStale ? .orange : .secondary)
                if value.isStale { Text("Stale reading").font(.caption.bold()).foregroundStyle(.orange) }
            } else { Text("Not captured").foregroundStyle(.secondary) }
        }
    }

    private func weatherValue(_ value: Double?, _ suffix: String) -> some View {
        Text(value.map { String(Int($0.rounded())) + suffix } ?? "—")
    }

    private var locationUnavailable: some View {
        let rows = visit.assessments.flatMap { assessment in
            assessment.observations.filter { observation in
                observation.photos.contains { $0.locationStatus == .unavailable } ||
                (observation.item == .growthStage && observation.linkedGrowthStageRecordID != nil && observation.linkedPinID == nil)
            }.map { "\($0.item.label) — \(store.paddocks.first { $0.id == assessment.paddockID }?.name ?? "Block")" }
        }
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location unavailable").font(.headline)
                    ForEach(rows, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func assessmentSection(_ assessment: ScoutBlockAssessment) -> some View {
        let block = store.paddocks.first { $0.id == assessment.paddockID }
        return VStack(alignment: .leading, spacing: 10) {
            Text(block?.name ?? "Block").font(.title3.bold())
            Text(blockDetails(block)).font(.caption).foregroundStyle(.secondary)
            ForEach(ScoutItem.allCases) { item in
                let observation = assessment.observation(item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label).font(.subheadline.bold())
                    Text(observationValue(observation)).foregroundStyle(.primary)
                    if !item.isFreeText, let notes = observation?.notes, !notes.isEmpty { Text(notes).font(.callout) }
                    if let photos = observation?.photos, !photos.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(photos) { photo in
                                    Color(.secondarySystemBackground).frame(width: 110, height: 82).overlay {
                                        if let image = insights.localImage(photo) { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).allowsHitTesting(false) }
                                        else { VStack { Image(systemName: "photo"); Text("Not downloaded").font(.caption2) } }
                                    }.clipShape(.rect(cornerRadius: 8))
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
        if observation.item == .growthStage { return observation.valueLabel ?? "Not assessed" }
        if observation.item.isFreeText { return observation.notes?.isEmpty == false ? observation.notes! : "Not assessed" }
        return observation.valueLabel ?? "Not assessed"
    }

    private func blockDetails(_ block: Paddock?) -> String {
        let varieties = block?.varietyAllocations.compactMap(\.name).filter { !$0.isEmpty } ?? []
        return varieties.isEmpty ? "Variety details unavailable" : varieties.joined(separator: ", ")
    }

    private func reportText(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(value?.isEmpty == false ? value! : "Not assessed") }
    }

    private func exportPDF() {
        let images = Dictionary(uniqueKeysWithValues: visit.assessments.flatMap(\.observations).flatMap(\.photos).compactMap { photo in
            insights.localImage(photo).map { (photo.id, $0) }
        })
        guard let url = ScoutReportPDFService.export(visit: visit, vineyard: vineyard, blocks: blocks, images: images) else {
            exportError = "The PDF could not be written to this device. Check available storage and try again."
            return
        }
        shareItem = ScoutReportShareItem(url: url)
    }
}

struct ScoutReportMarker: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let photo: ScoutPhoto?
}

struct ScoutWorkspaceMap: View {
    @Environment(MigratedDataStore.self) private var store
    let visit: ScoutVisit
    @State private var selectedMarker: ScoutReportMarker?

    var body: some View {
        let blocks = visit.assessments.compactMap { assessment in store.paddocks.first { $0.id == assessment.paddockID } }
        let markers = visit.assessments.flatMap { assessment -> [ScoutReportMarker] in
            let blockName = blocks.first { $0.id == assessment.paddockID }?.name ?? "Block"
            return assessment.observations.flatMap { observation in
                var result = observation.photos.compactMap { photo in
                    guard let latitude = photo.latitude, let longitude = photo.longitude, photo.locationStatus == .gpsConfirmed else { return nil }
                    return ScoutReportMarker(id: photo.id, title: observation.item.label, subtitle: blockName,
                        coordinate: .init(latitude: latitude, longitude: longitude), photo: photo)
                }
                if observation.item == .growthStage, let pinID = observation.linkedPinID,
                   let pin = store.pins.first(where: { $0.id == pinID }) {
                    result.append(ScoutReportMarker(id: observation.id, title: observation.valueLabel ?? "E-L observation",
                        subtitle: blockName, coordinate: .init(latitude: pin.latitude, longitude: pin.longitude), photo: nil))
                }
                return result
            }
        }
        ScoutReportMap(blocks: blocks, markers: markers, selectedMarker: $selectedMarker)
            .frame(height: 240).clipShape(.rect(cornerRadius: 14))
            .sheet(item: $selectedMarker) { marker in ScoutMarkerDetail(marker: marker) }
    }
}

private struct ScoutMarkerDetail: View {
    @Environment(VineyardInsightsService.self) private var insights
    let marker: ScoutReportMarker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(marker.title).font(.headline)
            Text(marker.subtitle).foregroundStyle(.secondary)
            if let photo = marker.photo {
                if let image = insights.localImage(photo) {
                    Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 12))
                } else {
                    ContentUnavailableView("Photograph unavailable", systemImage: "photo", description: Text("The saved photograph is not available on this device."))
                }
            } else {
                Label("Linked E-L observation", systemImage: "leaf.fill")
            }
            Text(marker.coordinate.latitude.formatted() + ", " + marker.coordinate.longitude.formatted())
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
}

private struct ScoutReportMap: View {
    let blocks: [Paddock]
    let markers: [ScoutReportMarker]
    @Binding var selectedMarker: ScoutReportMarker?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(blocks) { block in
                if block.polygonPoints.count >= 3 {
                    MapPolygon(coordinates: block.polygonPoints.map(\.coordinate))
                        .foregroundStyle(VineyardTheme.leafGreen.opacity(0.18)).stroke(VineyardTheme.leafGreen, lineWidth: 2)
                }
            }
            ForEach(markers) { marker in
                Annotation(marker.title, coordinate: marker.coordinate) {
                    Button { selectedMarker = marker } label: {
                        Image(systemName: marker.photo == nil ? "leaf.fill" : "camera.fill")
                            .foregroundStyle(.white).padding(8).background(.indigo, in: .circle)
                    }
                }
            }
        }.mapStyle(.hybrid)
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
    static func export(visit: ScoutVisit, vineyard: Vineyard?, blocks: [Paddock], images: [UUID: UIImage]) -> URL? {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            var y: CGFloat = 42
            func page(_ needed: CGFloat) { if y + needed > 800 { context.beginPage(); y = 42 } }
            func text(_ value: String, font: UIFont = .systemFont(ofSize: 10), color: UIColor = .black, gap: CGFloat = 6) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let lineHeight = font.lineHeight + 2
                var line = ""
                func drawLine(_ content: String) {
                    page(lineHeight); (content as NSString).draw(at: CGPoint(x: 42, y: y), withAttributes: attrs); y += lineHeight
                }
                for word in value.replacingOccurrences(of: "\n", with: " \n ").split(separator: " ").map(String.init) {
                    if word == "\n" { drawLine(line); line = ""; continue }
                    let candidate = line.isEmpty ? word : line + " " + word
                    if (candidate as NSString).size(withAttributes: attrs).width > 511, !line.isEmpty { drawLine(line); line = word }
                    else { line = candidate }
                }
                if !line.isEmpty { drawLine(line) }
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
            text("Visit: \(visit.scoutDate.formatted(date: .long, time: .omitted))   Vintage: \(VintageYearText.format(visit.vintageYear))   Observer: \(visit.scoutNameSnapshot ?? "Unavailable")")
            text(weatherText(visit.weather)); text("Visit summary", font: .boldSystemFont(ofSize: 14)); text(visit.visitSummary ?? "Not assessed")
            page(192); drawDiagram(blocks: blocks, visit: visit, context: context.cgContext, rect: CGRect(x: 42, y: y, width: 511, height: 180)); y += 192
            for assessment in visit.assessments {
                let block = blocks.first { $0.id == assessment.paddockID }
                text(block?.name ?? "Block", font: .boldSystemFont(ofSize: 16))
                let varieties = block?.varietyAllocations.compactMap(\.name).filter { !$0.isEmpty } ?? []
                text(varieties.isEmpty ? "Variety details unavailable" : varieties.joined(separator: ", "), color: .darkGray)
                for item in ScoutItem.allCases {
                    let observation = assessment.observation(item)
                    text(item.label, font: .boldSystemFont(ofSize: 11))
                    let value = item == .growthStage ? observation?.valueLabel : (item.isFreeText ? observation?.notes : observation?.valueLabel)
                    text(value?.isEmpty == false ? value! : "Not assessed")
                    if !item.isFreeText, let notes = observation?.notes, !notes.isEmpty { text(notes) }
                    for photo in observation?.photos ?? [] {
                        page(126)
                        if let image = images[photo.id] {
                            let scale = min(160 / image.size.width, 110 / image.size.height)
                            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                            image.draw(in: CGRect(x: 42, y: y, width: size.width, height: size.height))
                        }
                        else { text("Photograph not downloaded to this device", color: .darkGray); continue }
                        y += 118
                    }
                }
            }
        }
        let name = "Scout-\(visit.scoutDate.formatted(.iso8601.year().month().day()))-\(visit.id.uuidString.prefix(8)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    private static func weatherText(_ weather: ScoutWeatherSnapshot?) -> String {
        guard let weather else { return "Weather: Not captured" }
        if weather.isUnavailable { return "Weather: Unavailable at observation time (\(weather.source ?? "source unavailable"))" }
        var values = [String]()
        if let value = weather.temperatureCelsius { values.append("\(Int(value.rounded()))°C") }
        if let value = weather.humidityPercent { values.append("\(Int(value.rounded()))% RH") }
        if let value = weather.windSpeedKph { values.append("wind \(Int(value.rounded())) km/h") }
        values.append(weather.source ?? "source unavailable")
        values.append(weather.observedAt.map { "observed " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "observation time unavailable")
        if weather.isStale { values.append("STALE") }
        return "Weather: " + values.joined(separator: " • ")
    }

    private static func drawDiagram(blocks: [Paddock], visit: ScoutVisit, context: CGContext, rect: CGRect) {
        context.saveGState(); defer { context.restoreGState() }
        context.setFillColor(UIColor(white: 0.95, alpha: 1).cgColor); context.fill(rect)
        let points = blocks.flatMap(\.polygonPoints)
        guard let minLat = points.map(\.latitude).min(), let maxLat = points.map(\.latitude).max(),
              let minLon = points.map(\.longitude).min(), let maxLon = points.map(\.longitude).max(), maxLat > minLat, maxLon > minLon else {
            ("Map imagery unavailable — no mapped block boundaries" as NSString).draw(at: CGPoint(x: rect.minX + 12, y: rect.midY), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray]); return
        }
        func point(_ coordinate: CoordinatePoint) -> CGPoint { CGPoint(x: rect.minX + CGFloat((coordinate.longitude - minLon) / (maxLon - minLon)) * rect.width, y: rect.maxY - CGFloat((coordinate.latitude - minLat) / (maxLat - minLat)) * rect.height) }
        context.setStrokeColor(UIColor.systemGreen.cgColor); context.setFillColor(UIColor.systemGreen.withAlphaComponent(0.15).cgColor); context.setLineWidth(1.5)
        for block in blocks where block.polygonPoints.count >= 3 { let path = CGMutablePath(); path.move(to: point(block.polygonPoints[0])); block.polygonPoints.dropFirst().forEach { path.addLine(to: point($0)) }; path.closeSubpath(); context.addPath(path); context.drawPath(using: .fillStroke) }
        context.setFillColor(UIColor.systemIndigo.cgColor)
        for photo in visit.assessments.flatMap(\.observations).flatMap(\.photos) { if let lat = photo.latitude, let lon = photo.longitude { let p = point(CoordinatePoint(latitude: lat, longitude: lon)); context.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)) } }
    }
}

