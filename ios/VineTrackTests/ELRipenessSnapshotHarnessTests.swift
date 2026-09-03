import CoreLocation
import MapKit
import SwiftUI
import UIKit
import XCTest
@testable import VineTrack

/// Non-shipping visual harness for the E-L Ripeness Heatmap.
///
/// Renders the **real shipped drawing code** against the canonical contract
/// fixture and asserts that each surface actually painted something:
///
/// * the map surface is composited through the production
///   `ELRipenessHeatOverlayRenderer`, `ELRipenessHeatRaster` and
///   `ELRipenessPinFactory` — the same objects `ELRipenessMapView` hands to
///   MapKit at runtime;
/// * the chrome (controls, status, timeline, legend, sheets, empty states) is
///   rendered from the real SwiftUI views through `ImageRenderer`.
///
/// `UIView.drawHierarchy` and `MKMapView` snapshotting both return blank in a
/// headless unit-test host, which is why the surface is composited directly
/// rather than screenshotted through a live map view.
///
/// No fixture record ever reaches production: the data is decoded here in the
/// test bundle and pushed through a stub repository.
@MainActor
final class ELRipenessSnapshotHarnessTests: XCTestCase {

    /// Flip to `true` to emit base64 PNG frames into the test log for review.
    private static let emitBase64 = true

    private let mapSize = CGSize(width: 390, height: 420)
    private let vineyardId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let timeZone = TimeZone(identifier: "Australia/Adelaide")!

    // MARK: - Fixture plumbing

    private final class StubRepository: RipenessObservationRepositoryProtocol, @unchecked Sendable {
        var rows: [RipenessObservationRow] = []
        func fetchObservations(vineyardId: UUID) async throws -> [RipenessObservationRow] { rows }
    }

    private final class StubCache: ELRipenessObservationCaching, @unchecked Sendable {
        var stored: [String: ELRipenessCachePayload] = [:]
        func load(vineyardId: UUID) -> ELRipenessCachePayload? { stored[vineyardId.uuidString.lowercased()] }
        func save(_ payload: ELRipenessCachePayload) { stored[payload.vineyardId] = payload }
        func clear(vineyardId: UUID) { stored.removeValue(forKey: vineyardId.uuidString.lowercased()) }
    }

    /// Deterministic UUID for a fixture string ID.
    private static func uuid(for key: String) -> UUID {
        var bytes = Array(key.utf8.prefix(16))
        while bytes.count < 16 { bytes.append(0) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func fixturePaddocks() throws -> [Paddock] {
        let fixture = try ELRipenessContractFixtures.fixture()
        let blocks = try XCTUnwrap(fixture["blocks"] as? [[String: Any]])
        return blocks.compactMap { block -> Paddock? in
            guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
            let points = (block["polygon_points"] as? [[String: Any]] ?? []).compactMap { point -> CoordinatePoint? in
                guard let lat = point["lat"] as? Double, let lng = point["lng"] as? Double else { return nil }
                return CoordinatePoint(latitude: lat, longitude: lng)
            }
            return Paddock(id: Self.uuid(for: id), vineyardId: vineyardId, name: name, polygonPoints: points)
        }
    }

    /// Fixture observations decoded through the shipped `RipenessObservationRow`
    /// decoder, with IDs remapped onto the paddocks above.
    private func alignedRows() throws -> [RipenessObservationRow] {
        let fixture = try ELRipenessContractFixtures.fixture()
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        var flattened: [[String: Any]] = []
        for observation in observations {
            guard let id = observation["id"] as? String else { continue }
            var row: [String: Any] = ["id": id]
            if let owner = observation["vineyard_id"] as? String {
                row["vineyard_id"] = owner == "vy-fixture-south"
                    ? vineyardId.uuidString.lowercased()
                    : Self.uuid(for: owner).uuidString.lowercased()
            }
            if let paddock = observation["paddock_id"] as? String {
                row["paddock_id"] = Self.uuid(for: paddock).uuidString.lowercased()
            }
            for key in ["growth_stage_code", "latitude", "longitude", "date", "completed_at", "created_at", "deleted_at"] {
                if let value = observation[key], !(value is NSNull) { row[key] = value }
            }
            if let placement = observation["placement"] as? [String: Any],
               let assigned = placement["is_location_assigned"] as? Bool {
                row["is_location_assigned"] = assigned
            }
            flattened.append(row)
        }
        let data = try JSONSerialization.data(withJSONObject: flattened)
        return try JSONDecoder().decode([RipenessObservationRow].self, from: data)
    }

    private func loadedModel() async throws -> ELRipenessHeatmapModel {
        let repository = StubRepository()
        repository.rows = try alignedRows()
        let model = ELRipenessHeatmapModel(repository: repository, cache: StubCache())
        await model.load(
            vineyardId: vineyardId,
            paddocks: try fixturePaddocks(),
            pins: [],
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: timeZone,
            isOnline: true
        )
        await model.waitForRender()
        return model
    }

    // MARK: - Map compositor (production drawing code)

    /// Draws the map surface exactly as `ELRipenessMapView` asks MapKit to draw
    /// it: block outlines, then each block's heat overlay through the real
    /// `ELRipenessHeatOverlayRenderer`, then pins and labels from the real
    /// `ELRipenessPinFactory`.
    private func compositeMap(
        model: ELRipenessHeatmapModel,
        size: CGSize,
        isOnline: Bool = true
    ) -> UIImage {
        let blocks = model.heatModel?.blocks ?? []
        var bounding = MKMapRect.null
        for block in blocks where block.polygon.count >= 3 {
            for point in block.polygon {
                let mapPoint = MKMapPoint(CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng))
                bounding = bounding.union(MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 0, height: 0))
            }
        }
        guard !bounding.isNull, bounding.size.width > 0, bounding.size.height > 0 else {
            return UIGraphicsImageRenderer(size: size).image { context in
                UIColor.systemBackground.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
        // Pad so the outermost blocks are not flush against the edge.
        let pad = max(bounding.size.width, bounding.size.height) * 0.08
        bounding = bounding.insetBy(dx: -pad, dy: -pad)

        let scale = min(size.width / bounding.size.width, size.height / bounding.size.height)
        let offsetX = (size.width - bounding.size.width * scale) / 2
        let offsetY = (size.height - bounding.size.height * scale) / 2

        func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            let mapPoint = MKMapPoint(coordinate)
            return CGPoint(
                x: offsetX + (mapPoint.x - bounding.origin.x) * scale,
                y: offsetY + (mapPoint.y - bounding.origin.y) * scale
            )
        }

        return UIGraphicsImageRenderer(size: size).image { rendererContext in
            let cg = rendererContext.cgContext
            // Stand-in for the basemap: hybrid imagery when online, the plain
            // offline canvas when not.
            (isOnline ? UIColor(white: 0.16, alpha: 1) : UIColor.secondarySystemBackground).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            // Heat surfaces, each clipped to its own polygon.
            for block in blocks {
                guard let overlay = ELRipenessHeatOverlay.make(from: block),
                      block.polygon.count >= 3 else { continue }
                cg.saveGState()
                let path = CGMutablePath()
                for (index, point) in block.polygon.enumerated() {
                    let projected = project(CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng))
                    if index == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
                }
                path.closeSubpath()
                cg.addPath(path)
                cg.clip()

                let topLeft = MKMapPoint(x: overlay.drawRect.minX, y: overlay.drawRect.minY)
                let bottomRight = MKMapPoint(x: overlay.drawRect.maxX, y: overlay.drawRect.maxY)
                let rect = CGRect(
                    x: offsetX + (topLeft.x - bounding.origin.x) * scale,
                    y: offsetY + (topLeft.y - bounding.origin.y) * scale,
                    width: (bottomRight.x - topLeft.x) * scale,
                    height: (bottomRight.y - topLeft.y) * scale
                )
                cg.interpolationQuality = .high
                cg.translateBy(x: rect.minX, y: rect.maxY)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(overlay.image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
                cg.restoreGState()
            }

            // Block outlines.
            for block in blocks where block.polygon.count >= 3 {
                let path = UIBezierPath()
                for (index, point) in block.polygon.enumerated() {
                    let projected = project(CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng))
                    if index == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
                }
                path.close()
                let selected = block.paddockId == model.selectedBlockId
                UIColor.white.withAlphaComponent(selected ? 0.95 : 0.55).setStroke()
                path.lineWidth = selected ? 2.5 : 1.5
                path.stroke()
            }

            // Pins, above the surface.
            guard let dateISO = model.currentDateISO else { return }
            func drawPin(_ observation: ELRipeness.Observation, _ style: ELRipenessObservationAnnotation.Style) {
                let image = ELRipenessPinFactory.observationImage(el: observation.el, style: style)
                let centre = project(CLLocationCoordinate2D(latitude: observation.lat, longitude: observation.lng))
                image.draw(at: CGPoint(x: centre.x - image.size.width / 2, y: centre.y - image.size.height / 2))
            }
            for block in blocks {
                for observation in block.influencing { drawPin(observation, .current) }
                for observation in block.stale { drawPin(observation, .stale) }
            }
            for observation in model.heatModel?.unassigned ?? [] { drawPin(observation, .unassigned) }
            _ = dateISO

            // Block name plates with the influencing-only median.
            for block in blocks where block.polygon.count >= 3 {
                guard let centroid = ELRipenessGeometry.centroid(of: block.polygon) else { continue }
                let plate = ELRipenessPinFactory.blockLabelImage(
                    name: block.paddockName ?? "Block",
                    medianEl: block.medianEl,
                    mode: block.mode
                )
                let centre = project(centroid)
                plate.draw(at: CGPoint(x: centre.x - plate.size.width / 2, y: centre.y - plate.size.height / 2))
            }
        }
    }

    // MARK: - SwiftUI chrome rendering

    private func renderSwiftUI(_ view: some View, width: CGFloat, name: String) -> UIImage? {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .background(Color(.systemGroupedBackground))
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 2
        guard let image = renderer.uiImage else { return nil }
        emit(image, name: name)
        return image
    }

    // MARK: - Emission & assertions

    private func emit(_ image: UIImage, name: String) {
        guard Self.emitBase64, let data = image.pngData() else { return }
        let encoded = data.base64EncodedString()
        print("===SNAPSHOT-BEGIN:\(name):\(Int(image.size.width))x\(Int(image.size.height)):\(data.count)===")
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 4000, limitedBy: encoded.endIndex) ?? encoded.endIndex
            print("SNAP|\(encoded[index..<end])")
            index = end
        }
        print("===SNAPSHOT-END:\(name)===")
    }

    private func distinctColourCount(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var seen = Set<UInt32>()
        var index = 0
        while index < pixels.count {
            seen.insert((UInt32(pixels[index]) << 16) | (UInt32(pixels[index + 1]) << 8) | UInt32(pixels[index + 2]))
            index += 4 * 7
        }
        return seen.count
    }

    private func assertRendered(_ image: UIImage, _ name: String, minimumColours: Int = 12) {
        let colours = distinctColourCount(image)
        XCTAssertGreaterThan(colours, minimumColours, "\(name) rendered only \(colours) distinct colours — looks blank")
    }

    private func captureMap(
        _ model: ELRipenessHeatmapModel,
        name: String,
        isOnline: Bool = true,
        minimumColours: Int = 12
    ) {
        let image = compositeMap(model: model, size: mapSize, isOnline: isOnline)
        emit(image, name: name)
        assertRendered(image, name, minimumColours: minimumColours)
    }

    // MARK: - Frames

    func testCaptureAllBlocks() async throws {
        let model = try await loadedModel()
        XCTAssertEqual(model.loadState, .ready)
        XCTAssertFalse(model.overlays.isEmpty, "the fixture must produce heat overlays")
        captureMap(model, name: "01-all-blocks")
    }

    func testCaptureSelectedBlock() async throws {
        let model = try await loadedModel()
        let target = try XCTUnwrap(
            model.heatModel?.blocks.first { $0.mode == .surface }?.paddockId,
            "expected at least one block with a full surface"
        )
        model.selectedBlockId = target
        await model.waitForRender()
        XCTAssertEqual(model.heatModel?.blocks.count, 1)
        captureMap(model, name: "02-single-block")
    }

    func testCaptureEarlyAndLaterTimelineDates() async throws {
        let model = try await loadedModel()
        let first = try XCTUnwrap(model.observationDayIndices.first)
        let last = try XCTUnwrap(model.observationDayIndices.last)

        model.timelineIndex = first
        await model.waitForRender()
        let earlyCounts = model.statusCounts
        captureMap(model, name: "03-timeline-early")

        model.timelineIndex = last
        await model.waitForRender()
        let lateCounts = model.statusCounts
        captureMap(model, name: "04-timeline-late")

        XCTAssertLessThan(
            earlyCounts.recorded,
            lateCounts.recorded,
            "later in the season must have accumulated more observations"
        )
    }

    func testCaptureHaloSparseState() async throws {
        let model = try await loadedModel()
        var haloBlock: String?
        outer: for index in model.observationDayIndices {
            model.timelineIndex = index
            await model.waitForRender()
            for block in model.heatModel?.blocks ?? [] where block.mode == .halo {
                haloBlock = block.paddockId
                break outer
            }
        }
        let target = try XCTUnwrap(haloBlock, "the fixture should produce a halo somewhere in the season")
        model.selectedBlockId = target
        await model.waitForRender()
        XCTAssertEqual(model.heatModel?.blocks.first?.mode, .halo)
        captureMap(model, name: "05-halo-sparse")
    }

    func testCaptureGradientSparseState() async throws {
        let model = try await loadedModel()
        var gradientBlock: String?
        outer: for index in model.observationDayIndices {
            model.timelineIndex = index
            await model.waitForRender()
            for block in model.heatModel?.blocks ?? [] where block.mode == .gradient {
                gradientBlock = block.paddockId
                break outer
            }
        }
        guard let target = gradientBlock else {
            throw XCTSkip("no two-observation block in this fixture season")
        }
        model.selectedBlockId = target
        await model.waitForRender()
        XCTAssertEqual(model.heatModel?.blocks.first?.mode, .gradient)
        captureMap(model, name: "06-gradient-sparse")
    }

    /// Every observation in view is older than 84 days: pins remain, the
    /// surface does not. Driven by pushing the timeline well past the fixture's
    /// January cluster rather than hoping the fixture contains such a date.
    func testCaptureStaleOnlyState() async throws {
        let repository = StubRepository()
        repository.rows = try alignedRows()
        let model = ELRipenessHeatmapModel(repository: repository, cache: StubCache())
        await model.load(
            vineyardId: vineyardId,
            paddocks: try fixturePaddocks(),
            // A pin far later in the same Vintage extends the timeline past the
            // 84-day window of every fixture observation.
            pins: [
                VinePin(
                    id: UUID(),
                    vineyardId: vineyardId,
                    latitude: -34.502,
                    longitude: 138.502,
                    heading: nil,
                    buttonName: "Growth",
                    buttonColor: "green",
                    side: nil,
                    mode: .growth,
                    paddockId: Self.uuid(for: "BLOCK_F"),
                    timestamp: ISO8601DateFormatter().date(from: "2026-06-20T02:00:00Z") ?? Date(),
                    growthStageCode: "E-L 38"
                )
            ],
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: timeZone,
            isOnline: true
        )
        await model.waitForRender()

        let staleBlock = try XCTUnwrap(
            model.heatModel?.blocks.first { $0.mode == .stale }?.paddockId,
            "expected a block whose observations have all aged out by late June"
        )
        model.selectedBlockId = staleBlock
        await model.waitForRender()

        XCTAssertTrue(model.heatModel?.influencing.isEmpty ?? false)
        XCTAssertTrue(
            model.notices.contains { if case .staleOnly = $0 { return true } else { return false } },
            "a stale-only view must say so"
        )
        captureMap(model, name: "07-stale-only", minimumColours: 6)
    }

    func testCaptureOfflineNoBasemap() async throws {
        let model = try await loadedModel()
        captureMap(model, name: "08-offline-no-basemap", isOnline: false)
    }

    // MARK: - Chrome

    func testCaptureChromeAndStates() async throws {
        let model = try await loadedModel()
        let formatter = AppSettings().regionFormatter

        let fullScreen = try XCTUnwrap(
            renderSwiftUI(
                ELRipenessHeatmapContent(
                    model: model,
                    isOnline: true,
                    formatter: formatter,
                    timeZone: timeZone
                )
                .frame(height: 844),
                width: 390,
                name: "09-screen-chrome"
            )
        )
        assertRendered(fullScreen, "screen chrome")

        let legend = try XCTUnwrap(
            renderSwiftUI(ELRipenessLegendView().padding(), width: 360, name: "10-legend")
        )
        assertRendered(legend, "legend")

        let timeline = try XCTUnwrap(
            renderSwiftUI(
                ELRipenessTimelineBar(
                    index: .constant(model.timelineIndex),
                    dayCount: model.timelineDays.count,
                    observationIndices: model.observationDayIndices,
                    currentLabel: model.currentDay?.iso ?? "—",
                    isPlaying: false,
                    canStepBack: model.canStepBack,
                    canStepForward: model.canStepForward,
                    onStepBack: {},
                    onStepForward: {},
                    onTogglePlay: {}
                )
                .padding(),
                width: 390,
                name: "11-timeline"
            )
        )
        assertRendered(timeline, "timeline")

        let observation = try XCTUnwrap(model.heatModel?.influencing.first)
        let sheet = try XCTUnwrap(
            renderSwiftUI(
                ELRipenessObservationSheet(
                    observation: observation,
                    blockName: model.blocks.first { $0.id == observation.paddockId }?.name,
                    atDateISO: try XCTUnwrap(model.currentDateISO)
                )
                .frame(height: 560),
                width: 390,
                name: "12-pin-detail-sheet"
            )
        )
        assertRendered(sheet, "pin detail sheet")

        let info = try XCTUnwrap(
            renderSwiftUI(ELRipenessInfoView().frame(height: 900), width: 390, name: "13-info-el47")
        )
        assertRendered(info, "info")
    }

    func testCaptureUnavailableOfflineState() async throws {
        let model = ELRipenessHeatmapModel(repository: StubRepository(), cache: StubCache())
        await model.load(
            vineyardId: vineyardId,
            paddocks: try fixturePaddocks(),
            pins: [],
            seasonStartMonth: 7,
            seasonStartDay: 1,
            timeZone: timeZone,
            isOnline: false
        )
        XCTAssertEqual(model.loadState, .unavailableOffline)

        let image = try XCTUnwrap(
            renderSwiftUI(
                ELRipenessHeatmapContent(
                    model: model,
                    isOnline: false,
                    formatter: AppSettings().regionFormatter,
                    timeZone: timeZone
                )
                .frame(height: 600),
                width: 390,
                name: "14-unavailable-offline"
            )
        )
        assertRendered(image, "unavailable offline", minimumColours: 6)
    }

    func testCaptureLandscapeChrome() async throws {
        let model = try await loadedModel()
        let image = try XCTUnwrap(
            renderSwiftUI(
                ELRipenessHeatmapContent(
                    model: model,
                    isOnline: true,
                    formatter: AppSettings().regionFormatter,
                    timeZone: timeZone
                )
                .frame(height: 390)
                .environment(\.verticalSizeClass, .compact),
                width: 844,
                name: "15-landscape"
            )
        )
        assertRendered(image, "landscape")
    }
}
