import SwiftUI
import MapKit
import CoreLocation

nonisolated enum TripSortOption: String, CaseIterable, Sendable {
    case date = "Date"
    case name = "Name"
    case elStage = "E-L Stage"
}

nonisolated enum TripTypeFilter: String, CaseIterable, Sendable {
    case all = "All"
    case spray = "Spray"
    case maintenance = "Maintenance"
}

struct TripView: View {
    @Environment(DataStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @Environment(\.accessControl) private var accessControl
    @State private var showTripTypeChoice: Bool = false
    @State private var showStartSheet: Bool = false
    @State private var showSprayCalculator: Bool = false
    @State private var showSprayTripSetup: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var tripToDelete: Trip? = nil
    @State private var tripSortOption: TripSortOption = .date
    @State private var tripTypeFilter: TripTypeFilter = .all
    @State private var tripSearchText: String = ""
    @State private var selectedTripId: UUID? = nil

    var body: some View {
        NavigationStack {
            Group {
                if let activeTrip = store.activeTrip {
                    ActiveTripView(trip: activeTrip)
                } else {
                    noActiveTripView
                }
            }
            .navigationTitle("Trip")
            .navigationBarTitleDisplayMode(store.activeTrip != nil ? .inline : .large)
            .background(Color(.systemGroupedBackground))
            .sheet(isPresented: $showTripTypeChoice) {
                TripTypeChoiceSheet { tripType in
                    showTripTypeChoice = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        switch tripType {
                        case .maintenance:
                            showStartSheet = true
                        case .spray:
                            showSprayTripSetup = true
                        }
                    }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showStartSheet) {
                StartTripSheet()
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSprayTripSetup) {
                SprayTripSetupSheet(
                    onSelectProgram: { _ in
                        showSprayCalculator = true
                    },
                    onCreateNew: {
                        showSprayCalculator = true
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSprayCalculator, onDismiss: {
                showSprayTripSetup = false
            }) {
                SprayCalculatorView()
            }
        }
    }

    private func elStageForTrip(_ trip: Trip) -> String? {
        let paddockIds = !trip.paddockIds.isEmpty ? trip.paddockIds : (trip.paddockId.map { [$0] } ?? [])
        guard !paddockIds.isEmpty else { return nil }
        let stagePins = store.pins
            .filter { $0.mode == .growth && $0.growthStageCode != nil && paddockIds.contains($0.paddockId ?? UUID()) }
            .sorted { $0.timestamp > $1.timestamp }
        return stagePins.first?.growthStageCode
    }

    private func elStageNumeric(_ code: String?) -> Int {
        guard let code else { return Int.max }
        let digits = code.filter { $0.isNumber }
        return Int(digits) ?? Int.max
    }

    private func tripDisplayName(_ trip: Trip) -> String {
        if let record = store.sprayRecord(for: trip.id), !record.sprayReference.isEmpty {
            return record.sprayReference
        }
        let dateStr = trip.startTime.formatted(date: .abbreviated, time: .omitted)
        return "Maintenance Trip \(dateStr)"
    }

    private var pastTrips: [Trip] {
        store.trips.filter { !$0.isActive }
    }

    private var filteredAndSortedTrips: [Trip] {
        var trips = pastTrips

        switch tripTypeFilter {
        case .all:
            break
        case .spray:
            trips = trips.filter { store.sprayRecord(for: $0.id) != nil }
        case .maintenance:
            trips = trips.filter { store.sprayRecord(for: $0.id) == nil }
        }

        if !tripSearchText.isEmpty {
            trips = trips.filter { trip in
                let name = tripDisplayName(trip)
                let paddock = trip.paddockName
                let person = trip.personName
                let combined = "\(name) \(paddock) \(person)"
                return combined.localizedStandardContains(tripSearchText)
            }
        }

        switch tripSortOption {
        case .date:
            trips.sort { $0.startTime > $1.startTime }
        case .name:
            trips.sort { tripDisplayName($0).lowercased() < tripDisplayName($1).lowercased() }
        case .elStage:
            trips.sort { elStageNumeric(elStageForTrip($0)) < elStageNumeric(elStageForTrip($1)) }
        }

        return trips
    }

    private var noActiveTripView: some View {
        VStack(spacing: 0) {
            if pastTrips.isEmpty {
                Spacer()
                emptyStateView
                Spacer()
            } else {
                tripHistoryList
            }

            startTripButton
                .padding()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "road.lanes")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)

            VStack(spacing: 8) {
                Text("No Trips Yet")
                    .font(.title2.weight(.semibold))
                Text("Start a trip to track your path through the vineyard rows.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    private var startTripButton: some View {
        Button {
            showTripTypeChoice = true
        } label: {
            Label("Start Trip", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var tripHistoryList: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TripTypeFilter.allCases, id: \.self) { filter in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                tripTypeFilter = filter
                            }
                        } label: {
                            Text(filter.rawValue)
                                .font(.subheadline.weight(tripTypeFilter == filter ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(tripTypeFilter == filter ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                                .foregroundStyle(tripTypeFilter == filter ? .white : .primary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .contentMargins(.horizontal, 16)
            .padding(.vertical, 8)

            List {
                Section {
                    ForEach(filteredAndSortedTrips) { trip in
                        Button {
                            selectedTripId = trip.id
                        } label: {
                            TripHistoryRow(
                                trip: trip,
                                pinCount: store.pins.filter { $0.tripId == trip.id }.count,
                                hasSprayRecord: store.sprayRecord(for: trip.id) != nil,
                                sprayReferenceName: store.sprayRecord(for: trip.id)?.sprayReference,
                                elStage: elStageForTrip(trip)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        guard accessControl?.canDelete ?? false else { return }
                        let trips = filteredAndSortedTrips
                        tripToDelete = offsets.first.map { trips[$0] }
                        showDeleteConfirmation = true
                    }
                } header: {
                    Label("Trip History", systemImage: "road.lanes")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(0)
        }
        .searchable(text: $tripSearchText, prompt: "Search trips")
        .alert("Delete Trip", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let trip = tripToDelete {
                    store.deleteTrip(trip)
                }
                tripToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                tripToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete this trip? This action cannot be undone.")
        }
        .navigationDestination(for: UUID.self) { tripId in
            if let trip = store.trips.first(where: { $0.id == tripId }) {
                if let record = store.sprayRecord(for: tripId) {
                    SprayRecordDetailView(record: record)
                } else {
                    TripDetailView(trip: trip)
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedTripId != nil },
            set: { if !$0 { selectedTripId = nil } }
        )) {
            if let tripId = selectedTripId, let trip = store.trips.first(where: { $0.id == tripId }) {
                if let record = store.sprayRecord(for: tripId) {
                    SprayRecordDetailView(record: record)
                } else {
                    TripDetailView(trip: trip)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !pastTrips.isEmpty {
                    Menu {
                        Picker("Sort By", selection: $tripSortOption) {
                            ForEach(TripSortOption.allCases, id: \.self) { option in
                                Label(option.rawValue, systemImage: tripSortIconName(for: option))
                                    .tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
    }

    private func tripSortIconName(for option: TripSortOption) -> String {
        switch option {
        case .date: return "calendar"
        case .name: return "textformat"
        case .elStage: return "leaf"
        }
    }
}

struct TripHistoryRow: View {
    let trip: Trip
    let pinCount: Int
    var hasSprayRecord: Bool = false
    var sprayReferenceName: String? = nil
    var elStage: String? = nil

    private var displayName: String {
        if let name = sprayReferenceName, !name.isEmpty {
            return name
        }
        let dateStr = trip.startTime.formatted(date: .abbreviated, time: .omitted)
        return "Maintenance Trip \(dateStr)"
    }

    private var duration: TimeInterval {
        trip.activeDuration
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                HStack(spacing: 6) {
                    Label(trip.startTime.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !trip.paddockName.isEmpty {
                    Label { Text(trip.paddockName) } icon: { GrapeLeafIcon(size: 12) }
                        .font(.caption)
                        .foregroundStyle(VineyardTheme.olive)
                }

                HStack(spacing: 10) {
                    if !trip.personName.isEmpty {
                        Label(trip.personName, systemImage: "person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let elStage {
                        Label(elStage, systemImage: "leaf.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Label(formatDuration(duration), systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label(formatDistance(trip.totalDistance), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if pinCount > 0 {
                    Label("\(pinCount) pins", systemImage: "mappin")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let hrs = mins / 60
        if hrs > 0 {
            return "\(hrs)h \(mins % 60)m"
        }
        return "\(mins)m"
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }
}

// MARK: - Active Trip View

struct ActiveTripView: View {
    let trip: Trip
    @Environment(DataStore.self) private var store
    @Environment(LocationService.self) private var locationService
    @Environment(TripTrackingService.self) private var trackingService
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showEndConfirmation: Bool = false
    @State private var showRowIndicator: Bool = true
    @State private var showTripSummary: Bool = false
    @State private var detectedRow: Int? = nil
    @State private var detectedBlockName: String? = nil
    @State private var lastTrackingLocation: CLLocation? = nil
    @State private var pathDistanceMap: [Double: Double] = [:]
    @State private var confirmedPath: Double? = nil
    @State private var candidatePath: Double? = nil
    @State private var candidateCount: Int = 0
    @State private var isFollowingUser: Bool = true
    @State private var lockedTravelBearing: Double? = nil
    @State private var bearingLockSamples: Int = 0
    @State private var lastBearingLocation: CLLocation? = nil
    @State private var showSprayRecordForm: Bool = false
    @State private var showTankStartConfirmation: Bool = false
    @State private var showTankEndConfirmation: Bool = false
    @State private var activeDurationTimer: TimeInterval = 0
    @State private var durationTimer: Timer? = nil
    @State private var showFillStopConfirmation: Bool = false
    @State private var fillElapsed: TimeInterval = 0
    @State private var fillTimer: Timer? = nil
    @State private var pinDropShortcutMode: PinMode? = nil

    private var currentSpeedKmh: Double {
        guard let speed = locationService.location?.speed, speed > 0 else { return 0 }
        return speed * 3.6
    }

    private var remainingPathCount: Int {
        guard !trip.rowSequence.isEmpty else { return 0 }
        return max(trip.rowSequence.count - trip.sequenceIndex - 1, 0)
    }

    private var totalRemainingDistance: Double {
        guard !trip.rowSequence.isEmpty else { return 0 }
        let remainingPaths = Array(trip.rowSequence.suffix(from: min(trip.sequenceIndex + 1, trip.rowSequence.count)))
        var total: Double = 0
        for path in remainingPaths {
            if let length = rowLengthForPath(path) {
                total += length
            }
        }
        return total
    }

    private var estimatedTimeRemaining: (hours: Int, minutes: Int)? {
        if let speed = locationService.location?.speed, speed > 0.5 {
            let remaining = totalRemainingDistance
            if remaining > 0 {
                let seconds = remaining / speed
                let totalMinutes = Int(seconds / 60)
                return (hours: totalMinutes / 60, minutes: totalMinutes % 60)
            }
        }
        guard !trip.rowSequence.isEmpty else { return nil }
        let completed = trip.completedPaths.count + trip.skippedPaths.count
        let total = trip.rowSequence.count
        guard completed > 0, completed < total else { return nil }
        let elapsed = trip.activeDuration
        let progressFraction = Double(completed) / Double(total)
        let estimatedTotal = elapsed / progressFraction
        let remainingSeconds = estimatedTotal - elapsed
        guard remainingSeconds > 0 else { return nil }
        let totalMinutes = Int(remainingSeconds / 60)
        return (hours: totalMinutes / 60, minutes: totalMinutes % 60)
    }

    private var currentPaddocks: [Paddock] {
        if !trip.paddockIds.isEmpty {
            return store.paddocks.filter { trip.paddockIds.contains($0.id) }
        }
        guard let paddockId = trip.paddockId else { return [] }
        return store.paddocks.filter { $0.id == paddockId }
    }

    private var livePathNumber: Double? {
        guard let row = detectedRow, !trip.rowSequence.isEmpty else { return nil }
        let candidatePaths = [Double(row) - 0.5, Double(row) + 0.5]
        let sequenceSet = Set(trip.rowSequence)
        let matchingPaths = candidatePaths.filter { sequenceSet.contains($0) }
        if matchingPaths.isEmpty { return nil }
        return matchingPaths.min(by: { abs($0 - trip.currentRowNumber) < abs($1 - trip.currentRowNumber) })
    }

    private var liveNextPath: Double? {
        guard let currentPath = livePathNumber else { return nil }
        guard let idx = trip.rowSequence.firstIndex(of: currentPath) else { return nil }
        let nextIdx = idx + 1
        guard nextIdx < trip.rowSequence.count else { return nil }
        return trip.rowSequence[nextIdx]
    }

    private var effectivePath: Double {
        confirmedPath ?? livePathNumber ?? trip.currentRowNumber
    }

    private var increasingRowSide: Double {
        let rowDir = currentPaddocks.first?.rowDirection ?? 0
        return (rowDir + 90).truncatingRemainder(dividingBy: 360)
    }

    private var isTravelingAlongRowDirection: Bool {
        guard let locked = lockedTravelBearing else { return true }
        let rowDir = currentPaddocks.first?.rowDirection ?? 0
        var diff = locked - rowDir
        while diff < 0 { diff += 360 }
        while diff >= 360 { diff -= 360 }
        return diff < 90 || diff > 270
    }

    private var leftRowNumber: Int {
        return isTravelingAlongRowDirection ? Int(ceil(effectivePath)) : Int(floor(effectivePath))
    }

    private var rightRowNumber: Int {
        return isTravelingAlongRowDirection ? Int(floor(effectivePath)) : Int(ceil(effectivePath))
    }

    var body: some View {
        VStack(spacing: 0) {
            tripInfoBar
            
            ZStack(alignment: .topTrailing) {
                mapView
                
                VStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy) {
                            isFollowingUser = true
                            position = .userLocation(fallback: .automatic)
                        }
                    } label: {
                        Image(systemName: isFollowingUser ? "location.fill" : "location")
                            .font(.title2)
                            .foregroundStyle(isFollowingUser ? Color.accentColor : .primary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.snappy) {
                            showRowIndicator.toggle()
                        }
                    } label: {
                        Image(systemName: showRowIndicator ? "arrow.left.and.right.circle.fill" : "arrow.left.and.right.circle")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                
                if showRowIndicator {
                    rowIndicatorOverlay
                }
            }

            currentRowBanner
            fillControlBar
            tankControlBar
            tripControls
        }
        .sheet(isPresented: $showTripSummary) {
            TripSummarySheet(trip: trip)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSprayRecordForm) {
            SprayRecordFormView(
                tripId: trip.id,
                paddockIds: trip.paddockIds,
                existingRecord: store.sprayRecord(for: trip.id)
            )
        }
        .sheet(isPresented: Binding(
            get: { pinDropShortcutMode != nil },
            set: { if !$0 { pinDropShortcutMode = nil } }
        )) {
            PinDropView(initialMode: pinDropShortcutMode ?? .repairs)
        }
        .onAppear {
            locationService.startUpdating()
            if !trackingService.isTracking && !trip.isPaused {
                trackingService.startTracking()
            }
            confirmedPath = trip.currentRowNumber
            updateDetectedRow(from: locationService.location)
            activeDurationTimer = trip.activeDuration
            startDurationTimer()
            startFillTimerIfNeeded()
        }
        .onDisappear {
            durationTimer?.invalidate()
            durationTimer = nil
            fillTimer?.invalidate()
            fillTimer = nil
        }
        .onChange(of: locationService.location) { _, newLocation in
            updateDetectedRow(from: newLocation)
            updateTravelBearing(from: newLocation)
        }
        .onMapCameraChange { _ in
            isFollowingUser = false
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f km/h", currentSpeedKmh))
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: currentSpeedKmh)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let eta = estimatedTimeRemaining {
                            if eta.hours > 0 {
                                Text("\(eta.hours)h \(eta.minutes)m")
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            } else {
                                Text("\(eta.minutes)m")
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            }
                        } else {
                            Text("--")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var mapView: some View {
        Map(position: $position) {
            if trip.pathPoints.count > 1 {
                let coords = trip.pathPoints.map { $0.coordinate }
                let segmentCount = max(coords.count - 1, 1)
                ForEach(0..<(coords.count - 1), id: \.self) { i in
                    let progress = Double(i) / Double(segmentCount)
                    MapPolyline(coordinates: [coords[i], coords[i + 1]])
                        .stroke(gradientColor(for: progress), lineWidth: 4)
                }
            }

            UserAnnotation()
        }
        .mapStyle(.hybrid)
    }

    private var rowIndicatorOverlay: some View {
        HStack {
            VStack(spacing: 4) {
                Image(systemName: "arrow.left")
                    .font(.caption2.weight(.bold))
                Text("Row \(leftRowNumber)")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .contentTransition(.numericText())
            }
            .frame(width: 70, height: 60)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
            .padding(.leading, 12)

            Spacer()

            VStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.bold))
                Text("Row \(rightRowNumber)")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .contentTransition(.numericText())
            }
            .frame(width: 70, height: 60)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(.snappy, value: detectedRow)
    }

    private var tripInfoBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    pinDropShortcutMode = .repairs
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.fill")
                            .font(.caption)
                        Text("Repairs")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.15), in: .rect(cornerRadius: 8))
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)

                Button {
                    pinDropShortcutMode = .growth
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "leaf.fill")
                            .font(.caption)
                        Text("Growth")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(VineyardTheme.leafGreen.opacity(0.15), in: .rect(cornerRadius: 8))
                    .foregroundStyle(VineyardTheme.leafGreen)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemGroupedBackground))

            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("CURRENT PATH")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        if livePathNumber != nil {
                            Image(systemName: "location.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                    }
                    Text(formatPath(effectivePath))
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: effectivePath)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 40)

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Text("NEXT PATH")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        if liveNextPath != nil {
                            Image(systemName: "location.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                    }
                    Text(formatPath(liveNextPath ?? trip.nextRowNumber))
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: liveNextPath ?? trip.nextRowNumber)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 40)

                VStack(spacing: 4) {
                    Text("DISTANCE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(formatDistance(trip.totalDistance))
                        .font(.system(.headline, design: .monospaced))
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 40)

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
                    Text(formatActiveDuration(activeDurationTimer))
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(trip.isPaused ? .orange : .primary)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)

            if !trip.rowSequence.isEmpty {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: trip.trackingPattern.icon)
                            .font(.caption2)
                        Text(trip.trackingPattern.title)
                            .font(.caption2.weight(.medium))
                        Spacer()
                        Text("\(trip.sequenceIndex + 1) of \(trip.rowSequence.count)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                    ProgressView(value: Double(trip.sequenceIndex + 1), total: Double(trip.rowSequence.count))
                        .tint(Color.accentColor)
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var displayPath: Double? {
        if let confirmed = confirmedPath { return confirmed }
        if let live = livePathNumber { return live }
        guard let row = detectedRow else { return nil }
        return Double(row) - 0.5
    }

    private var currentRowBanner: some View {
        Group {
            if let path = displayPath {
                HStack(spacing: 10) {
                    Image(systemName: "location.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CURRENT PATH")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text("Path \(formatPath(path))")
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .contentTransition(.numericText())
                            if let blockName = detectedBlockName {
                                Text("• \(blockName)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    HStack(spacing: 12) {
                        if store.sprayRecord(for: trip.id) != nil {
                            Button {
                                showSprayRecordForm = true
                            } label: {
                                Image(systemName: "spray.and.fill")
                                    .font(.title3)
                                    .foregroundStyle(VineyardTheme.leafGreen)
                            }
                        }

                        Button {
                            showTripSummary = true
                        } label: {
                            Image(systemName: "list.bullet.clipboard")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
            }
        }
    }

    private func updateTravelBearing(from location: CLLocation?) {
        guard let location, let last = lastBearingLocation else {
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

        let rowDir = currentPaddocks.first?.rowDirection ?? 0
        var diffToRow = bearing - rowDir
        while diffToRow < 0 { diffToRow += 360 }
        while diffToRow >= 360 { diffToRow -= 360 }
        let isAlongRow = diffToRow < 45 || diffToRow > 315 || (diffToRow > 135 && diffToRow < 225)
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

    private func updateDetectedRow(from location: CLLocation?) {
        guard let coordinate = location?.coordinate else {
            detectedRow = nil
            detectedBlockName = nil
            return
        }
        let result = findPaddockAndRow(coordinate: coordinate, paddocks: currentPaddocks)
        withAnimation(.snappy(duration: 0.3)) {
            detectedRow = result?.closestRowNumber
            detectedBlockName = currentPaddocks.first(where: { $0.id == result?.paddockId })?.name
        }
        trackPathDistance(location: location)
    }

    private func trackPathDistance(location: CLLocation?) {
        guard let location else { return }

        if let last = lastTrackingLocation {
            let jumpDist = location.distance(from: last)
            if jumpDist > 50 {
                lastTrackingLocation = location
                return
            }
        }

        let currentPath = livePathNumber ?? (detectedRow.map { Double($0) - 0.5 })
        guard let path = currentPath else {
            lastTrackingLocation = location
            return
        }

        if path != confirmedPath {
            if path == candidatePath {
                candidateCount += 1
            } else {
                candidatePath = path
                candidateCount = 1
            }

            if candidateCount >= 3 {
                if let oldPath = confirmedPath {
                    finalizePathIfNeeded(oldPath)
                }
                confirmedPath = path
                candidatePath = nil
                candidateCount = 0
                syncConfirmedPath(path)
            } else {
                accumulateDistance(for: path, location: location)
                lastTrackingLocation = location
                return
            }
        }

        accumulateDistance(for: path, location: location)
        lastTrackingLocation = location
    }

    private func accumulateDistance(for path: Double, location: CLLocation) {
        guard let last = lastTrackingLocation else { return }
        let segmentDist = location.distance(from: last)
        guard segmentDist > 0.5 && segmentDist < 50 else { return }

        pathDistanceMap[path, default: 0] += segmentDist

        if let rowLength = rowLengthForPath(path), rowLength > 0 {
            let progress = pathDistanceMap[path, default: 0] / rowLength
            if progress >= 0.8 {
                var updated = trip
                if !updated.completedPaths.contains(path) {
                    updated.completedPaths.append(path)
                    store.updateTrip(updated)
                }
            }
        }
    }

    private func finalizePathIfNeeded(_ path: Double) {
        let distance = pathDistanceMap[path, default: 0]
        var updated = trip
        if !updated.completedPaths.contains(path) && !updated.skippedPaths.contains(path) {
            if let rowLength = rowLengthForPath(path), rowLength > 0 {
                let progress = distance / rowLength
                if progress >= 0.8 {
                    updated.completedPaths.append(path)
                    store.updateTrip(updated)
                }
            }
        }
    }

    private func syncConfirmedPath(_ path: Double) {
        guard !trip.rowSequence.isEmpty else { return }
        guard let liveIndex = trip.rowSequence.firstIndex(of: path) else { return }
        guard liveIndex != trip.sequenceIndex else { return }
        var updated = trip
        updated.sequenceIndex = liveIndex
        updated.currentRowNumber = path
        if liveIndex + 1 < updated.rowSequence.count {
            updated.nextRowNumber = updated.rowSequence[liveIndex + 1]
        } else {
            updated.nextRowNumber = path
        }
        store.updateTrip(updated)
    }

    private func rowLengthForPath(_ path: Double) -> Double? {
        let nearestRow = Int(ceil(path))
        for paddock in currentPaddocks {
            if let row = paddock.rows.first(where: { $0.number == nearestRow }) {
                let startLoc = CLLocation(latitude: row.startPoint.latitude, longitude: row.startPoint.longitude)
                let endLoc = CLLocation(latitude: row.endPoint.latitude, longitude: row.endPoint.longitude)
                let length = startLoc.distance(from: endLoc)
                if length > 1 { return length }
            }
        }
        return nil
    }

    private func finalizeCurrentPath() {
        let currentPath = trip.currentRowNumber
        var updated = trip
        if !updated.completedPaths.contains(currentPath) && !updated.skippedPaths.contains(currentPath) {
            let distance = pathDistanceMap[currentPath, default: 0]
            if let rowLength = rowLengthForPath(currentPath), rowLength > 0 {
                let progress = distance / rowLength
                if progress >= 0.8 {
                    updated.completedPaths.append(currentPath)
                } else {
                    updated.skippedPaths.append(currentPath)
                }
            } else {
                updated.skippedPaths.append(currentPath)
            }
        }

        for path in updated.rowSequence {
            if !updated.completedPaths.contains(path) && !updated.skippedPaths.contains(path) && path != currentPath {
                updated.skippedPaths.append(path)
            }
        }
        store.updateTrip(updated)
    }

    private var hasSprayProgram: Bool {
        store.sprayRecord(for: trip.id) != nil && trip.totalTanks > 0
    }

    private var nextTankToStart: Int? {
        guard hasSprayProgram else { return nil }
        if trip.activeTankNumber != nil { return nil }
        let completedTanks = trip.tankSessions.filter { $0.endTime != nil }.map { $0.tankNumber }
        for i in 1...trip.totalTanks {
            if !completedTanks.contains(i) { return i }
        }
        return nil
    }

    private var allTanksCompleted: Bool {
        guard hasSprayProgram else { return false }
        let completedTanks = Set(trip.tankSessions.filter { $0.endTime != nil }.map { $0.tankNumber })
        return completedTanks.count >= trip.totalTanks
    }

    private var fillTimerEnabled: Bool {
        store.settings.fillTimerEnabled
    }

    private var fillControlBar: some View {
        Group {
            if fillTimerEnabled && hasSprayProgram {
                VStack(spacing: 0) {
                    Divider()
                    if trip.isFillingTank, let tankNum = trip.fillingTankNumber {
                        HStack(spacing: 12) {
                            Button {
                                showFillStopConfirmation = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.title3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Stop Fill")
                                            .font(.headline)
                                        Text("Tank \(tankNum) • \(formatFillDuration(fillElapsed))")
                                            .font(.caption)
                                    }
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.orange.gradient, in: .rect(cornerRadius: 12))
                            }
                            .sensoryFeedback(.warning, trigger: showFillStopConfirmation)
                            .confirmationDialog(
                                "Stop filling Tank \(tankNum)?",
                                isPresented: $showFillStopConfirmation
                            ) {
                                Button("Stop Fill") {
                                    stopFill()
                                }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("This will record the fill duration for Tank \(tankNum).")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    } else if let nextTank = nextTankToFill {
                        Button {
                            startFill(tankNumber: nextTank)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "drop.circle.fill")
                                    .font(.title3)
                                Text("Start Fill – Tank \(nextTank)")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.cyan.gradient, in: .rect(cornerRadius: 12))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .sensoryFeedback(.success, trigger: trip.isFillingTank)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
            }
        }
    }

    private var nextTankToFill: Int? {
        guard hasSprayProgram else { return nil }
        if trip.isFillingTank { return nil }
        let filledTanks = Set(trip.tankSessions.compactMap { $0.fillEndTime != nil ? $0.tankNumber : nil })
        for i in 1...trip.totalTanks {
            if !filledTanks.contains(i) { return i }
        }
        return nil
    }

    private var tankControlBar: some View {
        Group {
            if hasSprayProgram && !allTanksCompleted {
                VStack(spacing: 0) {
                    Divider()
                    if let activeTank = trip.activeTankNumber {
                        Button {
                            showTankEndConfirmation = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "stop.circle.fill")
                                    .font(.title3)
                                Text("End Tank \(activeTank)")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.red.gradient, in: .rect(cornerRadius: 12))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .sensoryFeedback(.warning, trigger: showTankEndConfirmation)
                        .confirmationDialog(
                            "End Tank \(trip.activeTankNumber ?? 1)?",
                            isPresented: $showTankEndConfirmation
                        ) {
                            Button("End Tank \(trip.activeTankNumber ?? 1)", role: .destructive) {
                                endTank()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will finalize the row applications for Tank \(trip.activeTankNumber ?? 1).")
                        }
                    } else if let nextTank = nextTankToStart {
                        Button {
                            showTankStartConfirmation = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                Text("Start Tank \(nextTank)")
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(VineyardTheme.leafGreen.gradient, in: .rect(cornerRadius: 12))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .sensoryFeedback(.success, trigger: showTankStartConfirmation)
                        .confirmationDialog(
                            "Start Tank \(nextTankToStart ?? 1)?",
                            isPresented: $showTankStartConfirmation
                        ) {
                            Button("Start Tank \(nextTankToStart ?? 1)") {
                                startTank()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("All rows traversed while this tank is active will be recorded against Tank \(nextTankToStart ?? 1).")
                        }
                    }

                    let completedCount = trip.tankSessions.filter { $0.endTime != nil }.count
                    HStack(spacing: 6) {
                        ForEach(1...trip.totalTanks, id: \.self) { tankNum in
                            let isCompleted = trip.tankSessions.contains { $0.tankNumber == tankNum && $0.endTime != nil }
                            let isActive = trip.activeTankNumber == tankNum
                            Circle()
                                .fill(isCompleted ? Color.green : (isActive ? Color.orange : Color(.tertiarySystemFill)))
                                .frame(width: 8, height: 8)
                        }
                        Text("\(completedCount)/\(trip.totalTanks) tanks")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)
                }
                .background(Color(.secondarySystemGroupedBackground))
            }
        }
    }

    private func startTank() {
        guard let tankNum = nextTankToStart else { return }
        if trip.isFillingTank {
            stopFill()
        }
        var updated = store.activeTrip ?? trip
        updated.activeTankNumber = tankNum
        if let idx = updated.tankSessions.lastIndex(where: { $0.tankNumber == tankNum && $0.endTime == nil }) {
            updated.tankSessions[idx].startTime = Date()
        } else {
            let session = TankSession(
                tankNumber: tankNum,
                startTime: Date()
            )
            updated.tankSessions.append(session)
        }
        store.updateTrip(updated)
    }

    private func startFill(tankNumber: Int) {
        var updated = trip
        if let idx = updated.tankSessions.lastIndex(where: { $0.tankNumber == tankNumber && $0.endTime == nil }) {
            updated.tankSessions[idx].fillStartTime = Date()
        } else {
            let session = TankSession(
                tankNumber: tankNumber,
                startTime: Date(),
                fillStartTime: Date()
            )
            updated.tankSessions.append(session)
        }
        updated.isFillingTank = true
        updated.fillingTankNumber = tankNumber
        store.updateTrip(updated)
        startFillTimerIfNeeded()
    }

    private func stopFill() {
        var updated = store.activeTrip ?? trip
        guard let tankNum = updated.fillingTankNumber else { return }
        if let idx = updated.tankSessions.lastIndex(where: { $0.tankNumber == tankNum && $0.fillStartTime != nil && $0.fillEndTime == nil }) {
            updated.tankSessions[idx].fillEndTime = Date()
        }
        updated.isFillingTank = false
        updated.fillingTankNumber = nil
        store.updateTrip(updated)
        fillTimer?.invalidate()
        fillTimer = nil
        fillElapsed = 0
    }

    private func startFillTimerIfNeeded() {
        fillTimer?.invalidate()
        fillTimer = nil
        guard trip.isFillingTank, let tankNum = trip.fillingTankNumber else {
            fillElapsed = 0
            return
        }
        if let session = trip.tankSessions.last(where: { $0.tankNumber == tankNum && $0.fillStartTime != nil && $0.fillEndTime == nil }),
           let start = session.fillStartTime {
            fillElapsed = Date().timeIntervalSince(start)
            fillTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    fillElapsed = Date().timeIntervalSince(start)
                }
            }
        }
    }

    private func formatFillDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(seconds, 0))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func endTank() {
        guard let activeTank = trip.activeTankNumber else { return }
        var updated = trip

        if let idx = updated.tankSessions.lastIndex(where: { $0.tankNumber == activeTank && $0.endTime == nil }) {
            updated.tankSessions[idx].endTime = Date()

            let sessionStart = updated.tankSessions[idx].startTime
            let coveredPaths = updated.completedPaths
            updated.tankSessions[idx].pathsCovered = coveredPaths

            if let minPath = coveredPaths.min(), let maxPath = coveredPaths.max() {
                updated.tankSessions[idx].startRow = minPath
                updated.tankSessions[idx].endRow = maxPath
            }

            if var record = store.sprayRecord(for: trip.id) {
                let tankIndex = activeTank - 1
                if tankIndex < record.tanks.count {
                    let session = updated.tankSessions[idx]
                    let rowApp = TankRowApplication(
                        startRow: session.startRow ?? 0.5,
                        endRow: session.endRow ?? 0.5
                    )
                    record.tanks[tankIndex].rowApplications = [rowApp]
                    store.updateSprayRecord(record)
                }
            }
        }

        updated.activeTankNumber = nil
        store.updateTrip(updated)
    }

    private var isGPSActive: Bool {
        detectedRow != nil && trackingService.isTracking
    }

    private var tripControls: some View {
        HStack(spacing: 12) {
            if !isGPSActive && !trip.isPaused {
                Button {
                    advanceRow(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.bordered)
                .disabled(trip.rowSequence.isEmpty ? trip.currentRowNumber <= 0.5 : trip.sequenceIndex <= 0)

                Button {
                    advanceRow(by: 1)
                } label: {
                    Label("Next Path", systemImage: "chevron.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!trip.rowSequence.isEmpty && trip.sequenceIndex >= trip.rowSequence.count - 1)
            } else if trip.isPaused {
                HStack(spacing: 8) {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.orange)
                    Text("Trip Paused")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(VineyardTheme.leafGreen)
                    Text("GPS Tracking Active")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            Button {
                withAnimation(.snappy(duration: 0.3)) {
                    if trip.isPaused {
                        trackingService.resumeTracking()
                        startDurationTimer()
                    } else {
                        trackingService.pauseTracking()
                        durationTimer?.invalidate()
                        durationTimer = nil
                    }
                }
            } label: {
                Image(systemName: trip.isPaused ? "play.fill" : "pause.fill")
                    .font(.headline)
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(.bordered)
            .tint(trip.isPaused ? .green : .orange)
            .sensoryFeedback(.impact, trigger: trip.isPaused)

            Button {
                showEndConfirmation = true
            } label: {
                Image(systemName: "stop.fill")
                    .font(.headline)
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .confirmationDialog("End Trip?", isPresented: $showEndConfirmation) {
                Button("End Trip", role: .destructive) {
                    durationTimer?.invalidate()
                    durationTimer = nil
                    fillTimer?.invalidate()
                    fillTimer = nil
                    if trip.isFillingTank {
                        stopFill()
                    }
                    if trip.isPaused {
                        trackingService.resumeTracking()
                    }
                    finalizeCurrentPath()
                    trackingService.stopTracking()
                    store.endTrip(trip)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .animation(.snappy(duration: 0.3), value: isGPSActive)
        .animation(.snappy(duration: 0.3), value: trip.isPaused)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func advanceRow(by delta: Int) {
        var updated = trip
        let oldPath = updated.currentRowNumber

        if updated.rowSequence.isEmpty {
            updated.currentRowNumber += Double(delta)
            updated.nextRowNumber = updated.currentRowNumber + 1
        } else {
            let newIndex = updated.sequenceIndex + delta
            guard newIndex >= 0 && newIndex < updated.rowSequence.count else { return }

            if !updated.completedPaths.contains(oldPath) && !updated.skippedPaths.contains(oldPath) {
                let distance = pathDistanceMap[oldPath, default: 0]
                if let rowLength = rowLengthForPath(oldPath), rowLength > 0 {
                    let progress = distance / rowLength
                    if progress >= 0.8 {
                        updated.completedPaths.append(oldPath)
                    } else {
                        updated.skippedPaths.append(oldPath)
                    }
                } else {
                    updated.skippedPaths.append(oldPath)
                }
            }

            updated.sequenceIndex = newIndex
            updated.currentRowNumber = updated.rowSequence[newIndex]
            if newIndex + 1 < updated.rowSequence.count {
                updated.nextRowNumber = updated.rowSequence[newIndex + 1]
            } else {
                updated.nextRowNumber = updated.currentRowNumber
            }
        }

        confirmedPath = updated.currentRowNumber
        candidatePath = nil
        candidateCount = 0
        store.updateTrip(updated)
    }

    private func gradientColor(for progress: Double) -> Color {
        let r = 1.0 - progress
        let g = progress
        return Color(red: r, green: g, blue: 0)
    }

    private func formatPath(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }

    private func formatActiveDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(seconds, 0))
        let hrs = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        guard !trip.isPaused else { return }
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if let activeTrip = store.activeTrip {
                    activeDurationTimer = activeTrip.activeDuration
                }
            }
        }
    }
}

// MARK: - Trip Detail View (Historical)

struct TripDetailView: View {
    let trip: Trip
    @Environment(DataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @State private var position: MapCameraPosition = .automatic
    @State private var showSprayForm: Bool = false
    @State private var isGeneratingPDF: Bool = false
    @State private var includeCostingsInExport: Bool = true

    private var tripPins: [VinePin] {
        store.pins.filter { $0.tripId == trip.id }
    }

    private var sprayRecord: SprayRecord? {
        store.sprayRecord(for: trip.id)
    }

    private var duration: TimeInterval {
        trip.activeDuration
    }

    var body: some View {
        VStack(spacing: 0) {
            mapSection

            List {
                if let record = sprayRecord {
                    Section {
                        NavigationLink {
                            SprayRecordDetailView(record: record)
                        } label: {
                            SprayRecordBanner(record: record)
                        }
                    }
                }

                Section("Trip Info") {
                    if !trip.personName.isEmpty {
                        LabeledContent("Logged By", value: trip.personName)
                    }
                    LabeledContent("Block", value: trip.paddockName.isEmpty ? "—" : trip.paddockName)
                    LabeledContent("Date", value: trip.startTime.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Duration", value: formatDuration(duration))
                    LabeledContent("Distance", value: formatDistance(trip.totalDistance))
                    LabeledContent("Avg Speed", value: formatAverageSpeed())
                    LabeledContent("Pins Logged", value: "\(tripPins.count)")
                    LabeledContent("Pattern", value: trip.trackingPattern.title)
                }

                if !trip.rowSequence.isEmpty {
                    Section("Row Summary") {
                        let completed = trip.rowSequence.filter { trip.completedPaths.contains($0) }.count
                        let skipped = trip.rowSequence.filter { trip.skippedPaths.contains($0) }.count
                        LabeledContent("Completed", value: "\(completed)")
                        LabeledContent("Skipped", value: "\(skipped)")
                        LabeledContent("Total", value: "\(trip.rowSequence.count)")

                        ForEach(Array(trip.rowSequence.enumerated()), id: \.offset) { index, path in
                            let status = detailStatusForPath(path, at: index)
                            HStack(spacing: 10) {
                                Image(systemName: status.icon)
                                    .foregroundStyle(status.color)
                                    .frame(width: 24)
                                Text("Path \(formatPathValue(path))")
                                    .font(.subheadline)
                                Spacer()
                                Text(status.label)
                                    .font(.caption)
                                    .foregroundStyle(status.color)
                            }
                        }
                    }
                }

                if !tripPins.isEmpty {
                    Section("Pins") {
                        ForEach(tripPins) { pin in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color.fromString(pin.buttonColor).gradient)
                                    .frame(width: 28, height: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pin.buttonName)
                                        .font(.subheadline.weight(.medium))
                                    Text("\(pin.side.rawValue) • \(pin.timestamp.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if accessControl?.canViewFinancials ?? false {
                    tripCostSection
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle(trip.paddockName.isEmpty ? "Trip Details" : trip.paddockName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    if accessControl?.canExport ?? false {
                        Menu {
                            Button {
                                generatePDF()
                            } label: {
                                Label("Export as PDF", systemImage: "doc.richtext")
                            }
                            .disabled(isGeneratingPDF)

                            if accessControl?.canExportFinancialPDF ?? false {
                                Divider()
                                Toggle(isOn: $includeCostingsInExport) {
                                    Label("Include Costings", systemImage: "dollarsign.circle")
                                }
                            }
                        } label: {
                            if isGeneratingPDF {
                                ProgressView()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .disabled(isGeneratingPDF)
                    }

                    if sprayRecord == nil {
                        Button {
                            showSprayForm = true
                        } label: {
                            Image(systemName: "spray.and.fill")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSprayForm) {
            SprayRecordFormView(
                tripId: trip.id,
                paddockIds: trip.paddockIds
            )
        }
    }

    private var mapSection: some View {
        Map(position: $position) {
            if trip.pathPoints.count > 1 {
                let coords = trip.pathPoints.map { $0.coordinate }
                let segmentCount = max(coords.count - 1, 1)
                ForEach(0..<(coords.count - 1), id: \.self) { i in
                    let progress = Double(i) / Double(segmentCount)
                    MapPolyline(coordinates: [coords[i], coords[i + 1]])
                        .stroke(gradientColor(for: progress), lineWidth: 4)
                }
            }

            ForEach(tripPins) { pin in
                Annotation(pin.buttonName, coordinate: pin.coordinate) {
                    Circle()
                        .fill(Color.fromString(pin.buttonColor).gradient)
                        .frame(width: 24, height: 24)
                        .overlay {
                            Circle()
                                .fill(.white.opacity(0.4))
                                .frame(width: 8, height: 8)
                        }
                }
            }
        }
        .mapStyle(.hybrid)
        .frame(height: 280)
    }

    private func gradientColor(for progress: Double) -> Color {
        let r = 1.0 - progress
        let g = progress
        return Color(red: r, green: g, blue: 0)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let hrs = mins / 60
        if hrs > 0 {
            return "\(hrs)h \(mins % 60)m"
        }
        return "\(mins)m"
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }

    private func formatAverageSpeed() -> String {
        let durationSeconds = trip.activeDuration
        guard durationSeconds > 0 && trip.totalDistance > 0 else { return "—" }
        let speedKmh = (trip.totalDistance / durationSeconds) * 3.6
        return String(format: "%.1f km/h", speedKmh)
    }

    private func detailStatusForPath(_ path: Double, at index: Int) -> PathStatus {
        if trip.completedPaths.contains(path) {
            return .completed
        }
        if trip.skippedPaths.contains(path) {
            return .skipped
        }
        return .pending
    }

    private func formatPathValue(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private var tripFuelCost: Double {
        guard let record = sprayRecord else { return 0 }
        let tractor = store.tractors.first(where: { $0.displayName == record.tractor || $0.name == record.tractor })
        guard let tractor, tractor.fuelUsageLPerHour > 0 else { return 0 }
        let fuelPrice = store.seasonFuelCostPerLitre
        guard fuelPrice > 0 else { return 0 }
        let durationHours = trip.activeDuration / 3600.0
        return fuelPrice * tractor.fuelUsageLPerHour * durationHours
    }

    private var tripOperatorCost: Double {
        guard !trip.personName.isEmpty else { return 0 }
        guard let category = store.operatorCategoryForName(trip.personName) else { return 0 }
        guard category.costPerHour > 0 else { return 0 }
        let durationHours = trip.activeDuration / 3600.0
        return category.costPerHour * durationHours
    }

    private var tripOperatorCategoryName: String? {
        guard !trip.personName.isEmpty else { return nil }
        return store.operatorCategoryForName(trip.personName)?.name
    }

    private var tripCostSection: some View {
        let chemCostItems: [(String, Double)] = (sprayRecord?.tanks ?? []).flatMap { tank in
            tank.chemicals.compactMap { chemical -> (String, Double)? in
                let cost = chemical.costPerUnit * chemical.volumePerTank
                guard cost > 0 else { return nil }
                return (chemical.name.isEmpty ? "Unnamed" : chemical.name, cost)
            }
        }
        let totalChemCost = chemCostItems.reduce(0.0) { $0 + $1.1 }
        let fuelCost = tripFuelCost
        let operatorCost = tripOperatorCost
        let grandTotal = totalChemCost + fuelCost + operatorCost
        let hasCosts = totalChemCost > 0 || fuelCost > 0 || operatorCost > 0

        return Group {
            if hasCosts {
                Section("Costs") {
                    if totalChemCost > 0 {
                        HStack {
                            Label("Chemical", systemImage: "flask.fill")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "$%.2f", totalChemCost))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if fuelCost > 0 {
                        HStack {
                            Label("Fuel", systemImage: "fuelpump.fill")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "$%.2f", fuelCost))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if operatorCost > 0 {
                        HStack {
                            Label("Operator", systemImage: "person.badge.clock")
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "$%.2f", operatorCost))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Total Cost")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "$%.2f", grandTotal))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private func generatePDF() {
        guard !isGeneratingPDF else { return }
        isGeneratingPDF = true

        let includeCostings = includeCostingsInExport && (accessControl?.canExportFinancialPDF ?? false)
        let vineyardName = store.selectedVineyard?.name ?? ""
        let logoData = store.selectedVineyard?.logoData
        let paddockName = trip.paddockName
        let pinCount = tripPins.count
        let currentTrip = trip

        let fuelCostValue = tripFuelCost
        let operatorCostValue = tripOperatorCost
        let operatorCatNameValue = tripOperatorCategoryName
        let chemCostItems: [(String, Double)] = (sprayRecord?.tanks ?? []).flatMap { tank in
            tank.chemicals.compactMap { chemical -> (String, Double)? in
                let cost = chemical.costPerUnit * chemical.volumePerTank
                guard cost > 0 else { return nil }
                return (chemical.name.isEmpty ? "Unnamed" : chemical.name, cost)
            }
        }
        let costGrouped = Dictionary(grouping: chemCostItems, by: { $0.0.lowercased() })
        let pdfChemCosts = costGrouped.compactMap { (key, items) -> (String, Double)? in
            guard !key.isEmpty else { return nil }
            let displayName = items.first?.0 ?? key
            let totalCost = items.reduce(0.0) { $0 + $1.1 }
            return (displayName, totalCost)
        }.sorted { $0.0.lowercased() < $1.0.lowercased() }

        Task {
            let snapshot = await TripPDFService.captureMapSnapshot(trip: currentTrip)
            let pdfData = TripPDFService.generatePDF(
                trip: currentTrip,
                vineyardName: vineyardName,
                paddockName: paddockName,
                pinCount: pinCount,
                mapSnapshot: snapshot,
                logoData: logoData,
                fuelCost: fuelCostValue,
                chemicalCosts: pdfChemCosts,
                operatorCost: operatorCostValue,
                operatorCategoryName: operatorCatNameValue,
                includeCostings: includeCostings
            )
            if includeCostings {
                store.auditService?.log(
                    action: .financialExport,
                    entityType: "Trip",
                    entityId: currentTrip.id.uuidString,
                    entityLabel: paddockName,
                    details: "PDF export with costings"
                )
            }
            let fileName = "TripReport_\(paddockName.isEmpty ? "Trip" : paddockName)_\(currentTrip.startTime.formatted(date: .numeric, time: .omitted))"
            let url = TripPDFService.savePDFToTemp(data: pdfData, fileName: fileName)
            let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activityVC.completionWithItemsHandler = { _, _, _, _ in
                isGeneratingPDF = false
            }
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                var presenter = rootVC
                while let presented = presenter.presentedViewController {
                    presenter = presented
                }
                presenter.present(activityVC, animated: true)
            } else {
                isGeneratingPDF = false
            }
        }
    }
}

// MARK: - Start Trip Sheet

nonisolated enum StartDirection: String, Sendable {
    case firstRow = "firstRow"
    case lastRow = "lastRow"

    var title: String {
        switch self {
        case .firstRow: return "First Row (Lowest)"
        case .lastRow: return "Last Row (Highest)"
        }
    }

    var icon: String {
        switch self {
        case .firstRow: return "arrow.up"
        case .lastRow: return "arrow.down"
        }
    }
}

struct StartTripSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(AuthService.self) private var authService
    @Environment(TripTrackingService.self) private var trackingService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPaddockIds: Set<UUID> = []
    @State private var startDirection: StartDirection = .firstRow
    @State private var selectedPattern: TrackingPattern = .sequential



    private var selectedPaddocks: [Paddock] {
        store.paddocks.filter { selectedPaddockIds.contains($0.id) }
    }

    private var rowSequence: [Double] {
        var allRowNumbers: [Int] = []
        for paddock in selectedPaddocks {
            allRowNumbers.append(contentsOf: paddock.rows.map { $0.number })
        }
        allRowNumbers.sort()
        guard let globalFirst = allRowNumbers.first, let globalLast = allRowNumbers.last else { return [] }
        let totalRows = globalLast - globalFirst + 1
        let paths = selectedPattern.generateSequence(
            startRow: globalFirst,
            totalRows: totalRows,
            reversed: startDirection == .lastRow
        )
        return paths
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Who's Driving?") {
                    HStack {
                        Label(authService.userName.isEmpty ? "Unknown" : authService.userName, systemImage: "person.fill")
                            .font(.body)
                        Spacer()
                    }
                }

                paddockSection
                patternSection
                startDirectionSection

                if !selectedPaddockIds.isEmpty {
                    selectedBlocksSummary
                    sequencePreviewSection
                }
            }
            .navigationTitle("Maintenance Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { startTrip() }
                        .disabled(selectedPaddockIds.isEmpty || rowSequence.isEmpty)
                }
            }


        }
    }


    private var paddockSection: some View {
        Section {
            if store.orderedPaddocks.isEmpty {
                Text("No blocks configured. Add blocks in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.orderedPaddocks) { paddock in
                    Button {
                        if selectedPaddockIds.contains(paddock.id) {
                            selectedPaddockIds.remove(paddock.id)
                        } else {
                            selectedPaddockIds.insert(paddock.id)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(paddock.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                let rowNumbers = paddock.rows.map { $0.number }.sorted()
                                if let first = rowNumbers.first, let last = rowNumbers.last {
                                    Text("Row \(first) to Row \(last) \u{2022} \(paddock.rows.count) rows")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("\(paddock.rows.count) rows")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selectedPaddockIds.contains(paddock.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Blocks")
        } footer: {
            if !store.orderedPaddocks.isEmpty {
                Text("Select one or more blocks for this trip.")
            }
        }
    }

    private var patternSection: some View {
        Section {
            ForEach([TrackingPattern.sequential, .everySecondRow, .fiveThree, .twoRowUpBack], id: \.id) { pattern in
                PatternRowView(
                    pattern: pattern,
                    isSelected: selectedPattern == pattern,
                    action: { selectedPattern = pattern }
                )
            }
        } header: {
            Text("Track Pattern")
        } footer: {
            Text(selectedPattern.subtitle)
        }
    }

    private var startDirectionSection: some View {
        Section {
            ForEach([StartDirection.firstRow, .lastRow], id: \.rawValue) { direction in
                Button {
                    startDirection = direction
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: direction.icon)
                            .font(.title3)
                            .foregroundStyle(startDirection == direction ? Color.accentColor : .secondary)
                            .frame(width: 28)

                        Text(direction.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        Spacer()

                        if startDirection == direction {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        } header: {
            Text("Start From")
        } footer: {
            Text(startDirection == .firstRow
                 ? "Paths will go from lowest row to highest."
                 : "Paths will go from highest row to lowest.")
        }
    }

    private var selectedBlocksSummary: some View {
        Section("Selected Blocks") {
            ForEach(selectedPaddocks) { paddock in
                let rowNumbers = paddock.rows.map { $0.number }.sorted()
                let first = rowNumbers.first ?? 0
                let last = rowNumbers.last ?? 0
                HStack {
                    Text(paddock.name)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("Rows \(first)–\(last)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sequencePreviewSection: some View {
        Section {
            SequencePreviewRow(sequence: rowSequence)
        } header: {
            Text("Path Sequence Preview")
        } footer: {
            let seq = rowSequence
            let uniquePaths = Set(seq)
            Text("\(seq.count) paths to traverse across \(selectedPaddockIds.count) block\(selectedPaddockIds.count == 1 ? "" : "s"). \(uniquePaths.count) unique paths.")
        }
    }

    private func startTrip() {
        let sequence = rowSequence
        let firstRow = sequence.first ?? 0.5
        let secondRow = sequence.count > 1 ? sequence[1] : firstRow
        let paddockNames = selectedPaddocks.map { $0.name }.joined(separator: ", ")
        let tripId = UUID()
        let trip = Trip(
            id: tripId,
            vineyardId: store.selectedVineyardId ?? UUID(),
            paddockId: selectedPaddocks.first?.id,
            paddockName: paddockNames,
            paddockIds: selectedPaddocks.map { $0.id },
            currentRowNumber: firstRow,
            nextRowNumber: secondRow,
            trackingPattern: selectedPattern,
            rowSequence: sequence,
            sequenceIndex: 0,
            personName: authService.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        store.startTrip(trip)
        trackingService.startTracking()

        dismiss()
    }

    private func formatPath(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

struct PatternRowView: View {
    let pattern: TrackingPattern
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: pattern.icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pattern.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(pattern.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

struct SequencePreviewRow: View {
    let sequence: [Double]

    var body: some View {
        if !sequence.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(sequence.prefix(30).enumerated()), id: \.offset) { index, row in
                        SequenceChip(index: index, row: row)
                    }
                    if sequence.count > 30 {
                        Text("+\(sequence.count - 30)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }
}

struct SequenceChip: View {
    let index: Int
    let row: Double

    private var formattedRow: String {
        if row.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", row)
        }
        return String(format: "%.1f", row)
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("\(index + 1)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(formattedRow)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(index == 0 ? Color.accentColor : .primary)
        }
        .frame(minWidth: 36, minHeight: 40)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(index == 0 ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill))
        )
    }
}
