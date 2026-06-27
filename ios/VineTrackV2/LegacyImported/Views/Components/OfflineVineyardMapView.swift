//
//  OfflineVineyardMapView.swift
//  VineTrackV2
//
//  Overlay-only vineyard map used when the device is offline or Apple
//  hybrid/satellite tiles cannot load. It draws paddock polygons, rows,
//  trip/path lines, pins and the current GPS position on a plain neutral
//  background using `Canvas`, so field navigation never depends on network
//  tiles.
//

import SwiftUI
import CoreLocation

/// A self-contained, tile-free map renderer. Coordinates are projected with a
/// simple equirectangular projection fitted to the supplied geometry. Pan and
/// pinch-to-zoom are supported; a recentre button refits the content.
struct OfflineVineyardMapView: View {
    struct Paddock: Identifiable {
        let id: UUID
        let polygon: [CLLocationCoordinate2D]
        /// Each row is a pair (or polyline) of coordinates.
        let rows: [[CLLocationCoordinate2D]]
        var rowColor: Color = .white.opacity(0.55)
        var strokeColor: Color = VineyardTheme.leafGreen.opacity(0.85)
        var fillColor: Color = VineyardTheme.leafGreen.opacity(0.18)
        var name: String? = nil
    }

    struct Trail: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        var lineWidth: CGFloat = 4
    }

    struct Pin: Identifiable {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let color: Color
        var isCompleted: Bool = false
        var name: String = ""
    }

    var paddocks: [Paddock] = []
    var trails: [Trail] = []
    var pins: [Pin] = []
    var userCoordinate: CLLocationCoordinate2D? = nil
    var userHeading: Double? = nil
    /// Show the small "Offline map mode" status banner. Defaults to true.
    var showStatusBanner: Bool = true
    var showPaddockLabels: Bool = true

    @State private var committedScale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1
    @State private var committedOffset: CGSize = .zero
    @GestureState private var gestureOffset: CGSize = .zero

    private var liveScale: CGFloat { max(0.3, min(committedScale * gestureScale, 40)) }
    private var liveOffset: CGSize {
        CGSize(width: committedOffset.width + gestureOffset.width,
               height: committedOffset.height + gestureOffset.height)
    }

    var body: some View {
        ZStack {
            // Plain neutral field background (no satellite tiles).
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.16, blue: 0.13),
                    Color(red: 0.09, green: 0.11, blue: 0.09),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            GeometryReader { geo in
                Canvas { ctx, size in
                    let project = makeProjector(size: size)
                    drawGrid(in: &ctx, size: size)
                    drawPaddocks(in: &ctx, project: project)
                    drawTrails(in: &ctx, project: project)
                    drawPins(in: &ctx, project: project)
                    drawUser(in: &ctx, project: project)
                    if showPaddockLabels {
                        drawLabels(in: &ctx, project: project)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($gestureOffset) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            committedOffset.width += value.translation.width
                            committedOffset.height += value.translation.height
                        }
                        .simultaneously(with:
                            MagnifyGesture()
                                .updating($gestureScale) { value, state, _ in
                                    state = value.magnification
                                }
                                .onEnded { value in
                                    committedScale = max(0.3, min(committedScale * value.magnification, 40))
                                }
                        )
                )
            }

            if showStatusBanner {
                statusBanner
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }

            recentreButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(12)
        }
    }

    private var statusBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.caption2.weight(.bold))
            Text("Offline map mode — vineyard rows and GPS still available.")
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .frame(maxWidth: 320)
        .padding(.horizontal, 12)
    }

    private var recentreButton: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                committedScale = 1
                committedOffset = .zero
            }
        } label: {
            Image(systemName: "scope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(9)
                .background(.ultraThinMaterial, in: .circle)
        }
    }

    // MARK: - Projection

    private var allCoordinates: [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        for p in paddocks {
            coords.append(contentsOf: p.polygon)
            for r in p.rows { coords.append(contentsOf: r) }
        }
        for t in trails { coords.append(contentsOf: t.coordinates) }
        coords.append(contentsOf: pins.map(\.coordinate))
        if let u = userCoordinate { coords.append(u) }
        return coords
    }

    /// Build a coordinate -> screen-point projector fitted to the geometry.
    private func makeProjector(size: CGSize) -> (CLLocationCoordinate2D) -> CGPoint {
        let coords = allCoordinates
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return { _ in CGPoint(x: size.width / 2, y: size.height / 2) }
        }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let lonScale = max(cos(centerLat * .pi / 180), 0.01)
        let spanLat = max(maxLat - minLat, 0.0003)
        let spanLon = max((maxLon - minLon) * lonScale, 0.0003)

        let padding: CGFloat = 36
        let availW = max(size.width - padding * 2, 1)
        let availH = max(size.height - padding * 2, 1)
        // Points per degree of latitude (uniform for both axes after lonScale).
        let baseScale = min(availW / spanLon, availH / spanLat)
        let scale = baseScale * liveScale
        let offset = liveOffset

        return { coord in
            let x = (coord.longitude - centerLon) * lonScale * scale + size.width / 2 + offset.width
            let y = -(coord.latitude - centerLat) * scale + size.height / 2 + offset.height
            return CGPoint(x: x, y: y)
        }
    }

    // MARK: - Drawing

    private func drawGrid(in ctx: inout GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 48
        var path = Path()
        var x: CGFloat = 0
        while x <= size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += spacing
        }
        var y: CGFloat = 0
        while y <= size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += spacing
        }
        ctx.stroke(path, with: .color(.white.opacity(0.04)), lineWidth: 1)
    }

    private func drawPaddocks(in ctx: inout GraphicsContext, project: (CLLocationCoordinate2D) -> CGPoint) {
        for paddock in paddocks {
            if paddock.polygon.count >= 3 {
                var path = Path()
                let pts = paddock.polygon.map(project)
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
                ctx.fill(path, with: .color(paddock.fillColor))
                ctx.stroke(path, with: .color(paddock.strokeColor), lineWidth: 1.6)
            }
            for row in paddock.rows where row.count >= 2 {
                var rp = Path()
                let pts = row.map(project)
                rp.move(to: pts[0])
                for p in pts.dropFirst() { rp.addLine(to: p) }
                ctx.stroke(rp, with: .color(paddock.rowColor), lineWidth: 1)
            }
        }
    }

    private func drawTrails(in ctx: inout GraphicsContext, project: (CLLocationCoordinate2D) -> CGPoint) {
        for trail in trails where trail.coordinates.count >= 2 {
            var path = Path()
            let pts = trail.coordinates.map(project)
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
            ctx.stroke(
                path,
                with: .color(trail.color),
                style: StrokeStyle(lineWidth: trail.lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func drawPins(in ctx: inout GraphicsContext, project: (CLLocationCoordinate2D) -> CGPoint) {
        for pin in pins {
            let p = project(pin.coordinate)
            let r: CGFloat = 7
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(pin.color))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2)
            if pin.isCompleted {
                var check = Path()
                check.move(to: CGPoint(x: p.x - 3, y: p.y))
                check.addLine(to: CGPoint(x: p.x - 0.5, y: p.y + 2.5))
                check.addLine(to: CGPoint(x: p.x + 3.5, y: p.y - 2.5))
                ctx.stroke(check, with: .color(.white), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func drawUser(in ctx: inout GraphicsContext, project: (CLLocationCoordinate2D) -> CGPoint) {
        guard let user = userCoordinate else { return }
        let p = project(user)
        let halo: CGFloat = 16
        ctx.fill(
            Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo, width: halo * 2, height: halo * 2)),
            with: .color(Color.blue.opacity(0.18))
        )
        let r: CGFloat = 7
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.blue))
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white), lineWidth: 2.5)
    }

    private func drawLabels(in ctx: inout GraphicsContext, project: (CLLocationCoordinate2D) -> CGPoint) {
        for paddock in paddocks {
            guard let name = paddock.name, !name.isEmpty, paddock.polygon.count >= 3 else { continue }
            let centroid = paddock.polygon.reduce(CLLocationCoordinate2D(latitude: 0, longitude: 0)) { acc, c in
                CLLocationCoordinate2D(latitude: acc.latitude + c.latitude, longitude: acc.longitude + c.longitude)
            }
            let center = CLLocationCoordinate2D(
                latitude: centroid.latitude / Double(paddock.polygon.count),
                longitude: centroid.longitude / Double(paddock.polygon.count)
            )
            let p = project(center)
            let text = Text(name).font(.caption2.weight(.bold)).foregroundColor(.white)
            ctx.draw(text, at: p, anchor: .center)
        }
    }
}
