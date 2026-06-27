import SwiftUI
import MapKit
import CoreLocation

struct VineyardDetailsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @Environment(BackendAccessControl.self) private var accessControl

    @State private var selectedPaddock: Paddock? = nil
    @State private var soilProfilesByPaddockId: [UUID: BackendSoilProfile] = [:]

    private let soilProfileRepository: any SoilProfileRepositoryProtocol = SupabaseSoilProfileRepository()

    private var vineyard: Vineyard? { store.selectedVineyard }
    private var paddocks: [Paddock] { store.orderedPaddocks }
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var totalAreaHa: Double {
        paddocks.reduce(0) { $0 + $1.areaHectares }
    }

    private var totalVines: Int {
        paddocks.reduce(0) { $0 + $1.effectiveVineCount }
    }

    private var totalTrellisLength: Double {
        paddocks.reduce(0) { $0 + $1.effectiveTotalRowLength }
    }

    private var totalRows: Int {
        paddocks.reduce(0) { $0 + $1.rows.count }
    }

    private var openRepairPins: Int {
        store.pins.filter { $0.mode == .repairs && !$0.isCompleted }.count
    }

    private var growthPins: Int {
        store.pins.filter { $0.mode == .growth }.count
    }

    private var nonTemplateSprayCount: Int {
        store.sprayRecords.filter { !$0.isTemplate }.count
    }

    private var completedTripCount: Int {
        store.trips.filter { !$0.isActive }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                mapSection
                vineyardStatsSection
                blocksSection
                pinsOverviewSection
                seasonSummarySection
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(vineyard?.name ?? "Vineyard Details")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $selectedPaddock) { paddock in
            BlockDetailSheet(paddock: paddock)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: vineyard?.id) {
            await loadSoilProfiles()
        }
    }

    private func loadSoilProfiles() async {
        guard let vid = vineyard?.id else {
            soilProfilesByPaddockId = [:]
            return
        }
        do {
            let rows = try await soilProfileRepository.listVineyardSoilProfiles(vineyardId: vid)
            var map: [UUID: BackendSoilProfile] = [:]
            for row in rows {
                if let pid = row.paddockId {
                    map[pid] = row
                }
            }
            soilProfilesByPaddockId = map
        } catch {
            soilProfilesByPaddockId = [:]
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VineyardBlocksMiniMap(
                paddocks: paddocks,
                pins: store.pins,
                selectedPaddock: $selectedPaddock
            )

            HStack(spacing: 6) {
                Image(systemName: "hand.tap")
                    .font(.caption)
                Text("Tap a block for details")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Vineyard Stats

    private var vineyardStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vineyard Summary")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                statCard(label: "Total Area", value: fmt.formatArea(hectares: totalAreaHa), icon: "map", color: VineyardTheme.leafGreen)
                statCard(label: "Total Vines", value: formatLargeNumber(totalVines), icon: "leaf", color: VineyardTheme.olive)
                statCard(label: "Trellis Length", value: formatDistance(totalTrellisLength), icon: "ruler", color: VineyardTheme.earthBrown)
                statCard(label: "Total Rows", value: "\(totalRows)", icon: "line.3.horizontal", color: .blue)
            }
        }
    }

    private func statCard(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    // MARK: - Blocks

    private var blocksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(fmt.blockTermPluralCapitalised)
                .font(.headline)

            if paddocks.isEmpty {
                emptyCard(icon: "square.grid.2x2", title: "No \(fmt.blockTermPlural) configured", subtitle: "Set up \(fmt.blockTermPlural) in Vineyard Setup.")
            } else {
                ForEach(paddocks) { paddock in
                    Button {
                        selectedPaddock = paddock
                    } label: {
                        BlockInfoCard(paddock: paddock, soilProfile: soilProfilesByPaddockId[paddock.id])
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Pins Overview

    private var pinsOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pins by \(fmt.blockTermCapitalised)")
                .font(.headline)

            if store.pins.isEmpty {
                emptyCard(icon: "mappin", title: "No pins recorded", subtitle: nil)
            } else {
                ForEach(paddocks) { paddock in
                    let blockPins = store.pins.filter { $0.paddockId == paddock.id }
                    if !blockPins.isEmpty {
                        PinsSummaryCard(paddock: paddock, pins: blockPins)
                    }
                }

                let unassignedPins = store.pins.filter { $0.paddockId == nil }
                if !unassignedPins.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Unassigned")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 16) {
                            pinCategoryCount(label: "Repairs", count: unassignedPins.filter { $0.mode == .repairs }.count, color: .orange)
                            pinCategoryCount(label: "Growth", count: unassignedPins.filter { $0.mode == .growth }.count, color: VineyardTheme.leafGreen)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Season Summary

    private var seasonSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity")
                .font(.headline)

            VStack(spacing: 10) {
                summaryRow(icon: "sprinkler.and.droplets.fill", color: .purple, label: "Spray Records", value: "\(nonTemplateSprayCount)")
                summaryRow(icon: "road.lanes", color: .blue, label: "Completed Trips", value: "\(completedTripCount)")
                summaryRow(icon: "wrench.fill", color: .orange, label: "Open Repair Pins", value: "\(openRepairPins)")
                summaryRow(icon: "leaf.fill", color: VineyardTheme.leafGreen, label: "Growth Pins", value: "\(growthPins)")
            }
        }
    }

    private func summaryRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: .rect(cornerRadius: 10))

            Text(label)
                .font(.subheadline)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    // MARK: - Helpers

    private func emptyCard(icon: String, title: String, subtitle: String?) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 24)
            Spacer()
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func formatLargeNumber(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }
}

// MARK: - Mini Map

private struct VineyardBlocksMiniMap: View {
    let paddocks: [Paddock]
    let pins: [VinePin]
    @Binding var selectedPaddock: Paddock?
    @Environment(LocationService.self) private var locationService
    @Environment(NetworkMonitor.self) private var network

    @State private var position: MapCameraPosition = .automatic
    @State private var hasSetInitialPosition: Bool = false
    @State private var showFullScreen: Bool = false

    private var blockColors: [UUID: Color] {
        let palette: [Color] = [.blue, .green, .orange, .purple, .red, .cyan, .mint, .indigo, .pink, .teal, .yellow, .brown]
        var map: [UUID: Color] = [:]
        for (i, paddock) in paddocks.enumerated() {
            map[paddock.id] = palette[i % palette.count]
        }
        return map
    }

    private var offlineMap: some View {
        OfflineVineyardMapView(
            paddocks: paddocks.filter { $0.polygonPoints.count > 2 }.map { paddock in
                let color = blockColors[paddock.id] ?? .blue
                return OfflineVineyardMapView.Paddock(
                    id: paddock.id,
                    polygon: paddock.polygonPoints.map { $0.coordinate },
                    rows: paddock.rows.map { [$0.startPoint.coordinate, $0.endPoint.coordinate] },
                    strokeColor: color,
                    fillColor: color.opacity(0.25),
                    name: paddock.name
                )
            },
            pins: pins.map {
                OfflineVineyardMapView.Pin(
                    id: $0.id,
                    coordinate: $0.coordinate,
                    color: Color.fromString($0.buttonColor),
                    isCompleted: $0.isCompleted,
                    name: $0.buttonName
                )
            },
            userCoordinate: locationService.location?.coordinate
        )
        .clipShape(.rect(cornerRadius: 12))
    }

    private var hybridMap: some View {
            Map(position: $position) {
                ForEach(paddocks) { paddock in
                    if paddock.polygonPoints.count > 2 {
                        let color = blockColors[paddock.id] ?? .blue
                        MapPolygon(coordinates: paddock.polygonPoints.map { $0.coordinate })
                            .foregroundStyle(color.opacity(0.25))
                            .stroke(color, lineWidth: 2.5)

                        Annotation("", coordinate: paddock.polygonPoints.centroid) {
                            Button {
                                selectedPaddock = paddock
                            } label: {
                                Text(paddock.name)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(color.opacity(0.85), in: .rect(cornerRadius: 8))
                                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            }
                        }
                    }
                }

                UserAnnotation()
            }
            .mapStyle(.hybrid)
            .clipShape(.rect(cornerRadius: 12))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if network.isOnline {
                    hybridMap
                } else {
                    offlineMap
                }
            }

            if paddocks.contains(where: { $0.polygonPoints.count > 2 }) {
                Button {
                    showFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .padding(8)
            }
        }
        .frame(height: 280)
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenBlocksMap(
                paddocks: paddocks,
                blockColors: blockColors,
                onSelectPaddock: { selectedPaddock = $0 }
            )
        }
        .onAppear {
            fitInitialPosition()
        }
        .onChange(of: locationService.location) { _, newLocation in
            if !hasSetInitialPosition,
               let loc = newLocation,
               paddocks.allSatisfy({ $0.polygonPoints.count < 3 }) {
                position = .camera(MapCamera(centerCoordinate: loc.coordinate, distance: 1000))
                hasSetInitialPosition = true
            }
        }
    }

    private func fitInitialPosition() {
        let blocksWithBounds = paddocks.filter { $0.polygonPoints.count > 2 }
        guard !blocksWithBounds.isEmpty else {
            if let loc = locationService.location {
                position = .camera(MapCamera(centerCoordinate: loc.coordinate, distance: 1000))
                hasSetInitialPosition = true
            }
            return
        }
        let allPoints = paddocks.flatMap { $0.polygonPoints }
        guard !allPoints.isEmpty else { return }

        let minLat = allPoints.map(\.latitude).min()!
        let maxLat = allPoints.map(\.latitude).max()!
        let minLon = allPoints.map(\.longitude).min()!
        let maxLon = allPoints.map(\.longitude).max()!

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.4 + 0.001,
            longitudeDelta: (maxLon - minLon) * 1.4 + 0.001
        )
        position = .region(MKCoordinateRegion(center: center, span: span))
        hasSetInitialPosition = true
    }
}

private struct FullScreenBlocksMap: View {
    let paddocks: [Paddock]
    let blockColors: [UUID: Color]
    let onSelectPaddock: (Paddock) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(NetworkMonitor.self) private var network
    @State private var position: MapCameraPosition = .automatic

    private var offlineMap: some View {
        OfflineVineyardMapView(
            paddocks: paddocks.filter { $0.polygonPoints.count > 2 }.map { paddock in
                let color = blockColors[paddock.id] ?? .blue
                return OfflineVineyardMapView.Paddock(
                    id: paddock.id,
                    polygon: paddock.polygonPoints.map { $0.coordinate },
                    rows: paddock.rows.map { [$0.startPoint.coordinate, $0.endPoint.coordinate] },
                    strokeColor: color,
                    fillColor: color.opacity(0.25),
                    name: paddock.name
                )
            }
        )
    }

    private var hybridMap: some View {
            Map(position: $position) {
                ForEach(paddocks) { paddock in
                    if paddock.polygonPoints.count > 2 {
                        let color = blockColors[paddock.id] ?? .blue
                        MapPolygon(coordinates: paddock.polygonPoints.map { $0.coordinate })
                            .foregroundStyle(color.opacity(0.25))
                            .stroke(color, lineWidth: 2.5)

                        Annotation("", coordinate: paddock.polygonPoints.centroid) {
                            Button {
                                onSelectPaddock(paddock)
                                dismiss()
                            } label: {
                                Text(paddock.name)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(color.opacity(0.85), in: .rect(cornerRadius: 8))
                                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            }
                        }
                    }
                }
                UserAnnotation()
            }
            .mapStyle(.hybrid)
    }

    var body: some View {
        NavigationStack {
            Group {
                if network.isOnline {
                    hybridMap
                } else {
                    offlineMap
                }
            }
            .ignoresSafeArea()
            .navigationTitle("Blocks Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear { fitAllBlocks() }
        }
    }

    private func fitAllBlocks() {
        let allPoints = paddocks.flatMap { $0.polygonPoints }
        guard !allPoints.isEmpty else { return }
        let minLat = allPoints.map(\.latitude).min()!
        let maxLat = allPoints.map(\.latitude).max()!
        let minLon = allPoints.map(\.longitude).min()!
        let maxLon = allPoints.map(\.longitude).max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.4 + 0.001,
            longitudeDelta: (maxLon - minLon) * 1.4 + 0.001
        )
        position = .region(MKCoordinateRegion(center: center, span: span))
    }
}

// MARK: - Block Info Card

private struct BlockInfoCard: View {
    let paddock: Paddock
    let soilProfile: BackendSoilProfile?
    @Environment(MigratedDataStore.self) private var store
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var rowNumbers: [Int] {
        paddock.rows.map { $0.number }.sorted()
    }

    private var varietyLines: [VarietyAllocationFormatter.Line] {
        VarietyAllocationFormatter.lines(
            for: paddock.varietyAllocations,
            varieties: store.grapeVarieties
        )
    }

    private var soilTypeLabel: String? {
        if let texture = soilProfile?.soilTextureClass, !texture.isEmpty {
            return texture
        }
        if let typed = soilProfile?.typedSoilClass, typed != .unknown {
            return typed.fallbackLabel
        }
        if let asc = soilProfile?.australianSoilClassification, !asc.isEmpty {
            return asc
        }
        if let landscape = soilProfile?.soilLandscape, !landscape.isEmpty {
            return landscape
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                GrapeLeafIcon(size: 16)
                    .foregroundStyle(VineyardTheme.olive)
                Text(paddock.name)
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text(fmt.formatArea(hectares: paddock.areaHectares))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VineyardTheme.leafGreen)
            }

            if !varietyLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(varietyLines) { line in
                        Text(VarietyAllocationFormatter.compactLine(line))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                blockStat(label: "Vines", value: "\(paddock.effectiveVineCount)")
                blockStat(label: "Trellis", value: formatBlockDistance(paddock.effectiveTotalRowLength))
                blockStat(label: "Rows", value: "\(paddock.rows.count)")
            }

            if paddock.litresPerHour != nil || paddock.intermediatePostCount != nil {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    if let lph = paddock.litresPerHour {
                        blockStat(label: "Block Flow", value: "\(formatLitres(lph)) L/Hr")
                    }
                    if let posts = paddock.intermediatePostCount {
                        blockStat(label: "Int. Posts", value: "\(formatIntegerCount(posts))")
                    }
                }
            }

            if let first = rowNumbers.first, let last = rowNumbers.last, first != last {
                HStack(spacing: 4) {
                    Image(systemName: "number")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Rows \(first)–\(last)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .font(.caption2)
                    .foregroundStyle(VineyardTheme.earthBrown)
                Text("Soil Type")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(soilTypeLabel ?? "Not set")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(soilTypeLabel == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }

    private func blockStat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatBlockDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1fkm", meters / 1000)
        }
        return String(format: "%.0fm", meters)
    }

    private func formatLitres(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    private func formatIntegerCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Pins Summary Card

private struct PinsSummaryCard: View {
    let paddock: Paddock
    let pins: [VinePin]

    private var repairPins: [VinePin] { pins.filter { $0.mode == .repairs } }
    private var growthPins: [VinePin] { pins.filter { $0.mode == .growth } }
    private var unresolvedRepairs: Int { repairPins.filter { !$0.isCompleted }.count }
    private var completedRepairs: Int { repairPins.filter { $0.isCompleted }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                GrapeLeafIcon(size: 14)
                    .foregroundStyle(VineyardTheme.olive)
                Text(paddock.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(pins.count) pin\(pins.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                pinCategoryCount(label: "Repairs", count: repairPins.count, color: .orange)
                pinCategoryCount(label: "Growth", count: growthPins.count, color: VineyardTheme.leafGreen)
                if unresolvedRepairs > 0 {
                    pinCategoryCount(label: "Open", count: unresolvedRepairs, color: .red)
                }
                if completedRepairs > 0 {
                    pinCategoryCount(label: "Resolved", count: completedRepairs, color: .green)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }
}

private func pinCategoryCount(label: String, count: Int, color: Color) -> some View {
    HStack(spacing: 4) {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
        Text("\(count)")
            .font(.caption.weight(.semibold).monospacedDigit())
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Block Detail Sheet

private struct BlockDetailSheet: View {
    let paddock: Paddock
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var blockPins: [VinePin] {
        store.pins.filter { $0.paddockId == paddock.id }
    }

    private var blockTrips: [Trip] {
        store.trips.filter { !$0.isActive && $0.paddockIds.contains(paddock.id) }
    }

    private var varietyLines: [VarietyAllocationFormatter.Line] {
        VarietyAllocationFormatter.lines(
            for: paddock.varietyAllocations,
            varieties: store.grapeVarieties
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Overview") {
                    LabeledContent("Area", value: fmt.formatArea(hectares: paddock.areaHectares))
                    LabeledContent("Vines", value: "\(paddock.effectiveVineCount)")
                    LabeledContent("Trellis Length", value: String(format: "%.0f m", paddock.effectiveTotalRowLength))
                    LabeledContent("Rows", value: "\(paddock.rows.count)")
                    LabeledContent("Row Spacing", value: String(format: "%.1f m", paddock.rowWidth))
                    LabeledContent("Vine Spacing", value: String(format: "%.1f m", paddock.vineSpacing))
                }

                if paddock.intermediatePostSpacing != nil || paddock.intermediatePostCount != nil {
                    Section("Trellis") {
                        if let spacing = paddock.intermediatePostSpacing {
                            LabeledContent("Intermediate Post Spacing", value: String(format: "%.1f m", spacing))
                        }
                        if let posts = paddock.intermediatePostCount {
                            LabeledContent("Intermediate Posts", value: "\(posts)")
                        }
                    }
                }

                if paddock.flowPerEmitter != nil || paddock.emitterSpacing != nil {
                    Section("Irrigation") {
                        if let flow = paddock.flowPerEmitter {
                            LabeledContent("Emitter Rate", value: String(format: "%.1f L/hr", flow))
                        }
                        if let spacing = paddock.emitterSpacing {
                            LabeledContent("Emitter Spacing", value: String(format: "%.1f m", spacing))
                        }
                        if let totalEmitters = paddock.totalEmitters {
                            LabeledContent("Emitters", value: "\(totalEmitters)")
                        }
                        if let lVineHr = paddock.litresPerVinePerHour {
                            LabeledContent("L/Vine/Hr", value: String(format: "%.1f", lVineHr))
                        }
                        if let lph = paddock.litresPerHour {
                            LabeledContent("Block L/hr", value: String(format: "%.0f", lph))
                        }
                        if let lphha = paddock.litresPerHaPerHour {
                            LabeledContent("L/ha/hr", value: String(format: "%.0f", lphha))
                        }
                    }
                }

                Section("Pins") {
                    LabeledContent("Total Pins", value: "\(blockPins.count)")
                    LabeledContent("Repair Pins", value: "\(blockPins.filter { $0.mode == .repairs }.count)")
                    LabeledContent("Growth Pins", value: "\(blockPins.filter { $0.mode == .growth }.count)")
                    LabeledContent("Unresolved", value: "\(blockPins.filter { !$0.isCompleted && $0.mode == .repairs }.count)")
                }

                if !varietyLines.isEmpty {
                    Section("Varieties") {
                        ForEach(varietyLines) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(line.name ?? "Variety")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    if let pct = line.percentText {
                                        Text(pct)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(VineyardTheme.leafGreen)
                                    }
                                }
                                if let clone = line.clone {
                                    Text("Clone: \(clone)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let rootstock = line.rootstock {
                                    Text("Rootstock: \(rootstock)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Activity") {
                    LabeledContent("Trips", value: "\(blockTrips.count)")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(paddock.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
