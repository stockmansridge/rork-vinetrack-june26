import Foundation
import CoreLocation

/// Backend-neutral live trip tracking service. Keeps the active trip in
/// MigratedDataStore.trips (where isActive == true) and appends GPS points to
/// it as the device location updates. Uses when-in-use location only.
@Observable
@MainActor
final class TripTrackingService {

    // MARK: - Published state

    var isTracking: Bool = false
    var isPaused: Bool = false
    var currentDistance: Double = 0
    var elapsedTime: TimeInterval = 0
    var currentSpeed: Double?
    var errorMessage: String?

    // Row guidance / coverage (live)
    var currentPaddockId: UUID?
    var currentPaddockName: String?
    var currentRowNumber: Double?
    var currentRowDistance: Double?
    var rowsCoveredCount: Int = 0
    var rowGuidanceAvailable: Bool = false

    // Live diagnostics — exposed for in-app "Copy diagnostics" so we can
    // capture field-test snapshots without Xcode logs. Updated each GPS
    // tick by `updateRowGuidance` and `finalizeIfThresholdMet`.
    var diagLiveDetectedPath: Double?
    var diagDistanceToPath: Double?
    var diagCorridorTolerance: Double?
    var diagInCorridor: Bool = false
    var diagPathMatch: Bool = false
    var diagPlannedPathLengthMeters: Double?
    var diagAccumulatedMeters: Double = 0
    var diagAutoCompleteLastPath: Double?
    var diagAutoCompleteLastFiredAt: Date?
    var diagDuplicateCheckResult: String?
    var diagDuplicateRadiusMeters: Double?

    // Free-drive diagnostics (only populated when the active trip is in
    // Free Drive mode). These mirror the live detection logic so the
    // operator can field-test row labels and coverage.
    var diagFreeDriveActive: Bool = false
    var diagFreeDriveCandidatePath: Double?
    var diagFreeDriveStablePath: Double?
    var diagFreeDriveWindowSamples: Int = 0
    var diagFreeDriveWindowSeconds: Double = 0
    var diagFreeDriveDwellSamples: Int = 0
    var diagFreeDriveCompletedCount: Int = 0

    // Row-lock diagnostics (apply to BOTH planned and free-drive modes)
    /// The path the tracker is *currently locked onto* — the row the
    /// tractor is physically working in. Once locked we don't switch rows
    /// because of brief GPS drift; only after sustained off-corridor
    /// evidence on the locked row plus dwell on a new candidate.
    var diagLockedPath: Double?
    /// 0–1 confidence the locked path is correct, derived from how long
    /// we have been continuously in-corridor on that row.
    var diagLockConfidence: Double = 0
    /// Seconds we have been continuously in-corridor on the locked path.
    var diagLockDwellSeconds: Double = 0
    /// True when the GPS is within `nearRowEndTolerance` metres of
    /// either end of the planned/locked row (used to suppress
    /// wrong-row warnings around row ends).
    var diagNearRowEnd: Bool = false
    /// Percentage of the planned path covered (0–100). Drives the
    /// ">50% completion suppresses wrong-row warning" rule.
    var diagPlannedCompletionPercent: Double = 0
    /// Reason the wrong-row banner is suppressed, if any. Surfaced to the
    /// in-app diagnostics dump so we can verify field behaviour.
    var diagWrongRowSuppressedReason: String?
    /// Recent manual-correction events recorded during this trip.
    var diagManualCorrectionEvents: [String] = []

    /// Path the tracker thinks the tractor is locked onto but which differs
    /// from the planned sequence target. Surfaced to the UI so it can prompt
    /// the operator to realign. Cleared on accept/dismiss/match.
    var autoRealignSuggestedPath: Double?
    /// Last path the operator dismissed for realignment — we won't re-prompt
    /// for the same path until the lock changes.
    private var lastDismissedRealignPath: Double?
    /// Last time we surfaced a realign suggestion. Used to throttle the
    /// banner so it doesn't flood the screen during turning manoeuvres.
    private var lastAutoRealignShownAt: Date?
    /// Minimum gap between successive realign suggestions, even for
    /// different paths. Keeps the screen quiet while the planned and
    /// live sequences settle after a row-end manoeuvre.
    private let autoRealignReshowCooldown: TimeInterval = 15.0
    /// Was the previous GPS tick on the planned path AND in-corridor?
    /// Drives end-of-row exit completion for short rows.
    private var previousOnPlannedInCorridor: Bool = false

    /// Last locked path that triggered an auto_sequence_recover audit
    /// event. Used to debounce repeated recoveries on the same row so
    /// the formal Trip Report stays focused on operator-meaningful
    /// events.
    private var lastAutoSequenceRecoverPath: Double?
    private var lastAutoSequenceRecoverAt: Date?
    /// Minimum gap between successive auto_sequence_recover audit
    /// entries for the same path.
    private let autoSequenceRecoverCooldown: TimeInterval = 60.0

    /// Smoothed ground speed in m/s. Derived from a rolling-window
    /// distance/time calculation across recent GPS samples — *not* from
    /// CLLocation.speed, which iOS halves at slow tractor speeds after
    /// the location stream has been running for a while. Used by the
    /// speedometer, ETA and any operational calculation that needs speed.
    var smoothedSpeed: Double = 0

    // MARK: - Speed diagnostics (exposed for in-app diagnostics dump)
    /// Last raw CLLocation.speed value (m/s). Diagnostics only — never
    /// shown to the operator and never used for ETA/job calculations.
    var rawCLLocationSpeed: Double = 0
    /// Distance/time speed across the rolling sample window (m/s).
    /// This is the primary speed source.
    var calculatedGroundSpeed: Double = 0
    /// EMA-smoothed version of `calculatedGroundSpeed` (m/s). Mirrors
    /// `smoothedSpeed` and is the value the UI actually displays.
    var smoothedGroundSpeed: Double = 0
    /// Number of valid GPS samples currently in the rolling window.
    var speedWindowSampleCount: Int = 0
    /// Seconds spanned by the rolling window's first → last sample.
    var speedWindowSeconds: Double = 0
    /// `"calculated"` when the displayed speed came from the rolling
    /// distance/time window, `"core-location"` if we briefly fell back
    /// to CLLocation.speed because the window didn't have enough valid
    /// samples yet, or `"none"` when no speed could be derived.
    var speedDisplaySource: String = "none"

    private var recentSpeedSamples: [(date: Date, location: CLLocation)] = []

    /// Maximum horizontal accuracy (m) we trust for speed calculation.
    /// Above this the sample is dropped from the rolling window.
    private let speedMaxAcceptableAccuracy: Double = 25.0
    /// Length of the rolling window in seconds.
    private let speedWindowDuration: TimeInterval = 8.0
    /// Below this calculated speed (m/s) we clamp to 0 — at standstill
    /// GPS jitter alone can produce 0.1–0.3 m/s.
    private let speedJitterFloor: Double = 0.4
    /// Reject impossible inter-sample velocities (m/s). Tractors do not
    /// teleport; anything above this is GPS error.
    private let speedMaxInstantaneous: Double = 50.0

    // MARK: - Dependencies

    private weak var store: MigratedDataStore?
    private weak var locationService: LocationService?

    private var trackingTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var lastObservedLocation: CLLocation?

    // Path-distance tracking for auto path completion (global path → metres).
    private var pathDistanceMap: [Double: Double] = [:]
    private var lastTrackingLocation: CLLocation?

    // Cached GlobalRowIndex per selected paddock-id set. Built once per
    // selection change instead of every GPS tick.
    private var cachedRowIndex: GlobalRowIndex?
    private var cachedRowIndexKey: [UUID] = []

    // Hard cap on retained recent-speed samples in addition to the time window.
    private let maxRecentSpeedSamples: Int = 30

    // Cooldown to prevent the same path completing twice in quick succession.
    private var lastAutoCompletePath: Double?
    private var lastAutoCompleteAt: Date?
    private let autoCompleteCooldown: TimeInterval = 2.5

    // Last live-detected path that the GPS was confirmed to be inside the
    // physical corridor of. Held while the tractor is between rows or has
    // briefly drifted outside corridor tolerance, so the live indicator
    // doesn't flicker back to nil.
    private var lastLivePathInCorridor: Double?

    // MARK: - Free-drive stability
    // Rolling window of recent live-detected paths used to pick the
    // "stable" detected path in Free Drive mode. GPS can hop between
    // adjacent rows for a sample or two; we only switch the displayed
    // path after the candidate has dwelled in the window long enough.
    private struct FreeDrivePathSample {
        let date: Date
        let path: Double
        let inCorridor: Bool
    }
    private var freeDriveSamples: [FreeDrivePathSample] = []
    private var freeDriveStablePath: Double?

    // MARK: - Row lock (applies to both planned and free-drive modes)
    /// Currently locked path. Held across short out-of-corridor blips so
    /// brief GPS drift, headland turns and row-end manoeuvres don't
    /// flip the operator into a wrong-row warning.
    private var lockedPath: Double?
    private var lockedPathSince: Date?
    /// Date of the last in-corridor sample on the locked path. Used to
    /// detect sustained departure before unlocking.
    private var lastInCorridorOnLockedAt: Date?
    /// Candidate competing path — only takes over after dwell.
    private var candidatePath: Double?
    private var candidateInCorridorCount: Int = 0
    private var candidateSince: Date?
    /// Min seconds in-corridor on a new candidate before we switch lock.
    private let lockSwitchDwellSeconds: TimeInterval = 4.0
    /// Min seconds out-of-corridor on the locked row before we will even
    /// consider switching. Vines physically prevent sideways movement.
    private let lockReleaseGraceSeconds: TimeInterval = 3.0
    /// Distance (metres) from row end that counts as "near" the headland.
    /// Wrong-row warnings are suppressed within this radius.
    private let nearRowEndTolerance: Double = 12.0
    /// Window length used to pick the majority detected path.
    private let freeDriveWindow: TimeInterval = 6.0
    /// Minimum consecutive recent in-corridor samples on a new candidate
    /// before the stable path switches. Tied to the GPS sample interval
    /// (~1Hz) so this is roughly the dwell time in seconds.
    private let freeDriveMinSwitchSamples: Int = 3

    // MARK: - Diagnostics (DEBUG only)
    #if DEBUG
    private(set) var diagLocationUpdateCount: Int = 0
    private(set) var diagAutoCompleteFiredCount: Int = 0
    private(set) var diagSequenceIndexChanges: Int = 0
    private(set) var diagRowIndexBuildCount: Int = 0
    private var lastDiagLogAt: Date = .distantPast
    private func breadcrumb(_ message: @autoclosure () -> String) {
        print("[ActiveTrip] \(message())")
    }
    #else
    @inline(__always) private func breadcrumb(_ message: @autoclosure () -> String) {}
    #endif

    // MARK: - Configuration

    func configure(store: MigratedDataStore, locationService: LocationService) {
        self.store = store
        self.locationService = locationService
        resumeIfNeeded()
    }

    // MARK: - Active trip helpers

    var activeTrip: Trip? {
        store?.trips.first { $0.isActive }
    }

    // MARK: - Start

    func startTrip(
        type: TripType,
        paddockId: UUID?,
        paddockName: String,
        trackingPattern: TrackingPattern = .sequential,
        personName: String = "",
        tripFunction: String? = nil,
        tripTitle: String? = nil,
        machineId: UUID? = nil,
        tractorId: UUID? = nil,
        operatorUserId: UUID? = nil,
        operatorCategoryId: UUID? = nil
    ) {
        guard let store else { return }
        guard store.selectedVineyardId != nil else {
            errorMessage = "No vineyard selected."
            return
        }
        if activeTrip != nil {
            errorMessage = "A trip is already in progress."
            return
        }

        let trip = Trip(
            paddockId: paddockId,
            paddockName: paddockName,
            paddockIds: paddockId.map { [$0] } ?? [],
            startTime: Date(),
            isActive: true,
            trackingPattern: trackingPattern,
            personName: personName,
            tripFunction: tripFunction,
            tripTitle: tripTitle,
            machineId: machineId,
            tractorId: tractorId,
            operatorUserId: operatorUserId,
            operatorCategoryId: operatorCategoryId
        )
        store.startTrip(trip)
        errorMessage = nil
        beginTracking()
        _ = type
    }

    // MARK: - Pause / Resume

    func pauseTrip() {
        guard var trip = activeTrip, !trip.isPaused else { return }
        trip.isPaused = true
        trip.pauseTimestamps.append(Date())
        store?.updateTrip(trip)
        isPaused = true
        stopTrackingLoops(stopLocation: false)
    }

    func resumeTrip() {
        guard var trip = activeTrip, trip.isPaused else { return }
        trip.isPaused = false
        trip.resumeTimestamps.append(Date())
        store?.updateTrip(trip)
        isPaused = false
        beginTracking()
    }

    // MARK: - End

    func endTrip() {
        // Final completion pass — credit the current/last locked row if
        // it was clearly driven but never produced a normal row-end
        // transition (typical for the last planned row, where there is
        // no "next row" to trigger the advance). Safe to call even if
        // the sheet already invoked it; idempotent.
        finalizePendingRowsForReview()

        guard var trip = activeTrip else { return }
        // Persist the manual-correction audit trail onto the trip so the
        // saved record (and the Trip Report) reflects every override that
        // happened during the live trip.
        if !diagManualCorrectionEvents.isEmpty {
            trip.manualCorrectionEvents = diagManualCorrectionEvents
            store?.updateTrip(trip)
        }
        store?.endTrip(trip.id)
        stopTrackingLoops(stopLocation: true)
        isTracking = false
        isPaused = false
        currentDistance = 0
        elapsedTime = 0
        currentSpeed = nil
        lastObservedLocation = nil
        currentPaddockId = nil
        currentPaddockName = nil
        currentRowNumber = nil
        currentRowDistance = nil
        rowsCoveredCount = 0
        rowGuidanceAvailable = false
        smoothedSpeed = 0
        smoothedGroundSpeed = 0
        calculatedGroundSpeed = 0
        rawCLLocationSpeed = 0
        speedWindowSampleCount = 0
        speedWindowSeconds = 0
        speedDisplaySource = "none"
        recentSpeedSamples.removeAll()
        pathDistanceMap.removeAll()
        lastTrackingLocation = nil
        cachedRowIndex = nil
        cachedRowIndexKey = []
        lastAutoCompletePath = nil
        lastAutoCompleteAt = nil
        lastLivePathInCorridor = nil
        freeDriveSamples.removeAll()
        freeDriveStablePath = nil
        lockedPath = nil
        lockedPathSince = nil
        lastInCorridorOnLockedAt = nil
        candidatePath = nil
        candidateInCorridorCount = 0
        candidateSince = nil
        diagLockedPath = nil
        diagLockConfidence = 0
        diagLockDwellSeconds = 0
        diagNearRowEnd = false
        diagPlannedCompletionPercent = 0
        diagWrongRowSuppressedReason = nil
        diagManualCorrectionEvents.removeAll()
        autoRealignSuggestedPath = nil
        lastDismissedRealignPath = nil
        lastAutoRealignShownAt = nil
        previousOnPlannedInCorridor = false
        lastAutoSequenceRecoverPath = nil
        lastAutoSequenceRecoverAt = nil
        diagFreeDriveActive = false
        diagFreeDriveCandidatePath = nil
        diagFreeDriveStablePath = nil
        diagFreeDriveWindowSamples = 0
        diagFreeDriveWindowSeconds = 0
        diagFreeDriveDwellSamples = 0
        diagFreeDriveCompletedCount = 0
        breadcrumb("endTrip")
    }

    // MARK: - Manual point

    func addCurrentLocationPoint() {
        guard let location = locationService?.location else { return }
        appendPoint(from: location, force: true)
    }

    // MARK: - Quick pin during trip

    /// Result of an in-trip pin drop. `.duplicateNearby` lets the caller
    /// surface a duplicate-warning sheet (View existing / Create anyway /
    /// Cancel) before retrying with `force: true`.
    enum DropPinResult {
        case created(VinePin)
        case duplicateNearby(existing: VinePin, distance: Double, radius: Double)
        case staleLocation(String)
        case failed(String)
    }

    @discardableResult
    func dropPinDuringTrip(
        button: ButtonConfig,
        paddockId: UUID? = nil,
        rowNumber: Int? = nil,
        side: PinSide = .right,
        notes: String? = nil,
        force: Bool = false
    ) -> DropPinResult {
        guard let store, let trip = activeTrip else {
            return .failed("No active trip.")
        }
        let fix = locationService?.freshLocation() ?? (nil, .unavailable)
        guard let location = fix.location else {
            errorMessage = "Location unavailable \u{2014} enable location services to drop a pin."
            return .staleLocation(errorMessage ?? "Location unavailable.")
        }
        switch fix.quality {
        case .fresh:
            break
        case .stale:
            let msg = "GPS fix is stale \u{2014} wait a moment for a fresh location before dropping a pin."
            errorMessage = msg
            return .staleLocation(msg)
        case .lowAccuracy:
            let msg = "GPS accuracy is low \u{2014} move to open sky and try again for a precise pin."
            errorMessage = msg
            return .staleLocation(msg)
        case .unavailable:
            let msg = "Location unavailable \u{2014} enable location services to drop a pin."
            errorMessage = msg
            return .staleLocation(msg)
        }

        let resolved = PinContextResolver.resolve(coordinate: location.coordinate, store: store, tracking: self)
        let resolvedPaddock = paddockId ?? resolved.paddockId ?? trip.paddockId
        let resolvedRow = rowNumber ?? resolved.rowNumber

        // Snap the pin coordinate onto the live locked row line when we
        // have a confident lock. Pins are almost always for issues on the
        // vine row itself (broken post, irrigation, growth, repair) so
        // placing them on the row centreline is operationally correct
        // and gives us a stable along-row coordinate for duplicate
        // checking. Falls back to the raw GPS point when no lock or
        // geometry is available.
        let confident = diagLockConfidence >= 0.6
        let drivingPath: Double? = lockedPath ?? currentRowNumber
        let paddockForGeometry: Paddock? = resolvedPaddock.flatMap { id in
            store.paddocks.first(where: { $0.id == id })
        }
        let attachment = PinAttachmentResolver.resolveLive(
            rawCoordinate: location.coordinate,
            heading: locationService?.heading?.trueHeading ?? 0,
            operatorSide: side,
            drivingPath: drivingPath,
            paddock: paddockForGeometry,
            confident: confident
        )
        let pinCoordinate = attachment.snappedCoordinate ?? location.coordinate
        let snappedToRow = attachment.snappedToRow
        let dupRow = attachment.pinRowNumber ?? resolvedRow
        let dupSide = attachment.pinSide ?? side

        if !force {
            // Prefer along-row duplicate detection when we have a row
            // lock. Same vineyard + paddock + row + mode within ~2.5 m
            // along the row line is a likely duplicate even if the raw
            // GPS samples sit slightly apart.
            if let alongRow = PinDuplicateChecker.nearbyPinAlongRow(
                snappedCoordinate: pinCoordinate,
                vineyardId: store.selectedVineyardId,
                paddockId: resolvedPaddock,
                rowNumber: dupRow,
                side: dupSide,
                mode: button.mode,
                in: store.pins,
                paddocks: store.paddocks
            ) {
                let title = alongRow.pin.buttonName.isEmpty ? "pin" : alongRow.pin.buttonName
                let status = alongRow.pin.isCompleted ? "completed" : "active"
                let dist = String(format: "%.2f", alongRow.distance)
                diagDuplicateRadiusMeters = PinDuplicateChecker.alongRowDuplicateMetres
                diagDuplicateCheckResult =
                    "duplicate_warning_shown_along_row: \(title), \(dist)m, status=\(status)"
                return .duplicateNearby(
                    existing: alongRow.pin,
                    distance: alongRow.distance,
                    radius: PinDuplicateChecker.alongRowDuplicateMetres
                )
            }
            let radius = PinDuplicateChecker.duplicateRadius(
                coordinate: pinCoordinate,
                paddockId: resolvedPaddock,
                paddocks: store.paddocks
            )
            diagDuplicateRadiusMeters = radius
            if let match = PinDuplicateChecker.nearbyPin(
                coordinate: pinCoordinate,
                vineyardId: store.selectedVineyardId,
                paddockId: resolvedPaddock,
                radius: radius,
                in: store.pins
            ) {
                let title = match.pin.buttonName.isEmpty ? "pin" : match.pin.buttonName
                let status = match.pin.isCompleted ? "completed" : "active"
                let dist = String(format: "%.2f", match.distance)
                diagDuplicateCheckResult =
                    "duplicate_warning_shown: \(title), \(dist)m, status=\(status)"
                return .duplicateNearby(existing: match.pin, distance: match.distance, radius: radius)
            }
            diagDuplicateCheckResult = snappedToRow ? "no_duplicate_found_snapped" : "no_duplicate_found"
        } else {
            diagDuplicateCheckResult = "duplicate_create_anyway"
        }

        guard var pin = store.createPinFromButton(
            button: button,
            coordinate: pinCoordinate,
            heading: locationService?.heading?.trueHeading,
            side: side,
            paddockId: resolvedPaddock,
            rowNumber: resolvedRow,
            notes: notes,
            attachment: attachment
        ) else { return .failed("Could not create pin \u{2014} no vineyard selected.") }
        print(PinContextResolver.diagnostic(coordinate: location.coordinate, side: side, mode: button.mode, resolved: resolved, store: store, tracking: self))

        pin.tripId = trip.id
        store.updatePin(pin)

        var updatedTrip = trip
        if !updatedTrip.pinIds.contains(pin.id) {
            updatedTrip.pinIds.append(pin.id)
            store.updateTrip(updatedTrip)
        }
        return .created(pin)
    }

    // MARK: - Tank workflow

    /// Index of the current open tank session (no endTime). nil if none.
    private func openSessionIndex(in trip: Trip) -> Int? {
        trip.tankSessions.lastIndex(where: { $0.endTime == nil })
    }

    /// Index of the most recent session that has an active fill timer
    /// (fillStartTime set, fillEndTime nil).
    private func openFillIndex(in trip: Trip) -> Int? {
        trip.tankSessions.lastIndex(where: { $0.fillStartTime != nil && $0.fillEndTime == nil })
    }

    /// Start spraying a new tank. If a tank session is already open it is
    /// closed first.
    func startTank() {
        guard var trip = activeTrip else { return }
        if let openIdx = openSessionIndex(in: trip) {
            // If there's an open session that hasn't actually been started
            // (fill-only), reuse it. Otherwise close it.
            let existing = trip.tankSessions[openIdx]
            let hasSpray = existing.fillEndTime != nil || existing.fillStartTime == nil ? false : false
            _ = hasSpray
            // Reuse if it was fill-only (fill recorded, never sprayed)
            if existing.fillStartTime != nil {
                trip.tankSessions[openIdx].startTime = Date()
                trip.tankSessions[openIdx].startRow = currentRowNumber ?? trip.currentRowNumber
                trip.activeTankNumber = existing.tankNumber
                trip.isFillingTank = false
                store?.updateTrip(trip)
                return
            }
            // Otherwise close it
            trip.tankSessions[openIdx].endTime = Date()
            trip.tankSessions[openIdx].endRow = currentRowNumber ?? trip.currentRowNumber
        }
        let nextNumber = (trip.tankSessions.map { $0.tankNumber }.max() ?? 0) + 1
        let session = TankSession(
            tankNumber: nextNumber,
            startTime: Date(),
            startRow: currentRowNumber ?? trip.currentRowNumber
        )
        trip.tankSessions.append(session)
        trip.activeTankNumber = nextNumber
        trip.isFillingTank = false
        store?.updateTrip(trip)
    }

    /// End the currently active tank session.
    func endTank() {
        guard var trip = activeTrip else { return }
        guard let idx = openSessionIndex(in: trip) else { return }
        trip.tankSessions[idx].endTime = Date()
        trip.tankSessions[idx].endRow = currentRowNumber ?? trip.currentRowNumber
        trip.activeTankNumber = nil
        store?.updateTrip(trip)
    }

    /// Start the fill timer for the next (or current) tank.
    func startFillTimer() {
        guard var trip = activeTrip else { return }
        if let idx = openSessionIndex(in: trip) {
            // Tank still open — record fill on it (rare but valid)
            trip.tankSessions[idx].fillStartTime = Date()
            trip.tankSessions[idx].fillEndTime = nil
        } else {
            // Create a new session in fill-only mode
            let nextNumber = (trip.tankSessions.map { $0.tankNumber }.max() ?? 0) + 1
            var session = TankSession(
                tankNumber: nextNumber,
                startTime: Date()
            )
            session.fillStartTime = Date()
            trip.tankSessions.append(session)
            trip.fillingTankNumber = nextNumber
        }
        trip.isFillingTank = true
        store?.updateTrip(trip)
    }

    /// Stop the fill timer. Records fillEndTime on the open fill session.
    func stopFillTimer() {
        guard var trip = activeTrip else { return }
        if let idx = openFillIndex(in: trip) {
            trip.tankSessions[idx].fillEndTime = Date()
        }
        trip.isFillingTank = false
        trip.fillingTankNumber = nil
        store?.updateTrip(trip)
    }

    /// Cancel a running fill timer without recording it.
    func resetFillTimer() {
        guard var trip = activeTrip else { return }
        if let idx = openFillIndex(in: trip) {
            // If the session is fill-only with no spray yet, drop it entirely.
            let session = trip.tankSessions[idx]
            if session.startRow == nil && session.endTime == nil {
                trip.tankSessions.remove(at: idx)
            } else {
                trip.tankSessions[idx].fillStartTime = nil
                trip.tankSessions[idx].fillEndTime = nil
            }
        }
        trip.isFillingTank = false
        trip.fillingTankNumber = nil
        store?.updateTrip(trip)
    }

    // MARK: - Resume after launch

    func resumeIfNeeded() {
        guard activeTrip != nil, !isTracking else { return }
        if activeTrip?.isPaused == true {
            isPaused = true
            return
        }
        beginTracking()
    }

    // MARK: - Internals

    private func beginTracking() {
        guard let locationService else { return }
        let status = locationService.authorizationStatus
        if status == .notDetermined {
            locationService.requestPermission()
        } else if status == .denied || status == .restricted {
            errorMessage = "Location permission is required to track trips."
            return
        } else if status == .authorizedWhenInUse {
            // Ask to upgrade to Always so the trip continues when the screen
            // locks or the user switches apps. Safe to call repeatedly — iOS
            // only shows the prompt once per app install.
            locationService.requestAlwaysPermission()
        }

        locationService.startUpdating()
        locationService.startBackgroundUpdating()
        // Active trips need the freshest possible GPS for row guidance and
        // pin placement, so opt-in to BestForNavigation while a trip is
        // running. Restored when the trip ends or pauses.
        locationService.enableHighAccuracyForActiveTrip()
        breadcrumb("beginTracking")
        isTracking = true
        isPaused = false
        lastObservedLocation = locationService.location
        if let trip = activeTrip {
            currentDistance = trip.totalDistance
            elapsedTime = trip.activeDuration
        }

        trackingTask?.cancel()
        let interval = max(0.5, store?.settings.rowTrackingInterval ?? 1.0)
        trackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run {
                    self.sampleAndAppendPoint()
                }
            }
        }

        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if Task.isCancelled { return }
                await MainActor.run {
                    if let trip = self.activeTrip {
                        self.elapsedTime = trip.activeDuration
                    }
                }
            }
        }
    }

    private func stopTrackingLoops(stopLocation: Bool) {
        trackingTask?.cancel()
        trackingTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        // Always stop background updates when the tracking loop pauses or
        // ends — we only want background location during an active trip.
        locationService?.stopBackgroundUpdating()
        locationService?.disableHighAccuracy()
        if stopLocation {
            locationService?.stopUpdating()
        }
        isTracking = false
    }

    private func sampleAndAppendPoint() {
        guard let location = locationService?.location else { return }
        appendPoint(from: location, force: false)
    }

    private func appendPoint(from location: CLLocation, force: Bool) {
        guard let store, var trip = activeTrip, !trip.isPaused else { return }
        #if DEBUG
        diagLocationUpdateCount += 1
        #endif

        let newPoint = CoordinatePoint(coordinate: location.coordinate)
        if let last = trip.pathPoints.last {
            let lastLocation = CLLocation(latitude: last.latitude, longitude: last.longitude)
            let segment = location.distance(from: lastLocation)
            if !force && segment < 1.0 { return }
            trip.totalDistance += segment
            trip.pathPoints.append(newPoint)
        } else {
            trip.pathPoints.append(newPoint)
        }

        let rowTrackingEnabled = store.settings.rowTrackingEnabled
        if rowTrackingEnabled {
            updateRowGuidance(for: location.coordinate, trip: &trip, store: store)
        } else {
            currentRowNumber = nil
            currentRowDistance = nil
            rowGuidanceAvailable = false
            rowsCoveredCount = trip.completedPaths.count
        }

        store.updateTrip(trip)
        currentDistance = trip.totalDistance
        updateSmoothedSpeed(from: location)
        currentSpeed = smoothedSpeed > 0 ? smoothedSpeed : nil
        lastObservedLocation = location
        rawCLLocationSpeed = max(0, location.speed)
    }

    /// Compute ground speed from distance/time across a rolling window of
    /// recent GPS samples instead of trusting `CLLocation.speed`. iOS
    /// applies an opaque smoothing/filter to the reported speed that, on
    /// long-running location streams at slow tractor speeds, drifts to
    /// roughly half the real ground speed and only recovers after the
    /// location stream is restarted. Distance/time over a short window is
    /// noisier per-tick but stays accurate for the duration of a trip.
    private func updateSmoothedSpeed(from location: CLLocation) {
        let now = Date()

        // Validate the new sample before adding it to the window.
        let acc = location.horizontalAccuracy
        let accOK = acc > 0 && acc <= speedMaxAcceptableAccuracy
        let timestampOK = location.timestamp.timeIntervalSinceNow > -5

        if accOK && timestampOK {
            // Reject impossible jumps relative to the previous accepted sample.
            if let prev = recentSpeedSamples.last {
                let dt = now.timeIntervalSince(prev.date)
                if dt > 0 {
                    let dist = location.distance(from: prev.location)
                    let inst = dist / dt
                    if inst <= speedMaxInstantaneous {
                        recentSpeedSamples.append((now, location))
                    }
                    // else: drop the bad sample, keep window stable
                }
                // dt <= 0 → duplicate timestamp, ignore
            } else {
                recentSpeedSamples.append((now, location))
            }
        }

        // Trim the window to the configured duration and hard cap.
        recentSpeedSamples.removeAll { now.timeIntervalSince($0.date) > speedWindowDuration }
        if recentSpeedSamples.count > maxRecentSpeedSamples {
            recentSpeedSamples.removeFirst(recentSpeedSamples.count - maxRecentSpeedSamples)
        }

        speedWindowSampleCount = recentSpeedSamples.count
        if let first = recentSpeedSamples.first, let last = recentSpeedSamples.last {
            speedWindowSeconds = last.date.timeIntervalSince(first.date)
        } else {
            speedWindowSeconds = 0
        }

        // Calculate ground speed: total distance from first → last across
        // the window divided by the elapsed time. Requires ≥2 samples and
        // ≥1 second so we don't divide by tiny dt.
        var calcSpeed: Double = 0
        if recentSpeedSamples.count >= 2,
           let first = recentSpeedSamples.first,
           let last = recentSpeedSamples.last {
            let dt = last.date.timeIntervalSince(first.date)
            if dt >= 1.0 {
                // Sum chained segment distances rather than first→last
                // straight-line, so a curved path is measured correctly.
                var distance: Double = 0
                for i in 1..<recentSpeedSamples.count {
                    distance += recentSpeedSamples[i].location.distance(
                        from: recentSpeedSamples[i - 1].location
                    )
                }
                calcSpeed = distance / dt
            }
        }

        if calcSpeed < speedJitterFloor { calcSpeed = 0 }
        calculatedGroundSpeed = calcSpeed

        // EMA smooth the calculated speed for the speedometer/ETA.
        if calcSpeed > 0 {
            if smoothedGroundSpeed > 0 {
                smoothedGroundSpeed = smoothedGroundSpeed * 0.5 + calcSpeed * 0.5
            } else {
                smoothedGroundSpeed = calcSpeed
            }
            smoothedSpeed = smoothedGroundSpeed
            speedDisplaySource = "calculated"
            return
        }

        // Window not yet usable (e.g. just started, or all samples were
        // rejected). Fall back to CLLocation.speed only when it's fresh
        // and positive — purely so the UI shows *something* while the
        // window is filling. Diagnostics make this fallback visible.
        if location.speed > 0, timestampOK {
            smoothedGroundSpeed = location.speed
            smoothedSpeed = location.speed
            speedDisplaySource = "core-location"
            return
        }

        smoothedGroundSpeed = 0
        smoothedSpeed = 0
        speedDisplaySource = "none"
    }

    // MARK: - Row guidance / coverage

    private func updateRowGuidance(
        for coordinate: CLLocationCoordinate2D,
        trip: inout Trip,
        store: MigratedDataStore
    ) {
        // Resolve all selected paddocks for this trip (multi-block aware).
        var selectedIds: [UUID] = trip.paddockIds
        if selectedIds.isEmpty, let id = trip.paddockId { selectedIds = [id] }
        let selected = selectedIds.compactMap { id in
            store.paddocks.first(where: { $0.id == id })
        }
        let candidates: [Paddock] = selected.isEmpty ? store.paddocks : selected

        guard let paddock = RowGuidance.paddock(for: coordinate, in: candidates) else {
            currentPaddockId = trip.paddockId
            currentPaddockName = trip.paddockName.isEmpty ? nil : trip.paddockName
            currentRowNumber = nil
            currentRowDistance = nil
            rowGuidanceAvailable = false
            rowsCoveredCount = trip.completedPaths.count
            return
        }

        currentPaddockId = paddock.id
        currentPaddockName = paddock.name
        if !trip.paddockIds.contains(paddock.id) {
            trip.paddockIds.append(paddock.id)
        }

        guard let match = RowGuidance.nearestRow(for: coordinate, in: paddock) else {
            currentRowNumber = nil
            currentRowDistance = nil
            rowGuidanceAvailable = false
            rowsCoveredCount = trip.completedPaths.count
            return
        }

        // Convert local row hit → global path number that lines up with
        // trip.rowSequence (which uses combined multi-block paths from
        // StartTripSheet). The index is cached per selection so we don't
        // rebuild it on every GPS tick.
        let index = rowIndex(for: candidates)
        let localRow = Int(match.rowNumber)
        let globalRow = index.globalRow(paddockId: paddock.id, localRow: localRow)
            ?? localRow

        // Detected live path snapped to the X.5 grid that's closest to the
        // current sequence path. May or may not equal the current sequence
        // path — that's exactly what we use to gate auto-completion.
        let livePath = livePathForSequence(
            globalRow: globalRow,
            sequence: trip.rowSequence,
            currentPath: trip.currentRowNumber
        ) ?? (Double(globalRow) - 0.5)

        rowGuidanceAvailable = true
        currentRowDistance = match.distance

        // The current intended path is what the operator is meant to be
        // driving — it is NOT changed just because the GPS happens to be
        // near a different row. This is critical for maintenance trips
        // where the operator may pass through off-cycle paths without
        // intending to complete them.
        let currentSequencePath: Double? = trip.rowSequence.indices.contains(trip.sequenceIndex)
            ? trip.rowSequence[trip.sequenceIndex]
            : nil

        // Path-match tolerance: livePath is snapped to the .5 grid, so an
        // exact equality is the right physical comparison. We still compare
        // with a small epsilon for FP safety.
        let pathMatch: Bool = {
            guard let target = currentSequencePath else { return false }
            return abs(livePath - target) < 0.01
        }()

        // Live path is only shown once the tractor is physically inside the
        // row corridor (within ~half row spacing of the row centreline).
        // This stops the indicator jumping to a path before we've actually
        // entered it. While outside the corridor we hold the last confirmed
        // live path (or fall back to the planned path).
        let corridorTolerance = max(1.0, paddock.rowWidth / 2.0)
        let inCorridor = match.distance <= corridorTolerance
        diagLiveDetectedPath = livePath
        diagDistanceToPath = match.distance
        diagCorridorTolerance = corridorTolerance
        diagInCorridor = inCorridor
        diagPathMatch = pathMatch
        diagPlannedPathLengthMeters = currentSequencePath.flatMap { rowLength(forPath: $0, paddock: paddock) }
        diagAccumulatedMeters = currentSequencePath.map { pathDistanceMap[$0, default: 0] } ?? 0

        // Update the path-lock state for both planned and free-drive
        // modes. Once locked, the tractor is treated as remaining on
        // that row until there is sustained evidence to the contrary.
        updatePathLock(livePath: livePath, inCorridor: inCorridor)

        // Near-row-end + completion percentage — used by the UI to
        // suppress wrong-row warnings when we are likely just
        // approaching/leaving the headland or have already covered most
        // of the planned row.
        let lockedOrPlanned = lockedPath ?? currentSequencePath
        diagNearRowEnd = lockedOrPlanned.map {
            isNearPathEnd(path: $0, paddock: paddock, location: locationService?.location, tolerance: nearRowEndTolerance)
        } ?? false
        if let len = diagPlannedPathLengthMeters, len > 0 {
            diagPlannedCompletionPercent = min(100, diagAccumulatedMeters / len * 100)
        } else {
            diagPlannedCompletionPercent = 0
        }

        let isFreeDrive = trip.trackingPattern == .freeDrive

        if isFreeDrive {
            // Free Drive: no planned sequence. Use a rolling-window
            // majority + dwell rule to pick the stable detected path,
            // then accumulate coverage on that path directly.
            updateFreeDriveStability(livePath: livePath, inCorridor: inCorridor)
            let stable = freeDriveStablePath
            diagFreeDriveActive = true
            diagFreeDriveCandidatePath = livePath
            diagFreeDriveStablePath = stable

            if inCorridor {
                lastLivePathInCorridor = livePath
                currentRowNumber = stable ?? livePath
            } else if let stable {
                currentRowNumber = stable
            } else if let held = lastLivePathInCorridor {
                currentRowNumber = held
            } else {
                currentRowNumber = livePath
            }
            trip.currentRowNumber = currentRowNumber ?? livePath

            if inCorridor, let stable, abs(stable - livePath) < 0.01 {
                accumulateDistanceAlong(path: stable, location: locationService?.location)
                let proximity = max(0.5, paddock.rowWidth / 2.0)
                if match.distance <= proximity {
                    _ = finalizeIfThresholdMet(
                        path: stable,
                        trip: &trip,
                        paddock: paddock,
                        rowWidth: paddock.rowWidth,
                        location: locationService?.location
                    )
                    // Free Drive never advances a sequence — there is no
                    // planned ordering to advance through.
                }
            } else {
                // Off-corridor or candidate not yet stable: reset segment
                // anchor so the next valid on-path tick doesn't accumulate
                // the gap distance.
                lastTrackingLocation = locationService?.location
            }
            diagFreeDriveCompletedCount = trip.completedPaths.count
        } else {
            diagFreeDriveActive = false
            // Prefer the LOCKED path for the live indicator. This keeps
            // the displayed row stable when GPS briefly drifts out of
            // corridor or near the row end. Falls back to live in-corridor
            // path, then last seen, then planned target.
            if let locked = lockedPath {
                currentRowNumber = locked
            } else if inCorridor {
                lastLivePathInCorridor = livePath
                currentRowNumber = livePath
            } else if let held = lastLivePathInCorridor {
                currentRowNumber = held
            } else if let target = currentSequencePath {
                currentRowNumber = target
            } else {
                currentRowNumber = livePath
            }
            if let target = currentSequencePath {
                trip.currentRowNumber = target
            } else {
                trip.currentRowNumber = currentRowNumber ?? livePath
            }

            // Only accumulate distance along the *current planned* path, and
            // only when the live GPS is actually on that path AND inside the
            // corridor. Driving an off-cycle path or skirting the corridor edge
            // contributes zero progress to the planned path.
            if pathMatch, inCorridor, let target = currentSequencePath {
                accumulateDistanceAlong(path: target, location: locationService?.location)

                // Auto-complete only when we are physically near the planned
                // row centreline and have covered enough of its length.
                let proximity = max(0.5, paddock.rowWidth / 2.0)
                if match.distance <= proximity {
                    let didComplete = finalizeIfThresholdMet(
                        path: target,
                        trip: &trip,
                        paddock: paddock,
                        rowWidth: paddock.rowWidth,
                        location: locationService?.location
                    )
                    if didComplete {
                        advanceSequenceAfterCompletion(trip: &trip)
                    }
                }
                previousOnPlannedInCorridor = true
            } else {
                // End-of-row exit completion: if the previous tick was on
                // the planned path in-corridor and the tractor has now
                // left the corridor near a row end, treat the row as
                // worked. This is critical for short rows where GPS
                // coverage often falls a metre or two short — without
                // this rule the planned sequence cascades out of sync.
                if previousOnPlannedInCorridor,
                   let target = currentSequencePath,
                   !trip.completedPaths.contains(target),
                   !trip.skippedPaths.contains(target) {
                    let nearEnd = isNearPathEnd(
                        path: target,
                        paddock: paddock,
                        location: locationService?.location,
                        tolerance: exitCompletionEndTolerance
                    )
                    if nearEnd {
                        let len = rowLength(forPath: target, paddock: paddock) ?? 0
                        let acc = pathDistanceMap[target, default: 0]
                        let minByFraction = max(0, len * exitCompletionMinCoverageFraction)
                        let minRequired = max(exitCompletionMinCoverageMeters, minByFraction)
                        if acc >= minRequired {
                            trip.completedPaths.append(target)
                            lastAutoCompletePath = target
                            lastAutoCompleteAt = Date()
                            diagAutoCompleteLastPath = target
                            diagAutoCompleteLastFiredAt = lastAutoCompleteAt
                            #if DEBUG
                            diagAutoCompleteFiredCount += 1
                            print("[TripAutoComplete] exit-near-end path=\(target) len=\(len) acc=\(acc)")
                            #endif
                            advanceSequenceAfterCompletion(trip: &trip)
                        }
                    }
                }
                previousOnPlannedInCorridor = false
                // Off-cycle: reset last tracking location so the next valid
                // on-path tick doesn't accumulate the off-path distance.
                lastTrackingLocation = locationService?.location
            }
        }

        #if DEBUG
        let acc = currentSequencePath.map { pathDistanceMap[$0, default: 0] } ?? 0
        let len = currentSequencePath.flatMap { rowLength(forPath: $0, paddock: paddock) } ?? 0
        let pct = len > 0 ? (acc / len * 100) : 0
        breadcrumb(
            "row plannedPath=\(currentSequencePath.map { String($0) } ?? "nil") " +
            "livePath=\(livePath) distance=\(String(format: "%.2f", match.distance))m " +
            "corridor=\(String(format: "%.2f", corridorTolerance))m inCorridor=\(inCorridor) " +
            "pathMatch=\(pathMatch) len=\(String(format: "%.1f", len))m " +
            "acc=\(String(format: "%.1f", acc))m pct=\(String(format: "%.0f", pct))%"
        )
        #endif

        rowsCoveredCount = trip.completedPaths.count
        #if DEBUG
        if Date().timeIntervalSince(lastDiagLogAt) > 10 {
            lastDiagLogAt = Date()
            breadcrumb(
                "diag updates=\(diagLocationUpdateCount) trailPts=\(trip.pathPoints.count) " +
                "autoCompletes=\(diagAutoCompleteFiredCount) seqChanges=\(diagSequenceIndexChanges) " +
                "rowIndexBuilds=\(diagRowIndexBuildCount) selectedPaddocks=\(candidates.count)"
            )
        }
        #endif
    }

    /// Maintain the rolling-window stability state used by Free Drive mode.
    /// `livePath` is the snapped live-detected path for this GPS tick (in
    /// the X.5 grid). `inCorridor` is whether the tractor is physically
    /// inside the row corridor for that path. Out-of-corridor samples are
    /// still tracked (as nil candidates) so brief drift to the headland
    /// doesn't immediately flip the stable path.
    private func updateFreeDriveStability(livePath: Double, inCorridor: Bool) {
        let now = Date()
        freeDriveSamples.append(.init(date: now, path: livePath, inCorridor: inCorridor))
        freeDriveSamples.removeAll { now.timeIntervalSince($0.date) > freeDriveWindow }
        let window = freeDriveSamples
        diagFreeDriveWindowSamples = window.count
        if let first = window.first {
            diagFreeDriveWindowSeconds = now.timeIntervalSince(first.date)
        } else {
            diagFreeDriveWindowSeconds = 0
        }

        // Majority candidate among in-corridor samples only — we don't want
        // out-of-corridor noise to dominate the vote.
        let inCorridorSamples = window.filter { $0.inCorridor }
        var counts: [Double: Int] = [:]
        for s in inCorridorSamples { counts[s.path, default: 0] += 1 }
        let candidate = counts.max(by: { $0.value < $1.value })?.key

        guard let cand = candidate else {
            // No in-corridor samples yet — hold previous stable path.
            diagFreeDriveDwellSamples = 0
            return
        }

        // Consecutive recent in-corridor samples on `cand`, counted from
        // the tail of the window. This is the "dwell" used to switch.
        var dwell = 0
        for s in window.reversed() {
            guard s.inCorridor else { break }
            if abs(s.path - cand) < 0.01 { dwell += 1 } else { break }
        }
        diagFreeDriveDwellSamples = dwell

        if freeDriveStablePath == nil {
            // First lock — require at least 2 in-corridor samples on the
            // candidate so a single GPS tick can't claim a row.
            if (counts[cand] ?? 0) >= 2 {
                freeDriveStablePath = cand
            }
        } else if abs((freeDriveStablePath ?? cand) - cand) > 0.01 {
            // Switching paths — require dwell.
            if dwell >= freeDriveMinSwitchSamples {
                freeDriveStablePath = cand
            }
        }
    }

    private func rowIndex(for candidates: [Paddock]) -> GlobalRowIndex {
        let key = candidates.map(\.id)
        if let cached = cachedRowIndex, key == cachedRowIndexKey {
            return cached
        }
        let built = GlobalRowIndex(paddocks: candidates)
        cachedRowIndex = built
        cachedRowIndexKey = key
        #if DEBUG
        diagRowIndexBuildCount += 1
        breadcrumb("rowIndex rebuilt entries=\(built.entries.count) totalRows=\(built.totalRows)")
        #endif
        return built
    }

    /// Choose the path (X-0.5 or X+0.5) for a detected global row that lies
    /// inside the active row sequence and is closest to the current path.
    private func livePathForSequence(
        globalRow: Int,
        sequence: [Double],
        currentPath: Double
    ) -> Double? {
        guard !sequence.isEmpty else { return nil }
        let candidates = [Double(globalRow) - 0.5, Double(globalRow) + 0.5]
        let set = Set(sequence)
        let matches = candidates.filter { set.contains($0) }
        if matches.isEmpty { return nil }
        return matches.min(by: { abs($0 - currentPath) < abs($1 - currentPath) })
    }

    private func accumulateDistanceAlong(path: Double, location: CLLocation?) {
        guard let location else { return }
        defer { lastTrackingLocation = location }
        guard let last = lastTrackingLocation else { return }
        let segment = location.distance(from: last)
        // Reject GPS jumps and noise.
        guard segment > 0.5, segment < 50 else { return }
        pathDistanceMap[path, default: 0] += segment
    }

    /// Rows shorter than this are considered "short" and use a more
    /// forgiving auto-completion rule that accounts for GPS drift, turning
    /// radius and slow tractor speed at the row ends.
    private let shortRowThresholdMetres: Double = 40.0
    /// Tolerance (m) used by end-of-row exit completion. When the tractor
    /// leaves the corridor of the planned path within this distance of
    /// either row end, we treat the row as worked even if GPS coverage
    /// fell short of the normal threshold (common on short vineyard rows).
    private let exitCompletionEndTolerance: Double = 8.0
    /// Minimum fraction of the planned row that must be covered before
    /// end-of-row exit can finalize it. Prevents a passing tractor that
    /// barely entered the corridor from being credited with the row.
    private let exitCompletionMinCoverageFraction: Double = 0.3
    /// Absolute minimum metres of accumulated coverage required before
    /// end-of-row exit completion can fire (used in addition to the
    /// fractional rule). Stops a 0.5m brush of the corridor counting.
    private let exitCompletionMinCoverageMeters: Double = 3.0

    /// Advance the planned sequence to the next pending path after the
    /// current one auto-completes. Skips any entries that are already
    /// marked completed/skipped so we never get stuck.
    private func advanceSequenceAfterCompletion(trip: inout Trip) {
        guard !trip.rowSequence.isEmpty else { return }
        var next = trip.sequenceIndex + 1
        while next < trip.rowSequence.count {
            let candidate = trip.rowSequence[next]
            if !trip.completedPaths.contains(candidate),
               !trip.skippedPaths.contains(candidate) { break }
            next += 1
        }
        let clamped = min(next, trip.rowSequence.count - 1)
        if clamped != trip.sequenceIndex {
            #if DEBUG
            diagSequenceIndexChanges += 1
            breadcrumb("sequenceIndex \(trip.sequenceIndex) -> \(clamped) (auto-complete advance)")
            #endif
            trip.sequenceIndex = clamped
            trip.currentRowNumber = trip.rowSequence[clamped]
            if clamped + 1 < trip.rowSequence.count {
                trip.nextRowNumber = trip.rowSequence[clamped + 1]
            } else {
                // End of sequence: keep nextRowNumber distinct from the
                // current row so the UI doesn't show "Current 96.5 / Next
                // 96.5". Use a sentinel just past the last row.
                trip.nextRowNumber = trip.rowSequence[clamped] + 1
            }
        }
    }

    @discardableResult
    private func finalizeIfThresholdMet(
        path: Double,
        trip: inout Trip,
        paddock: Paddock,
        rowWidth: Double,
        location: CLLocation?
    ) -> Bool {
        guard !trip.completedPaths.contains(path),
              !trip.skippedPaths.contains(path) else { return false }

        // Cooldown: never auto-complete the same path twice within a few
        // seconds, even if upstream calls us repeatedly.
        if let last = lastAutoCompletePath, last == path,
           let lastAt = lastAutoCompleteAt,
           Date().timeIntervalSince(lastAt) < autoCompleteCooldown {
            return false
        }

        let accumulated = pathDistanceMap[path, default: 0]
        let length = rowLength(forPath: path, paddock: paddock)

        var ruleUsed: String
        var requiredDistance: Double
        var didComplete = false

        if let length, length > 1 {
            if length <= shortRowThresholdMetres {
                // Short-row rule: complete on either
                //  • ~50 % of the row length covered (min 3 m), OR
                //  • operator is within ~5 m of either row end.
                // Tuned more forgiving than the long-row rule so short
                // rows (≈10–15 m) don't cascade into realign warnings
                // when GPS coverage falls a metre or two short.
                ruleUsed = "shortRow"
                requiredDistance = max(3.0, length * 0.5)
                let nearEnd = isNearPathEnd(path: path, paddock: paddock, location: location, tolerance: 5.0)
                if accumulated >= requiredDistance || nearEnd {
                    trip.completedPaths.append(path)
                    didComplete = true
                }
            } else {
                // Long-row rule: don't auto-complete in the middle of the row.
                // Either the operator must be near the row end (about to
                // turn out) with at least 60 % coverage, OR they have
                // covered ~95 % of the row (rare overshoot). This prevents
                // a 245 m row from being marked complete at 80 % (about
                // 50 m before the end) which then makes the planned
                // sequence advance and triggers a spurious wrong-row
                // warning while the operator is still driving the row.
                //
                // Special case: when this is the FIRST planned row, the
                // operator very often starts the trip part-way down the
                // row (e.g. drove the tractor from the shed into the
                // headland). In that case 60 % of the row length is
                // unreachable because we never accumulated the early
                // metres. Use a forgiving threshold so the first row
                // doesn't get stuck partial.
                ruleUsed = "longRow"
                let nearEnd = isNearPathEnd(
                    path: path,
                    paddock: paddock,
                    location: location,
                    tolerance: nearRowEndTolerance
                )
                let isFirstPlanned: Bool = trip.sequenceIndex == 0
                    && (trip.rowSequence.first.map { abs($0 - path) < 0.01 } ?? false)
                let nearEndCoverage = length * (isFirstPlanned ? 0.35 : 0.6)
                let overshootCoverage = length * 0.95
                requiredDistance = nearEnd ? nearEndCoverage : overshootCoverage
                if accumulated >= requiredDistance {
                    trip.completedPaths.append(path)
                    didComplete = true
                }
            }
        } else {
            // Fallback: no usable geometry length — 10 m of accumulation.
            ruleUsed = "fallback"
            requiredDistance = 10.0
            if accumulated >= requiredDistance {
                trip.completedPaths.append(path)
                didComplete = true
            }
        }

        if didComplete {
            lastAutoCompletePath = path
            lastAutoCompleteAt = Date()
            diagAutoCompleteLastPath = path
            diagAutoCompleteLastFiredAt = lastAutoCompleteAt
            #if DEBUG
            diagAutoCompleteFiredCount += 1
            #endif
        }

        #if DEBUG
        let lengthStr = length.map { String(format: "%.1f", $0) } ?? "nil"
        print(
            "[TripAutoComplete] path=\(path) rowLength=\(lengthStr)m rule=\(ruleUsed) " +
            "required=\(String(format: "%.1f", requiredDistance))m " +
            "accumulated=\(String(format: "%.1f", accumulated))m " +
            "autoComplete=\(didComplete)"
        )
        #endif
        return didComplete
    }

    private func isNearPathEnd(
        path: Double,
        paddock: Paddock,
        location: CLLocation?,
        tolerance: Double
    ) -> Bool {
        guard let location else { return false }
        let neighbours = [Int(floor(path)), Int(ceil(path))]
        for number in neighbours {
            guard let row = paddock.rows.first(where: { $0.number == number }) else { continue }
            let start = CLLocation(latitude: row.startPoint.latitude, longitude: row.startPoint.longitude)
            let end = CLLocation(latitude: row.endPoint.latitude, longitude: row.endPoint.longitude)
            if location.distance(from: start) <= tolerance { return true }
            if location.distance(from: end) <= tolerance { return true }
        }
        return false
    }

    // MARK: - Row lock

    /// Update the locked path / candidate path state. Vines physically
    /// prevent the tractor from changing rows mid-way, so we hold the
    /// lock through brief out-of-corridor blips and only switch after
    /// sustained evidence that the tractor is genuinely in another row.
    private func updatePathLock(livePath: Double, inCorridor: Bool) {
        let now = Date()

        if lockedPath == nil {
            // No lock yet — first solid in-corridor sample claims the lock.
            if inCorridor {
                lockedPath = livePath
                lockedPathSince = now
                lastInCorridorOnLockedAt = now
                candidatePath = nil
                candidateInCorridorCount = 0
                candidateSince = nil
            }
        } else if let locked = lockedPath, abs(locked - livePath) < 0.01 {
            // Still on the locked path. Refresh the in-corridor timestamp
            // when GPS confirms we are inside the corridor.
            if inCorridor { lastInCorridorOnLockedAt = now }
            candidatePath = nil
            candidateInCorridorCount = 0
            candidateSince = nil
        } else if inCorridor {
            // GPS reports a different in-corridor path. Only switch the
            // lock if we have been off the previously locked corridor for
            // a sustained grace period AND dwelled on the new path.
            let releasedAgo = lastInCorridorOnLockedAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            if let cand = candidatePath, abs(cand - livePath) < 0.01 {
                candidateInCorridorCount += 1
            } else {
                candidatePath = livePath
                candidateInCorridorCount = 1
                candidateSince = now
            }
            let dwell = candidateSince.map { now.timeIntervalSince($0) } ?? 0
            if releasedAgo >= lockReleaseGraceSeconds && dwell >= lockSwitchDwellSeconds {
                lockedPath = livePath
                lockedPathSince = now
                lastInCorridorOnLockedAt = now
                candidatePath = nil
                candidateInCorridorCount = 0
                candidateSince = nil
            }
        }
        // Else: out of corridor and not on locked row — hold lock.

        diagLockedPath = lockedPath
        if let since = lockedPathSince {
            let dwell = now.timeIntervalSince(since)
            diagLockDwellSeconds = dwell
            // Saturate to 1.0 after ~10s of continuous lock.
            diagLockConfidence = min(1.0, dwell / 10.0)
        } else {
            diagLockDwellSeconds = 0
            diagLockConfidence = 0
        }
        recomputeAutoRealignSuggestion()
    }

    // MARK: - Manual correction

    /// Force the planned-sequence index to the row the tractor is
    /// physically on right now. Records a diagnostic breadcrumb so we
    /// can audit the override after the trip.
    func snapPlannedSequenceToCurrentLivePath() {
        guard var trip = activeTrip, !trip.rowSequence.isEmpty else { return }
        guard let livePath = lockedPath ?? diagLiveDetectedPath else { return }
        if let idx = trip.rowSequence.firstIndex(where: { abs($0 - livePath) < 0.01 }) {
            trip.sequenceIndex = idx
            trip.currentRowNumber = trip.rowSequence[idx]
            if idx + 1 < trip.rowSequence.count {
                trip.nextRowNumber = trip.rowSequence[idx + 1]
            }
            store?.updateTrip(trip)
            recordCorrection("snap_to_live_path: \(livePath)")
        }
    }

    /// Mark the current planned path as completed manually and advance.
    func markCurrentPlannedPathComplete() {
        guard var trip = activeTrip, !trip.rowSequence.isEmpty else { return }
        let path = trip.rowSequence.indices.contains(trip.sequenceIndex)
            ? trip.rowSequence[trip.sequenceIndex]
            : trip.currentRowNumber
        if !trip.completedPaths.contains(path),
           !trip.skippedPaths.contains(path) {
            trip.completedPaths.append(path)
        }
        // Advance to next pending path.
        var next = trip.sequenceIndex + 1
        while next < trip.rowSequence.count {
            let p = trip.rowSequence[next]
            if !trip.completedPaths.contains(p) && !trip.skippedPaths.contains(p) { break }
            next += 1
        }
        let clamped = min(next, max(trip.rowSequence.count - 1, 0))
        trip.sequenceIndex = clamped
        if trip.rowSequence.indices.contains(clamped) {
            trip.currentRowNumber = trip.rowSequence[clamped]
        }
        store?.updateTrip(trip)
        recordCorrection("manual_complete: \(path)")
    }

    /// Skip the current planned path manually and advance.
    func skipCurrentPlannedPath() {
        guard var trip = activeTrip, !trip.rowSequence.isEmpty else { return }
        let path = trip.rowSequence.indices.contains(trip.sequenceIndex)
            ? trip.rowSequence[trip.sequenceIndex]
            : trip.currentRowNumber
        if !trip.skippedPaths.contains(path),
           !trip.completedPaths.contains(path) {
            trip.skippedPaths.append(path)
        }
        var next = trip.sequenceIndex + 1
        while next < trip.rowSequence.count {
            let p = trip.rowSequence[next]
            if !trip.completedPaths.contains(p) && !trip.skippedPaths.contains(p) { break }
            next += 1
        }
        let clamped = min(next, max(trip.rowSequence.count - 1, 0))
        trip.sequenceIndex = clamped
        if trip.rowSequence.indices.contains(clamped) {
            trip.currentRowNumber = trip.rowSequence[clamped]
        }
        store?.updateTrip(trip)
        recordCorrection("manual_skip: \(path)")
    }

    /// Operator-confirmed override of the locked row. Useful when the
    /// detection has drifted and the operator knows which row they are
    /// in. Sets the lock immediately with full confidence.
    func confirmCurrentLockedPath(_ path: Double) {
        lockedPath = path
        lockedPathSince = Date().addingTimeInterval(-10) // full confidence
        lastInCorridorOnLockedAt = Date()
        candidatePath = nil
        candidateInCorridorCount = 0
        candidateSince = nil
        diagLockedPath = path
        diagLockConfidence = 1.0
        recordCorrection("confirm_locked_path: \(path)")
    }

    private func recordCorrection(_ note: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        diagManualCorrectionEvents.append("\(stamp) \(note)")
        if diagManualCorrectionEvents.count > 30 {
            diagManualCorrectionEvents.removeFirst(diagManualCorrectionEvents.count - 30)
        }
    }

    /// Public hook so views (end-of-trip review, Next/Back, paddock add) can
    /// log manual correction events into the trip diagnostics audit trail.
    func recordManualCorrection(_ note: String) {
        recordCorrection(note)
    }

    // MARK: - Next/Back planned path (with audit)

    /// Manually advance to the next planned path, marking the current as
    /// completed. Mirrors the live auto-advance logic so the saved trip
    /// record stays consistent.
    func advanceToNextPlannedPath() {
        markCurrentPlannedPathComplete()
        recordCorrection("manual_next_path")
    }

    /// Manually step back one planned path. Removes the most recent
    /// completed/skipped entry on the new index so the operator can recover
    /// from a premature advance.
    func goBackOnePlannedPath() {
        guard var trip = activeTrip, !trip.rowSequence.isEmpty else { return }
        let newIndex = trip.sequenceIndex - 1
        guard newIndex >= 0 else { return }
        trip.sequenceIndex = newIndex
        trip.currentRowNumber = trip.rowSequence[newIndex]
        if newIndex + 1 < trip.rowSequence.count {
            trip.nextRowNumber = trip.rowSequence[newIndex + 1]
        }
        let restored = trip.rowSequence[newIndex]
        trip.completedPaths.removeAll { abs($0 - restored) < 0.01 }
        trip.skippedPaths.removeAll { abs($0 - restored) < 0.01 }
        store?.updateTrip(trip)
        recordCorrection("manual_back_path: \(restored)")
    }

    // MARK: - Auto-realign

    /// Accept the suggested realignment: snap the planned sequence index to
    /// the locked live path. Records the override in diagnostics.
    func acceptAutoRealign() {
        guard let path = autoRealignSuggestedPath else { return }
        if var trip = activeTrip,
           let idx = trip.rowSequence.firstIndex(where: { abs($0 - path) < 0.01 }) {
            trip.sequenceIndex = idx
            trip.currentRowNumber = trip.rowSequence[idx]
            if idx + 1 < trip.rowSequence.count {
                trip.nextRowNumber = trip.rowSequence[idx + 1]
            }
            store?.updateTrip(trip)
            recordCorrection("auto_realign_accepted: \(path)")
        }
        autoRealignSuggestedPath = nil
    }

    /// Operator dismissed the realignment prompt. Suppress for this same
    /// path until the lock changes.
    func dismissAutoRealign() {
        if let p = autoRealignSuggestedPath {
            recordCorrection("auto_realign_ignored: \(p)")
            lastDismissedRealignPath = p
        }
        autoRealignSuggestedPath = nil
    }

    /// Re-evaluate whether to suggest a realignment. Called from the row-lock
    /// updater whenever the locked path or trip state changes.
    private func recomputeAutoRealignSuggestion() {
        guard var trip = activeTrip,
              !trip.rowSequence.isEmpty,
              trip.rowSequence.indices.contains(trip.sequenceIndex),
              let locked = lockedPath,
              diagLockConfidence >= 0.6 else {
            autoRealignSuggestedPath = nil
            return
        }
        let planned = trip.rowSequence[trip.sequenceIndex]
        if abs(planned - locked) < 0.01 {
            autoRealignSuggestedPath = nil
            return
        }
        // Suppress contradictory banners: if the operator-visible "current"
        // path or the displayed "next" path already matches the locked
        // live path, asking them to realign to the same row is confusing.
        // In that case quietly sync the planned pointer instead.
        let displayedCurrent = currentRowNumber ?? trip.currentRowNumber
        let displayedNext = trip.nextRowNumber
        if abs(displayedCurrent - locked) < 0.01 || abs(displayedNext - locked) < 0.01 {
            autoRealignSuggestedPath = nil
            // Stalled-sequence recovery: live row is the locked path but the
            // planned pointer is stuck (likely because a previous short row
            // didn't auto-complete). Advance the pointer silently to the
            // locked path so Current/Next labels make sense again.
            if let idx = trip.rowSequence.firstIndex(where: { abs($0 - locked) < 0.01 }),
               idx != trip.sequenceIndex {
                trip.sequenceIndex = idx
                trip.currentRowNumber = trip.rowSequence[idx]
                if idx + 1 < trip.rowSequence.count {
                    trip.nextRowNumber = trip.rowSequence[idx + 1]
                }
                store?.updateTrip(trip)
                // Debounce: only audit one auto_sequence_recover per
                // path, and not within the cooldown window. Without
                // this, the live tick can re-fire the recovery many
                // times per row and flood the formal Trip Report
                // with noisy lines that drown out operator events.
                let now = Date()
                let isNewPath = lastAutoSequenceRecoverPath.map { abs($0 - locked) > 0.01 } ?? true
                let isOutsideCooldown = lastAutoSequenceRecoverAt
                    .map { now.timeIntervalSince($0) > autoSequenceRecoverCooldown } ?? true
                if isNewPath || isOutsideCooldown {
                    lastAutoSequenceRecoverPath = locked
                    lastAutoSequenceRecoverAt = now
                    recordCorrection("auto_sequence_recover: \(locked)")
                }
            }
            return
        }
        // Only suggest if the locked path actually exists somewhere in the
        // planned sequence (there is something to realign to).
        guard trip.rowSequence.contains(where: { abs($0 - locked) < 0.01 }) else {
            autoRealignSuggestedPath = nil
            return
        }
        if let dismissed = lastDismissedRealignPath, abs(dismissed - locked) < 0.01 {
            return
        }
        // Quiet the realign banner during normal row-end turning and when
        // the operator is already most of the way through the planned row
        // — at that point the right move is to finish/accept rather than
        // realign. Both conditions are common during short-row work.
        if diagNearRowEnd {
            diagWrongRowSuppressedReason = "realign suppressed: near row end"
            return
        }
        if diagPlannedCompletionPercent > 40 {
            diagWrongRowSuppressedReason = "realign suppressed: planned >40% complete"
            return
        }
        // Cooldown: avoid flooding the screen with realign prompts. If we
        // recently surfaced a suggestion, hold off until the cooldown has
        // passed (unless the locked path is the same one already showing).
        if let last = lastAutoRealignShownAt,
           Date().timeIntervalSince(last) < autoRealignReshowCooldown,
           autoRealignSuggestedPath.map({ abs($0 - locked) > 0.01 }) ?? true {
            return
        }
        if autoRealignSuggestedPath.map({ abs($0 - locked) > 0.01 }) ?? true {
            lastAutoRealignShownAt = Date()
        }
        autoRealignSuggestedPath = locked
    }

    // MARK: - Paused trip: add paddocks

    /// Add additional paddocks to the active trip without resetting existing
    /// coverage. New paddocks' rows are appended to the planned sequence so
    /// the operator can continue into them after resuming. Records an audit
    /// event in diagnostics.
    func addPaddocksToActiveTrip(_ ids: [UUID]) {
        guard let store, var trip = activeTrip else { return }
        let existing = Set(trip.paddockIds)
        let newIds = ids.filter { !existing.contains($0) }
        guard !newIds.isEmpty else { return }
        trip.paddockIds.append(contentsOf: newIds)

        if !trip.rowSequence.isEmpty {
            for id in newIds {
                guard let paddock = store.paddocks.first(where: { $0.id == id }) else { continue }
                let nums = paddock.rows.map(\.number).sorted()
                for n in nums {
                    let path = Double(n) + 0.5
                    if !trip.rowSequence.contains(where: { abs($0 - path) < 0.01 }) {
                        trip.rowSequence.append(path)
                    }
                }
            }
        }
        store.updateTrip(trip)
        cachedRowIndex = nil
        cachedRowIndexKey = []
        let names = newIds.compactMap { id in store.paddocks.first(where: { $0.id == id })?.name }
        recordCorrection("paddocks_added: \(names.joined(separator: ", "))")
    }

    /// Final-pass completion review used by the End Trip Review sheet
    /// (and `endTrip`). Gives the current planned path and the live
    /// locked path (if different) one last chance to be marked complete
    /// using a more forgiving threshold than the live auto-complete.
    ///
    /// This is the safety net for first/last-row issues where the
    /// normal row-end transition never fires:
    ///  - first row was started mid-way so coverage never hits 60 %.
    ///  - last row has no following row to trigger the advance, and
    ///    the operator stops the trip before the exit-corridor rule
    ///    triggers.
    /// Idempotent — already completed/skipped paths are left alone.
    func finalizePendingRowsForReview() {
        guard let store, var trip = activeTrip else { return }
        guard !trip.rowSequence.isEmpty else { return }

        // Resolve all paddocks selected for this trip.
        var ids: [UUID] = trip.paddockIds
        if ids.isEmpty, let id = trip.paddockId { ids = [id] }
        let paddocks: [Paddock] = ids.compactMap { id in
            store.paddocks.first(where: { $0.id == id })
        }
        guard !paddocks.isEmpty else { return }

        // Candidate rows to revisit: the current planned sequence path
        // and the locked live path (if different and still in the
        // planned sequence). We do not credit arbitrary off-cycle
        // paths the operator drove through.
        var candidates: [Double] = []
        if trip.rowSequence.indices.contains(trip.sequenceIndex) {
            candidates.append(trip.rowSequence[trip.sequenceIndex])
        }
        if let locked = lockedPath,
           trip.rowSequence.contains(where: { abs($0 - locked) < 0.01 }),
           !candidates.contains(where: { abs($0 - locked) < 0.01 }) {
            candidates.append(locked)
        }

        var credited: [Double] = []
        for path in candidates {
            if trip.completedPaths.contains(path) || trip.skippedPaths.contains(path) { continue }
            // Find the paddock that owns this path so we can measure it.
            guard let paddock = paddocks.first(where: { rowLength(forPath: path, paddock: $0) != nil })
                ?? paddocks.first else { continue }
            let length = rowLength(forPath: path, paddock: paddock)
            let accumulated = pathDistanceMap[path, default: 0]

            // First or last row of the planned sequence — the cases
            // where the live finalize most often misses the row.
            let isFirstPlanned = trip.rowSequence.first.map { abs($0 - path) < 0.01 } ?? false
            let isLastPlanned = trip.rowSequence.last.map { abs($0 - path) < 0.01 } ?? false
            let isEdge = isFirstPlanned || isLastPlanned

            let threshold: Double
            if let len = length, len > 1 {
                if len <= shortRowThresholdMetres {
                    // Short rows: very forgiving on the review pass.
                    threshold = max(2.0, len * 0.35)
                } else if isLastPlanned {
                    // Last row in plan: most permissive — there is no
                    // "next row" to trigger the normal advance, and the
                    // operator is opening End Trip Review precisely
                    // because they're done. 10 % coverage or 8 m.
                    threshold = max(8.0, len * 0.10)
                } else if isFirstPlanned {
                    // First long row: 20 % coverage or 15 m (slightly
                    // stricter than last because the operator might
                    // genuinely be still in the row).
                    threshold = max(15.0, len * 0.20)
                } else {
                    // Mid-sequence long row: a little stricter.
                    threshold = max(30.0, len * 0.40)
                }
            } else {
                threshold = isEdge ? 4.0 : 8.0
            }

            // Edge-case fallback: if the live tracker is currently
            // locked onto this path AND we have any meaningful
            // coverage, credit it. Catches the last row when GPS
            // confidence was solid but coverage just under the
            // threshold (typical short trail-out at row end).
            let isCurrentlyLocked = lockedPath.map { abs($0 - path) < 0.01 } ?? false
            let lockedFallbackHits = isCurrentlyLocked && accumulated >= 3.0 && isEdge

            if accumulated >= threshold || lockedFallbackHits {
                trip.completedPaths.append(path)
                credited.append(path)
            }
        }

        guard !credited.isEmpty else { return }

        // Advance the sequence index past any newly completed entries
        // so the End Trip Review counts reflect the fix immediately.
        var idx = trip.sequenceIndex
        while idx < trip.rowSequence.count {
            let p = trip.rowSequence[idx]
            if !trip.completedPaths.contains(p) && !trip.skippedPaths.contains(p) { break }
            idx += 1
        }
        let clamped = min(idx, max(trip.rowSequence.count - 1, 0))
        if clamped != trip.sequenceIndex {
            trip.sequenceIndex = clamped
            if trip.rowSequence.indices.contains(clamped) {
                trip.currentRowNumber = trip.rowSequence[clamped]
            }
        }
        store.updateTrip(trip)
        let summary = credited.sorted().map { String(format: "%g", $0) }.joined(separator: ",")
        recordCorrection("end_review_auto_finalize: [\(summary)]")
    }

    private func rowLength(forPath path: Double, paddock: Paddock) -> Double? {
        // Path X.5 sits between rows X and X+1 — use either neighbour for length.
        let neighbours = [Int(floor(path)), Int(ceil(path))]
        for number in neighbours {
            if let row = paddock.rows.first(where: { $0.number == number }) {
                let a = CLLocation(latitude: row.startPoint.latitude, longitude: row.startPoint.longitude)
                let b = CLLocation(latitude: row.endPoint.latitude, longitude: row.endPoint.longitude)
                let length = a.distance(from: b)
                if length > 1 { return length }
            }
        }
        return nil
    }
}
