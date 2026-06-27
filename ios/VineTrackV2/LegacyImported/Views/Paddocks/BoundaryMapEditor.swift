import SwiftUI
import MapKit

struct BoundaryMapEditor: View {
    @Binding var polygonPoints: [CoordinatePoint]
    var existingPaddocks: [Paddock] = []
    @Environment(LocationService.self) private var locationService
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var hasSetInitialPosition: Bool = false
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var draggingIndex: Int?
    @AppStorage("boundaryDrawTipDismissed") private var boundaryTipDismissed: Bool = false
    @State private var showTip: Bool = true

    private var midpointEdges: [MidpointEdge] {
        guard polygonPoints.count >= 2 else { return [] }
        var edges: [MidpointEdge] = []
        for i in 0..<polygonPoints.count {
            let j = (i + 1) % polygonPoints.count
            if j == 0 && polygonPoints.count < 3 { continue }
            let midLat = (polygonPoints[i].latitude + polygonPoints[j].latitude) / 2
            let midLon = (polygonPoints[i].longitude + polygonPoints[j].longitude) / 2
            let mid = CLLocationCoordinate2D(latitude: midLat, longitude: midLon)
            edges.append(MidpointEdge(id: "\(polygonPoints[i].id)-\(polygonPoints[j].id)", midpoint: mid, insertIndex: i + 1))
        }
        return edges
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                MapReader { proxy in
                    Map(position: $position, interactionModes: draggingIndex != nil ? [] : [.pan, .zoom, .pitch, .rotate]) {
                        ForEach(existingPaddocks) { paddock in
                            if paddock.polygonPoints.count > 2 {
                                MapPolygon(coordinates: paddock.polygonPoints.map { $0.coordinate })
                                    .foregroundStyle(.orange.opacity(0.12))
                                    .stroke(.orange, lineWidth: 3)
                                Annotation("", coordinate: paddock.polygonPoints.centroid) {
                                    Text(paddock.name)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.orange.opacity(0.85), in: .capsule)
                                        .allowsHitTesting(false)
                                }
                            }
                        }

                        if polygonPoints.count > 2 {
                            MapPolygon(coordinates: polygonPoints.map { $0.coordinate })
                                .foregroundStyle(.blue.opacity(0.15))
                                .stroke(.blue, lineWidth: 2)
                        } else if polygonPoints.count == 2 {
                            MapPolyline(coordinates: polygonPoints.map { $0.coordinate })
                                .stroke(.blue, lineWidth: 2)
                        }

                        ForEach(Array(polygonPoints.enumerated()), id: \.element.id) { index, point in
                            Annotation("", coordinate: point.coordinate) {
                                PointHandle(
                                    index: index,
                                    isDragging: draggingIndex == index
                                )
                                .gesture(
                                    DragGesture(coordinateSpace: .global)
                                        .onChanged { value in
                                            draggingIndex = index
                                            if let coord = proxy.convert(value.location, from: .global) {
                                                let existingId = polygonPoints[index].id
                                                polygonPoints[index] = CoordinatePoint(id: existingId, coordinate: coord)
                                            }
                                        }
                                        .onEnded { _ in
                                            draggingIndex = nil
                                        }
                                )
                            }
                        }

                        ForEach(midpointEdges, id: \.id) { edge in
                            Annotation("", coordinate: edge.midpoint) {
                                MidpointHandle()
                                    .onTapGesture {
                                        withAnimation(.snappy(duration: 0.2)) {
                                            let newPoint = CoordinatePoint(coordinate: edge.midpoint)
                                            polygonPoints.insert(newPoint, at: edge.insertIndex)
                                        }
                                    }
                            }
                        }

                        UserAnnotation()
                    }
                    .mapStyle(.hybrid)
                    .onMapCameraChange { context in
                        visibleRegion = context.region
                    }
                    .onTapGesture { screenCoord in
                        guard draggingIndex == nil else { return }
                        if let coordinate = proxy.convert(screenCoord, from: .local) {
                            withAnimation(.snappy(duration: 0.2)) {
                                polygonPoints.append(CoordinatePoint(coordinate: coordinate))
                            }
                        }
                    }
                }

                Image(systemName: "plus")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(VineyardTheme.info)
                    .frame(width: 12, height: 12)
                    .allowsHitTesting(false)

                if showTip && !boundaryTipDismissed {
                    VStack {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(VineyardTheme.info)
                                .font(.subheadline)
                            Text("Tip: Place boundary points between rows, not directly on vine rows, for better row and area calculations.")
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button {
                                withAnimation(.snappy) {
                                    showTip = false
                                    boundaryTipDismissed = true
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Dismiss tip")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(VineyardTheme.info.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                VStack(spacing: 12) {
                    Button {
                        if let region = visibleRegion {
                            withAnimation(.snappy(duration: 0.2)) {
                                polygonPoints.append(CoordinatePoint(coordinate: region.center))
                            }
                        }
                    } label: {
                        Label("Add Point at Center", systemImage: "mappin.and.ellipse")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.blue, in: .capsule)
                            .foregroundStyle(.white)
                    }

                    if !polygonPoints.isEmpty {
                        HStack(spacing: 12) {
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    _ = polygonPoints.popLast()
                                }
                            } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(.ultraThinMaterial, in: .capsule)
                            }

                            Button(role: .destructive) {
                                withAnimation(.snappy(duration: 0.2)) {
                                    polygonPoints.removeAll()
                                }
                            } label: {
                                Label("Clear All", systemImage: "trash")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(.ultraThinMaterial, in: .capsule)
                            }
                        }
                    }

                    Text(draggingIndex != nil
                         ? "Dragging point \(draggingIndex! + 1) — release to place"
                         : "\(polygonPoints.count) point\(polygonPoints.count == 1 ? "" : "s") — Tap map to add, drag points to move")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: .capsule)
                }
                .padding(.bottom, 20)
            }
            .navigationTitle("Set Boundary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    if polygonPoints.count >= 2 {
                        Text("Tap \(Image(systemName: "plus.circle.dashed")) between points to insert")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .bottomBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                showTip = !boundaryTipDismissed
                locationService.requestPermission()
                locationService.startUpdating()
                if let loc = locationService.location {
                    position = .camera(MapCamera(centerCoordinate: loc.coordinate, distance: 500))
                    hasSetInitialPosition = true
                }
            }
            .onChange(of: locationService.location) { _, newLocation in
                if !hasSetInitialPosition, let loc = newLocation {
                    position = .camera(MapCamera(centerCoordinate: loc.coordinate, distance: 500))
                    hasSetInitialPosition = true
                }
            }
        }
    }
}

private struct MidpointEdge: Sendable {
    let id: String
    let midpoint: CLLocationCoordinate2D
    let insertIndex: Int
}

private struct MidpointHandle: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.2), radius: 3)
            Image(systemName: "plus")
                .font(.caption2.bold())
                .foregroundStyle(VineyardTheme.info)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
}

private struct PointHandle: View {
    let index: Int
    let isDragging: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isDragging ? .orange : .blue)
                .frame(width: isDragging ? 30 : 24, height: isDragging ? 30 : 24)
                .overlay {
                    Circle().stroke(.white, lineWidth: 2)
                }
                .shadow(color: isDragging ? .orange.opacity(0.5) : .black.opacity(0.3), radius: isDragging ? 8 : 4)
            Text("\(index + 1)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .animation(.snappy(duration: 0.15), value: isDragging)
    }
}
