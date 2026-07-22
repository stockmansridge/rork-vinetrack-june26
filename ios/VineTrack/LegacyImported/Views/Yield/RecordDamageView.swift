import SwiftUI
import MapKit

struct RecordDamageView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(DamageRecordSyncService.self) private var damageRecordSync
    @Environment(\.accessControl) private var accessControl
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.dismiss) private var dismiss
    let paddock: Paddock
    let editingRecord: DamageRecord?

    private var canDelete: Bool { accessControl?.canDelete ?? false }
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    init(paddock: Paddock, editingRecord: DamageRecord? = nil) {
        self.paddock = paddock
        self.editingRecord = editingRecord
        _polygonPoints = State(initialValue: editingRecord?.polygonPoints ?? [])
        _damageDate = State(initialValue: editingRecord?.date ?? Date())
        _damageType = State(initialValue: editingRecord?.damageType ?? .frost)
        _damagePercentText = State(initialValue: editingRecord.map { String(format: "%.0f", $0.damagePercent) } ?? "20")
        _notes = State(initialValue: editingRecord?.notes ?? "")
    }

    @State private var polygonPoints: [CoordinatePoint]
    @State private var damageDate: Date
    @State private var damageType: DamageType
    @State private var damagePercentText: String
    @State private var notes: String
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var draggingIndex: Int?
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var showConfirmation: Bool = false
    @State private var isFullScreenMap: Bool = false
    @State private var showDeleteConfirmation: Bool = false

    private var damageAreaHa: Double {
        let points = polygonPoints
        guard points.count >= 3 else { return 0 }
        let centroidLat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        var area = 0.0
        let n = points.count
        for i in 0..<n {
            let j = (i + 1) % n
            let xi = points[i].longitude * mPerDegLon
            let yi = points[i].latitude * mPerDegLat
            let xj = points[j].longitude * mPerDegLon
            let yj = points[j].latitude * mPerDegLat
            area += xi * yj - xj * yi
        }
        area = abs(area) / 2.0
        return area / 10_000.0
    }

    private var damagePercent: Double {
        Double(damagePercentText) ?? 0
    }

    private var isValid: Bool {
        polygonPoints.count >= 3 && damagePercent > 0 && damagePercent <= 100
    }

    private var midpointEdges: [DamageMidpointEdge] {
        guard polygonPoints.count >= 2 else { return [] }
        var edges: [DamageMidpointEdge] = []
        for i in 0..<polygonPoints.count {
            let j = (i + 1) % polygonPoints.count
            if j == 0 && polygonPoints.count < 3 { continue }
            let midLat = (polygonPoints[i].latitude + polygonPoints[j].latitude) / 2
            let midLon = (polygonPoints[i].longitude + polygonPoints[j].longitude) / 2
            let mid = CLLocationCoordinate2D(latitude: midLat, longitude: midLon)
            edges.append(DamageMidpointEdge(id: "\(polygonPoints[i].id)-\(polygonPoints[j].id)", midpoint: mid, insertIndex: i + 1))
        }
        return edges
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let record = editingRecord {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack {
                            Spacer()
                            RecordSyncBadge(state: RecordSyncState.forDamageRecord(record.id, damageSync: damageRecordSync))
                        }
                        RecordSyncFailureHint(state: RecordSyncState.forDamageRecord(record.id, damageSync: damageRecordSync))
                    }
                }
                mapSection
                drawingControls
                damageAreaInfo
                damageDetailsSection
                saveButton
                if editingRecord != nil && canDelete {
                    deleteButton
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .navigationTitle(editingRecord == nil ? "Record Damage" : "Edit Damage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { fitMapToPaddock() }
        .fullScreenCover(isPresented: $isFullScreenMap) {
            fullScreenMap
        }
        .sensoryFeedback(.success, trigger: showConfirmation)
        .alert(editingRecord == nil ? "Damage Recorded" : "Damage Updated", isPresented: $showConfirmation) {
            Button("OK") { dismiss() }
        } message: {
            Text("Damage of \(Int(damagePercent))% \(damageType.rawValue) has been \(editingRecord == nil ? "recorded" : "updated") for \(paddock.name).")
        }
        .confirmationDialog("Delete Damage Record?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Record", role: .destructive) {
                if let record = editingRecord {
                    store.deleteDamageRecord(record)
                    Task { await damageRecordSync.syncForSelectedVineyard() }
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This damage record will be permanently removed. This action cannot be undone.")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Label("Delete Damage Record", systemImage: "trash")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    // MARK: - Map

    private var mapSection: some View {
        MapReader { proxy in
            Map(position: $mapPosition, interactionModes: draggingIndex != nil ? [] : [.pan, .zoom, .pitch, .rotate]) {
                MapPolygon(coordinates: paddock.polygonPoints.map(\.coordinate))
                    .foregroundStyle(.blue.opacity(0.08))
                    .stroke(.blue.opacity(0.6), lineWidth: 2)

                Annotation("", coordinate: paddock.polygonPoints.centroid) {
                    Text(paddock.name)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.8), in: .capsule)
                        .allowsHitTesting(false)
                }

                ForEach(paddock.rows) { row in
                    MapPolyline(coordinates: [row.startPoint.coordinate, row.endPoint.coordinate])
                        .stroke(.blue.opacity(0.15), lineWidth: 0.5)
                }

                let existingDamage = store.damageRecords(for: paddock.id).filter { $0.id != editingRecord?.id }
                ForEach(existingDamage) { record in
                    if record.polygonPoints.count >= 3 {
                        MapPolygon(coordinates: record.polygonPoints.map(\.coordinate))
                            .foregroundStyle(.red.opacity(0.2))
                            .stroke(.red.opacity(0.6), lineWidth: 1.5)
                    }
                }

                if polygonPoints.count > 2 {
                    MapPolygon(coordinates: polygonPoints.map(\.coordinate))
                        .foregroundStyle(.orange.opacity(0.25))
                        .stroke(.orange, lineWidth: 2.5)
                } else if polygonPoints.count == 2 {
                    MapPolyline(coordinates: polygonPoints.map(\.coordinate))
                        .stroke(.orange, lineWidth: 2.5)
                }

                ForEach(Array(polygonPoints.enumerated()), id: \.element.id) { index, point in
                    Annotation("", coordinate: point.coordinate) {
                        DamagePointHandle(index: index, isDragging: draggingIndex == index)
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
                        DamageMidpointHandle()
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.2)) {
                                    let newPoint = CoordinatePoint(coordinate: edge.midpoint)
                                    polygonPoints.insert(newPoint, at: edge.insertIndex)
                                }
                            }
                    }
                }
            }
            .mapStyle(.hybrid)
            .frame(height: 350)
            .clipShape(.rect(cornerRadius: 14))
            .overlay(alignment: .top) {
                if !network.isOnline {
                    offlineMapBanner
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                Button {
                    isFullScreenMap = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(.rect(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .padding(10)
            }
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
    }

    // MARK: - Full Screen Map

    private var fullScreenMap: some View {
        ZStack(alignment: .top) {
            MapReader { proxy in
                Map(position: $mapPosition, interactionModes: draggingIndex != nil ? [] : [.pan, .zoom, .pitch, .rotate]) {
                    MapPolygon(coordinates: paddock.polygonPoints.map(\.coordinate))
                        .foregroundStyle(.blue.opacity(0.08))
                        .stroke(.blue.opacity(0.6), lineWidth: 2)

                    Annotation("", coordinate: paddock.polygonPoints.centroid) {
                        Text(paddock.name)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.blue.opacity(0.8), in: .capsule)
                            .allowsHitTesting(false)
                    }

                    ForEach(paddock.rows) { row in
                        MapPolyline(coordinates: [row.startPoint.coordinate, row.endPoint.coordinate])
                            .stroke(.blue.opacity(0.15), lineWidth: 0.5)
                    }

                    let existingDamage = store.damageRecords(for: paddock.id).filter { $0.id != editingRecord?.id }
                    ForEach(existingDamage) { record in
                        if record.polygonPoints.count >= 3 {
                            MapPolygon(coordinates: record.polygonPoints.map(\.coordinate))
                                .foregroundStyle(.red.opacity(0.2))
                                .stroke(.red.opacity(0.6), lineWidth: 1.5)
                        }
                    }

                    if polygonPoints.count > 2 {
                        MapPolygon(coordinates: polygonPoints.map(\.coordinate))
                            .foregroundStyle(.orange.opacity(0.25))
                            .stroke(.orange, lineWidth: 2.5)
                    } else if polygonPoints.count == 2 {
                        MapPolyline(coordinates: polygonPoints.map(\.coordinate))
                            .stroke(.orange, lineWidth: 2.5)
                    }

                    ForEach(Array(polygonPoints.enumerated()), id: \.element.id) { index, point in
                        Annotation("", coordinate: point.coordinate) {
                            DamagePointHandle(index: index, isDragging: draggingIndex == index)
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
                            DamageMidpointHandle()
                                .onTapGesture {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        let newPoint = CoordinatePoint(coordinate: edge.midpoint)
                                        polygonPoints.insert(newPoint, at: edge.insertIndex)
                                    }
                                }
                        }
                    }
                }
                .mapStyle(.hybrid)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    if !network.isOnline {
                        offlineMapBanner
                            .padding(.top, 56)
                            .allowsHitTesting(false)
                    }
                }
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

            VStack {
                HStack {
                    Button {
                        isFullScreenMap = false
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: .capsule)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 10) {
                    Text(polygonPoints.isEmpty
                         ? "Tap the map to draw a damage zone polygon"
                         : "\(polygonPoints.count) point\(polygonPoints.count == 1 ? "" : "s") — tap to add more")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: .capsule)

                    HStack(spacing: 10) {
                        if !polygonPoints.isEmpty {
                            Button {
                                withAnimation(.snappy(duration: 0.2)) { _ = polygonPoints.popLast() }
                            } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.gray)

                            Button(role: .destructive) {
                                withAnimation(.snappy(duration: 0.2)) { polygonPoints.removeAll() }
                            } label: {
                                Label("Clear", systemImage: "trash")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }

                        if let region = visibleRegion {
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    polygonPoints.append(CoordinatePoint(coordinate: region.center))
                                }
                            } label: {
                                Label("Add Center", systemImage: "mappin")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Offline Banner

    private var offlineMapBanner: some View {
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

    // MARK: - Drawing Controls

    private var drawingControls: some View {
        VStack(spacing: 10) {
            Text(polygonPoints.isEmpty
                 ? "Tap the map to draw a damage zone polygon"
                 : "\(polygonPoints.count) point\(polygonPoints.count == 1 ? "" : "s") — tap to add more")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if !polygonPoints.isEmpty {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            _ = polygonPoints.popLast()
                        }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        withAnimation(.snappy(duration: 0.2)) {
                            polygonPoints.removeAll()
                        }
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                }

                if let region = visibleRegion {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            polygonPoints.append(CoordinatePoint(coordinate: region.center))
                        }
                    } label: {
                        Label("Add at Center", systemImage: "mappin")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Area Info

    private var damageAreaInfo: some View {
        Group {
            if polygonPoints.count >= 3 {
                HStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("Damage Zone")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(fmt.formatArea(hectares: damageAreaHa, fractionDigits: 4))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.orange)
                    }

                    Divider().frame(height: 30)

                    VStack(spacing: 4) {
                        Text("Block Area")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(fmt.formatArea(hectares: paddock.areaHectares))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(VineyardTheme.info)
                    }

                    Divider().frame(height: 30)

                    VStack(spacing: 4) {
                        Text("% of Block")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        let pct = paddock.areaHectares > 0 ? (damageAreaHa / paddock.areaHectares) * 100 : 0
                        Text(String(format: "%.1f%%", pct))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
            }
        }
    }

    // MARK: - Damage Details

    private var damageDetailsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Damage Details", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Date")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $damageDate, displayedComponents: .date)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Type of Damage")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                    ForEach(DamageType.allCases, id: \.self) { type in
                        let isSelected = damageType == type
                        Button {
                            damageType = type
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: type.icon)
                                    .font(.caption2)
                                Text(type.rawValue)
                                    .font(.caption.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? .orange.opacity(0.15) : Color(.tertiarySystemFill))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? .orange : .clear, lineWidth: 1.5)
                            )
                            .foregroundStyle(isSelected ? .orange : .primary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Damage Amount (%)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    TextField("20", text: $damagePercentText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)

                    Slider(value: Binding(
                        get: { damagePercent },
                        set: { damagePercentText = String(format: "%.0f", $0) }
                    ), in: 1...100, step: 5)
                    .tint(.orange)

                    Text("\(Int(damagePercent))%")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes (optional)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Additional details...", text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
        }
    }

    // MARK: - Save

    private var saveButton: some View {
        Button {
            if let existing = editingRecord {
                var updated = existing
                updated.polygonPoints = polygonPoints
                updated.date = damageDate
                updated.damageType = damageType
                updated.damagePercent = damagePercent
                updated.notes = notes
                store.updateDamageRecord(updated)
                Task { await damageRecordSync.syncForSelectedVineyard() }
            } else {
                let record = DamageRecord(
                    vineyardId: paddock.vineyardId,
                    paddockId: paddock.id,
                    polygonPoints: polygonPoints,
                    date: damageDate,
                    damageType: damageType,
                    damagePercent: damagePercent,
                    notes: notes
                )
                store.addDamageRecord(record)
                Task { await damageRecordSync.syncForSelectedVineyard() }
            }
            showConfirmation = true
        } label: {
            Label(editingRecord == nil ? "Save Damage Record" : "Update Damage Record", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(!isValid)
    }

    // MARK: - Helpers

    private func fitMapToPaddock() {
        let points = paddock.polygonPoints
        guard !points.isEmpty else { return }
        let minLat = points.map(\.latitude).min()!
        let maxLat = points.map(\.latitude).max()!
        let minLon = points.map(\.longitude).min()!
        let maxLon = points.map(\.longitude).max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.5 + 0.001,
            longitudeDelta: (maxLon - minLon) * 1.5 + 0.001
        )
        mapPosition = .region(MKCoordinateRegion(center: center, span: span))
    }
}

private struct DamageMidpointEdge: Sendable {
    let id: String
    let midpoint: CLLocationCoordinate2D
    let insertIndex: Int
}

private struct DamagePointHandle: View {
    let index: Int
    let isDragging: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isDragging ? .red : .orange)
                .frame(width: isDragging ? 30 : 24, height: isDragging ? 30 : 24)
                .overlay {
                    Circle().stroke(.white, lineWidth: 2)
                }
                .shadow(color: isDragging ? .red.opacity(0.5) : .black.opacity(0.3), radius: isDragging ? 8 : 4)
            Text("\(index + 1)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .animation(.snappy(duration: 0.15), value: isDragging)
    }
}

private struct DamageMidpointHandle: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.2), radius: 3)
            Image(systemName: "plus")
                .font(.caption2.bold())
                .foregroundStyle(.orange)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
}
