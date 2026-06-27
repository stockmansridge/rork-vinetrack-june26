import SwiftUI
import MapKit

struct TripDetailView: View {
    let trip: Trip
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(NetworkMonitor.self) private var network
    @Environment(TripSyncService.self) private var tripSync
    @Environment(\.dismiss) private var dismiss
    @State private var showSummary: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var position: MapCameraPosition = .automatic
    @State private var isExporting: Bool = false
    @State private var displayTrailSegments: [TrailSegment] = []
    @State private var showRowCompletion: Bool = false
    @State private var showPathMap: Bool = false
    @State private var showSprayDetails: Bool = false
    @State private var showSeedingDetails: Bool = false
    @State private var showPinsSection: Bool = false
    @State private var showCostSection: Bool = true
    @State private var showEditCostingLinks: Bool = false
    @State private var vineyardMembers: [BackendVineyardMember] = []
    private let teamRepository: any TeamRepositoryProtocol = SupabaseTeamRepository()

    private static let maxDisplayTrailPoints: Int = 500
    private static let maxTrailBuckets: Int = 5

    private var sprayRecord: SprayRecord? {
        store.sprayRecords.first { $0.tripId == trip.id }
    }

    /// Live copy of `trip` from the store so the cost summary reflects any
    /// owner/manager edits made via `TripCostingLinksEditSheet` without
    /// requiring the view to be dismissed and reopened.
    private var currentTrip: Trip {
        store.trips.first(where: { $0.id == trip.id }) ?? trip
    }

    private var pinsForTrip: [VinePin] {
        store.pins.filter { $0.tripId == trip.id }
    }

    /// Read-only label for the Work Task this trip is grouped under, if any.
    /// Prefers the task description, then the task type. Returns nil when the
    /// trip is ungrouped or the linked task is not available locally.
    private var linkedWorkTaskLabel: String? {
        guard let workTaskId = currentTrip.workTaskId,
              let task = store.workTasks.first(where: { $0.id == workTaskId }) else { return nil }
        if let desc = task.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            return desc
        }
        let type = task.taskType.trimmingCharacters(in: .whitespacesAndNewlines)
        return type.isEmpty ? nil : type
    }

    private var tz: TimeZone { store.settings.resolvedTimeZone }
    private var fmt: RegionFormatter { store.settings.regionFormatter }

    private var displayName: String {
        if let record = sprayRecord, !record.sprayReference.isEmpty {
            return record.sprayReference
        }
        let dateStr = trip.startTime.formattedTZ(date: .abbreviated, time: .omitted, in: tz)
        return "Maintenance Trip \(dateStr)"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(displayName)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(VineyardTheme.olive)
                        Spacer(minLength: 8)
                        RecordSyncBadge(state: RecordSyncState.forTrip(trip.id, tripSync: tripSync))
                    }
                    RecordSyncFailureHint(state: RecordSyncState.forTrip(trip.id, tripSync: tripSync))
                    Label(trip.startTime.formattedTZ(date: .abbreviated, time: .shortened, in: tz), systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let endTime = trip.endTime {
                        Label("Ended \(endTime.formattedTZ(date: .abbreviated, time: .shortened, in: tz))", systemImage: "flag.checkered")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if trip.isActive {
                        Label("Active", systemImage: "circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Trip Summary") {
                if let raw = trip.tripFunction, !raw.isEmpty {
                    if let function = TripFunction(rawValue: raw) {
                        statRow("Function", value: function.displayName, icon: function.icon)
                    } else if raw.hasPrefix("custom:") {
                        let label = trip.tripTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let display = (label?.isEmpty == false) ? label! : String(raw.dropFirst("custom:".count))
                        statRow("Function", value: display, icon: "wrench.and.screwdriver")
                    }
                }
                if let title = trip.tripTitle, !title.isEmpty {
                    statRow("Title", value: title, icon: "text.cursor")
                }
                statRow("Duration", value: formatDuration(trip.activeDuration), icon: "clock")
                statRow("Distance", value: formatDistance(trip.totalDistance), icon: "point.topleft.down.to.point.bottomright.curvepath")
                if !trip.paddockName.isEmpty {
                    statRow("Block", value: trip.paddockName, icon: "leaf")
                }
                if !trip.personName.isEmpty {
                    statRow("Operator", value: trip.personName, icon: "person")
                }
                if let workTaskLabel = linkedWorkTaskLabel {
                    statRow("Work Task", value: workTaskLabel, icon: "checklist")
                }
                if !trip.rowSequence.isEmpty {
                    statRow("Pattern", value: trip.trackingPattern.title, icon: trip.trackingPattern.icon)
                    if let startDescription = startMidrowDescription {
                        statRow("Started", value: startDescription, icon: "flag")
                    }
                    statRow("Paths planned", value: "\(trip.rowSequence.count)", icon: "list.number")
                    statRow("Complete", value: "\(rowCompletionResults.filter { $0.status == .complete }.count)", icon: "checkmark.circle")
                    let partialCount = rowCompletionResults.filter { $0.status == .partial }.count
                    if partialCount > 0 {
                        statRow("Partial", value: "\(partialCount)", icon: "exclamationmark.triangle")
                    }
                    let notDoneCount = rowCompletionResults.filter { $0.status == .notComplete }.count
                    if notDoneCount > 0 {
                        statRow("Not complete", value: "\(notDoneCount)", icon: "xmark.circle")
                    }
                }
                if pinsForTrip.count > 0 {
                    statRow("Pins recorded", value: "\(pinsForTrip.count)", icon: "mappin")
                }
            }

            if let record = sprayRecord {
                Section {
                    DisclosureGroup(isExpanded: $showSprayDetails) {
                        if !record.sprayReference.isEmpty {
                            statRow("Reference", value: record.sprayReference, icon: "drop.fill")
                        }
                        statRow("Date", value: record.date.formattedTZ(date: .abbreviated, time: .omitted, in: tz), icon: "calendar")
                        if record.tanks.count > 0 {
                            statRow("Tanks", value: "\(record.tanks.count)", icon: "cylinder")
                        }
                    } label: {
                        Label("Spray Record", systemImage: "drop.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if !rowCompletionResults.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showRowCompletion) {
                        if let paddockName = coverageSourcePaddockName {
                            statRow("Block", value: paddockName, icon: "leaf")
                        }
                        ForEach(rowCompletionResults) { result in
                            rowCompletionRow(result)
                        }
                    } label: {
                        Label("Row Completion", systemImage: "checklist")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            } else if !coveredRowSummary.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showRowCompletion) {
                        statRow("Rows covered", value: "\(coveredRowNumbers.count)", icon: "checkmark.circle")
                        if let paddockName = coverageSourcePaddockName {
                            statRow("Block", value: paddockName, icon: "leaf")
                        }
                        Text(coveredRowSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Row Coverage", systemImage: "checklist")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if trip.pathPoints.count > 1 {
                Section {
                    DisclosureGroup(isExpanded: $showPathMap) {
                        Group {
                            if network.isOnline {
                                Map(position: $position) {
                                    ForEach(displayTrailSegments) { segment in
                                        MapPolyline(coordinates: segment.coordinates)
                                            .stroke(segment.color, lineWidth: 4)
                                    }
                                }
                                .mapStyle(.hybrid)
                            } else {
                                OfflineVineyardMapView(
                                    trails: displayTrailSegments.map {
                                        OfflineVineyardMapView.Trail(id: $0.id, coordinates: $0.coordinates, color: $0.color)
                                    }
                                )
                                .clipShape(.rect(cornerRadius: 12))
                            }
                        }
                        .frame(height: 240)
                    } label: {
                        Label("Path Map", systemImage: "map")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if !trip.rowSequence.isEmpty {
                Section {
                    Button {
                        showSummary = true
                    } label: {
                        Label("View Path Summary", systemImage: "list.bullet.clipboard")
                    }
                }
            }

            if let details = trip.seedingDetails, details.hasAnyValue {
                Section {
                    DisclosureGroup(isExpanded: $showSeedingDetails) {
                        seedingDetailsBody(details)
                    } label: {
                        Label("Seeding Details", systemImage: "leaf.arrow.circlepath")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if accessControl.canViewCosting {
                Section {
                    DisclosureGroup(isExpanded: $showCostSection) {
                        tripCostBody
                        Button {
                            showEditCostingLinks = true
                        } label: {
                            Label("Edit operator, category & tractor", systemImage: "pencil")
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.top, 4)
                    } label: {
                        Label("Estimated Trip Cost", systemImage: "dollarsign.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }

            if let notes = trip.completionNotes?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !notes.isEmpty {
                Section("Completion Notes") {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 2)
                }
            }

            // Manual Corrections intentionally hidden from the normal Trip
            // Review UI. Events are still stored on the trip and included
            // in audit/debug surfaces and exports as required.

            if !pinsForTrip.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showPinsSection) {
                        ForEach(pinsForTrip) { pin in
                        HStack {
                            Group {
                                if pin.mode == .growth {
                                    GrapeLeafIcon(size: 18, color: VineyardTheme.leafGreen)
                                } else {
                                    Image(systemName: "wrench.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pin.buttonName.isEmpty ? "Pin" : pin.buttonName)
                                    .font(.subheadline.weight(.medium))
                                Text(pin.timestamp.formattedTZ(date: .abbreviated, time: .shortened, in: tz))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if pin.isCompleted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    } label: {
                        Label("Pins (\(pinsForTrip.count))", systemImage: "mappin.and.ellipse")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .navigationTitle("Trip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if accessControl.canExport {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            exportTrip()
                        } label: {
                            Label("Export PDF", systemImage: "doc.richtext")
                        }
                        Button {
                            exportTripCSV()
                        } label: {
                            Label("Export CSV", systemImage: "tablecells")
                        }
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExporting)
                }
            }
            if accessControl.canDeleteOperationalRecords {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .sheet(isPresented: $showSummary) {
            TripSummarySheet(trip: trip)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEditCostingLinks) {
            TripCostingLinksEditSheet(
                trip: currentTrip,
                vineyardMembers: vineyardMembers
            ) { tractorId, operatorUserId, operatorCategoryId in
                var updated = currentTrip
                updated.tractorId = tractorId
                updated.operatorUserId = operatorUserId
                updated.operatorCategoryId = operatorCategoryId
                store.updateTrip(updated)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Delete Trip", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteTrip(trip.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this trip? This action cannot be undone.")
        }
        .task {
            if accessControl.canViewCosting, vineyardMembers.isEmpty {
                if let members = try? await teamRepository.listMembers(vineyardId: trip.vineyardId) {
                    vineyardMembers = members
                }
            }
        }
        .onAppear {
            rebuildDisplayTrail()
            if trip.pathPoints.count > 1 {
                let coords = trip.pathPoints.map { $0.coordinate }
                let lats = coords.map { $0.latitude }
                let lons = coords.map { $0.longitude }
                if let minLat = lats.min(), let maxLat = lats.max(),
                   let minLon = lons.min(), let maxLon = lons.max() {
                    let center = CLLocationCoordinate2D(
                        latitude: (minLat + maxLat) / 2,
                        longitude: (minLon + maxLon) / 2
                    )
                    let span = MKCoordinateSpan(
                        latitudeDelta: max(maxLat - minLat, 0.001) * 1.4,
                        longitudeDelta: max(maxLon - minLon, 0.001) * 1.4
                    )
                    position = .region(MKCoordinateRegion(center: center, span: span))
                }
            }
        }
        .onChange(of: trip.pathPoints.count) { _, _ in
            rebuildDisplayTrail()
        }
    }

    /// Build the bucketed display trail once for this historical trip. Mirrors
    /// the live `ActiveTripView` renderer but without the 1s timer — pathPoints
    /// are static here, so we recompute only on appear or if the array changes.
    // MARK: - Trip Cost

    private var resolvedOperatorCategory: OperatorCategory? {
        let trip = currentTrip
        if let cid = trip.operatorCategoryId,
           let cat = store.operatorCategories.first(where: { $0.id == cid }) {
            return cat
        }
        if let uid = trip.operatorUserId,
           let memberCategoryId = vineyardMembers.first(where: { $0.userId == uid })?.operatorCategoryId,
           let cat = store.operatorCategories.first(where: { $0.id == memberCategoryId }) {
            return cat
        }
        return nil
    }

    private var resolvedTractor: Tractor? {
        guard let tid = currentTrip.tractorId else { return nil }
        return store.tractors.first { $0.id == tid }
    }

    /// Vineyard machine linked to this trip (preferred fuel source). Resolves
    /// from `machineId` first, then falls back to the legacy tractor link so
    /// older trips still surface their backfilled machine.
    private var resolvedMachine: VineyardMachine? {
        if let mid = currentTrip.machineId,
           let m = store.vineyardMachines.first(where: { $0.id == mid }) {
            return m
        }
        if let tid = currentTrip.tractorId {
            return store.vineyardMachines.first { $0.legacyTractorId == tid && $0.vineyardId == currentTrip.vineyardId }
        }
        return nil
    }

    private var tripFuelPurchases: [FuelPurchase] {
        store.fuelPurchases.filter { $0.vineyardId == trip.vineyardId }
    }

    private var costResult: TripCostService.Result {
        TripCostService.estimate(
            trip: currentTrip,
            operatorCategory: resolvedOperatorCategory,
            machine: resolvedMachine,
            tractor: resolvedTractor,
            fuelPurchases: tripFuelPurchases,
            sprayRecord: sprayRecord,
            savedChemicals: store.savedChemicals,
            savedInputs: store.savedInputs,
            paddockHectares: tripPaddockHectares,
            paddockAreasById: tripPaddockAreasById,
            historicalYieldRecords: store.historicalYieldRecords
        )
    }

    /// Per-paddock area map for every paddock linked to this trip. Phase 4D
    /// uses this to compute treated hectares from the actual selected blocks,
    /// rather than the whole vineyard.
    private var tripPaddockAreasById: [UUID: Double] {
        var ids: [UUID] = []
        if !trip.paddockIds.isEmpty { ids = trip.paddockIds }
        else if let single = trip.paddockId { ids = [single] }
        var result: [UUID: Double] = [:]
        for id in ids {
            if let p = store.paddocks.first(where: { $0.id == id }) {
                result[id] = p.areaHectares
            }
        }
        return result
    }

    /// Sum of `hectares` across every paddock referenced by this trip
    /// (single or multi-block). Used so seeding/spreading mix lines that
    /// only record `kg/ha` can be costed without explicit `amountUsed`.
    private var tripPaddockHectares: Double? {
        var ids: [UUID] = []
        if !trip.paddockIds.isEmpty { ids = trip.paddockIds }
        else if let single = trip.paddockId { ids = [single] }
        guard !ids.isEmpty else { return nil }
        let total = ids.reduce(0.0) { acc, id in
            if let p = store.paddocks.first(where: { $0.id == id }) {
                return acc + p.areaHectares
            }
            return acc
        }
        return total > 0 ? total : nil
    }

    @ViewBuilder
    private var tripCostBody: some View {
        let r = costResult
        VStack(alignment: .leading, spacing: 8) {
            costLineRow(
                label: "Labour",
                detail: r.labour.categoryName.map { name -> String in
                    if let rate = r.labour.costPerHour, rate > 0 {
                        return "\(name) · \(formatCurrency(rate))/hr × \(formatHours(r.labour.hours))"
                    }
                    return name
                },
                amount: r.labour.cost,
                showAmount: r.labour.warning == nil,
                icon: "person.fill"
            )
            if let w = r.labour.warning {
                warningRow(w)
            }

            costLineRow(
                label: "Fuel",
                detail: fuelDetailLabel(r.fuel),
                amount: r.fuel.cost,
                showAmount: r.fuel.warning == nil,
                icon: "fuelpump.fill"
            )
            if let w = r.fuel.warning {
                warningRow(w)
            }

            if let chem = r.chemical {
                costLineRow(
                    label: "Chemicals",
                    detail: nil,
                    amount: chem.cost,
                    showAmount: chem.warning == nil || chem.cost > 0,
                    icon: "drop.fill"
                )
                if let w = chem.warning {
                    warningRow(w)
                }
            }

            if let seed = r.seeding {
                costLineRow(
                    label: "Seed / Input",
                    detail: seed.missingCount > 0 ? "\(seed.missingCount) line(s) missing cost" : nil,
                    amount: seed.cost,
                    showAmount: seed.cost > 0,
                    icon: "leaf.fill"
                )
                if let w = seed.warning {
                    warningRow(w)
                }
            }

            Divider().padding(.vertical, 2)

            HStack {
                Text("Total estimated")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(formatCurrency(r.totalCost))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(VineyardTheme.olive)
            }

            // Treated area + cost per ha
            costLineRow(
                label: "Treated area",
                detail: nil,
                amount: 0,
                showAmount: false,
                icon: "square.dashed",
                valueOverride: r.treatedAreaHa.map { formatHectares($0) } ?? "—"
            )
            costLineRow(
                label: "Cost per \(fmt.areaUnitAbbreviation)",
                detail: nil,
                amount: 0,
                showAmount: false,
                icon: "dollarsign.square",
                valueOverride: r.costPerHa.map { "\(formatCurrency(fmt.perAreaValue(perHectare: $0)))/\(fmt.areaUnitAbbreviation)" } ?? "—"
            )
            if r.costPerHa == nil, let w = r.areaWarning {
                warningRow(w)
            }

            // Yield + cost per tonne
            costLineRow(
                label: "Yield",
                detail: nil,
                amount: 0,
                showAmount: false,
                icon: "scalemass",
                valueOverride: r.yieldTonnes.map { formatTonnes($0) } ?? "—"
            )
            costLineRow(
                label: "Cost per tonne",
                detail: nil,
                amount: 0,
                showAmount: false,
                icon: "dollarsign.square",
                valueOverride: r.costPerTonne.map { "\(formatCurrency($0))/t" } ?? "—"
            )
            if r.costPerTonne == nil, let w = r.yieldWarning {
                warningRow(w)
            }

            HStack(spacing: 6) {
                Image(systemName: completenessIcon(r.completeness))
                    .font(.caption2)
                    .foregroundStyle(completenessTint(r.completeness))
                Text(completenessLabel(r.completeness))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func fuelDetailLabel(_ f: TripCostService.FuelBreakdown) -> String? {
        // Show the fuel basis, rate and litres even when cost per litre is
        // unavailable, as long as we could estimate litres.
        guard f.litres > 0, let rate = f.fuelUsageLPerHour, rate > 0 else { return nil }
        var parts: [String] = ["\(formatLitres(f.litres)) · \(fmt.formatFuelRatePerHour(litresPerHour: rate))"]
        if let perL = f.costPerLitre {
            parts.append(fmt.formatFuelCostPerUnit(perLitre: perL))
        }
        parts.append(f.basis.label)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func costLineRow(label: String, detail: String?, amount: Double, showAmount: Bool, icon: String, valueOverride: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(label, systemImage: icon)
                .font(.subheadline)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let v = valueOverride {
                    Text(v)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(v == "—" ? .secondary : .primary)
                } else if showAmount {
                    Text(formatCurrency(amount))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                } else {
                    Text("—")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatHectares(_ value: Double) -> String {
        fmt.formatArea(hectares: value)
    }

    private func formatTonnes(_ value: Double) -> String {
        String(format: "%.2f t", value)
    }

    @ViewBuilder
    private func warningRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func formatCurrency(_ value: Double) -> String {
        fmt.formatCurrency(value)
    }

    private func formatHours(_ hours: Double) -> String {
        String(format: "%.2f hr", hours)
    }

    private func formatLitres(_ litres: Double) -> String {
        fmt.formatFuel(litres: litres)
    }

    private func completenessIcon(_ c: TripCostService.CostingCompleteness) -> String {
        switch c {
        case .complete: return "checkmark.seal.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .unavailable: return "questionmark.circle.fill"
        }
    }

    private func completenessTint(_ c: TripCostService.CostingCompleteness) -> Color {
        switch c {
        case .complete: return VineyardTheme.leafGreen
        case .partial: return .orange
        case .unavailable: return .secondary
        }
    }

    private func completenessLabel(_ c: TripCostService.CostingCompleteness) -> String {
        switch c {
        case .complete: return "Estimate complete"
        case .partial: return "Partial estimate — see warnings above"
        case .unavailable: return "Cost data unavailable"
        }
    }

    private func rebuildDisplayTrail() {
        let segments = TrailDisplayProcessor.makeDisplayTrailSegments(
            points: trip.pathPoints,
            maxDisplayPoints: Self.maxDisplayTrailPoints,
            maxColourBuckets: Self.maxTrailBuckets
        )
        displayTrailSegments = segments
        #if DEBUG
        let displayCount = segments.reduce(0) { $0 + $1.coordinates.count }
        print("[Trail/Detail] full=\(trip.pathPoints.count) display=\(displayCount) " +
              "polylines=\(segments.count) mode=bucketed-static")
        #endif
    }

    private var rowCompletionResults: [RowCompletionResult] {
        guard !trip.rowSequence.isEmpty else { return [] }
        return RowCompletionDeriver.results(for: trip)
    }

    @ViewBuilder
    private func rowCompletionRow(_ result: RowCompletionResult) -> some View {
        HStack(spacing: 12) {
            Image(systemName: result.status.iconName)
                .font(.body)
                .foregroundStyle(rowTint(result.status))
                .frame(width: 22)
            Text(result.formattedPath)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, alignment: .leading)
            Spacer()
            Text(result.statusAndSourceLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rowTint(_ status: RowCompletionStatus) -> Color {
        switch status {
        case .complete: return VineyardTheme.leafGreen
        case .partial: return .orange
        case .notComplete: return .red
        }
    }

    private var coverageSourcePaddock: Paddock? {
        if let id = trip.paddockId, let p = store.paddocks.first(where: { $0.id == id }) {
            return p
        }
        for id in trip.paddockIds {
            if let p = store.paddocks.first(where: { $0.id == id }) { return p }
        }
        return nil
    }

    private var coverageSourcePaddockName: String? {
        coverageSourcePaddock?.name
    }

    private var coveredRowNumbers: [Double] {
        if !trip.completedPaths.isEmpty {
            return trip.completedPaths.sorted()
        }
        guard let paddock = coverageSourcePaddock, trip.pathPoints.count > 1 else { return [] }
        return RowGuidance.coveredRows(for: trip.pathPoints, in: paddock)
    }

    private var coveredRowSummary: String {
        let rows = coveredRowNumbers
        guard !rows.isEmpty else { return "" }
        let formatted = rows.map { value -> String in
            if value.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0f", value)
            }
            return String(format: "%.1f", value)
        }
        return formatted.joined(separator: ", ")
    }

    private var startMidrowDescription: String? {
        guard trip.trackingPattern == .everySecondRow,
              let startMidrow = trip.rowSequence.first else { return nil }
        let lowerRow = Int(floor(startMidrow))
        let upperRow = lowerRow + 1
        let midrowText: String
        if startMidrow.truncatingRemainder(dividingBy: 1) == 0 {
            midrowText = String(format: "%.0f", startMidrow)
        } else {
            midrowText = String(format: "%.1f", startMidrow)
        }
        return "Between rows \(lowerRow)–\(upperRow) — midrow \(midrowText)"
    }

    @ViewBuilder
    private func seedingDetailsBody(_ details: SeedingDetails) -> some View {
        Group {
            if let depth = details.sowingDepthCm {
                statRow("Sowing depth", value: "\(formatNumber(depth)) cm", icon: "ruler")
            }
            if let front = details.frontBox, front.hasAnyValue {
                seedingBoxRows(title: "Front Box", box: front)
            }
            if let back = details.backBox, back.hasAnyValue {
                seedingBoxRows(title: "Back Box", box: back)
            }
            if let lines = details.mixLines, !lines.isEmpty {
                ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                    seedingMixLineRow(index: idx, line: line)
                }
            }
        }
    }

    @ViewBuilder
    private func seedingBoxRows(title: String, box: SeedingBox) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let mix = box.mixName, !mix.isEmpty {
                statRow("Mix", value: mix, icon: "text.alignleft")
            }
            if let rate = box.ratePerHa {
                statRow("Rate/ha", value: "\(formatNumber(rate)) kg/ha", icon: "speedometer")
            }
            if let s = box.shutterSlide, !s.isEmpty {
                statRow("Shutter", value: s, icon: "slider.horizontal.3")
            }
            if let f = box.bottomFlap, !f.isEmpty {
                statRow("Bottom flap", value: f, icon: "rectangle.bottomthird.inset.filled")
            }
            if let w = box.meteringWheel, !w.isEmpty {
                statRow("Metering wheel", value: w, icon: "gearshape")
            }
            if let v = box.seedVolumeKg {
                statRow("Seed volume", value: "\(formatNumber(v)) kg", icon: "shippingbox")
            }
            if let g = box.gearboxSetting {
                statRow("Gearbox", value: formatNumber(g), icon: "gearshape.2")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func seedingMixLineRow(index: Int, line: SeedingMixLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mix line \(index + 1)\(line.name.flatMap { $0.isEmpty ? nil : " — \($0)" } ?? "")")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if let pct = line.percentOfMix {
                statRow("% of mix", value: "\(formatNumber(pct))%", icon: "percent")
            }
            if let box = line.seedBox, !box.isEmpty {
                statRow("Seed box", value: box, icon: "shippingbox")
            }
            if let kg = line.kgPerHa {
                statRow("Kg/ha", value: "\(formatNumber(kg)) kg/ha", icon: "scalemass")
            }
            if let supplier = line.supplierManufacturer, !supplier.isEmpty {
                statRow("Supplier", value: supplier, icon: "building.2")
            }
        }
        .padding(.vertical, 4)
    }

    private func formatNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%g", value)
    }

    private func statRow(_ label: String, value: String, icon: String) -> some View {
        HStack {
            if icon.hasPrefix("leaf") {
                Label { Text(label) } icon: { GrapeLeafIcon(size: 16) }
            } else {
                Label(label, systemImage: icon)
            }
            Spacer()
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        fmt.formatDuration(seconds: seconds)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }

    private func resolvedTripFunctionLabel() -> String? {
        guard let raw = trip.tripFunction, !raw.isEmpty else { return nil }
        if let f = TripFunction(rawValue: raw) { return f.displayName }
        if raw.hasPrefix("custom:") {
            let title = trip.tripTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { return title }
            return String(raw.dropFirst("custom:".count))
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
        return raw.capitalized
    }

    private func paddockGroupsForReport() -> [TripPDFService.PaddockCoverage] {
        let ids: [UUID] = {
            if !trip.paddockIds.isEmpty { return trip.paddockIds }
            if let single = trip.paddockId { return [single] }
            return []
        }()
        guard !ids.isEmpty, !trip.rowSequence.isEmpty else { return [] }
        var groups: [TripPDFService.PaddockCoverage] = []
        var assigned = Set<Double>()
        for id in ids {
            guard let p = store.paddocks.first(where: { $0.id == id }) else { continue }
            let nums = p.rows.map(\.number)
            guard let minN = nums.min(), let maxN = nums.max() else {
                groups.append(TripPDFService.PaddockCoverage(name: p.name, plannedPaths: []))
                continue
            }
            let lo = Double(minN) + 0.5
            let hi = Double(maxN) - 0.5
            let paths = trip.rowSequence.filter { $0 >= lo - 0.01 && $0 <= hi + 0.01 && !assigned.contains($0) }
            paths.forEach { assigned.insert($0) }
            groups.append(TripPDFService.PaddockCoverage(name: p.name, plannedPaths: paths))
        }
        // Any leftovers go to a fallback group so the operator still sees them.
        let leftover = trip.rowSequence.filter { !assigned.contains($0) }
        if !leftover.isEmpty {
            groups.append(TripPDFService.PaddockCoverage(name: "Other", plannedPaths: leftover))
        }
        // Drop entirely empty groups when we have at least one populated group.
        let populated = groups.filter { !$0.plannedPaths.isEmpty }
        return populated.isEmpty ? groups : populated
    }

    private func exportTrip() {
        guard !isExporting else { return }
        isExporting = true
        let vineyardName = store.selectedVineyard?.name ?? "Vineyard"
        let logoData = store.selectedVineyard?.logoData
        let paddockName = trip.paddockName
        let pinCount = pinsForTrip.count
        let tripCopy = currentTrip
        let exportTimeZone = tz
        let functionLabel = resolvedTripFunctionLabel()
        let paddockGroups = paddockGroupsForReport()
        let fileNameSuffix = functionLabel.map { "_\($0)" } ?? ""
        let fileName = "TripReport_\(vineyardName)\(fileNameSuffix)_\(trip.startTime.formattedTZ(date: .numeric, time: .omitted, in: exportTimeZone))"
        let includeCostings = accessControl.canViewCosting
        let costResult: TripCostService.Result? = includeCostings ? costResult : nil
        let formatter = store.settings.regionFormatter

        Task {
            let snapshot = await TripPDFService.captureMapSnapshot(trip: tripCopy)
            let pdfData = TripPDFService.generatePDF(
                trip: tripCopy,
                vineyardName: vineyardName,
                paddockName: paddockName,
                pinCount: pinCount,
                mapSnapshot: snapshot,
                logoData: logoData,
                includeCostings: includeCostings,
                timeZone: exportTimeZone,
                tripFunctionLabel: functionLabel,
                paddockGroups: paddockGroups,
                tripCostResult: costResult,
                formatter: formatter
            )
            let url = TripPDFService.savePDFToTemp(data: pdfData, fileName: fileName)
            isExporting = false

            let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                var presenter = rootVC
                while let presented = presenter.presentedViewController {
                    presenter = presented
                }
                presenter.present(activityVC, animated: true)
            }
        }
    }

    private func exportTripCSV() {
        guard !isExporting else { return }
        isExporting = true
        let vineyardName = store.selectedVineyard?.name ?? "Vineyard"
        let paddockName = trip.paddockName
        let tripCopy = currentTrip
        let exportTimeZone = tz
        let functionLabel = resolvedTripFunctionLabel()
        let includeCostings = accessControl.canViewCosting
        let resultForExport: TripCostService.Result? = includeCostings ? costResult : nil

        let url = TripCSVService.exportTrip(
            trip: tripCopy,
            vineyardName: vineyardName,
            paddockName: paddockName,
            tripFunctionLabel: functionLabel,
            tripCostResult: resultForExport,
            includeCostings: includeCostings,
            timeZone: exportTimeZone
        )
        isExporting = false

        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var presenter = rootVC
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(activityVC, animated: true)
        }
    }
}
