import SwiftUI
import MapKit
import CoreLocation

/// Creation / edit form for a Manual Issue: a focused form (title, optional
/// description, category, priority, assignee, due date) plus one of three
/// location scopes — tap a point on the map (with the established row
/// snapping), select rows/quarters, or flag a whole block.
///
/// A manual issue never asks for labour, cost, machinery, worker type or
/// Work Task data.
struct ManualIssueComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(ManualIssueSyncService.self) private var issueService

    /// Non-nil when editing an existing issue.
    let existing: ManualIssueRecord?

    @State private var title: String
    @State private var descriptionText: String
    @State private var category: ManualIssueCategory
    @State private var priority: ManualIssuePriority
    @State private var scope: ManualIssueLocationScope
    @State private var selectedPaddockId: UUID?
    @State private var assignedUserId: UUID?
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var members: [BackendVineyardMember] = []

    // Point scope
    @State private var tappedCoordinate: CLLocationCoordinate2D?
    @State private var pointSnap: ManualIssuePointSnap?

    // Row scope
    @State private var selectedSegments: Set<ManualIssueSegment>

    @State private var validationMessage: String?
    @State private var isSaving = false

    init(existing: ManualIssueRecord? = nil) {
        self.existing = existing
        _title = State(initialValue: existing?.title ?? "")
        _descriptionText = State(initialValue: existing?.description ?? "")
        _category = State(initialValue: existing?.categoryValue ?? ManualIssueContract.defaultCategory)
        _priority = State(initialValue: existing?.priorityValue ?? ManualIssueContract.defaultPriority)
        _scope = State(initialValue: existing?.scopeValue ?? .point)
        _selectedPaddockId = State(initialValue: existing?.paddockId)
        _assignedUserId = State(initialValue: existing?.assignedUserId)
        let existingDue = existing?.dueDate.flatMap { Self.dueDateFormatter.date(from: $0) }
        _hasDueDate = State(initialValue: existingDue != nil)
        _dueDate = State(initialValue: existingDue ?? Date())
        _selectedSegments = State(initialValue: Set(existing?.segments ?? []))
        if let existing, existing.scopeValue == .point,
           let lat = existing.latitude, let lon = existing.longitude {
            _tappedCoordinate = State(initialValue: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            if existing.snappedToRow == true, let sLat = existing.snappedLatitude, let sLon = existing.snappedLongitude {
                _pointSnap = State(initialValue: ManualIssuePointSnap(
                    paddockId: existing.paddockId,
                    rowPath: existing.drivingRowNumber,
                    rowNumber: existing.pinRowNumber,
                    snapped: CLLocationCoordinate2D(latitude: sLat, longitude: sLon),
                    distanceAlongMetres: existing.alongRowDistanceM
                ))
            }
        }
    }

    private static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private var selectedPaddock: Paddock? {
        store.paddocks.first { $0.id == selectedPaddockId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Issue") {
                    TextField("Title (required)", text: $title)
                    TextField("Description", text: $descriptionText, axis: .vertical)
                        .lineLimit(2...5)
                    Picker("Category", selection: $category) {
                        ForEach(ManualIssueCategory.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(ManualIssuePriority.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }

                Section("Assignment") {
                    Picker("Assign to", selection: $assignedUserId) {
                        Text("Unassigned").tag(UUID?.none)
                        ForEach(members) { member in
                            Text(member.displayName ?? "Member").tag(UUID?.some(member.userId))
                        }
                    }
                    Toggle("Due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    }
                }

                Section("Location") {
                    Picker("Applies to", selection: $scope) {
                        ForEach(ManualIssueLocationScope.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    // Changing the location type replaces the previous
                    // location data — a block issue keeps no stale snapping.
                    .onChange(of: scope) { _, _ in validationMessage = nil }

                    switch scope {
                    case .point:
                        pointPicker
                    case .row:
                        blockPicker
                        rowGrid
                    case .block:
                        blockPicker
                        if selectedPaddock != nil {
                            Label("The whole block will be flagged", systemImage: "square.dashed")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Manual Issue" : "Edit Manual Issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Save" : "Update") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
            .task { await loadMembers() }
        }
    }

    // MARK: - Point

    private var pointPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap the map to place the pin")
                .font(.footnote)
                .foregroundStyle(.secondary)
            MapReader { proxy in
                Map(initialPosition: .region(initialRegion)) {
                    if let tappedCoordinate {
                        Annotation("", coordinate: tappedCoordinate) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, .orange)
                        }
                    }
                    if let snapped = pointSnap?.snapped {
                        Annotation("", coordinate: snapped) {
                            Circle()
                                .fill(Color.orange.opacity(0.9))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                .mapStyle(.hybrid)
                .frame(height: 260)
                .clipShape(.rect(cornerRadius: 10))
                .onTapGesture { position in
                    if let coordinate = proxy.convert(position, from: .local) {
                        place(coordinate)
                    }
                }
            }
            if let pointSnap, let label = ManualIssueContract.attachedRowLabel(
                drivingRowNumber: pointSnap.rowPath,
                pinRowNumber: pointSnap.rowNumber,
                side: nil
            ) {
                Label(label, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if tappedCoordinate != nil {
                Label("Pin placed (not attached to a row)", systemImage: "mappin")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var initialRegion: MKCoordinateRegion {
        if let tappedCoordinate {
            return MKCoordinateRegion(
                center: tappedCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
            )
        }
        if let paddock = selectedPaddock ?? store.paddocks.first(where: { !$0.polygonPoints.isEmpty }) {
            return MKCoordinateRegion(
                center: paddock.polygonPoints.centroid,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            )
        }
        if let pin = store.pins.first {
            return MKCoordinateRegion(
                center: pin.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -34.9, longitude: 138.6),
            span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
        )
    }

    /// Place the pin and apply the same row-snapping behaviour used by the
    /// other VineTrack pins: keep the original tapped coordinates, and — when
    /// a mapped row is close enough — record the exact path-row value, the
    /// attached row, and the canonical snapped point.
    private func place(_ coordinate: CLLocationCoordinate2D) {
        tappedCoordinate = coordinate
        pointSnap = nil
        validationMessage = nil
        guard let paddock = RowGuidance.paddock(for: coordinate, in: store.paddocks) else { return }
        selectedPaddockId = paddock.id
        guard let match = RowGuidance.nearestRow(for: coordinate, in: paddock) else {
            pointSnap = ManualIssuePointSnap(paddockId: paddock.id, rowPath: nil, rowNumber: nil, snapped: nil, distanceAlongMetres: nil)
            return
        }
        // Same confidence rule as the manual pin editor: only attach when the
        // tap is within half a row width (min 3 m) of a row centreline.
        let threshold = max(3.0, paddock.rowWidth > 0 ? paddock.rowWidth : 3.0)
        guard match.distance <= threshold else {
            pointSnap = ManualIssuePointSnap(paddockId: paddock.id, rowPath: nil, rowNumber: nil, snapped: nil, distanceAlongMetres: nil)
            return
        }
        let rowNumber = Int(match.rowNumber.rounded())
        if let snapped = RowGuidance.snapToRow(coordinate: coordinate, rowNumber: rowNumber, in: paddock) {
            pointSnap = ManualIssuePointSnap(
                paddockId: paddock.id,
                rowPath: match.rowNumber,
                rowNumber: Double(rowNumber),
                snapped: snapped.snapped,
                distanceAlongMetres: snapped.distanceAlongMetres
            )
        } else {
            pointSnap = ManualIssuePointSnap(
                paddockId: paddock.id,
                rowPath: match.rowNumber,
                rowNumber: Double(rowNumber),
                snapped: nil,
                distanceAlongMetres: nil
            )
        }
    }

    // MARK: - Block / rows

    private var blockPicker: some View {
        Picker("Block", selection: $selectedPaddockId) {
            Text("Select a block").tag(UUID?.none)
            ForEach(store.paddocks) { paddock in
                Text(paddock.name).tag(UUID?.some(paddock.id))
            }
        }
        .onChange(of: selectedPaddockId) { _, _ in
            selectedSegments = []
            validationMessage = nil
        }
    }

    @ViewBuilder
    private var rowGrid: some View {
        if let paddock = selectedPaddock {
            let rows = paddock.rows.sorted { $0.number < $1.number }
            if rows.isEmpty {
                Label("This block has no mapped rows — flag the whole block instead", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if !selectedSegments.isEmpty {
                    Text(ManualIssueContract.rowSelectionSummary(Array(selectedSegments)))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                }
                ForEach(rows) { row in
                    rowLine(row)
                }
            }
        }
    }

    private func rowLine(_ row: PaddockRow) -> some View {
        HStack(spacing: 6) {
            Button {
                let all = (1...4).map { ManualIssueSegment(row: row.number, segment: $0) }
                if all.allSatisfy({ selectedSegments.contains($0) }) {
                    all.forEach { selectedSegments.remove($0) }
                } else {
                    all.forEach { selectedSegments.insert($0) }
                }
            } label: {
                Text("\(row.number)")
                    .font(.caption.weight(.semibold))
                    .frame(width: 34, height: 26)
                    .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            ForEach(1...4, id: \.self) { quarter in
                let segment = ManualIssueSegment(row: row.number, segment: quarter)
                let isSelected = selectedSegments.contains(segment)
                Button {
                    if isSelected {
                        selectedSegments.remove(segment)
                    } else {
                        selectedSegments.insert(segment)
                    }
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Color.orange : Color(.tertiarySystemBackground))
                        .frame(height: 26)
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Save

    private func loadMembers() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        do {
            members = try await SupabaseTeamRepository().listMembers(vineyardId: vineyardId)
        } catch {
            // Assignment stays optional — an unassigned issue is valid.
        }
    }

    /// Marker coordinate for the current scope: original tap for point, mean
    /// of segment midpoints for rows (block centroid fallback when the block
    /// has no geometry for a selected row), block centroid for block. The
    /// structured selection stays authoritative.
    private func markerCoordinate() -> (latitude: Double, longitude: Double)? {
        switch scope {
        case .point:
            guard let tappedCoordinate else { return nil }
            return (tappedCoordinate.latitude, tappedCoordinate.longitude)
        case .row:
            guard let paddock = selectedPaddock else { return nil }
            var rowLines: [Int: (start: (latitude: Double, longitude: Double), end: (latitude: Double, longitude: Double))] = [:]
            for row in paddock.rows {
                rowLines[row.number] = (
                    start: (row.startPoint.latitude, row.startPoint.longitude),
                    end: (row.endPoint.latitude, row.endPoint.longitude)
                )
            }
            if let marker = ManualIssueContract.markerCoordinate(segments: Array(selectedSegments), rowLines: rowLines) {
                return marker
            }
            return ManualIssueContract.blockCentroid(points: paddock.polygonPoints.map { ($0.latitude, $0.longitude) })
        case .block:
            guard let paddock = selectedPaddock else { return nil }
            return ManualIssueContract.blockCentroid(points: paddock.polygonPoints.map { ($0.latitude, $0.longitude) })
        }
    }

    private func save() async {
        let marker = markerCoordinate()
        let segments = scope == .row ? ManualIssueContract.canonicalSegments(Array(selectedSegments)) : []
        if let error = ManualIssueContract.validationError(
            title: title,
            scope: scope,
            latitude: marker?.latitude,
            longitude: marker?.longitude,
            paddockId: scope == .point ? (pointSnap?.paddockId ?? selectedPaddockId ?? UUID()) : selectedPaddockId,
            segments: segments
        ) {
            validationMessage = error
            return
        }
        guard let marker else {
            validationMessage = "A map location is required."
            return
        }
        isSaving = true
        defer { isSaving = false }

        issueService.store = store
        let stamp = ManualIssueTimestamp.now()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let due = hasDueDate ? Self.dueDateFormatter.string(from: dueDate) : nil
        let paddockId = scope == .point ? (pointSnap?.paddockId ?? selectedPaddockId) : selectedPaddockId

        if let existing {
            let params = ManualIssueUpdateParams(
                id: existing.id,
                title: trimmedTitle,
                locationScope: scope.rawValue,
                paddockId: paddockId,
                description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                category: category.rawValue,
                priority: priority.rawValue,
                latitude: marker.latitude,
                longitude: marker.longitude,
                snappedLatitude: scope == .point ? pointSnap?.snapped?.latitude : nil,
                snappedLongitude: scope == .point ? pointSnap?.snapped?.longitude : nil,
                drivingRowNumber: scope == .point ? pointSnap?.rowPath : nil,
                pinRowNumber: scope == .point ? pointSnap?.rowNumber : nil,
                pinSide: nil,
                alongRowDistanceM: scope == .point ? pointSnap?.distanceAlongMetres : nil,
                snappedToRow: scope == .point && pointSnap?.snapped != nil,
                assignedUserId: assignedUserId,
                dueDate: due,
                clientUpdatedAt: stamp,
                segments: scope == .row ? segments : nil
            )
            await issueService.update(params)
        } else {
            let vineyardId = store.selectedVineyardId ?? UUID()
            let params = ManualIssueCreateParams(
                id: UUID(),
                vineyardId: vineyardId,
                title: trimmedTitle,
                locationScope: scope.rawValue,
                paddockId: paddockId,
                description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                category: category.rawValue,
                priority: priority.rawValue,
                latitude: marker.latitude,
                longitude: marker.longitude,
                snappedLatitude: scope == .point ? pointSnap?.snapped?.latitude : nil,
                snappedLongitude: scope == .point ? pointSnap?.snapped?.longitude : nil,
                drivingRowNumber: scope == .point ? pointSnap?.rowPath : nil,
                pinRowNumber: scope == .point ? pointSnap?.rowNumber : nil,
                pinSide: nil,
                alongRowDistanceM: scope == .point ? pointSnap?.distanceAlongMetres : nil,
                snappedToRow: scope == .point && pointSnap?.snapped != nil,
                assignedUserId: assignedUserId,
                dueDate: due,
                clientUpdatedAt: stamp,
                segments: scope == .row ? segments : nil
            )
            await issueService.create(params)
        }
        if issueService.errorMessage != nil {
            validationMessage = issueService.errorMessage
            issueService.errorMessage = nil
            return
        }
        dismiss()
    }
}

/// Snapping result captured when the user taps a point on the map.
nonisolated struct ManualIssuePointSnap: Sendable {
    let paddockId: UUID?
    /// Exact path-row value (e.g. 19.5) — retained internally even though the
    /// customer-facing wording says the pin is "on" a row.
    let rowPath: Double?
    let rowNumber: Double?
    let snapped: CLLocationCoordinate2D?
    let distanceAlongMetres: Double?
}
