import SwiftUI
import MapKit
import CoreLocation
import UIKit

/// Restored original-style active trip screen. Backend-neutral: uses
/// `MigratedDataStore` and `TripTrackingService` only.
struct ActiveTripView: View {
    let trip: Trip

    @Environment(MigratedDataStore.self) private var store
    @Environment(TripTrackingService.self) private var tracking
    @Environment(LocationService.self) private var locationService
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(NetworkMonitor.self) private var network

    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var isFollowingUser: Bool = true
    @State private var mapMode: MapFollowMode = .free
    @State private var lastNavCameraUpdate: Date = .distantPast
    @State private var smoothedCourse: Double?
    @State private var noGpsToast: Bool = false
    @State private var showRowIndicator: Bool = true
    @State private var showPinOverlay: Bool = true
    @State private var showManualCorrection: Bool = false
    @State private var showEndConfirmation: Bool = false
    @State private var showEndReview: Bool = false
    @State private var showAddBlocks: Bool = false
    @State private var showSummary: Bool = false
    @State private var showRepairs: Bool = false
    @State private var showGrowth: Bool = false
    @State private var elapsedTimer: TimeInterval = 0
    @State private var ticker: Timer?
    @State private var fillElapsed: TimeInterval = 0
    @State private var showEndTankConfirmation: Bool = false

    /// Display-only trail segments. Recomputed on a 1Hz throttled timer rather
    /// than every GPS tick or every SwiftUI body invocation.
    @State private var displayTrailSegments: [TrailSegment] = []
    @State private var trailUpdateTimer: Timer?
    @State private var lastTrailUpdate: Date?
    @State private var trailDiagFullCount: Int = 0
    @State private var trailDiagDisplayCount: Int = 0

    /// Last accepted (non-spike) speed in km/h. Held across GPS spikes so the
    /// pill keeps showing a sensible value rather than flashing 95 km/h.
    @State private var lastValidSpeedKmh: Double = 0
    /// Rolling window of valid moving-speed samples (km/h) used for ETA.
    /// Excludes stationary noise (<0.5 km/h) and impossible spikes (>40 km/h).
    @State private var validSpeedSamples: [(date: Date, kmh: Double)] = []

    /// Hard cap on tractor ground speed for vineyard work. Anything above is
    /// treated as a GPS spike for both display and ETA.
    private static let maxValidSpeedKmh: Double = 40.0
    /// Below this, the tractor is considered stationary and the sample is
    /// excluded from the ETA average.
    private static let minMovingSpeedKmh: Double = 0.5
    /// Retain ETA samples for ~2 minutes so the average reflects current pace.
    private static let etaSampleWindow: TimeInterval = 120

    /// GPS-derived travel bearing (degrees, 0=N) latched once we've seen
    /// stable movement along the row direction. Only flips when the new
    /// bearing is opposite the locked one for ≥3 consecutive samples — this
    /// stops the left/right labels from flickering when the tractor is
    /// stationary, turning at row ends, or experiencing GPS jitter.
    @State private var lockedTravelBearing: Double?
    @State private var lastBearingLocation: CLLocation?
    @State private var bearingLockSamples: Int = 0

    /// Toast shown after "Copy diagnostics" finishes writing to the
    /// pasteboard. Auto-dismissed after a short delay.
    @State private var showDiagnosticsToast: Bool = false

    /// Throttle interval for the live trail render. Location updates can keep
    /// flowing in faster than this — only the on-screen polylines are paced.
    private static let trailUpdateInterval: TimeInterval = 1.0
    private static let maxDisplayTrailPoints: Int = 500
    private static let maxTrailBuckets: Int = 5

    private var sprayRecord: SprayRecord? {
        store.sprayRecords.first { $0.tripId == trip.id }
    }

    /// Active paddock prefers the live GPS-detected block (so the operator
    /// always sees the block they are currently in across multi-block trips),
    /// falling back to the trip's pinned/selected blocks.
    private var currentPaddock: Paddock? {
        if let liveId = tracking.currentPaddockId,
           let paddock = store.paddocks.first(where: { $0.id == liveId }) {
            return paddock
        }
        if let id = trip.paddockId,
           let paddock = store.paddocks.first(where: { $0.id == id }) {
            return paddock
        }
        for id in trip.paddockIds {
            if let paddock = store.paddocks.first(where: { $0.id == id }) {
                return paddock
            }
        }
        return nil
    }

    private var paddocksOnMap: [Paddock] {
        var ids = Set<UUID>()
        if let id = trip.paddockId { ids.insert(id) }
        ids.formUnion(trip.paddockIds)
        if let liveId = tracking.currentPaddockId { ids.insert(liveId) }
        return store.paddocks.filter { ids.contains($0.id) }
    }

    private var displayPath: Double? {
        if let row = tracking.currentRowNumber { return row }
        if !trip.rowSequence.isEmpty { return trip.currentRowNumber }
        return nil
    }

    private var nextPath: Double? {
        let live = tracking.activeTrip ?? trip
        guard !live.rowSequence.isEmpty else { return nil }
        // Skip any pending entries that match the displayed current path or
        // are already completed/skipped — prevents "Current 96.5 / Next
        // 96.5" when the planned pointer hasn't advanced past a duplicate
        // or just-completed row.
        let current = displayPath
        var idx = live.sequenceIndex + 1
        while idx < live.rowSequence.count {
            let candidate = live.rowSequence[idx]
            let sameAsCurrent = current.map { abs($0 - candidate) < 0.01 } ?? false
            let alreadyDone = live.completedPaths.contains(where: { abs($0 - candidate) < 0.01 })
                || live.skippedPaths.contains(where: { abs($0 - candidate) < 0.01 })
            if !sameAsCurrent && !alreadyDone { return candidate }
            idx += 1
        }
        return nil
    }

    /// True when this trip is using the Free Drive (no planned path) mode.
    private var isFreeDrive: Bool {
        (tracking.activeTrip ?? trip).trackingPattern == .freeDrive
    }

    /// The path the operator is meant to be driving (sequence target).
    /// Always nil in Free Drive mode — there is no planned ordering.
    private var plannedPath: Double? {
        if isFreeDrive { return nil }
        let live = tracking.activeTrip ?? trip
        if live.rowSequence.indices.contains(live.sequenceIndex) {
            return live.rowSequence[live.sequenceIndex]
        }
        return nil
    }

    /// The path GPS says the tractor is physically on right now (when the
    /// fix is inside the row corridor). Held as the most recently reported
    /// live detected path so transient nil ticks don't reset the labels.
    private var liveDetectedPath: Double? {
        guard tracking.diagInCorridor else { return nil }
        return tracking.diagLiveDetectedPath
    }

    /// True when the GPS-detected live path differs from the planned path
    /// while the tractor is in corridor — the operator is driving the
    /// wrong row and labels/warning should reflect the live path. Always
    /// false in Free Drive mode (there is no planned path to be wrong
    /// against).
    private var isOffPlannedPath: Bool {
        if isFreeDrive { return false }
        guard let planned = plannedPath, let live = liveDetectedPath else { return false }
        return abs(planned - live) > 0.01
    }

    /// True when the wrong-row warning should be ACTIVELY shown to the
    /// operator. Suppressed near row ends (turning area) and when the
    /// operator has already covered most of the planned row, since at
    /// that point the right move is to finish/accept the row rather
    /// than redirect the tractor.
    private var shouldShowWrongPathBanner: Bool {
        guard isOffPlannedPath else { return false }
        if tracking.diagNearRowEnd { return false }
        // Once 35% or more of the planned row has been covered, finishing
        // is the right action — no need to scream "wrong row" at the
        // operator. Mirrors the auto-realign suppression rule.
        if tracking.diagPlannedCompletionPercent > 35 { return false }
        // Require solid lock confidence so brief GPS hops while turning
        // at headlands don't trigger the banner.
        if tracking.diagLockConfidence < 0.6 { return false }
        // Post-completion grace: if the planned sequence has just
        // advanced (auto-complete fired in the last 20s) and the live
        // path is still the row that was just completed, the operator
        // is finishing the row — don't warn.
        if let firedAt = tracking.diagAutoCompleteLastFiredAt,
           Date().timeIntervalSince(firedAt) < 20,
           let last = tracking.diagAutoCompleteLastPath,
           let live = liveDetectedPath,
           abs(last - live) < 0.01 {
            return false
        }
        return true
    }

    /// Path used to render the left/right side row labels. Live detected
    /// path wins when GPS is in corridor so the operator sees the correct
    /// adjacent row numbers; otherwise falls back to whatever the tracking
    /// service reported, then the planned target. This is the fix for the
    /// “wrong row labels while off planned path” issue.
    private var pathForLabels: Double {
        if let live = liveDetectedPath { return live }
        return displayPath ?? trip.currentRowNumber
    }

    /// Identifier used in diagnostics to make it obvious which path drove
    /// the displayed labels.
    private var labelPathSource: String {
        if liveDetectedPath != nil { return "live" }
        if tracking.currentRowNumber != nil { return "tracker" }
        return "planned"
    }

    /// Highest row number across the active sequence. Used to render the
    /// “End” boundary label past the last row.
    private var maxSequenceRow: Int {
        guard !trip.rowSequence.isEmpty else { return Int.max }
        return Int(trip.rowSequence.map { ceil($0) }.max() ?? 0)
    }

    /// True when the tractor's locked travel bearing matches the row
    /// vector start→end direction. When false, left/right are swapped.
    /// Falls back to `true` (no swap) when we don't yet have a stable
    /// bearing — keeps labels readable while GPS settles.
    private var isTravelingAlongRow: Bool {
        guard let locked = lockedTravelBearing,
              let rowDir = currentPaddock?.rowDirection else { return true }
        var diff = locked - rowDir
        while diff < 0 { diff += 360 }
        while diff >= 360 { diff -= 360 }
        return diff < 90 || diff > 270
    }

    /// Convert an adjacent row number to a display label, returning
    /// “Start” / “End” at the sequence boundaries.
    private func sideLabel(forRow number: Int) -> String {
        if number < 1 { return "Start" }
        if maxSequenceRow != Int.max, number > maxSequenceRow { return "End" }
        return "Row \(number)"
    }

    /// Row number on the operator's left, accounting for travel direction.
    /// For path X.5 the two adjacent rows are X (floor) and X+1 (ceil).
    /// When travelling start→end of the row geometry, the higher-numbered
    /// row sits on the left; reversed when travelling end→start.
    private var leftRowLabel: String {
        let path = pathForLabels
        let lower = Int(floor(path))
        let upper = lower + 1
        let row = isTravelingAlongRow ? upper : lower
        return sideLabel(forRow: row)
    }

    private var rightRowLabel: String {
        let path = pathForLabels
        let lower = Int(floor(path))
        let upper = lower + 1
        let row = isTravelingAlongRow ? lower : upper
        return sideLabel(forRow: row)
    }

    /// Show the side row indicator whenever row tracking is enabled and we
    /// have any usable path — either a live GPS hit OR a stored sequence path.
    /// This avoids the labels disappearing when GPS detection is briefly lost.
    private var canShowRowSides: Bool {
        guard store.settings.rowTrackingEnabled else { return false }
        return tracking.rowGuidanceAvailable || !trip.rowSequence.isEmpty
    }

    private var currentSpeedKmh: Double {
        // Prefer the smoothed tracking speed (m/s) which falls back to recent
        // GPS points when CLLocation.speed dips. This is the fix for the
        // half-speed dropout reported during slow tractor work.
        if let smoothed = tracking.currentSpeed, smoothed > 0 {
            return smoothed * 3.6
        }
        guard let speed = locationService.location?.speed, speed > 0 else { return 0 }
        return speed * 3.6
    }

    /// Speed shown in the top-right pill. Spikes above `maxValidSpeedKmh` are
    /// rejected and the previous valid reading is held instead.
    private var displayedSpeedKmh: Double {
        let raw = currentSpeedKmh
        if raw > 0 && raw <= Self.maxValidSpeedKmh { return raw }
        return lastValidSpeedKmh
    }

    /// Average of valid moving-speed samples (km/h). Used by the ETA only.
    private var averageValidSpeedKmh: Double {
        let moving = validSpeedSamples.filter { $0.kmh >= Self.minMovingSpeedKmh && $0.kmh <= Self.maxValidSpeedKmh }
        guard moving.count >= 3 else { return 0 }
        return moving.reduce(0) { $0 + $1.kmh } / Double(moving.count)
    }

    /// Remaining planned distance in metres, estimated from the row sequence
    /// paths still to drive multiplied by the average row length across the
    /// trip's selected paddocks.
    private var remainingPlannedDistanceMeters: Double {
        let live = tracking.activeTrip ?? trip
        guard !live.rowSequence.isEmpty else { return 0 }
        let remaining = live.rowSequence.dropFirst(live.sequenceIndex).filter {
            !live.completedPaths.contains($0)
        }.count
        guard remaining > 0 else { return 0 }
        let lens = paddocksOnMap.flatMap { paddock -> [Double] in
            let mPerDegLat = 111_320.0
            let lat = paddock.polygonPoints.first?.latitude ?? paddock.rows.first?.startPoint.latitude ?? 0
            let mPerDegLon = 111_320.0 * cos(lat * .pi / 180)
            return paddock.rows.map { row in
                let dLat = (row.endPoint.latitude - row.startPoint.latitude) * mPerDegLat
                let dLon = (row.endPoint.longitude - row.startPoint.longitude) * mPerDegLon
                return sqrt(dLat * dLat + dLon * dLon)
            }
        }
        guard !lens.isEmpty else { return 0 }
        let avgRowLen = lens.reduce(0, +) / Double(lens.count)
        return Double(remaining) * avgRowLen
    }

    private var timeLeftText: String {
        let live = tracking.activeTrip ?? trip
        if !live.rowSequence.isEmpty {
            let remaining = live.rowSequence.dropFirst(live.sequenceIndex).filter {
                !live.completedPaths.contains($0)
            }.count
            if remaining == 0 { return "Complete" }
        }
        let avgKmh = averageValidSpeedKmh
        let distance = remainingPlannedDistanceMeters
        guard avgKmh > 0, distance > 0 else { return "Calculating…" }
        let speedMps = avgKmh / 3.6
        let seconds = distance / speedMps
        if seconds < 60 { return "<1m" }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return "\(h)h \(m)m"
    }

    private var speedDisplayText: String {
        let v = displayedSpeedKmh
        guard v > 0 else { return "— km/h" }
        return String(format: "%.1f km/h", min(v, 99.9))
    }

    // MARK: - GPS quality

    /// Operator-friendly GPS quality verdict based on horizontal accuracy,
    /// staleness of the last fix, and the rolling update interval. Kept
    /// deliberately simple — the operator only needs to know whether row
    /// accuracy is currently trustworthy.
    private enum GpsQuality {
        case good, fair, poor, unavailable

        var label: String {
            switch self {
            case .good: return "GPS Good"
            case .fair: return "GPS Fair"
            case .poor: return "GPS Poor"
            case .unavailable: return "GPS —"
            }
        }

        var tint: Color {
            switch self {
            case .good: return .green
            case .fair: return .orange
            case .poor: return .red
            case .unavailable: return .secondary
            }
        }

        var symbol: String {
            switch self {
            case .good: return "dot.radiowaves.up.forward"
            case .fair: return "dot.radiowaves.up.forward"
            case .poor: return "exclamationmark.triangle.fill"
            case .unavailable: return "questionmark.circle"
            }
        }
    }

    /// Most recent GPS update age in seconds (positive). nil if no fix.
    private var gpsLastUpdateAge: TimeInterval? {
        guard let ts = locationService.lastUpdateTimestamp else { return nil }
        return max(0, -ts.timeIntervalSinceNow)
    }

    private var gpsQuality: GpsQuality {
        guard let loc = locationService.location else { return .unavailable }
        let acc = loc.horizontalAccuracy
        // Negative accuracy from CoreLocation means invalid fix.
        if acc < 0 { return .poor }
        let age = gpsLastUpdateAge ?? .infinity
        let interval = locationService.averageUpdateInterval

        // Poor: very inaccurate, very stale, or updates have stalled.
        if acc > 12 { return .poor }
        if age > 5 { return .poor }
        if interval > 0 && interval > 4 { return .poor }

        // Good: tight accuracy, fresh fix, healthy ~1Hz updates.
        if acc <= 5, age <= 2.5, (interval == 0 || interval <= 2) {
            return .good
        }

        // Anything in between is Fair.
        return .fair
    }

    /// Capture a fresh speed reading from the live tracking service into the
    /// ETA window, filtering out impossible spikes. Called from the 1Hz ticker
    /// rather than every GPS update so the pill and ETA settle smoothly.
    private func captureSpeedSample() {
        let raw = currentSpeedKmh
        if raw > 0 && raw <= Self.maxValidSpeedKmh {
            lastValidSpeedKmh = raw
            if raw >= Self.minMovingSpeedKmh {
                validSpeedSamples.append((Date(), raw))
            }
        }
        let cutoff = Date().addingTimeInterval(-Self.etaSampleWindow)
        validSpeedSamples.removeAll { $0.date < cutoff }
    }

    var body: some View {
        VStack(spacing: 0) {
            tripInfoBar

            ZStack(alignment: .topTrailing) {
                mapView

                mapControls
                    .padding(12)

                if showRowIndicator, canShowRowSides {
                    rowIndicatorOverlay
                }

                if shouldShowWrongPathBanner {
                    wrongPathBanner
                }

                if let suggested = tracking.autoRealignSuggestedPath,
                   shouldShowRealignBanner(for: suggested) {
                    autoRealignBanner
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Pin the action buttons (row banner, spray banner, tank
            // controls and pause/end controls) above the floating tab bar
            // and home-indicator safe area. Without this the iOS 26 tab
            // bar overlays the bottom action buttons and makes End/Pause
            // hard or impossible to tap in the cab.
            VStack(spacing: 0) {
                if store.settings.rowTrackingEnabled {
                    currentRowBanner
                } else {
                    rowTrackingDisabledBanner
                }

                if let record = sprayRecord {
                    sprayBanner(record: record)
                    tankControls(record: record)
                }

                tripControls
            }
            .background(Color(.systemGroupedBackground))
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Hide the floating tab bar for the whole active trip so the bottom
        // control strip (row banner, tank controls, Pause/End) is always
        // clear and tappable in the cab. The tab bar returns when the trip
        // ends and this view is swapped out.
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Fix what the app thinks") {
                        Button {
                            tracking.snapPlannedSequenceToCurrentLivePath()
                        } label: {
                            Label("I'm actually on this row", systemImage: "location.viewfinder")
                        }
                        .disabled(trip.rowSequence.isEmpty || liveDetectedPath == nil)

                        if let live = liveDetectedPath {
                            Button {
                                tracking.confirmCurrentLockedPath(live)
                            } label: {
                                Label("Confirm I'm on path \(formatPath(live))", systemImage: "hand.thumbsup")
                            }
                        }
                    }
                    Section("Move through the plan") {
                        Button {
                            tracking.markCurrentPlannedPathComplete()
                        } label: {
                            Label("Mark this path done & move on", systemImage: "checkmark.circle")
                        }
                        .disabled(trip.rowSequence.isEmpty)

                        Button(role: .destructive) {
                            tracking.skipCurrentPlannedPath()
                        } label: {
                            Label("Skip this path (won't count)", systemImage: "forward.end")
                        }
                        .disabled(trip.rowSequence.isEmpty)
                    }
                    Divider()
                    Button {
                        copyDiagnosticsToClipboard()
                    } label: {
                        Label("Copy diagnostics", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Trip options")
            }
        }
        .sheet(isPresented: $showSummary) {
            TripSummarySheet(trip: trip)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEndReview) {
            EndTripReviewSheet(trip: tracking.activeTrip ?? trip)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddBlocks) {
            AddBlocksToTripSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showRepairs) {
            NavigationStack { RepairsGrowthView(initial: .repairs) }
        }
        .sheet(isPresented: $showGrowth) {
            NavigationStack { RepairsGrowthView(initial: .growth) }
        }
        .onAppear {
            elapsedTimer = trip.activeDuration
            startTicker()
            startTrailUpdater()
            refreshDisplayTrail()
            ScreenAwakeManager.shared.acquire("ActiveTripView")
        }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
            trailUpdateTimer?.invalidate()
            trailUpdateTimer = nil
            ScreenAwakeManager.shared.release("ActiveTripView")
        }
        .onMapCameraChange { _ in
            isFollowingUser = false
            // User dragged the map → drop out of follow/navigation modes
            // so we don't fight their gesture.
            if mapMode != .free {
                // Only react to gesture-initiated changes, not our own
                // programmatic camera updates. The throttle below ensures
                // navigation-mode auto updates don't immediately flip us
                // back to free mode.
                let now = Date()
                if now.timeIntervalSince(lastNavCameraUpdate) > 0.6 {
                    mapMode = .free
                }
            }
        }
        .onChange(of: locationService.location?.timestamp) { _, _ in
            updateNavigationCameraIfNeeded()
        }
        .onChange(of: mapMode) { _, newMode in
            applyMapMode(newMode)
        }
        .overlay(alignment: .top) {
            if showDiagnosticsToast {
                Text("Diagnostics copied")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if noGpsToast {
                Text("GPS unavailable")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.9), in: Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Map controls

    /// Stacked map control column. Each control has to be one-tap usable
    /// in a bouncing tractor — we deliberately removed the redundant
    /// "go-to-location" recentre button (the zoom button already centres
    /// on the tractor) and the unreliable heading-up Navigation mode.
    private var mapControls: some View {
        VStack(spacing: 8) {
            mapControlButton(
                systemImage: "scope",
                tint: mapMode == .zoomed ? Color.accentColor : .primary
            ) {
                mapMode = .zoomed
            }

            mapControlButton(
                systemImage: showRowIndicator ? "arrow.left.and.right.circle.fill" : "arrow.left.and.right.circle",
                tint: .primary
            ) {
                withAnimation(.snappy) { showRowIndicator.toggle() }
            }

            mapControlButton(
                systemImage: showPinOverlay ? "mappin.circle.fill" : "mappin.circle",
                tint: showPinOverlay ? Color.accentColor : .primary
            ) {
                withAnimation(.snappy) { showPinOverlay.toggle() }
            }
        }
    }

    /// Compact GPS quality pill shown next to the speed/ETA chips. Operator
    /// only sees a label + colour; raw accuracy/age stays in diagnostics.
    private var gpsQualityPill: some View {
        let q = gpsQuality
        return HStack(spacing: 4) {
            Image(systemName: q.symbol)
                .font(.caption2)
                .foregroundStyle(q.tint)
            Text(q.label)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(q.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(q.label)
    }

    private func mapControlButton(systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: .circle)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: tint)
    }

    private func ensureGpsAvailable() -> Bool {
        if locationService.location != nil { return true }
        withAnimation(.snappy) { noGpsToast = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { noGpsToast = false }
        }
        return false
    }

    /// Apply the camera state for a newly chosen map mode. Free mode is
    /// no-op (we leave whatever the user has). Zoomed mode snaps to a
    /// close top-down view of the live GPS. Navigation mode kicks off
    /// the first heading-up camera; subsequent updates flow through
    /// `updateNavigationCameraIfNeeded`.
    private func applyMapMode(_ mode: MapFollowMode) {
        switch mode {
        case .free:
            isFollowingUser = false
        case .zoomed:
            guard ensureGpsAvailable(), let loc = locationService.location else { return }
            isFollowingUser = true
            lastNavCameraUpdate = Date()
            withAnimation(.easeInOut(duration: 0.4)) {
                position = .camera(MapCamera(
                    centerCoordinate: loc.coordinate,
                    distance: 120,
                    heading: 0,
                    pitch: 0
                ))
            }
        case .navigation:
            guard ensureGpsAvailable(), let loc = locationService.location else { return }
            isFollowingUser = true
            lastNavCameraUpdate = Date()
            let course = bestCourse(for: loc) ?? 0
            smoothedCourse = course
            withAnimation(.easeInOut(duration: 0.5)) {
                position = .camera(MapCamera(
                    centerCoordinate: loc.coordinate,
                    distance: 180,
                    heading: course,
                    pitch: 55
                ))
            }
        }
    }

    /// Refresh the camera while in zoomed/navigation mode. Throttled to
    /// ~3Hz so MapKit isn't asked to animate on every CLLocation tick,
    /// which causes jitter and battery drain.
    private func updateNavigationCameraIfNeeded() {
        guard mapMode != .free, let loc = locationService.location else { return }
        let now = Date()
        guard now.timeIntervalSince(lastNavCameraUpdate) > 0.33 else { return }
        lastNavCameraUpdate = now

        switch mapMode {
        case .free:
            return
        case .zoomed:
            withAnimation(.linear(duration: 0.3)) {
                position = .camera(MapCamera(
                    centerCoordinate: loc.coordinate,
                    distance: 120,
                    heading: 0,
                    pitch: 0
                ))
            }
        case .navigation:
            // Use GPS course (movement-derived) over device compass —
            // the iPad/iPhone may not be mounted straight in the cab.
            // Fall back to the locked travel bearing the trip already
            // tracks for row labels, then to whatever course MapKit had.
            let raw = bestCourse(for: loc)
            let target = raw ?? smoothedCourse ?? 0
            // Circular EMA so the camera doesn't snap on every tick.
            let prev = smoothedCourse ?? target
            let blended = blendBearings(prev: prev, next: target, alpha: 0.25)
            smoothedCourse = blended
            withAnimation(.linear(duration: 0.3)) {
                position = .camera(MapCamera(
                    centerCoordinate: loc.coordinate,
                    distance: 180,
                    heading: blended,
                    pitch: 55
                ))
            }
        }
    }

    /// Pick the best available bearing for navigation-mode camera. Prefer
    /// CLLocation.course when valid (≥0 and speed above the GPS noise
    /// floor), then fall back to the bearing locked from row movement.
    private func bestCourse(for loc: CLLocation) -> Double? {
        if loc.course >= 0, loc.speed > 0.6 { return loc.course }
        return lockedTravelBearing
    }

    /// Exponential moving average over circular degrees so we cross the
    /// 0/360 boundary smoothly instead of spinning the camera around.
    private func blendBearings(prev: Double, next: Double, alpha: Double) -> Double {
        let prevRad = prev * .pi / 180
        let nextRad = next * .pi / 180
        let x = (1 - alpha) * cos(prevRad) + alpha * cos(nextRad)
        let y = (1 - alpha) * sin(prevRad) + alpha * sin(nextRad)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }

    // MARK: - Diagnostics

    /// Build a plain-text diagnostics snapshot from the live trip, tracking
    /// service and location, copy it to the pasteboard, and show a toast.
    /// Available in all build configurations so it works in TestFlight.
    private func copyDiagnosticsToClipboard() {
        let snapshot = buildDiagnosticsSnapshot()
        UIPasteboard.general.string = snapshot
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.snappy) { showDiagnosticsToast = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { showDiagnosticsToast = false }
        }
    }

    private func buildDiagnosticsSnapshot() -> String {
        let live = tracking.activeTrip ?? trip
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let plannedPath: Double? = live.rowSequence.indices.contains(live.sequenceIndex)
            ? live.rowSequence[live.sequenceIndex]
            : nil
        let livePath = tracking.diagLiveDetectedPath
        let distanceToPath = tracking.diagDistanceToPath
        let corridor = tracking.diagCorridorTolerance
        let inCorridor = tracking.diagInCorridor
        let pathMatch = tracking.diagPathMatch
        let pathLen = tracking.diagPlannedPathLengthMeters
        let acc = tracking.diagAccumulatedMeters
        let pct: Double = (pathLen ?? 0) > 0 ? (acc / (pathLen ?? 1) * 100) : 0

        let paddockNames = paddocksOnMap.map { $0.name }.joined(separator: ", ")
        let functionLabel = live.displayFunctionLabel.isEmpty ? "—" : live.displayFunctionLabel

        let rawSpeedKmh = currentSpeedKmh
        let smoothedKmh = (tracking.currentSpeed ?? 0) * 3.6
        let avgKmh = averageValidSpeedKmh
        let rawCLKmh = tracking.rawCLLocationSpeed * 3.6
        let calcKmh = tracking.calculatedGroundSpeed * 3.6
        let smoothedCalcKmh = tracking.smoothedGroundSpeed * 3.6

        let loc = locationService.location
        let lat = loc?.coordinate.latitude
        let lon = loc?.coordinate.longitude
        let acc2D = loc?.horizontalAccuracy
        let locTs = loc?.timestamp

        let rowDir = currentPaddock?.rowDirection
        let movement = lockedTravelBearing
        let sameDir = isTravelingAlongRow

        let path = pathForLabels
        let lower = Int(floor(path))
        let upper = lower + 1

        let warning: String = {
            if isFreeDrive {
                if !inCorridor, livePath != nil { return "Detecting row…" }
                return "—"
            }
            if !live.rowSequence.isEmpty {
                let remaining = live.rowSequence.dropFirst(live.sequenceIndex).filter {
                    !live.completedPaths.contains($0)
                }.count
                if remaining == 0 { return "Complete" }
            }
            if isOffPlannedPath, let p = plannedPath, let l = liveDetectedPath {
                return "Wrong row — on path \(l), planned \(p)"
            }
            if averageValidSpeedKmh <= 0 { return "Calculating ETA" }
            if let planned = plannedPath, let live = livePath, abs(planned - live) > 0.01 {
                return "Off planned path"
            }
            if !inCorridor, livePath != nil { return "Approaching path" }
            return "—"
        }()

        func fmt(_ d: Double?, _ digits: Int = 1, suffix: String = "") -> String {
            guard let d else { return "nil" }
            return String(format: "%.\(digits)f%@", d, suffix)
        }

        var lines: [String] = []
        lines.append("Active Trip Diagnostics")
        lines.append("Time: \(isoFormatter.string(from: now))")
        lines.append("Trip ID: \(live.id.uuidString)")
        lines.append("Trip: \(functionLabel)")
        lines.append("Mode: \(live.trackingPattern.rawValue)\(isFreeDrive ? " (Free Drive / No Planned Path)" : "")")
        lines.append("Paddocks: \(paddockNames.isEmpty ? "—" : paddockNames)")
        lines.append("")
        lines.append("Planned path: \(plannedPath.map { String($0) } ?? "nil")")
        lines.append("Live detected path: \(livePath.map { String($0) } ?? "nil")")
        lines.append("Current row number: \(tracking.currentRowNumber.map { String($0) } ?? "nil")")
        lines.append("Sequence index: \(live.sequenceIndex) / \(live.rowSequence.count)")
        lines.append("Row sequence count: \(live.rowSequence.count)")
        lines.append("Distance to path: \(fmt(distanceToPath, 2, suffix: " m"))")
        lines.append("Corridor tolerance: \(fmt(corridor, 2, suffix: " m"))")
        lines.append("In corridor: \(inCorridor)")
        lines.append("Path match: \(pathMatch)")
        lines.append("Path length: \(fmt(pathLen, 1, suffix: " m"))")
        lines.append("Accumulated: \(fmt(acc, 1, suffix: " m"))")
        lines.append("Progress: \(fmt(pct, 0, suffix: "%"))")
        if let last = tracking.diagAutoCompleteLastFiredAt {
            lines.append("Auto-complete last fired: path \(tracking.diagAutoCompleteLastPath.map { String($0) } ?? "?") at \(isoFormatter.string(from: last))")
        } else {
            lines.append("Auto-complete last fired: never")
        }
        lines.append("")
        lines.append("Speed: raw \(fmt(rawSpeedKmh, 1)) km/h, smoothed \(fmt(smoothedKmh, 1)) km/h, avg \(fmt(avgKmh, 1)) km/h")
        lines.append("Speed sources:")
        lines.append("  CLLocation.speed: \(fmt(rawCLKmh, 1, suffix: " km/h"))")
        lines.append("  calculated (distance/time): \(fmt(calcKmh, 1, suffix: " km/h"))")
        lines.append("  smoothed calculated: \(fmt(smoothedCalcKmh, 1, suffix: " km/h"))")
        lines.append("  display source: \(tracking.speedDisplaySource)")
        lines.append("  window samples: \(tracking.speedWindowSampleCount)")
        lines.append("  window seconds: \(fmt(tracking.speedWindowSeconds, 1, suffix: " s"))")
        if let lat, let lon {
            lines.append("GPS: \(String(format: "%.6f", lat)), \(String(format: "%.6f", lon)), accuracy \(fmt(acc2D, 1, suffix: " m"))")
        } else {
            lines.append("GPS: unavailable")
        }
        if let locTs {
            lines.append("GPS timestamp: \(isoFormatter.string(from: locTs))")
        }
        lines.append("")
        lines.append("Orientation:")
        lines.append("  movement heading: \(fmt(movement, 1, suffix: "°"))")
        lines.append("  row heading: \(fmt(rowDir, 1, suffix: "°"))")
        lines.append("  sameDirection: \(sameDir)")
        lines.append("  path \(path) → lower row \(lower), upper row \(upper)")
        lines.append("  left: \(leftRowLabel)")
        lines.append("  right: \(rightRowLabel)")
        lines.append("")
        lines.append("Labels:")
        lines.append("  plannedPath: \(plannedPath.map { String($0) } ?? "nil")")
        lines.append("  livePath: \(liveDetectedPath.map { String($0) } ?? "nil")")
        lines.append("  labelPathUsed: \(labelPathSource) (\(path))")
        lines.append("  label lower row: \(lower)")
        lines.append("  label upper row: \(upper)")
        lines.append("  left label: \(leftRowLabel)")
        lines.append("  right label: \(rightRowLabel)")
        lines.append("  off-planned-path: \(isOffPlannedPath)")
        lines.append("  warning shown: \(shouldShowWrongPathBanner)")
        lines.append("  near row end: \(tracking.diagNearRowEnd)")
        lines.append("  planned completion: \(fmt(tracking.diagPlannedCompletionPercent, 0, suffix: "%"))")
        lines.append("  locked path: \(tracking.diagLockedPath.map { String($0) } ?? "nil")")
        lines.append("  lock confidence: \(fmt(tracking.diagLockConfidence, 2))")
        lines.append("  lock dwell: \(fmt(tracking.diagLockDwellSeconds, 1, suffix: " s"))")
        if let reason = tracking.diagWrongRowSuppressedReason {
            lines.append("  suppression reason: \(reason)")
        }
        if let suggested = tracking.autoRealignSuggestedPath {
            lines.append("  auto-realign suggested: \(suggested)")
        } else {
            lines.append("  auto-realign suggested: none")
        }
        lines.append("")
        lines.append("GPS service:")
        lines.append("  desiredAccuracy: best (high-accuracy active=\(locationService.isHighAccuracyEnabled))")
        lines.append("  background updates: \(locationService.isBackgroundUpdatingEnabled)")
        lines.append("  update interval (ema): \(fmt(locationService.averageUpdateInterval, 2, suffix: " s"))")
        lines.append("  update count: \(locationService.locationUpdateCount)")
        if let last = locationService.lastUpdateTimestamp {
            lines.append("  last update: \(isoFormatter.string(from: last))")
        }
        lines.append("  raw CLLocation.speed: \(fmt(loc?.speed, 2, suffix: " m/s"))")
        lines.append("")
        lines.append("GPS quality:")
        lines.append("  label: \(gpsQuality.label)")
        lines.append("  horizontal accuracy: \(fmt(acc2D, 2, suffix: " m"))")
        lines.append("  last update age: \(fmt(gpsLastUpdateAge, 2, suffix: " s"))")
        lines.append("  average update interval: \(fmt(locationService.averageUpdateInterval, 2, suffix: " s"))")
        lines.append("  rolling speed sample count: \(tracking.speedWindowSampleCount)")
        lines.append("")
        lines.append("Map:")
        lines.append("  camera mode: \(mapMode == .free ? "free" : (mapMode == .zoomed ? "zoomed" : "navigation"))")
        lines.append("  pin overlay: \(showPinOverlay ? "on" : "off")")
        lines.append("  visible pins: \(visibleMapPins.count)")
        lines.append("")
        if !tracking.diagManualCorrectionEvents.isEmpty {
            lines.append("Manual corrections:")
            for event in tracking.diagManualCorrectionEvents.suffix(10) {
                lines.append("  \(event)")
            }
            lines.append("")
        }
        lines.append("Map / trail:")
        lines.append("  full point count: \(live.pathPoints.count)")
        lines.append("  display point count: \(trailDiagDisplayCount)")
        lines.append("  display polyline count: \(displayTrailSegments.count)")
        lines.append("")
        lines.append("Duplicate pin:")
        lines.append("  last check: \(tracking.diagDuplicateCheckResult ?? "—")")
        lines.append("  radius: \(fmt(tracking.diagDuplicateRadiusMeters, 2, suffix: " m"))")
        lines.append("")
        if isFreeDrive {
            lines.append("")
            lines.append("Free Drive:")
            lines.append("  active: \(tracking.diagFreeDriveActive)")
            lines.append("  candidate path: \(tracking.diagFreeDriveCandidatePath.map { String($0) } ?? "nil")")
            lines.append("  stable detected path: \(tracking.diagFreeDriveStablePath.map { String($0) } ?? "nil")")
            lines.append("  rolling window samples: \(tracking.diagFreeDriveWindowSamples)")
            lines.append("  rolling window seconds: \(fmt(tracking.diagFreeDriveWindowSeconds, 1, suffix: " s"))")
            lines.append("  dwell samples on candidate: \(tracking.diagFreeDriveDwellSamples)")
            lines.append("  paths completed: \(tracking.diagFreeDriveCompletedCount)")
            lines.append("  paths skipped: \(live.skippedPaths.count) (skipped not used in Free Drive)")
            lines.append("  travel direction (locked): \(fmt(movement, 1, suffix: "°"))")
            lines.append("  row heading: \(fmt(rowDir, 1, suffix: "°"))")
            lines.append("  sameDirection: \(sameDir)")
            lines.append("  left row label: \(leftRowLabel)")
            lines.append("  right row label: \(rightRowLabel)")
        }
        lines.append("Warning: \(warning)")
        return lines.joined(separator: "\n")
    }

    /// Pins rendered on the live trip map. By default we show only pins
    /// that belong to the current trip. With the pin-overlay toggle ON
    /// the operator also sees existing pins in the same vineyard so they
    /// can avoid dropping duplicates before the warning is triggered.
    private var visibleMapPins: [VinePin] {
        let tripPins = store.pins.filter { $0.tripId == trip.id }
        guard showPinOverlay else { return tripPins }
        let vineyardId = store.selectedVineyardId
        let blockIds: Set<UUID> = {
            var ids = Set<UUID>(trip.paddockIds)
            if let id = trip.paddockId { ids.insert(id) }
            if let id = tracking.currentPaddockId { ids.insert(id) }
            return ids
        }()
        let overlay = store.pins.filter { pin in
            if let v = vineyardId, pin.vineyardId != v { return false }
            if !blockIds.isEmpty, let pid = pin.paddockId, !blockIds.contains(pid) {
                // include pins outside selected blocks too if they share
                // the vineyard — but cap to vineyard scope only.
                return true
            }
            return true
        }
        // Keep performance reasonable by capping overlay pin count.
        let combined = (tripPins + overlay).reduce(into: [UUID: VinePin]()) { acc, pin in
            acc[pin.id] = pin
        }
        let unique = Array(combined.values)
        if unique.count > 250 {
            return Array(unique.prefix(250))
        }
        return unique
    }

    private var navTitle: String {
        let label = trip.displayFunctionLabel
        if !label.isEmpty { return label }
        return currentPaddock?.name ?? (trip.paddockName.isEmpty ? "Active Trip" : trip.paddockName)
    }

    // MARK: - Top info bar

    private var tripInfoBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    showRepairs = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin").font(.caption)
                        Text("Repairs").font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.15), in: .rect(cornerRadius: 8))
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .disabled(!accessControl.canCreateOperationalRecords)

                Button {
                    showGrowth = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin").font(.caption)
                        Text("Growth").font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(VineyardTheme.leafGreen.opacity(0.15), in: .rect(cornerRadius: 8))
                    .foregroundStyle(VineyardTheme.leafGreen)
                }
                .buttonStyle(.plain)
                .disabled(!accessControl.canCreateOperationalRecords)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemGroupedBackground))

            HStack(spacing: 0) {
                statColumn(label: "CURRENT PATH",
                           value: formatPath(displayPath),
                           tint: Color.accentColor,
                           liveIndicator: tracking.rowGuidanceAvailable && tracking.currentRowNumber != nil)

                Divider().frame(height: 40)

                if isFreeDrive {
                    VStack(spacing: 4) {
                        Text("MODE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text("Free Drive")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(.teal)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    statColumn(label: "NEXT PATH",
                               value: formatPath(nextPath),
                               tint: .primary,
                               liveIndicator: false)
                }

                Divider().frame(height: 40)

                VStack(spacing: 4) {
                    Text("DISTANCE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(formatDistance(tracking.currentDistance))
                        .font(.system(.headline, design: .monospaced))
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 40)

                VStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Text("DURATION")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        if trip.isPaused {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(formatDuration(elapsedTimer))
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(trip.isPaused ? .orange : .primary)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)

            // Live status strip: speed, GPS quality and time remaining moved
            // out of the navigation toolbar (where the floating pill covered
            // the title and map) and into the fixed info bar instead.
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(speedDisplayText)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: displayedSpeedKmh)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)

                Divider().frame(height: 16)

                gpsQualityPill
                    .frame(maxWidth: .infinity)

                Divider().frame(height: 16)

                HStack(spacing: 3) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(timeLeftText)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: timeLeftText)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemGroupedBackground))

            if !trip.rowSequence.isEmpty {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: trip.trackingPattern.icon).font(.caption2)
                        Text(trip.trackingPattern.title).font(.caption2.weight(.medium))
                        Spacer()
                        Text("\(trip.sequenceIndex + 1) of \(trip.rowSequence.count)")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                    ProgressView(
                        value: Double(min(trip.sequenceIndex + 1, trip.rowSequence.count)),
                        total: Double(max(trip.rowSequence.count, 1))
                    )
                    .tint(Color.accentColor)
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func statColumn(label: String, value: String, tint: Color, liveIndicator: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if liveIndicator {
                    Image(systemName: "location.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
            }
            Text(value)
                .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Map

    enum MapFollowMode: Equatable {
        case free
        case zoomed
        case navigation
    }

    @ViewBuilder
    private var mapView: some View {
        if network.isOnline {
            hybridMapView
        } else {
            offlineMapView
        }
    }

    private var offlineMapView: some View {
        OfflineVineyardMapView(
            paddocks: paddocksOnMap.map { paddock in
                OfflineVineyardMapView.Paddock(
                    id: paddock.id,
                    polygon: paddock.polygonPoints.map { $0.coordinate },
                    rows: paddock.rows.map { [$0.startPoint.coordinate, $0.endPoint.coordinate] },
                    name: paddock.name
                )
            },
            trails: displayTrailSegments.map {
                OfflineVineyardMapView.Trail(id: $0.id, coordinates: $0.coordinates, color: $0.color)
            },
            pins: visibleMapPins.map {
                OfflineVineyardMapView.Pin(
                    id: $0.id,
                    coordinate: $0.coordinate,
                    color: Color.fromString($0.buttonColor),
                    name: $0.buttonName
                )
            },
            userCoordinate: locationService.location?.coordinate
        )
    }

    private var hybridMapView: some View {
        Map(position: $position) {
            ForEach(paddocksOnMap) { paddock in
                if paddock.polygonPoints.count >= 3 {
                    MapPolygon(coordinates: paddock.polygonPoints.map { $0.coordinate })
                        .foregroundStyle(VineyardTheme.leafGreen.opacity(0.15))
                        .stroke(VineyardTheme.leafGreen.opacity(0.7), lineWidth: 1.5)
                }
                ForEach(paddock.rows, id: \.id) { row in
                    MapPolyline(coordinates: [row.startPoint.coordinate, row.endPoint.coordinate])
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                }
            }

            // Display trail is precomputed off-body on a 1Hz throttle. Map
            // renders at most `maxTrailBuckets` polylines (3–5) regardless of
            // trip length, preventing the per-GPS-tick overlay explosion that
            // froze SwiftUI/MapKit.
            ForEach(displayTrailSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.color, lineWidth: 4)
            }

            ForEach(visibleMapPins) { pin in
                Annotation(pin.buttonName, coordinate: pin.coordinate) {
                    Circle()
                        .fill(Color.fromString(pin.buttonColor))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 1)
                }
            }

            UserAnnotation()
        }
        .mapStyle(.hybrid)
    }

    /// Compact wrong-row pill rendered above the side row chips so the
    /// row labels remain visible. Sits centred at the top of the map and
    /// keeps within a fixed width so it never reaches the left/right
    /// row labels.
    private var wrongPathBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.bold))
            VStack(alignment: .leading, spacing: 0) {
                Text("Wrong row")
                    .font(.caption.weight(.heavy))
                if let live = liveDetectedPath, let planned = plannedPath {
                    Text("on \(formatPath(live)) · planned \(formatPath(planned))")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [Color.red, Color.red.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(.white.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
        .sensoryFeedback(.warning, trigger: shouldShowWrongPathBanner)
    }

    /// Defensive UI guard so we never show "Realign to 96.5" while
    /// Current/Next already display 96.5. Mirrors the service-side
    /// suppression but protects against any state-update lag.
    private func shouldShowRealignBanner(for suggested: Double) -> Bool {
        if let current = displayPath, abs(current - suggested) < 0.01 { return false }
        if let next = nextPath, abs(next - suggested) < 0.01 { return false }
        if let planned = plannedPath, abs(planned - suggested) < 0.01 { return false }
        if let live = liveDetectedPath, abs(live - suggested) < 0.01,
           let current = displayPath, abs(current - live) < 0.01 { return false }
        return true
    }

    /// Auto-realign suggestion. Shown when the tracker is confidently
    /// locked onto a row that differs from the planned target. Two
    /// actions: “Realign” snaps the planned sequence to the locked
    /// row; “Ignore” suppresses the prompt for that path.
    private var autoRealignBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Realign trip?")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                if let p = tracking.autoRealignSuggestedPath {
                    Text("Looks like you're on path \(formatPath(p)).")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            Spacer(minLength: 8)
            Button {
                tracking.acceptAutoRealign()
            } label: {
                Text("Realign")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            Button {
                tracking.dismissAutoRealign()
            } label: {
                Text("Ignore")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color.blue, Color.blue.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 56)
        .padding(.horizontal, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var rowIndicatorOverlay: some View {
        HStack {
            rowChip(arrow: "arrow.left", label: leftRowLabel)
                // Push the left chip down to match the right side so the
                // two row indicators sit at the same height in the cab.
                .padding(.top, 180)
                .padding(.leading, 12)

            Spacer()

            rowChip(arrow: "arrow.right", label: rightRowLabel)
                // Push the right chip down past the stacked map controls
                // so it doesn't overlap with them.
                .padding(.top, 180)
                .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// Row side chip. When the wrong-path warning is active the chip
    /// switches to a red background and pulses so the operator can see
    /// at a glance that the displayed row labels apply to the LIVE path,
    /// not the planned target.
    private func rowChip(arrow: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: arrow).font(.caption2.weight(.bold))
            Text(label)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
        }
        .foregroundStyle(shouldShowWrongPathBanner ? Color.white : Color.primary)
        .frame(width: 78, height: 60)
        .background {
            if shouldShowWrongPathBanner {
                PulsingRedBackground()
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(shouldShowWrongPathBanner ? Color.white.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: shouldShowWrongPathBanner)
    }

    // MARK: - Trail throttling

    /// Schedule the throttled display-trail rebuild. Location updates and
    /// `trip.pathPoints` mutations keep happening; the on-screen polylines
    /// only refresh at most once per `trailUpdateInterval`.
    private func startTrailUpdater() {
        trailUpdateTimer?.invalidate()
        trailUpdateTimer = Timer.scheduledTimer(
            withTimeInterval: Self.trailUpdateInterval,
            repeats: true
        ) { _ in
            Task { @MainActor in
                refreshDisplayTrail()
            }
        }
    }

    /// Recompute display segments off the SwiftUI body. The full
    /// `trip.pathPoints` array is left untouched so trip history, export and
    /// sync still see every recorded point.
    private func refreshDisplayTrail() {
        let live = tracking.activeTrip ?? trip
        let points = live.pathPoints
        let segments = TrailDisplayProcessor.makeDisplayTrailSegments(
            points: points,
            maxDisplayPoints: Self.maxDisplayTrailPoints,
            maxColourBuckets: Self.maxTrailBuckets
        )
        displayTrailSegments = segments
        lastTrailUpdate = Date()
        trailDiagFullCount = points.count
        trailDiagDisplayCount = segments.reduce(0) { $0 + $1.coordinates.count }

        // Update the locked travel bearing on the same throttle so the
        // left/right row labels respond to direction without flicker.
        updateTravelBearing(from: locationService.location)

        #if DEBUG
        print("[Trail] full=\(trailDiagFullCount) display=\(trailDiagDisplayCount) " +
              "polylines=\(segments.count) interval=\(Self.trailUpdateInterval)s mode=bucketed")
        let path = pathForLabels
        let lower = Int(floor(path))
        let upper = lower + 1
        print("[RowSides] path=\(path) lower=\(lower) upper=\(upper) " +
              "rowDir=\(currentPaddock?.rowDirection ?? -1) " +
              "travelBearing=\(lockedTravelBearing.map { String(format: "%.1f", $0) } ?? "nil") " +
              "alongRow=\(isTravelingAlongRow) left=\(leftRowLabel) right=\(rightRowLabel)")
        #endif
    }

    /// Latch a stable travel bearing from recent GPS movement. Mirrors the
    /// legacy V1 behaviour: requires ≥3m of movement, only updates when the
    /// movement vector is close to (or opposite) the row direction, and
    /// flips the locked bearing only after 3 consecutive opposite samples.
    private func updateTravelBearing(from location: CLLocation?) {
        guard let location else { return }
        guard let last = lastBearingLocation else {
            lastBearingLocation = location
            return
        }
        let dist = location.distance(from: last)
        guard dist > 3 else { return }

        let dLat = location.coordinate.latitude - last.coordinate.latitude
        let dLon = location.coordinate.longitude - last.coordinate.longitude
        let lat1 = last.coordinate.latitude * .pi / 180
        let adjustedDLon = dLon * cos(lat1)
        var bearing = atan2(adjustedDLon, dLat) * 180 / .pi
        if bearing < 0 { bearing += 360 }

        lastBearingLocation = location

        let rowDir = currentPaddock?.rowDirection ?? 0
        var diffToRow = bearing - rowDir
        while diffToRow < 0 { diffToRow += 360 }
        while diffToRow >= 360 { diffToRow -= 360 }
        // Only accept samples that are roughly along the row vector
        // (within ±45°). Cross-row movement (turning at the headland)
        // is ignored so it can't flip left/right.
        let isAlongRow = diffToRow < 45 || diffToRow > 315
            || (diffToRow > 135 && diffToRow < 225)
        guard isAlongRow else { return }

        if let locked = lockedTravelBearing {
            var diffToLocked = bearing - locked
            while diffToLocked < 0 { diffToLocked += 360 }
            while diffToLocked >= 360 { diffToLocked -= 360 }
            if diffToLocked > 135 && diffToLocked < 225 {
                bearingLockSamples += 1
                if bearingLockSamples >= 3 {
                    lockedTravelBearing = bearing
                    bearingLockSamples = 0
                }
            } else {
                bearingLockSamples = 0
            }
        } else {
            lockedTravelBearing = bearing
        }
    }

    // MARK: - Banners

    private var rowTrackingDisabledBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.slash.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("ROW TRACKING DISABLED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("GPS path is still recording. Enable row tracking in Preferences for live row guidance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                showSummary = true
            } label: {
                Image(systemName: "list.bullet.clipboard")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var currentRowBanner: some View {
        let warn = shouldShowWrongPathBanner
        return HStack(spacing: 10) {
            Image(systemName: "location.fill")
                .font(.subheadline)
                .foregroundStyle(warn ? Color.white : Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(warn ? "LIVE PATH (WRONG ROW)" : "CURRENT PATH")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(warn ? Color.white.opacity(0.9) : .secondary)
                HStack(spacing: 4) {
                    Text("Path \(formatPath(displayPath))")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(warn ? Color.white : Color.accentColor)
                        .contentTransition(.numericText())
                    if let blockName = currentPaddock?.name {
                        Text("• \(blockName)")
                            .font(.subheadline)
                            .foregroundStyle(warn ? Color.white.opacity(0.85) : .secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Button {
                showSummary = true
            } label: {
                Image(systemName: "list.bullet.clipboard")
                    .font(.title3)
                    .foregroundStyle(warn ? Color.white : Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            if warn {
                PulsingRedBackground(cornerRadius: 0)
            } else {
                Color(.secondarySystemGroupedBackground)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: warn)
    }

    private func sprayBanner(record: SprayRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sprinkler.and.droplets.fill")
                .font(.title3)
                .foregroundStyle(VineyardTheme.leafGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.sprayReference.isEmpty ? "Spray Record" : record.sprayReference)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(record.tanks.count) tank\(record.tanks.count == 1 ? "" : "s") • \(record.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink {
                SprayRecordDetailView(record: record)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(VineyardTheme.leafGreen.opacity(0.08))
    }

    // MARK: - Trip controls

    private var tripControls: some View {
        HStack(spacing: 8) {
            if !trip.rowSequence.isEmpty && !trip.isPaused {
                // Compact undo/done pair — secondary to the live GPS
                // auto-advancement, but always available as a manual
                // fallback. Labels include the actual path number so it's
                // obvious in the cab which row each button affects. Both
                // buttons share remaining width so on a narrow iPhone
                // (SE) the labels still fit alongside pause + stop.
                HStack(spacing: 6) {
                    Button {
                        advanceRow(by: -1)
                    } label: {
                        Text(undoButtonLabel)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(trip.sequenceIndex <= 0)

                    Button {
                        advanceRow(by: 1)
                    } label: {
                        Text(doneButtonLabel)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                    .disabled(trip.sequenceIndex >= trip.rowSequence.count - 1)
                }
                .frame(maxWidth: .infinity)
            } else if trip.isPaused {
                HStack(spacing: 8) {
                    Image(systemName: "pause.fill").foregroundStyle(.orange)
                    Text("Trip Paused")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button {
                        showAddBlocks = true
                    } label: {
                        Label("Add block", systemImage: "plus.square")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .clipShape(Capsule())
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(VineyardTheme.leafGreen)
                    Text(tracking.rowGuidanceAvailable ? "GPS Tracking Active" : "Waiting for GPS")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            Button {
                withAnimation(.snappy) {
                    if trip.isPaused {
                        tracking.resumeTrip()
                    } else {
                        tracking.pauseTrip()
                    }
                }
            } label: {
                Image(systemName: trip.isPaused ? "play.fill" : "pause.fill")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .tint(trip.isPaused ? .green : .orange)
            .sensoryFeedback(.impact, trigger: trip.isPaused)

            Button {
                if (tracking.activeTrip ?? trip).rowSequence.isEmpty {
                    showEndConfirmation = true
                } else {
                    showEndReview = true
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .confirmationDialog("End Trip?", isPresented: $showEndConfirmation) {
                Button("End Trip", role: .destructive) {
                    ticker?.invalidate()
                    ticker = nil
                    tracking.endTrip()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will stop tracking and finalise the trip.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Helpers

    /// Label for the primary "mark current path complete & move on" button.
    /// Includes the actual planned path number so the operator can see in
    /// the cab exactly which row will be ticked off.
    private var doneButtonLabel: String {
        if let p = plannedPath {
            return "Done \(formatPath(p))"
        }
        return "Done"
    }

    /// Label for the secondary undo button. Reads as "Undo {previous path}"
    /// so it is clear that tapping will UN-tick the row that was just
    /// completed and step the planned sequence back by one.
    private var undoButtonLabel: String {
        let live = tracking.activeTrip ?? trip
        let prevIndex = live.sequenceIndex - 1
        if prevIndex >= 0, live.rowSequence.indices.contains(prevIndex) {
            return "Undo \(formatPath(live.rowSequence[prevIndex]))"
        }
        return "Undo"
    }

    private func advanceRow(by delta: Int) {
        guard !trip.rowSequence.isEmpty else { return }
        if delta > 0 {
            // Mark the current planned path as completed and advance to the
            // next pending one. Records a manual_next_path correction event
            // so the saved trip reflects the override.
            tracking.advanceToNextPlannedPath()
        } else if delta < 0 {
            tracking.goBackOnePlannedPath()
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if let active = tracking.activeTrip {
                    elapsedTimer = active.activeDuration
                    if let session = active.tankSessions.last(where: { $0.fillStartTime != nil && $0.fillEndTime == nil }),
                       let start = session.fillStartTime {
                        fillElapsed = Date().timeIntervalSince(start)
                    } else {
                        fillElapsed = 0
                    }
                }
                captureSpeedSample()
            }
        }
    }

    // MARK: - Tank controls

    private var liveTrip: Trip {
        tracking.activeTrip ?? trip
    }

    private var openTankSession: TankSession? {
        liveTrip.tankSessions.last(where: { $0.endTime == nil && $0.startRow != nil })
    }

    private var hasActiveTank: Bool {
        liveTrip.activeTankNumber != nil
    }

    private var isFilling: Bool {
        liveTrip.isFillingTank
    }

    private var completedTankCount: Int {
        liveTrip.tankSessions.filter { $0.endTime != nil }.count
    }

    @ViewBuilder
    private func tankControls(record: SprayRecord) -> some View {
        let totalTanks = max(record.tanks.count, liveTrip.totalTanks)
        let active = liveTrip.activeTankNumber
        let fillEnabled = store.settings.fillTimerEnabled

        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "drop.fill")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("TANK")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        if let n = active {
                            Text("\(n)\(totalTanks > 0 ? " of \(totalTanks)" : "")")
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .foregroundStyle(.cyan)
                        } else {
                            Text(totalTanks > 0 ? "\(completedTankCount) of \(totalTanks) done" : "Not started")
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let session = openTankSession {
                        if let idx = record.tanks.firstIndex(where: { $0.tankNumber == session.tankNumber }) {
                            let tank = record.tanks[idx]
                            Text("\(Int(tank.waterVolume)) L water • \(Int(tank.areaPerTank * 100) / 100) ha")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if !hasActiveTank, completedTankCount < record.tanks.count {
                        let next = record.tanks[completedTankCount]
                        Text("Next: Tank \(next.tankNumber) • \(Int(next.waterVolume)) L")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isFilling {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("FILLING")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.cyan)
                        Text(formatFillElapsed(fillElapsed))
                            .font(.system(.title3, design: .monospaced, weight: .bold))
                            .foregroundStyle(.cyan)
                            .contentTransition(.numericText())
                    }
                }
            }

            HStack(spacing: 8) {
                if hasActiveTank {
                    Button {
                        showEndTankConfirmation = true
                    } label: {
                        Label("End Tank", systemImage: "stop.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(!accessControl.canCreateOperationalRecords)
                } else {
                    Button {
                        tracking.startTank()
                    } label: {
                        Label("Start Tank", systemImage: "play.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(!accessControl.canCreateOperationalRecords)
                }

                if fillEnabled {
                    if isFilling {
                        Button {
                            tracking.stopFillTimer()
                        } label: {
                            Label("Stop Fill", systemImage: "stop.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(.cyan)
                    } else {
                        Button {
                            tracking.startFillTimer()
                        } label: {
                            Label("Start Fill", systemImage: "timer")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .tint(.cyan)
                        .disabled(hasActiveTank || !accessControl.canCreateOperationalRecords)
                    }
                }
            }

            if !liveTrip.tankSessions.isEmpty {
                tankProgressDots(total: totalTanks)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .confirmationDialog("End this tank?", isPresented: $showEndTankConfirmation) {
            Button("End Tank", role: .destructive) {
                tracking.endTank()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func tankProgressDots(total: Int) -> some View {
        let count = max(total, liveTrip.tankSessions.count)
        return HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                let number = i + 1
                let session = liveTrip.tankSessions.first(where: { $0.tankNumber == number })
                let isComplete = session?.endTime != nil
                let isActive = session?.endTime == nil && session?.startRow != nil
                Circle()
                    .fill(isComplete ? Color.cyan : (isActive ? Color.cyan.opacity(0.5) : Color.secondary.opacity(0.2)))
                    .frame(height: 6)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func formatFillElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatPath(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters))m" }
        return String(format: "%.1fkm", meters / 1000)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
