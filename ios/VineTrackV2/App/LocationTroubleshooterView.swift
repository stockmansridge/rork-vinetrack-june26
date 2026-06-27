import SwiftUI
import CoreLocation
import UIKit

/// System Admin → Location Troubleshooter.
///
/// Diagnostic tool for GPS / vineyard / block / row alignment issues. Loads
/// every vineyard + paddock the admin can see (not just the currently
/// selected vineyard) and runs the same row-detection logic used in
/// production (`RowGuidance`) against the live GPS fix so a field
/// operator can confirm exactly what the app is "seeing" while
/// standing in a row/path.
///
/// Access is gated by `SystemAdminService.isSystemAdmin`; the menu row
/// in `BackendSettingsView` is only emitted for active platform admins.
struct LocationTroubleshooterView: View {
    @Environment(SystemAdminService.self) private var systemAdmin

    @State private var location = LocationService()
    @State private var isRunning: Bool = false
    @State private var isLoadingPaddocks: Bool = false
    @State private var loadError: String?
    @State private var loadErrorDetail: String?
    @State private var diagnosticLog: AdminGeometryDiagnosticLog?
    @State private var paddocks: [TroubleshooterPaddock] = []
    @State private var radius: LocationTroubleshooterRadius = .km50
    @State private var manualVineyardId: UUID?
    @State private var manualVineyardName: String?
    @State private var availableVineyards: [AdminVineyardRow] = []
    @State private var isLoadingVineyardList: Bool = false
    @State private var vineyardListError: String?
    @State private var isShowingVineyardPicker: Bool = false
    @State private var hasLoadedOnce: Bool = false
    @State private var samples: [DiagnosticSample] = []
    @State private var sessionStartedAt: Date?
    @State private var sessionEndedAt: Date?
    @State private var shareItems: [Any] = []
    @State private var isShowingShare: Bool = false

    var body: some View {
        Group {
            if !systemAdmin.isSystemAdmin {
                ContentUnavailableView(
                    "System admin required",
                    systemImage: "lock.shield",
                    description: Text("Only platform administrators can use the Location Troubleshooter.")
                )
            } else {
                content
            }
        }
        .navigationTitle("Row Location Troubleshooter")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPaddocksIfNeeded()
        }
        .sheet(isPresented: $isShowingShare) {
            ActivityShareSheet(activityItems: shareItems)
        }
        .sheet(isPresented: $isShowingVineyardPicker) {
            ManualVineyardPickerSheet(
                vineyards: availableVineyards,
                isLoading: isLoadingVineyardList,
                errorMessage: vineyardListError,
                onReload: { Task { await loadVineyardList(force: true) } },
                onPick: { row in
                    isShowingVineyardPicker = false
                    manualVineyardId = row.id
                    manualVineyardName = row.name
                    Task { await loadPaddocks(force: true) }
                }
            )
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Main content

    private var content: some View {
        List {
            controlSection
            radiusSection
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                    if let detail = loadErrorDetail {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            if diagnosticLog != nil {
                diagnosticLogSection
            }
            if isRunning {
                livePositionSection
                detectedLocationSection
                rowDiagnosisSection
                captureSection
            }
            if !samples.isEmpty {
                capturedPointsSection
            }
            if !samples.isEmpty || sessionStartedAt != nil {
                exportSection
            }
            adminScopeSection
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Sections

    private var controlSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { isRunning },
                set: { newValue in
                    if newValue { startTroubleshooter() } else { stopTroubleshooter() }
                }
            )) {
                Label(isRunning ? "Troubleshooter Running" : "Start Troubleshooter",
                      systemImage: isRunning ? "dot.radiowaves.left.and.right" : "location.viewfinder")
                    .font(.headline)
            }
            .tint(.purple)

            if isLoadingPaddocks {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loadingLabel).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(paddocks.count) usable blocks loaded across \(loadedVineyardCount) vineyards.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let log = diagnosticLog, log.paddocksWithoutGeometry > 0 {
                        Text("\(log.paddocksWithoutGeometry) blocks had missing geometry and were skipped.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let log = diagnosticLog, log.vineyardsSkipped > 0 {
                        Text("\(log.vineyardsSkipped) vineyards had missing or incomplete geometry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Diagnostic Session")
        } footer: {
            Text("Stand in the middle of a vineyard row or path, then capture a diagnostic point. Repeat in several rows to detect block-wide row-offset issues.")
        }
    }

    private var livePositionSection: some View {
        Section {
            if let loc = location.location {
                infoRow("Latitude", String(format: "%.6f", loc.coordinate.latitude))
                infoRow("Longitude", String(format: "%.6f", loc.coordinate.longitude))
                infoRow("Accuracy", String(format: "%.1f m (%@)", loc.horizontalAccuracy, accuracyLabel(loc.horizontalAccuracy)))
                if loc.verticalAccuracy >= 0 {
                    infoRow("Altitude", String(format: "%.1f m", loc.altitude))
                }
                if loc.speed >= 0 {
                    infoRow("Speed", String(format: "%.2f m/s", loc.speed))
                }
                if loc.course >= 0 {
                    infoRow("GPS course", String(format: "%.1f°", loc.course))
                }
                if let h = location.heading {
                    infoRow("Compass heading", String(format: "%.1f°", h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading))
                }
                infoRow("Timestamp", DiagnosticFormat.isoTimestamp(loc.timestamp))
            } else {
                Text("Waiting for GPS fix…").foregroundStyle(.secondary)
            }
        } header: {
            Text("Live Position")
        }
    }

    private var detectedLocationSection: some View {
        Section {
            if let interp = currentInterpretation {
                if let vName = interp.vineyardName {
                    infoRow("Vineyard", vName)
                    if let vid = interp.vineyardId { infoRow("Vineyard ID", vid.uuidString) }
                } else {
                    Text("No vineyard match found near current position.").foregroundStyle(.secondary)
                }
                if let bName = interp.blockName {
                    infoRow("Block / Paddock", bName)
                    if let bid = interp.blockId { infoRow("Block ID", bid.uuidString) }
                    infoRow("Inside boundary", interp.insideBlockBoundary ? "Yes" : "No")
                    if !interp.insideBlockBoundary, let d = interp.distanceToBlockEdgeM {
                        infoRow("Distance to block", String(format: "%.1f m", d))
                    }
                }
            } else {
                Text("Waiting for GPS fix…").foregroundStyle(.secondary)
            }
        } header: {
            Text("Detected Location")
        }
    }

    private var rowDiagnosisSection: some View {
        Section {
            if let interp = currentInterpretation, let row = interp.nearestRowNumber {
                infoRow("Closest row / path", DiagnosticFormat.rowLabel(row))
                if let off = interp.distanceFromRowCentreM {
                    let side = interp.detectedSide ?? "—"
                    infoRow("Offset from centre", String(format: "%.2f m (%@)", off, side))
                }
                if let s = interp.snappedLatitude, let sl = interp.snappedLongitude {
                    infoRow("Snapped position", String(format: "%.6f, %.6f", s, sl))
                }
                if let along = interp.alongRowDistanceM {
                    infoRow("Along-row distance", String(format: "%.1f m", along))
                }
                if let rh = interp.rowHeadingDegrees {
                    infoRow("Row heading", String(format: "%.1f°", rh))
                }
                if let dir = interp.interpretedDirection {
                    infoRow("Travel direction", dir)
                }
                if let hd = interp.headingDifferenceDegrees {
                    infoRow("Heading vs row", String(format: "%.1f°", hd))
                }
                if let suggestion = interp.suggestedCorrection {
                    Label(suggestion, systemImage: "arrow.left.and.right")
                        .font(.footnote)
                        .foregroundStyle(.blue)
                }
                Label(interp.confidenceLabel, systemImage: interp.confidenceIcon)
                    .font(.footnote)
                    .foregroundStyle(interp.confidenceColor)
            } else {
                Text("No row data yet.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Row Diagnosis")
        }
    }

    private var captureSection: some View {
        Section {
            Button {
                captureDiagnosticPoint()
            } label: {
                Label("Capture Diagnostic Point", systemImage: "scope")
                    .font(.headline)
            }
            .disabled(currentInterpretation == nil)
        } footer: {
            Text("Capture multiple points while standing in the middle of different rows. Points with GPS accuracy above 6 m are flagged as low-confidence.")
        }
    }

    private var capturedPointsSection: some View {
        Section {
            ForEach(Array(samples.enumerated()), id: \.element.id) { idx, sample in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Point \(idx + 1)").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(DiagnosticFormat.shortTime(sample.timestamp)).font(.caption).foregroundStyle(.secondary)
                    }
                    let row = sample.nearestRowNumber.map(DiagnosticFormat.rowLabel) ?? "—"
                    let offset: String = {
                        if let d = sample.distanceFromRowCentreM {
                            return String(format: "%.2f m %@", d, sample.detectedSide ?? "")
                        }
                        return "—"
                    }()
                    Text("Row \(row) · \(offset) · Acc \(String(format: "%.1f m", sample.horizontalAccuracyM))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let block = sample.detectedBlockName {
                        Text(block).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                samples.remove(atOffsets: offsets)
            }
        } header: {
            Text("Captured Points (\(samples.count))")
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                exportLog()
            } label: {
                Label("Export Troubleshooter Log", systemImage: "square.and.arrow.up")
            }
            .disabled(samples.isEmpty)

            Button(role: .destructive) {
                clearSession()
            } label: {
                Label("Clear Session", systemImage: "trash")
            }
        }
    }

    private var radiusSection: some View {
        Section {
            Picker("Search radius", selection: $radius) {
                ForEach(LocationTroubleshooterRadius.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .onChange(of: radius) { _, _ in
                Task { await loadPaddocks(force: true) }
            }
            if radius != .all {
                if let coord = diagnosticLog?.filterCenter {
                    Text(String(format: "Filter centre: %.5f, %.5f", coord.latitude, coord.longitude))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                } else if location.location == nil {
                    Text("Waiting for GPS fix to filter nearby vineyards…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await loadPaddocks(force: true) }
            } label: {
                Label("Retry location & reload", systemImage: "location.circle")
                    .font(.footnote)
            }
        } header: {
            Text("Geometry Scope")
        } footer: {
            Text("Nearby filtering uses your current GPS location and each block's polygon centroid. Choose \"All vineyards\" only if you need the full admin scope.")
        }
    }

    private var loadingLabel: String {
        if radius == .all {
            return "Loading all vineyards & blocks…"
        }
        return "Loading nearby vineyard geometry within \(radius.kmLabel)…"
    }

    private var adminScopeSection: some View {
        Section {
            HStack {
                Text("Vineyards loaded")
                Spacer()
                Text("\(loadedVineyardCount)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Blocks loaded")
                Spacer()
                Text("\(paddocks.count)").foregroundStyle(.secondary)
            }
            Button {
                Task { await loadPaddocks(force: true) }
            } label: {
                Label("Reload admin geometry", systemImage: "arrow.clockwise")
            }
        } header: {
            Text("Admin Scope")
        } footer: {
            Text("Diagnostic-only: this screen evaluates against every vineyard the admin can access, not the currently selected vineyard.")
        }
    }

    // MARK: - Lifecycle

    private func startTroubleshooter() {
        if location.authorizationStatus == .notDetermined {
            location.requestPermission()
        }
        location.startUpdating()
        sessionStartedAt = sessionStartedAt ?? Date()
        sessionEndedAt = nil
        isRunning = true
        Task { await loadPaddocksIfNeeded() }
    }

    private func stopTroubleshooter() {
        location.stopUpdating()
        sessionEndedAt = Date()
        isRunning = false
    }

    private func loadPaddocksIfNeeded() async {
        guard !hasLoadedOnce else { return }
        await loadPaddocks(force: false)
    }

    private func loadPaddocks(force: Bool) async {
        guard systemAdmin.isSystemAdmin else { return }
        if isLoadingPaddocks { return }

        let isManual: Bool = manualVineyardId != nil

        // Acquire a GPS fix first if we need one for radius filtering.
        var filterCoord: CLLocationCoordinate2D?
        var filterAccuracy: Double?
        if !isManual, let radiusMeters = radius.meters {
            if location.authorizationStatus == .notDetermined {
                location.requestPermission()
            }
            location.startUpdating()
            let start = Date()
            while location.location == nil && Date().timeIntervalSince(start) < 6 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let loc = location.location else {
                loadError = "Current location is needed to load nearby vineyard geometry."
                loadErrorDetail = "Tap \"Retry location & reload\" once a GPS fix is available, or switch the search radius to \"All vineyards\"."
                paddocks = []
                hasLoadedOnce = true
                _ = radiusMeters
                return
            }
            filterCoord = loc.coordinate
            filterAccuracy = loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
        }

        isLoadingPaddocks = true
        loadError = nil
        loadErrorDetail = nil
        defer {
            isLoadingPaddocks = false
            hasLoadedOnce = true
        }
        let repo = SupabaseAdminRepository()
        let startedAt = Date()
        do {
            let result = try await repo.fetchAllPaddocksDiagnostic()

            // Apply radius filter (client-side, on polygon centroid).
            let unfilteredRows = result.rows
            let vineyardsBefore = Set(unfilteredRows.map { $0.paddock.vineyardId }).count
            let paddocksBefore = unfilteredRows.count
            let filteredRows: [(vineyard: AdminVineyardRow, paddock: AdminVineyardPaddockRow)]
            if let manualId = manualVineyardId {
                filteredRows = unfilteredRows.filter { $0.paddock.vineyardId == manualId }
            } else if let radiusMeters = radius.meters, let centre = filterCoord {
                filteredRows = unfilteredRows.filter { entry in
                    guard let c = paddockCentre(entry.paddock) else { return false }
                    return RowGuidance.metresBetween(c, centre) <= radiusMeters
                }
            } else {
                filteredRows = unfilteredRows
            }
            let mapped = filteredRows.compactMap {
                TroubleshooterPaddock(vineyard: $0.vineyard, paddock: $0.paddock)
            }
            paddocks = mapped
            let vineyardsAfter = Set(mapped.map { $0.vineyardId }).count
            let rowsAfter = mapped.reduce(0) { $0 + $1.paddock.rows.count }
            diagnosticLog = AdminGeometryDiagnosticLog(
                startedAt: startedAt,
                finishedAt: Date(),
                userIdDescription: SupabaseAuthRepository().currentUserId?.uuidString ?? "(not signed in)",
                isSystemAdmin: systemAdmin.isSystemAdmin,
                rpcName: "admin_list_vineyards + admin_list_vineyard_paddocks",
                vineyardsReturned: result.vineyardsReturned,
                vineyardsAttempted: result.vineyardsAttempted,
                vineyardsSucceeded: result.vineyardsSucceeded,
                vineyardsUsable: vineyardsAfter,
                uniqueVineyardIdsInPaddockData: result.uniqueVineyardIdsInPaddockData,
                uniqueVineyardIdsInSkippedPaddocks: result.uniqueVineyardIdsInSkippedPaddocks,
                paddockVineyardsNotInVineyardRPC: result.paddockVineyardsNotInVineyardRPC,
                paddocksReturned: result.paddocksReturned,
                paddocksUsable: mapped.count,
                rowsReturned: result.rowsReturned,
                rowsUsable: rowsAfter,
                paddocksWithoutGeometry: result.paddocksWithoutGeometry,
                skippedRows: result.totalSkippedRows,
                skippedPolygonPoints: result.totalSkippedPolygonPoints,
                filterRadiusLabel: isManual ? "(manual)" : radius.kmLabel,
                filterModeLabel: filterModeLabelText(isManual: isManual),
                filterCenter: filterCoord,
                filterAccuracyM: filterAccuracy,
                vineyardsBeforeFilter: vineyardsBefore,
                vineyardsAfterFilter: vineyardsAfter,
                paddocksBeforeFilter: paddocksBefore,
                paddocksAfterFilter: mapped.count,
                rowsAfterFilter: rowsAfter,
                samplePaddockSummaries: mapped.prefix(5).map {
                    "\($0.vineyardName) / \($0.paddock.name) [\($0.paddock.id.uuidString.prefix(8))]"
                },
                vineyardErrors: result.vineyardErrors.map { "\($0.vineyardName): \($0.message)" },
                skippedPaddocks: result.skippedPaddocks.map {
                    AdminGeometryDiagnosticLog.SkippedPaddock(
                        vineyardName: $0.vineyardName,
                        vineyardId: $0.vineyardId,
                        paddockName: $0.paddockName,
                        paddockId: $0.paddockId,
                        reason: $0.reason
                    )
                }
            )
            if mapped.isEmpty && !result.vineyardErrors.isEmpty {
                loadError = "Location Troubleshooter could not load vineyard geometry. Some block or row geometry may be missing or in an unexpected format."
                loadErrorDetail = diagnosticErrorDetail(result: result)
            } else if !result.vineyardErrors.isEmpty || result.totalSkippedRows > 0 || result.totalSkippedPolygonPoints > 0 || result.paddocksWithoutGeometry > 0 {
                loadError = "Some records were skipped — see diagnostic log below for details."
            }
        } catch {
            paddocks = []
            diagnosticLog = AdminGeometryDiagnosticLog(
                startedAt: startedAt,
                finishedAt: Date(),
                userIdDescription: SupabaseAuthRepository().currentUserId?.uuidString ?? "(not signed in)",
                isSystemAdmin: systemAdmin.isSystemAdmin,
                rpcName: "admin_list_vineyards",
                vineyardsReturned: 0,
                vineyardsAttempted: 0,
                vineyardsSucceeded: 0,
                vineyardsUsable: 0,
                uniqueVineyardIdsInPaddockData: 0,
                uniqueVineyardIdsInSkippedPaddocks: 0,
                paddockVineyardsNotInVineyardRPC: 0,
                paddocksReturned: 0,
                paddocksUsable: 0,
                rowsReturned: 0,
                rowsUsable: 0,
                paddocksWithoutGeometry: 0,
                skippedRows: 0,
                skippedPolygonPoints: 0,
                filterRadiusLabel: isManual ? "(manual)" : radius.kmLabel,
                filterModeLabel: filterModeLabelText(isManual: isManual),
                filterCenter: filterCoord,
                filterAccuracyM: filterAccuracy,
                vineyardsBeforeFilter: 0,
                vineyardsAfterFilter: 0,
                paddocksBeforeFilter: 0,
                paddocksAfterFilter: 0,
                rowsAfterFilter: 0,
                samplePaddockSummaries: [],
                vineyardErrors: ["(initial vineyard list): \(error.localizedDescription)"],
                skippedPaddocks: []
            )
            loadError = "Location Troubleshooter could not load vineyard geometry. Some block or row geometry may be missing or in an unexpected format."
            loadErrorDetail = diagnosticDescription(for: error)
        }
    }

    private func diagnosticErrorDetail(result: AdminGeometryLoadResult) -> String {
        var parts: [String] = []
        parts.append("vineyards returned: \(result.vineyardsReturned)")
        parts.append("vineyards attempted: \(result.vineyardsAttempted)")
        parts.append("succeeded: \(result.vineyardsSucceeded)")
        parts.append("errors: \(result.vineyardErrors.count)")
        if let first = result.vineyardErrors.first {
            parts.append("first: \(first.vineyardName) — \(first.message)")
        }
        return parts.joined(separator: "\n")
    }

    private func diagnosticDescription(for error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, let ctx):
                return "decoding: keyNotFound \(key.stringValue) at \(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))"
            case .valueNotFound(let type, let ctx):
                return "decoding: valueNotFound \(type) at \(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))"
            case .typeMismatch(let type, let ctx):
                return "decoding: typeMismatch \(type) at \(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))"
            case .dataCorrupted(let ctx):
                return "decoding: dataCorrupted at \(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))"
            @unknown default:
                return "decoding: \(decoding)"
            }
        }
        return String(describing: error)
    }

    private var diagnosticLogSection: some View {
        Section {
            if let log = diagnosticLog {
                Text(log.renderedText)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = log.renderedText
                } label: {
                    Label("Copy diagnostic log", systemImage: "doc.on.doc")
                }
            }
        } header: {
            Text("Diagnostic Log")
        } footer: {
            Text("Tap to copy. Share this with the VineTrack team when reporting row-alignment or geometry issues.")
        }
    }

    private func clearSession() {
        samples = []
        sessionStartedAt = nil
        sessionEndedAt = nil
    }

    // MARK: - Live interpretation

    private var currentInterpretation: LiveInterpretation? {
        guard let loc = location.location else { return nil }
        return LocationTroubleshooterEngine.interpret(
            location: loc,
            heading: location.heading,
            paddocks: paddocks
        )
    }

    private var uniqueVineyardCount: Int {
        Set(paddocks.map { $0.vineyardId }).count
    }

    /// Centroid for radius filtering — prefers the polygon centroid; falls
    /// back to the midpoint of the first row when the polygon is empty.
    private func paddockCentre(_ p: AdminVineyardPaddockRow) -> CLLocationCoordinate2D? {
        if !p.polygonPoints.isEmpty {
            return RowGuidance.polygonCentroid(p.polygonPoints.map { $0.coordinate })
        }
        if let r = p.rows.first {
            let s = r.startPoint.coordinate
            let e = r.endPoint.coordinate
            return CLLocationCoordinate2D(
                latitude: (s.latitude + e.latitude) / 2,
                longitude: (s.longitude + e.longitude) / 2
            )
        }
        return nil
    }

    /// Single source of truth for the vineyard count shown on the screen.
    /// Prefers the diagnostic log's `vineyardsUsable` (distinct vineyards in
    /// the usable paddock set) when available so the main summary and the
    /// warning never disagree.
    private var loadedVineyardCount: Int {
        diagnosticLog?.vineyardsUsable ?? uniqueVineyardCount
    }

    // MARK: - Capture

    private func captureDiagnosticPoint() {
        guard let loc = location.location else { return }
        let interp = LocationTroubleshooterEngine.interpret(
            location: loc,
            heading: location.heading,
            paddocks: paddocks
        )
        let sample = DiagnosticSample(
            id: UUID(),
            timestamp: loc.timestamp,
            latitude: loc.coordinate.latitude,
            longitude: loc.coordinate.longitude,
            horizontalAccuracyM: loc.horizontalAccuracy,
            altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
            speedMps: loc.speed >= 0 ? loc.speed : nil,
            gpsCourseDegrees: loc.course >= 0 ? loc.course : nil,
            compassHeadingDegrees: location.heading.map { $0.trueHeading >= 0 ? $0.trueHeading : $0.magneticHeading },
            detectedVineyardId: interp?.vineyardId,
            detectedVineyardName: interp?.vineyardName,
            detectedBlockId: interp?.blockId,
            detectedBlockName: interp?.blockName,
            insideBlockBoundary: interp?.insideBlockBoundary ?? false,
            nearestRowNumber: interp?.nearestRowNumber,
            snappedLatitude: interp?.snappedLatitude,
            snappedLongitude: interp?.snappedLongitude,
            distanceFromRowCentreM: interp?.distanceFromRowCentreM,
            alongRowDistanceM: interp?.alongRowDistanceM,
            detectedSide: interp?.detectedSide,
            interpretedDirection: interp?.interpretedDirection,
            rowHeadingDegrees: interp?.rowHeadingDegrees,
            headingDifferenceDegrees: interp?.headingDifferenceDegrees,
            confidence: interp?.confidence ?? .low,
            diagnosticNotes: interp?.suggestedCorrection
        )
        samples.append(sample)
    }

    // MARK: - Export

    private func exportLog() {
        let session = DiagnosticSession(
            sessionStartedAt: sessionStartedAt ?? Date(),
            sessionEndedAt: sessionEndedAt ?? Date(),
            appVersion: AppBuildInfo.displayVersion,
            deviceModel: AppBuildInfo.deviceModel,
            iosVersion: AppBuildInfo.iosVersion,
            vineyardCountAvailableToAdmin: uniqueVineyardCount,
            sampleCount: samples.count,
            samples: samples
        )
        var items: [Any] = []
        if let jsonURL = try? writeJSON(session: session) { items.append(jsonURL) }
        if let txtURL = try? writeTXT(session: session) { items.append(txtURL) }
        guard !items.isEmpty else { return }
        shareItems = items
        isShowingShare = true
    }

    private func writeJSON(session: DiagnosticSession) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("location-troubleshooter-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func writeTXT(session: DiagnosticSession) throws -> URL {
        let txt = DiagnosticReport.render(session: session)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("location-troubleshooter-\(Int(Date().timeIntervalSince1970)).txt")
        try txt.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Helpers

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func filterModeLabelText(isManual: Bool) -> String {
        if isManual { return "manual vineyard" }
        return radius == .all ? "all" : "nearby (client-side)"
    }

    private var shouldShowNoNearbyResults: Bool {
        hasLoadedOnce
            && !isLoadingPaddocks
            && paddocks.isEmpty
            && manualVineyardId == nil
            && radius != .all
            && loadError == nil
            && (diagnosticLog?.vineyardsBeforeFilter ?? 0) > 0
    }

    private var noNearbyResultsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("No vineyards within \(radius.kmLabel)", systemImage: "location.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("No vineyards were found within \(radius.kmLabel) of your current location. Choose a wider radius, load every vineyard, or pick a vineyard manually.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if radius != .km100 {
                Button {
                    radius = .km100
                } label: {
                    Label("Increase radius to 100 km", systemImage: "plus.magnifyingglass")
                }
            }
            if radius != .km250 {
                Button {
                    radius = .km250
                } label: {
                    Label("Increase radius to 250 km", systemImage: "plus.magnifyingglass")
                }
            }
            Button {
                radius = .all
            } label: {
                Label("Load all vineyards", systemImage: "globe")
            }
            Button {
                openManualVineyardPicker()
            } label: {
                Label("Select vineyard manually", systemImage: "list.bullet.rectangle")
            }
        } header: {
            Text("No Nearby Results")
        }
    }

    private var manualVineyardSection: some View {
        Section {
            if let name = manualVineyardName, manualVineyardId != nil {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manual vineyard").font(.caption).foregroundStyle(.secondary)
                        Text(name).font(.callout.weight(.semibold))
                    }
                    Spacer()
                    Button(role: .destructive) {
                        clearManualVineyard()
                    } label: {
                        Text("Clear")
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    openManualVineyardPicker()
                } label: {
                    Label("Choose a different vineyard", systemImage: "arrow.left.arrow.right")
                }
            } else {
                Button {
                    openManualVineyardPicker()
                } label: {
                    Label("Select vineyard manually", systemImage: "list.bullet.rectangle")
                }
            }
        } header: {
            Text("Manual Vineyard")
        } footer: {
            Text("Override the nearby filter and load geometry for a specific vineyard. Useful when testing remotely or inspecting a site without standing on it.")
        }
    }

    private func openManualVineyardPicker() {
        isShowingVineyardPicker = true
        if availableVineyards.isEmpty {
            Task { await loadVineyardList(force: false) }
        }
    }

    private func clearManualVineyard() {
        manualVineyardId = nil
        manualVineyardName = nil
        Task { await loadPaddocks(force: true) }
    }

    private func loadVineyardList(force: Bool) async {
        if isLoadingVineyardList { return }
        if !force && !availableVineyards.isEmpty { return }
        isLoadingVineyardList = true
        vineyardListError = nil
        defer { isLoadingVineyardList = false }
        let repo = SupabaseAdminRepository()
        do {
            let rows = try await repo.fetchAllVineyards()
                .filter { $0.deletedAt == nil }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
            availableVineyards = rows
        } catch {
            vineyardListError = error.localizedDescription
        }
    }

    private func accuracyLabel(_ acc: Double) -> String {
        if acc < 0 { return "invalid" }
        switch acc {
        case ..<2: return "Excellent"
        case ..<4: return "Good"
        case ..<6: return "Acceptable"
        default: return "Poor"
        }
    }
}

// MARK: - Radius

enum LocationTroubleshooterRadius: String, CaseIterable, Identifiable {
    case km50
    case km100
    case km250
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .km50: return "Nearby — 50 km"
        case .km100: return "100 km"
        case .km250: return "250 km"
        case .all: return "All vineyards"
        }
    }

    var kmLabel: String {
        switch self {
        case .km50: return "50 km"
        case .km100: return "100 km"
        case .km250: return "250 km"
        case .all: return "all"
        }
    }

    /// Filter radius in metres, or `nil` to disable filtering.
    var meters: Double? {
        switch self {
        case .km50: return 50_000
        case .km100: return 100_000
        case .km250: return 250_000
        case .all: return nil
        }
    }
}

// MARK: - Models

/// In-memory paddock view used by the troubleshooter. We carry the
/// vineyard name + a synthetic `Paddock` so we can reuse `RowGuidance`
/// directly without changing production code.
private struct TroubleshooterPaddock: Identifiable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let vineyardName: String
    let paddock: Paddock

    init?(vineyard: AdminVineyardRow, paddock row: AdminVineyardPaddockRow) {
        guard !row.polygonPoints.isEmpty || !row.rows.isEmpty else { return nil }
        self.id = row.id
        self.vineyardId = row.vineyardId
        self.vineyardName = vineyard.name
        self.paddock = Paddock(
            id: row.id,
            vineyardId: row.vineyardId,
            name: row.name,
            polygonPoints: row.polygonPoints,
            rows: row.rows,
            rowDirection: row.rowDirection ?? 0,
            rowWidth: row.rowWidth ?? 2.5,
            rowOffset: 0,
            vineSpacing: row.vineSpacing ?? 1.0
        )
    }
}

private enum DiagnosticConfidence: String, Codable {
    case high
    case medium
    case low
}

private struct LiveInterpretation {
    let vineyardId: UUID?
    let vineyardName: String?
    let blockId: UUID?
    let blockName: String?
    let insideBlockBoundary: Bool
    let distanceToBlockEdgeM: Double?
    let nearestRowNumber: Double?
    let snappedLatitude: Double?
    let snappedLongitude: Double?
    let distanceFromRowCentreM: Double?
    let alongRowDistanceM: Double?
    let detectedSide: String?
    let interpretedDirection: String?
    let rowHeadingDegrees: Double?
    let headingDifferenceDegrees: Double?
    let confidence: DiagnosticConfidence
    let suggestedCorrection: String?

    var confidenceLabel: String {
        switch confidence {
        case .high: return "Confidence: high"
        case .medium: return "Confidence: medium"
        case .low: return "Confidence: low — GPS accuracy too poor to trust row offset"
        }
    }
    var confidenceIcon: String {
        switch confidence {
        case .high: return "checkmark.seal.fill"
        case .medium: return "exclamationmark.circle"
        case .low: return "exclamationmark.triangle.fill"
        }
    }
    var confidenceColor: Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}

private struct DiagnosticSample: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyM: Double
    let altitude: Double?
    let speedMps: Double?
    let gpsCourseDegrees: Double?
    let compassHeadingDegrees: Double?
    let detectedVineyardId: UUID?
    let detectedVineyardName: String?
    let detectedBlockId: UUID?
    let detectedBlockName: String?
    let insideBlockBoundary: Bool
    let nearestRowNumber: Double?
    let snappedLatitude: Double?
    let snappedLongitude: Double?
    let distanceFromRowCentreM: Double?
    let alongRowDistanceM: Double?
    let detectedSide: String?
    let interpretedDirection: String?
    let rowHeadingDegrees: Double?
    let headingDifferenceDegrees: Double?
    let confidence: DiagnosticConfidence
    let diagnosticNotes: String?
}

/// Plain diagnostic log surfaced in the System Admin Location Troubleshooter
/// so admins can copy / share what the geometry load actually saw.
private struct AdminGeometryDiagnosticLog {
    struct SkippedPaddock {
        let vineyardName: String
        let vineyardId: UUID
        let paddockName: String
        let paddockId: UUID
        let reason: String
    }

    let startedAt: Date
    let finishedAt: Date
    let userIdDescription: String
    let isSystemAdmin: Bool
    let rpcName: String
    let vineyardsReturned: Int
    let vineyardsAttempted: Int
    let vineyardsSucceeded: Int
    let vineyardsUsable: Int
    let uniqueVineyardIdsInPaddockData: Int
    let uniqueVineyardIdsInSkippedPaddocks: Int
    let paddockVineyardsNotInVineyardRPC: Int
    let paddocksReturned: Int
    let paddocksUsable: Int
    let rowsReturned: Int
    let rowsUsable: Int
    let paddocksWithoutGeometry: Int
    let skippedRows: Int
    let skippedPolygonPoints: Int
    let filterRadiusLabel: String
    let filterModeLabel: String
    let filterCenter: CLLocationCoordinate2D?
    let filterAccuracyM: Double?
    let vineyardsBeforeFilter: Int
    let vineyardsAfterFilter: Int
    let paddocksBeforeFilter: Int
    let paddocksAfterFilter: Int
    let rowsAfterFilter: Int
    let samplePaddockSummaries: [String]
    let vineyardErrors: [String]
    let skippedPaddocks: [SkippedPaddock]

    /// Vineyards we attempted to load but whose paddock RPC failed.
    var vineyardsFailedRpc: Int { max(0, vineyardsAttempted - vineyardsSucceeded) }
    /// Vineyards returned by the vineyard RPC that did not yield any usable
    /// geometry — either the RPC failed or every paddock was skipped.
    var vineyardsSkipped: Int { max(0, vineyardsReturned - vineyardsUsable) }

    var renderedText: String {
        var lines: [String] = []
        lines.append("VineTrack Admin Geometry Diagnostic")
        lines.append("Started:  \(DiagnosticFormat.isoTimestamp(startedAt))")
        lines.append("Finished: \(DiagnosticFormat.isoTimestamp(finishedAt))")
        lines.append("User:     \(userIdDescription)")
        lines.append("Admin:    \(isSystemAdmin ? "yes" : "no")")
        lines.append("")
        lines.append("RPC source:")
        lines.append("  \(rpcName)")
        lines.append("")
        lines.append("Location filter:")
        if let c = filterCenter {
            lines.append(String(format: "  Current location:        %.6f, %.6f", c.latitude, c.longitude))
        } else {
            lines.append("  Current location:        (none — radius=all or no GPS fix)")
        }
        if let acc = filterAccuracyM {
            lines.append(String(format: "  Accuracy:                %.1f m", acc))
        } else {
            lines.append("  Accuracy:                —")
        }
        lines.append("  Radius:                  \(filterRadiusLabel)")
        lines.append("  Filter mode:             \(filterModeLabel)")
        lines.append("  Vineyards before filter: \(vineyardsBeforeFilter)")
        lines.append("  Vineyards after filter:  \(vineyardsAfterFilter)")
        lines.append("  Paddocks before filter:  \(paddocksBeforeFilter)")
        lines.append("  Paddocks after filter:   \(paddocksAfterFilter)")
        lines.append("  Rows after filter:       \(rowsAfterFilter)")
        lines.append("")
        lines.append("Returned:")
        lines.append("  Vineyard records returned:           \(vineyardsReturned)")
        lines.append("  Unique vineyard IDs in paddock data: \(uniqueVineyardIdsInPaddockData)")
        lines.append("  Paddocks returned:                   \(paddocksReturned)")
        lines.append("  Rows returned:                       \(rowsReturned)")
        if paddockVineyardsNotInVineyardRPC > 0 {
            lines.append("  Paddocks referenced additional vineyards not returned by vineyard RPC: \(paddockVineyardsNotInVineyardRPC)")
        }
        lines.append("")
        lines.append("Usable:")
        lines.append("  Unique vineyards with usable geometry: \(vineyardsUsable)")
        lines.append("  Paddocks usable:                       \(paddocksUsable)")
        lines.append("  Rows usable:                           \(rowsUsable)")
        lines.append("")
        lines.append("Skipped:")
        lines.append("  Vineyards skipped:                     \(vineyardsSkipped) (\(vineyardsSucceeded)/\(vineyardsAttempted) vineyard RPC calls succeeded)")
        lines.append("  Unique vineyards in skipped paddocks:  \(uniqueVineyardIdsInSkippedPaddocks)")
        lines.append("  Paddocks with empty geometry:          \(paddocksWithoutGeometry)")
        lines.append("  Invalid polygon vertices skipped:      \(skippedPolygonPoints)")
        lines.append("  Rows skipped:                          \(skippedRows)")

        if !skippedPaddocks.isEmpty {
            lines.append("")
            lines.append("Skipped records:")
            for s in skippedPaddocks {
                let vidShort = s.vineyardId.uuidString.prefix(8)
                let pidShort = s.paddockId.uuidString.prefix(8)
                lines.append("  • \(s.vineyardName) [\(vidShort)] / \(s.paddockName) [\(pidShort)] — \(s.reason)")
            }
        }
        if !samplePaddockSummaries.isEmpty {
            lines.append("")
            lines.append("Sample usable paddocks:")
            for s in samplePaddockSummaries { lines.append("  • \(s)") }
        }
        if !vineyardErrors.isEmpty {
            lines.append("")
            lines.append("Per-vineyard errors:")
            for e in vineyardErrors { lines.append("  • \(e)") }
        }
        return lines.joined(separator: "\n")
    }
}

private struct DiagnosticSession: Codable {
    let sessionStartedAt: Date
    let sessionEndedAt: Date
    let appVersion: String
    let deviceModel: String
    let iosVersion: String
    let vineyardCountAvailableToAdmin: Int
    let sampleCount: Int
    let samples: [DiagnosticSample]
}

// MARK: - Engine

/// All diagnostic-only math. Production row snapping still goes through
/// `RowGuidance` directly; this engine just calls into it and augments
/// the result with side/direction/offset suggestions.
private enum LocationTroubleshooterEngine {
    static let lowConfidenceAccuracyThresholdM: Double = 6.0
    static let mediumConfidenceAccuracyThresholdM: Double = 4.0
    static let recommendedOffsetThresholdM: Double = 0.5

    static func interpret(
        location: CLLocation,
        heading: CLHeading?,
        paddocks: [TroubleshooterPaddock]
    ) -> LiveInterpretation? {
        let coord = location.coordinate

        // 1. Block detection (containing or nearest by centroid).
        var containingPaddock: TroubleshooterPaddock?
        for p in paddocks {
            let polygon = p.paddock.polygonPoints.map { $0.coordinate }
            if polygon.count >= 3,
               RowGuidance.isPointInPolygon(point: coord, polygon: polygon) {
                containingPaddock = p
                break
            }
        }

        var detectedPaddock: TroubleshooterPaddock?
        var insideBoundary = false
        var distanceToEdge: Double?

        if let containing = containingPaddock {
            detectedPaddock = containing
            insideBoundary = true
        } else {
            // Pick nearest paddock by centroid across all admin vineyards.
            var best: (TroubleshooterPaddock, Double)?
            for p in paddocks where !p.paddock.polygonPoints.isEmpty {
                let centroid = RowGuidance.polygonCentroid(p.paddock.polygonPoints.map { $0.coordinate })
                let d = RowGuidance.metresBetween(centroid, coord)
                if best == nil || d < (best?.1 ?? .greatestFiniteMagnitude) {
                    best = (p, d)
                }
            }
            detectedPaddock = best?.0
            distanceToEdge = best?.1
        }

        // 2. Row detection inside the chosen paddock.
        var nearestRowNumber: Double?
        var snappedLat: Double?
        var snappedLon: Double?
        var distanceFromCentre: Double?
        var alongRow: Double?
        var detectedSide: String?
        var rowHeading: Double?
        var headingDiff: Double?
        var interpretedDirection: String?
        var suggestion: String?

        if let p = detectedPaddock,
           let match = RowGuidance.nearestRow(for: coord, in: p.paddock) {
            nearestRowNumber = match.rowNumber
            distanceFromCentre = match.distance

            if let row = p.paddock.rows.first(where: { Double($0.number) == match.rowNumber }) {
                let start = row.startPoint.coordinate
                let end = row.endPoint.coordinate
                rowHeading = bearingDegrees(from: start, to: end)
                if let snap = RowGuidance.snapToRow(coordinate: coord, rowNumber: row.number, in: p.paddock) {
                    snappedLat = snap.snapped.latitude
                    snappedLon = snap.snapped.longitude
                    alongRow = snap.distanceAlongMetres
                }
                detectedSide = sideOfRow(point: coord, start: start, end: end)
                if let h = heading?.trueHeading, h >= 0, let rh = rowHeading {
                    headingDiff = abs(angularDifference(h, rh))
                    interpretedDirection = compassDirection(for: h)
                }
                if let off = distanceFromCentre,
                   off >= recommendedOffsetThresholdM,
                   let side = detectedSide,
                   side != "centre" {
                    suggestion = String(
                        format: "Rows appear shifted %.1f m %@. Consider an offset correction of ~%.1f m %@.",
                        off, side, off, opposite(side)
                    )
                }
            }
        }

        // 3. Confidence.
        let acc = location.horizontalAccuracy
        let confidence: DiagnosticConfidence
        if acc < 0 {
            confidence = .low
        } else if acc <= mediumConfidenceAccuracyThresholdM {
            confidence = .high
        } else if acc <= lowConfidenceAccuracyThresholdM {
            confidence = .medium
        } else {
            confidence = .low
        }

        return LiveInterpretation(
            vineyardId: detectedPaddock?.vineyardId,
            vineyardName: detectedPaddock?.vineyardName,
            blockId: detectedPaddock?.paddock.id,
            blockName: detectedPaddock?.paddock.name,
            insideBlockBoundary: insideBoundary,
            distanceToBlockEdgeM: distanceToEdge,
            nearestRowNumber: nearestRowNumber,
            snappedLatitude: snappedLat,
            snappedLongitude: snappedLon,
            distanceFromRowCentreM: distanceFromCentre,
            alongRowDistanceM: alongRow,
            detectedSide: detectedSide,
            interpretedDirection: interpretedDirection,
            rowHeadingDegrees: rowHeading,
            headingDifferenceDegrees: headingDiff,
            confidence: confidence,
            suggestedCorrection: suggestion
        )
    }

    private static func bearingDegrees(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    private static func angularDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    private static func compassDirection(for heading: Double) -> String {
        let dirs = ["northbound", "northeastbound", "eastbound", "southeastbound",
                    "southbound", "southwestbound", "westbound", "northwestbound"]
        let i = Int(((heading + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return dirs[max(0, min(7, i))]
    }

    /// Returns "east" / "west" / "centre" relative to the row centreline,
    /// using the row direction's perpendicular as the east/west axis. This
    /// is an approximation: "east" means positive cross-track in the
    /// row-perpendicular frame, "west" negative. It's stable enough for
    /// diagnostics across a single block.
    private static func sideOfRow(
        point p: CLLocationCoordinate2D,
        start a: CLLocationCoordinate2D,
        end b: CLLocationCoordinate2D
    ) -> String {
        let centroidLat = (a.latitude + b.latitude + p.latitude) / 3.0
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        let ax = a.longitude * mPerDegLon
        let ay = a.latitude * mPerDegLat
        let bx = b.longitude * mPerDegLon
        let by = b.latitude * mPerDegLat
        let px = p.longitude * mPerDegLon
        let py = p.latitude * mPerDegLat
        let cross = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
        if abs(cross) < 0.25 { return "centre" }
        return cross > 0 ? "west" : "east"
    }

    private static func opposite(_ side: String) -> String {
        switch side {
        case "east": return "west"
        case "west": return "east"
        case "north": return "south"
        case "south": return "north"
        default: return side
        }
    }
}

// MARK: - Formatting

private enum DiagnosticFormat {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    static let humanDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func isoTimestamp(_ date: Date) -> String { iso.string(from: date) }
    static func shortTime(_ date: Date) -> String { short.string(from: date) }

    /// Row 19 → "19". Row 19.5 → "19.5". Used in the captured-points list.
    static func rowLabel(_ row: Double) -> String {
        if row.rounded() == row { return String(Int(row)) }
        return String(format: "%.1f", row)
    }
}

private enum DiagnosticReport {
    static func render(session: DiagnosticSession) -> String {
        var lines: [String] = []
        lines.append("VineTrack Location Troubleshooter Log")
        lines.append("")
        lines.append("Session started: \(DiagnosticFormat.humanDateTime.string(from: session.sessionStartedAt))")
        lines.append("Session ended:   \(DiagnosticFormat.humanDateTime.string(from: session.sessionEndedAt))")
        lines.append("App version:     \(session.appVersion)")
        lines.append("Device:          \(session.deviceModel) (iOS \(session.iosVersion))")
        lines.append("Admin scope:     \(session.vineyardCountAvailableToAdmin) vineyards")
        lines.append("Sample count:    \(session.sampleCount)")
        lines.append("")

        // Detected vineyard/block summary from majority of samples.
        let vineyardName = mostCommon(session.samples.compactMap { $0.detectedVineyardName }) ?? "—"
        let blockName = mostCommon(session.samples.compactMap { $0.detectedBlockName }) ?? "—"
        lines.append("Detected vineyard: \(vineyardName)")
        lines.append("Detected block:    \(blockName)")
        lines.append("")

        if let summary = offsetSummary(samples: session.samples) {
            lines.append("Potential issue:")
            lines.append(summary)
            lines.append("")
        }

        lines.append("Samples:")
        for (idx, s) in session.samples.enumerated() {
            lines.append("")
            lines.append("\(idx + 1). Time: \(DiagnosticFormat.shortTime(s.timestamp))")
            lines.append("   GPS: \(String(format: "%.6f, %.6f", s.latitude, s.longitude))")
            lines.append("   Accuracy: \(String(format: "%.1f m", s.horizontalAccuracyM)) (\(s.confidence.rawValue))")
            if let r = s.nearestRowNumber {
                lines.append("   Detected row: \(DiagnosticFormat.rowLabel(r))")
            }
            if let d = s.distanceFromRowCentreM {
                let side = s.detectedSide ?? "—"
                lines.append("   Distance from row centre: \(String(format: "%.2f", d)) m \(side)")
            }
            if let dir = s.interpretedDirection { lines.append("   Direction: \(dir)") }
            if let block = s.detectedBlockName { lines.append("   Block: \(block)") }
            if let v = s.detectedVineyardName { lines.append("   Vineyard: \(v)") }
            if let note = s.diagnosticNotes { lines.append("   Note: \(note)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func mostCommon(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private static func offsetSummary(samples: [DiagnosticSample]) -> String? {
        let trustworthy = samples.filter {
            $0.horizontalAccuracyM > 0
                && $0.horizontalAccuracyM <= LocationTroubleshooterEngine.lowConfidenceAccuracyThresholdM
                && $0.distanceFromRowCentreM != nil
                && $0.detectedSide != nil
                && $0.detectedSide != "centre"
        }
        guard trustworthy.count >= 2 else { return nil }
        let sides = trustworthy.compactMap { $0.detectedSide }
        var sideCounts: [String: Int] = [:]
        for s in sides { sideCounts[s, default: 0] += 1 }
        guard let dominantSide = sideCounts.max(by: { $0.value < $1.value })?.key else { return nil }
        let matching = trustworthy.filter { $0.detectedSide == dominantSide }
        guard matching.count >= 2 else { return nil }
        let offsets = matching.compactMap { $0.distanceFromRowCentreM }
        guard let lo = offsets.min(), let hi = offsets.max() else { return nil }
        let avg = offsets.reduce(0, +) / Double(offsets.count)
        let opposite: String = dominantSide == "east" ? "west" : (dominantSide == "west" ? "east" : dominantSide)
        return String(
            format: "Across %d trustworthy samples, the app consistently detected the user as %.1f m to %.1f m %@ of the expected row centreline (avg %.1f m). This suggests the block row geometry may need an offset correction of approximately %.1f m %@, or the row generation / snap algorithm may be using the wrong boundary reference.",
            matching.count, lo, hi, dominantSide, avg, avg, opposite
        )
    }
}

// MARK: - Share sheet

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Manual vineyard picker

private struct ManualVineyardPickerSheet: View {
    let vineyards: [AdminVineyardRow]
    let isLoading: Bool
    let errorMessage: String?
    let onReload: () -> Void
    let onPick: (AdminVineyardRow) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    private var filtered: [AdminVineyardRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return vineyards }
        return vineyards.filter { v in
            v.name.lowercased().contains(q)
                || (v.ownerEmail?.lowercased().contains(q) ?? false)
                || (v.ownerFullName?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && vineyards.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading vineyards…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage, vineyards.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load vineyards", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(err).font(.footnote)
                    } actions: {
                        Button("Retry", action: onReload)
                    }
                } else if vineyards.isEmpty {
                    ContentUnavailableView(
                        "No vineyards",
                        systemImage: "leaf",
                        description: Text("No vineyards are available in the admin scope.")
                    )
                } else {
                    List {
                        ForEach(filtered) { v in
                            Button {
                                onPick(v)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.name).font(.body).foregroundStyle(.primary)
                                    Text(v.ownerDisplay).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if filtered.isEmpty {
                            Text("No vineyards match “\(query)”.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Search vineyard or owner")
            .navigationTitle("Select Vineyard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onReload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
    }
}
