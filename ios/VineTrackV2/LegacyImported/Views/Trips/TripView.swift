import SwiftUI

nonisolated enum TripSortOption: String, CaseIterable, Sendable {
    case date = "Date"
    case name = "Name"
    case duration = "Duration"
}

nonisolated enum TripTypeFilter: String, CaseIterable, Sendable {
    case all = "All"
    case spray = "Spray"
    case maintenance = "Maintenance"
}

struct TripView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(TripTrackingService.self) private var tracking
    @Environment(LocationService.self) private var locationService
    @State private var tripSortOption: TripSortOption = .date
    @State private var tripTypeFilter: TripTypeFilter = .all
    @State private var tripFunctionFilter: TripFunction? = nil
    @State private var tripMonthFilter: Int? = nil // 1...12, nil = all
    @State private var tripYearFilter: Int? = nil  // nil = all
    @State private var tripSearchText: String = ""
    @State private var tripToDelete: Trip?
    @State private var showDeleteConfirmation: Bool = false
    @State private var showStartTrip: Bool = false
    @State private var showTripChoice: Bool = false
    @State private var showSpraySetup: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if let active = tracking.activeTrip {
                    ActiveTripView(trip: active)
                } else if pastTrips.isEmpty {
                    emptyStateView
                } else {
                    tripHistoryList
                }
            }
            .navigationTitle(tracking.activeTrip != nil ? "Active Trip" : "Trips")
            .navigationBarTitleDisplayMode(tracking.activeTrip != nil ? .inline : .large)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if tracking.activeTrip == nil, !pastTrips.isEmpty {
                        Menu {
                            Picker("Sort By", selection: $tripSortOption) {
                                ForEach(TripSortOption.allCases, id: \.self) { option in
                                    Label(option.rawValue, systemImage: tripSortIconName(for: option))
                                        .tag(option)
                                }
                            }
                            Picker("Function", selection: $tripFunctionFilter) {
                                Label("All functions", systemImage: "square.grid.2x2").tag(TripFunction?.none)
                                ForEach(TripFunction.allCases) { function in
                                    Label(function.displayName, systemImage: function.icon)
                                        .tag(TripFunction?.some(function))
                                }
                            }
                            Picker("Month", selection: $tripMonthFilter) {
                                Label("All months", systemImage: "calendar").tag(Int?.none)
                                ForEach(1...12, id: \.self) { m in
                                    Text(monthName(m)).tag(Int?.some(m))
                                }
                            }
                            Picker("Year", selection: $tripYearFilter) {
                                Label("All years", systemImage: "calendar.badge.clock").tag(Int?.none)
                                ForEach(availableYears, id: \.self) { y in
                                    Text(String(y)).tag(Int?.some(y))
                                }
                            }
                            if hasActiveFilters {
                                Divider()
                                Button(role: .destructive) {
                                    clearFilters()
                                } label: {
                                    Label("Clear filters", systemImage: "xmark.circle")
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if tracking.activeTrip == nil {
                    Button {
                        showTripChoice = true
                    } label: {
                        Label("Start Trip", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.large)
                    .disabled(!accessControl.canCreateOperationalRecords)
                    .padding()
                    .background(.bar)
                }
            }
            .sheet(isPresented: $showTripChoice) {
                TripTypeChoiceSheet { type in
                    showTripChoice = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        switch type {
                        case .maintenance:
                            showStartTrip = true
                        case .spray:
                            showSpraySetup = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showStartTrip) {
                StartTripSheet()
            }
            .sheet(isPresented: $showSpraySetup) {
                SprayTripSetupSheet()
            }
            .alert("Delete Trip", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let trip = tripToDelete {
                        store.deleteTrip(trip.id)
                    }
                    tripToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    tripToDelete = nil
                }
            } message: {
                Text("Are you sure you want to delete this trip? This action cannot be undone.")
            }
        }
    }

    // MARK: - Filtering

    private func tripDisplayName(_ trip: Trip) -> String {
        if let title = trip.tripTitle, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let raw = trip.tripFunction, let function = TripFunction(rawValue: raw) {
            return function.displayName
        }
        if let raw = trip.tripFunction, raw.hasPrefix("custom:") {
            return String(raw.dropFirst("custom:".count)).replacingOccurrences(of: "-", with: " ").capitalized
        }
        if let record = store.sprayRecords.first(where: { $0.tripId == trip.id }),
           !record.sprayReference.isEmpty {
            return record.sprayReference
        }
        let dateStr = trip.startTime.formatted(date: .abbreviated, time: .omitted)
        return "Maintenance Trip \(dateStr)"
    }

    private func hasSprayRecord(_ trip: Trip) -> Bool {
        store.sprayRecords.contains { $0.tripId == trip.id }
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
            trips = trips.filter { hasSprayRecord($0) }
        case .maintenance:
            trips = trips.filter { !hasSprayRecord($0) }
        }

        if let function = tripFunctionFilter {
            trips = trips.filter { $0.tripFunction == function.rawValue }
        }

        if tripMonthFilter != nil || tripYearFilter != nil {
            let cal = Calendar.current
            trips = trips.filter { trip in
                let comps = cal.dateComponents([.month, .year], from: trip.startTime)
                if let m = tripMonthFilter, comps.month != m { return false }
                if let y = tripYearFilter, comps.year != y { return false }
                return true
            }
        }

        if !tripSearchText.isEmpty {
            trips = trips.filter { trip in
                let combined = "\(tripDisplayName(trip)) \(trip.paddockName) \(trip.personName)"
                return combined.localizedStandardContains(tripSearchText)
            }
        }

        switch tripSortOption {
        case .date:
            trips.sort { $0.startTime > $1.startTime }
        case .name:
            trips.sort { tripDisplayName($0).lowercased() < tripDisplayName($1).lowercased() }
        case .duration:
            trips.sort { $0.activeDuration > $1.activeDuration }
        }

        return trips
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "road.lanes")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse)

            VStack(spacing: 8) {
                Text("No Trips Yet")
                    .font(.title2.weight(.semibold))
                Text("Trips you record will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tripHistoryList: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TripTypeFilter.allCases, id: \.self) { filter in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                tripTypeFilter = filter
                                if filter != .all {
                                    tripFunctionFilter = nil
                                }
                            }
                        } label: {
                            Text(filter == .all ? "All trips" : filter.rawValue)
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
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(functionChipOptions) { function in
                        let isSelected = tripFunctionFilter == function
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                tripFunctionFilter = isSelected ? nil : function
                                if function == .spraying {
                                    tripTypeFilter = .all
                                } else if tripTypeFilter == .spray {
                                    tripTypeFilter = .all
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: function.icon)
                                    .font(.caption2)
                                Text(function.displayName)
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color.accentColor.opacity(0.85) : Color(.secondarySystemGroupedBackground))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .contentMargins(.horizontal, 16)
            .padding(.vertical, 8)

            if tripFunctionFilter != nil || tripMonthFilter != nil || tripYearFilter != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let function = tripFunctionFilter {
                            activeChip(text: function.displayName, systemImage: function.icon) {
                                tripFunctionFilter = nil
                            }
                        }
                        if let m = tripMonthFilter {
                            activeChip(text: monthName(m), systemImage: "calendar") {
                                tripMonthFilter = nil
                            }
                        }
                        if let y = tripYearFilter {
                            activeChip(text: String(y), systemImage: "calendar.badge.clock") {
                                tripYearFilter = nil
                            }
                        }
                    }
                }
                .contentMargins(.horizontal, 16)
                .padding(.bottom, 8)
            }

            List {
                Section {
                    ForEach(filteredAndSortedTrips) { trip in
                        NavigationLink(value: trip.id) {
                            TripHistoryRow(
                                trip: trip,
                                pinCount: store.pins.filter { $0.tripId == trip.id }.count,
                                hasSprayRecord: hasSprayRecord(trip),
                                sprayReferenceName: store.sprayRecords.first(where: { $0.tripId == trip.id })?.sprayReference,
                                displayTitle: tripDisplayName(trip)
                            )
                        }
                    }
                    .onDelete(perform: accessControl.canDeleteOperationalRecords ? { offsets in
                        let trips = filteredAndSortedTrips
                        tripToDelete = offsets.first.map { trips[$0] }
                        showDeleteConfirmation = true
                    } : nil)
                } header: {
                    Label("Trip History", systemImage: "road.lanes")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(0)
            .navigationDestination(for: UUID.self) { tripId in
                if let trip = store.trips.first(where: { $0.id == tripId }) {
                    TripDetailView(trip: trip)
                }
            }
        }
        .searchable(text: $tripSearchText, prompt: "Search trips")
    }

    private var functionChipOptions: [TripFunction] {
        // Customer-facing order; show all known functions as chips.
        let order: [TripFunction] = [
            .spraying,
            .mowing,
            .slashing,
            .mulching,
            .harrowing,
            .seeding,
            .spreading,
            .fertilising,
            .undervineWeeding,
            .undervineMowing,
            .undervineMulticlean,
            .undervineRollHacke,
            .undervineDisc,
            .undervineKnifing,
            .interRowCultivation,
            .pruning,
            .shootThinning,
            .canopyWork,
            .irrigationCheck,
            .repairs,
            .other
        ]
        return order
    }

    private var availableYears: [Int] {
        let cal = Calendar.current
        let years = Set(pastTrips.map { cal.component(.year, from: $0.startTime) })
        return years.sorted(by: >)
    }

    private var hasActiveFilters: Bool {
        tripTypeFilter != .all || tripFunctionFilter != nil || tripMonthFilter != nil || tripYearFilter != nil
    }

    private func clearFilters() {
        tripTypeFilter = .all
        tripFunctionFilter = nil
        tripMonthFilter = nil
        tripYearFilter = nil
    }

    private func monthName(_ month: Int) -> String {
        let df = DateFormatter()
        return df.monthSymbols[month - 1]
    }

    private func tripSortIconName(for option: TripSortOption) -> String {
        switch option {
        case .date: return "calendar"
        case .name: return "textformat"
        case .duration: return "clock"
        }
    }

    private func activeChip(text: String, systemImage: String, onRemove: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { onRemove() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption2)
                Text(text)
                    .font(.caption.weight(.medium))
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trip History Row

struct TripHistoryRow: View {
    @Environment(TripSyncService.self) private var tripSync
    let trip: Trip
    let pinCount: Int
    var hasSprayRecord: Bool = false
    var sprayReferenceName: String? = nil
    var displayTitle: String? = nil

    private var resolvedFunction: TripFunction? {
        guard let raw = trip.tripFunction else { return nil }
        return TripFunction(rawValue: raw)
    }

    private var customFunctionLabel: String? {
        guard let raw = trip.tripFunction, raw.hasPrefix("custom:") else { return nil }
        if let title = trip.tripTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return String(raw.dropFirst("custom:".count)).replacingOccurrences(of: "-", with: " ").capitalized
    }

    private var displayName: String {
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        if let title = trip.tripTitle, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let function = resolvedFunction { return function.displayName }
        if let custom = customFunctionLabel, !custom.isEmpty {
            return custom
        }
        if let name = sprayReferenceName, !name.isEmpty {
            return name
        }
        let dateStr = trip.startTime.formatted(date: .abbreviated, time: .omitted)
        return "Maintenance Trip \(dateStr)"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                if let function = resolvedFunction,
                   trip.tripTitle?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                    Label(function.displayName, systemImage: function.icon)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if let custom = customFunctionLabel,
                          trip.tripTitle?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                    Label(custom, systemImage: "wrench.and.screwdriver")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Label(trip.startTime.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !trip.paddockName.isEmpty {
                    Label { Text(trip.paddockName) } icon: { GrapeLeafIcon(size: 12, color: VineyardTheme.olive) }
                        .font(.caption)
                        .foregroundStyle(VineyardTheme.olive)
                }

                if !trip.personName.isEmpty {
                    Label(trip.personName, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                RecordSyncBadge(state: RecordSyncState.forTrip(trip.id, tripSync: tripSync), showsLabel: false)
                Label(formatDuration(trip.activeDuration), systemImage: "clock")
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
                if hasSprayRecord {
                    Label("Spray", systemImage: "drop.fill")
                        .font(.caption2)
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        RegionFormatter.formatDuration(seconds: seconds)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }
}
