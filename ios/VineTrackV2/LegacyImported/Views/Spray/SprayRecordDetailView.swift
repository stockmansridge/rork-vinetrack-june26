import SwiftUI
import MapKit

struct SprayRecordDetailView: View {
    let record: SprayRecord
    @Environment(MigratedDataStore.self) private var store
    @Environment(SprayRecordSyncService.self) private var sprayRecordSync
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss
    @State private var showEditSheet: Bool = false
    @State private var isGeneratingPDF: Bool = false
    @State private var sharePDFURL: ShareURL?
    @State private var exportError: String?
    @State private var isMapExpanded: Bool = true
    @State private var isRowsExpanded: Bool = false
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var includeCostingsInExport: Bool = true

    private var tripForRecord: Trip? {
        store.trips.first(where: { $0.id == record.tripId })
    }

    private var canViewFinancials: Bool {
        accessControl?.canViewFinancials ?? false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard

                templateCard

                if let trip = tripForRecord, trip.pathPoints.count > 1 {
                    tripMapCard(trip)
                }

                summaryCard
                timingCard
                weatherCard

                if let trip = tripForRecord, !trip.rowSequence.isEmpty {
                    rowsSprayedCard(trip)
                }

                tanksCard
                chemicalTotalsCard

                if canViewFinancials {
                    sprayCostCard
                }

                if !record.notes.isEmpty {
                    notesCard
                }

                exportCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Spray Record")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { dismiss() }
                    .font(.headline)
            }
        }
        .sheet(item: $sharePDFURL) { wrapper in
            ShareSheet(items: [wrapper.url])
        }
        .alert("Export Failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .sheet(isPresented: $showEditSheet) {
            SprayRecordFormView(
                tripId: record.tripId,
                paddockIds: paddockIdsForTrip,
                existingRecord: record
            )
        }
        .onAppear {
            includeCostingsInExport = canViewFinancials
        }
    }

    // MARK: - Card Container

    private func cardContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func sectionHeader(_ title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !record.sprayReference.isEmpty {
                    Text(record.sprayReference)
                        .font(.title2.bold())
                }
                RecordSyncBadge(state: RecordSyncState.forSprayRecord(record.id, spraySync: sprayRecordSync))
                Spacer()
                Button {
                    showEditSheet = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.headline)
                        .foregroundStyle(VineyardTheme.leafGreen)
                        .padding(10)
                        .background(VineyardTheme.leafGreen.opacity(0.12))
                        .clipShape(Circle())
                }
            }
            RecordSyncFailureHint(state: RecordSyncState.forSprayRecord(record.id, spraySync: sprayRecordSync))
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Template

    private var currentRecord: SprayRecord {
        store.sprayRecords.first(where: { $0.id == record.id }) ?? record
    }

    private var templateCard: some View {
        let binding = Binding<Bool>(
            get: { currentRecord.isTemplate },
            set: { newValue in
                var updated = currentRecord
                updated.isTemplate = newValue
                store.updateSprayRecord(updated)
            }
        )

        return cardContainer {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Template")
                        .font(.headline)
                    Text("Mark as template to reuse for future trips")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .tint(VineyardTheme.leafGreen)
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        cardContainer {
            sectionHeader("Job Details", systemImage: "doc.text.fill", color: .blue)
            VStack(spacing: 10) {
                detailRow("Date", value: record.date.formattedTZ(date: .abbreviated, time: .omitted, in: store.settings.resolvedTimeZone))
                if let trip = tripForRecord, !trip.paddockName.isEmpty {
                    Divider()
                    detailRow("Block", value: trip.paddockName)
                }
                let tractorName = store.resolvedSprayTractorName(record)
                if !tractorName.isEmpty {
                    Divider()
                    HStack {
                        Label("Tractor", systemImage: "steeringwheel")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(tractorName)
                            .font(.subheadline)
                    }
                }
                let equipmentName = store.resolvedSprayEquipmentName(record)
                if !equipmentName.isEmpty {
                    Divider()
                    detailRow("Equipment", value: equipmentName)
                }
                if let trip = tripForRecord, !trip.personName.isEmpty {
                    Divider()
                    detailRow("Operator", value: trip.personName)
                }
                if !record.tractorGear.isEmpty {
                    Divider()
                    detailRow("Tractor Gear", value: record.tractorGear)
                }
                if !record.numberOfFansJets.isEmpty {
                    Divider()
                    detailRow("No. Fans/Jets", value: record.numberOfFansJets)
                }
            }
        }
    }

    // MARK: - Timing

    private var timingCard: some View {
        let effectiveEnd = record.endTime ?? tripForRecord?.endTime
        let tz = store.settings.resolvedTimeZone

        return cardContainer {
            sectionHeader("Timing", systemImage: "clock.fill", color: .orange)
            VStack(spacing: 10) {
                detailRow("Started", value: record.startTime.formattedTZ(date: .abbreviated, time: .shortened, in: tz))
                if let endTime = effectiveEnd {
                    Divider()
                    detailRow("Finished", value: endTime.formattedTZ(date: .abbreviated, time: .shortened, in: tz))
                }
                if let trip = tripForRecord {
                    let duration = trip.activeDuration
                    let hours = Int(duration) / 3600
                    let minutes = (Int(duration) % 3600) / 60
                    Divider()
                    detailRow("Duration", value: hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")

                    let fillSessions = trip.tankSessions.filter { $0.fillDuration != nil }
                    ForEach(fillSessions) { session in
                        if let fillDur = session.fillDuration {
                            Divider()
                            HStack {
                                Label("Tank \(session.tankNumber) Fill", systemImage: "drop.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.cyan)
                                Spacer()
                                Text(formatFillDurationDetail(fillDur))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if let endTime = effectiveEnd {
                    let duration = endTime.timeIntervalSince(record.startTime)
                    let hours = Int(duration) / 3600
                    let minutes = (Int(duration) % 3600) / 60
                    Divider()
                    detailRow("Duration", value: hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")
                }
            }
        }
    }

    private func formatFillDurationDetail(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(seconds, 0))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    // MARK: - Weather

    private var weatherCard: some View {
        let hasWeather = record.temperature != nil || record.windSpeed != nil ||
            !record.windDirection.isEmpty || record.humidity != nil || record.averageSpeed != nil

        return cardContainer {
            sectionHeader("Weather Conditions", systemImage: "sun.max.fill", color: .yellow)
            if hasWeather {
                VStack(spacing: 10) {
                    if let temp = record.temperature {
                        detailRow("Temperature", value: String(format: "%.1f°C", temp))
                        Divider()
                    }
                    if let wind = record.windSpeed {
                        detailRow("Wind Speed (10 min avg)", value: String(format: "%.1f km/h", wind))
                        Divider()
                    }
                    if !record.windDirection.isEmpty {
                        detailRow("Wind Direction", value: record.windDirection)
                        Divider()
                    }
                    if let humidity = record.humidity {
                        detailRow("Humidity", value: String(format: "%.0f%%", humidity))
                        Divider()
                    }
                    if let avgSpeed = record.averageSpeed {
                        detailRow("Average Speed", value: String(format: "%.1f km/h", avgSpeed))
                    }
                }
            } else {
                Text("No weather data captured")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tanks

    private var tanksCard: some View {
        cardContainer {
            sectionHeader("Tanks", systemImage: "drop.fill", color: .blue)
            VStack(spacing: 12) {
                ForEach(record.tanks) { tank in
                    tankCard(tank)
                }
            }
        }
    }

    private func tankCard(_ tank: SprayTank) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tank \(tank.tankNumber)")
                    .font(.title3.bold())
                Spacer()
                if tank.areaPerTank > 0 {
                    Text(String(format: "%.2f Ha/tank", tank.areaPerTank))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
            }

            HStack(alignment: .top, spacing: 0) {
                tankMetric(label: "Water", value: String(format: "%.0f L", tank.waterVolume))
                tankMetric(label: "Rate", value: String(format: "%.0f L/Ha", tank.sprayRatePerHa))
                tankMetric(label: "CF", value: String(format: "%.2f", tank.effectiveConcentrationFactor))
            }

            if !tank.rowApplications.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Row Applications")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(tank.rowApplications) { application in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.left.and.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(application.rowRange)
                                .font(.caption)
                        }
                    }
                }
            }

            if !tank.chemicals.isEmpty {
                VStack(spacing: 8) {
                    ForEach(tank.chemicals) { chemical in
                        chemicalRow(chemical)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func tankMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chemicalRow(_ chemical: SprayChemical) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "flask.fill")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 28)
            Text(chemical.name.isEmpty ? "Unnamed" : chemical.name)
                .font(.subheadline)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.2f %@/tank", chemical.displayVolume, chemical.unitLabel))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.2f %@/Ha", chemical.displayRate, chemical.unitLabel))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Chemical Totals

    private var chemicalTotalsCard: some View {
        let allChemicals = record.tanks.flatMap { $0.chemicals }
        let grouped = Dictionary(grouping: allChemicals, by: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let totals = grouped.compactMap { (key, chems) -> (String, Double, ChemicalUnit)? in
            guard !key.isEmpty else { return nil }
            let displayName = chems.first?.name ?? key
            let unit = chems.first?.unit ?? .litres
            let totalBase = chems.reduce(0.0) { $0 + $1.volumePerTank }
            return (displayName, totalBase, unit)
        }.sorted { $0.0.lowercased() < $1.0.lowercased() }

        return Group {
            if !totals.isEmpty {
                cardContainer {
                    sectionHeader("Chemical Totals", systemImage: "flask.fill", color: VineyardTheme.leafGreen)
                    VStack(spacing: 10) {
                        ForEach(Array(totals.enumerated()), id: \.offset) { index, item in
                            let (name, totalBase, unit) = item
                            let displayTotal = unit.fromBase(totalBase)
                            let unitAbbrev = unit == .litres ? "L" : unit == .kilograms ? "Kg" : unit.rawValue
                            HStack {
                                Text(name)
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f%@", displayTotal, unitAbbrev))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                            if index < totals.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Costs

    private var fuelCostForTrip: Double {
        guard let trip = tripForRecord else { return 0 }
        let tractor = store.tractors.first(where: { $0.displayName == record.tractor || $0.name == record.tractor })
        guard let tractor, tractor.fuelUsageLPerHour > 0 else { return 0 }
        let fuelPrice = store.seasonFuelCostPerLitre
        guard fuelPrice > 0 else { return 0 }
        let durationHours = trip.activeDuration / 3600.0
        return fuelPrice * tractor.fuelUsageLPerHour * durationHours
    }

    private var operatorCostForTrip: Double {
        guard let trip = tripForRecord, !trip.personName.isEmpty else { return 0 }
        guard let category = store.operatorCategoryForName(trip.personName) else { return 0 }
        guard category.costPerHour > 0 else { return 0 }
        let durationHours = trip.activeDuration / 3600.0
        return category.costPerHour * durationHours
    }

    private var operatorCategoryNameForTrip: String? {
        guard let trip = tripForRecord, !trip.personName.isEmpty else { return nil }
        return store.operatorCategoryForName(trip.personName)?.name
    }

    private var sprayCostCard: some View {
        let costItems: [(String, Double)] = record.tanks.flatMap { tank in
            tank.chemicals.compactMap { chemical -> (String, Double)? in
                let cost = chemical.costPerUnit * chemical.volumePerTank
                guard cost > 0 else { return nil }
                return (chemical.name.isEmpty ? "Unnamed" : chemical.name, cost)
            }
        }
        let grouped = Dictionary(grouping: costItems, by: { $0.0.lowercased() })
        let chemCosts = grouped.compactMap { (key, items) -> (String, Double)? in
            guard !key.isEmpty else { return nil }
            let displayName = items.first?.0 ?? key
            let totalCost = items.reduce(0.0) { $0 + $1.1 }
            return (displayName, totalCost)
        }.sorted { $0.0.lowercased() < $1.0.lowercased() }
        let totalChemCost = chemCosts.reduce(0.0) { $0 + $1.1 }
        let fuelCost = fuelCostForTrip
        let operatorCost = operatorCostForTrip
        let operatorCatName = operatorCategoryNameForTrip
        let grandTotal = totalChemCost + fuelCost + operatorCost
        let hasCosts = !chemCosts.isEmpty || fuelCost > 0 || operatorCost > 0

        return Group {
            if hasCosts {
                cardContainer {
                    sectionHeader("Costs", systemImage: "dollarsign.circle.fill", color: .green)
                    VStack(spacing: 10) {
                        ForEach(chemCosts, id: \.0) { name, cost in
                            HStack {
                                Text(name)
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "$%.2f", cost))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                        if !chemCosts.isEmpty {
                            HStack {
                                Label("Chemical", systemImage: "flask.fill")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(String(format: "$%.2f", totalChemCost))
                                    .font(.subheadline.weight(.semibold))
                            }
                            Divider()
                        }
                        if fuelCost > 0 {
                            HStack {
                                Label("Fuel", systemImage: "fuelpump.fill")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "$%.2f", fuelCost))
                                    .font(.subheadline)
                            }
                            Divider()
                        }
                        if operatorCost > 0 {
                            HStack {
                                Label(operatorCatName ?? "Operator", systemImage: "person.badge.clock")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "$%.2f", operatorCost))
                                    .font(.subheadline)
                            }
                            Divider()
                        }
                        HStack {
                            Text("Total Cost")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(String(format: "$%.2f", grandTotal))
                                .font(.headline)
                                .foregroundStyle(VineyardTheme.leafGreen)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Notes

    private var notesCard: some View {
        cardContainer {
            sectionHeader("Notes", systemImage: "note.text", color: .indigo)
            Text(record.notes)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Map / Rows

    private func tripMapCard(_ trip: Trip) -> some View {
        cardContainer {
            DisclosureGroup(isExpanded: $isMapExpanded) {
                Map(position: $mapPosition) {
                    if trip.pathPoints.count > 1 {
                        let coords = trip.pathPoints.map { $0.coordinate }
                        let segmentCount = max(coords.count - 1, 1)
                        ForEach(0..<(coords.count - 1), id: \.self) { i in
                            let progress = Double(i) / Double(segmentCount)
                            MapPolyline(coordinates: [coords[i], coords[i + 1]])
                                .stroke(mapGradientColor(for: progress), lineWidth: 4)
                        }
                    }
                }
                .mapStyle(.hybrid)
                .frame(height: 220)
                .clipShape(.rect(cornerRadius: 10))
                .padding(.top, 8)
            } label: {
                Label("Trip Map", systemImage: "map.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
        }
    }

    private func rowsSprayedCard(_ trip: Trip) -> some View {
        let completed = trip.rowSequence.filter { trip.completedPaths.contains($0) }.count
        let skipped = trip.rowSequence.filter { trip.skippedPaths.contains($0) }.count

        return cardContainer {
            DisclosureGroup(isExpanded: $isRowsExpanded) {
                VStack(spacing: 8) {
                    HStack(spacing: 16) {
                        rowStatLabel(count: completed, label: "Done", color: VineyardTheme.leafGreen)
                        rowStatLabel(count: skipped, label: "Skipped", color: .red)
                        rowStatLabel(count: trip.rowSequence.count, label: "Total", color: .secondary)
                    }
                    .padding(.vertical, 4)

                    ForEach(Array(trip.rowSequence.enumerated()), id: \.offset) { _, path in
                        let status = rowStatusForPath(path, in: trip)
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
                .padding(.top, 8)
            } label: {
                Label("Rows Sprayed", systemImage: "arrow.left.and.right")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
        }
    }

    private func rowStatLabel(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func rowStatusForPath(_ path: Double, in trip: Trip) -> PathStatus {
        if trip.completedPaths.contains(path) { return .completed }
        if trip.skippedPaths.contains(path) { return .skipped }
        return .pending
    }

    private func formatPathValue(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func mapGradientColor(for progress: Double) -> Color {
        let r = 1.0 - progress
        let g = progress
        return Color(red: r, green: g, blue: 0)
    }

    // MARK: - Export

    private var exportCard: some View {
        cardContainer {
            sectionHeader("Export This Record", systemImage: "square.and.arrow.up", color: VineyardTheme.leafGreen)

            if canViewFinancials {
                HStack(spacing: 12) {
                    Image(systemName: "dollarsign.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    Text("Include Costings")
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: $includeCostingsInExport)
                        .labelsHidden()
                        .tint(VineyardTheme.leafGreen)
                }
            }

            Button {
                exportPDF()
            } label: {
                HStack(spacing: 8) {
                    if isGeneratingPDF {
                        ProgressView()
                    } else {
                        Image(systemName: "doc.richtext")
                            .font(.headline)
                        Text("Export as PDF")
                            .font(.headline)
                    }
                }
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(.tertiarySystemBackground))
                .clipShape(Capsule())
            }
            .disabled(isGeneratingPDF)
        }
    }

    private var paddockIdsForTrip: [UUID] {
        if let trip = store.trips.first(where: { $0.id == record.tripId }) {
            return trip.paddockIds
        }
        return []
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ShareURL: Identifiable {
    let id = UUID()
    let url: URL
}

extension SprayRecordDetailView {
    fileprivate func exportPDF() {
        guard !isGeneratingPDF else { return }
        isGeneratingPDF = true
        let trip = tripForRecord
        let vineyardName = store.selectedVineyard?.name ?? "Vineyard"
        let logoData = store.selectedVineyard?.logoData
        let paddockName: String = trip?.paddockName ?? ""
        let personName: String = trip?.personName ?? ""
        let paddocks = store.paddocks
        let fuelCost = fuelCostForTrip
        let operatorCost = operatorCostForTrip
        let operatorCatName = operatorCategoryNameForTrip
        let includeCostings = canViewFinancials && includeCostingsInExport
        let recordCopy = record
        let resolvedTractorName = store.resolvedSprayTractorName(record)
        let resolvedEquipmentName = store.resolvedSprayEquipmentName(record)
        let exportTimeZone = store.settings.resolvedTimeZone

        // Build TripCostService.Result for owner/manager exports so we render
        // the richer Estimated Trip Cost section with warnings + completeness.
        let costResult: TripCostService.Result? = {
            guard includeCostings, let trip else { return nil }
            let category: OperatorCategory? = {
                if let cid = trip.operatorCategoryId,
                   let c = store.operatorCategories.first(where: { $0.id == cid }) {
                    return c
                }
                if !trip.personName.isEmpty {
                    return store.operatorCategoryForName(trip.personName)
                }
                return nil
            }()
            let tractor: Tractor? = {
                if let tid = trip.tractorId {
                    return store.tractors.first { $0.id == tid }
                }
                return store.tractors.first { $0.displayName == recordCopy.tractor || $0.name == recordCopy.tractor }
            }()
            let fuelPurchases = store.fuelPurchases.filter { $0.vineyardId == trip.vineyardId }
            var areasById: [UUID: Double] = [:]
            let tripPaddockIds: [UUID] = !trip.paddockIds.isEmpty ? trip.paddockIds : (trip.paddockId.map { [$0] } ?? [])
            for pid in tripPaddockIds {
                if let p = store.paddocks.first(where: { $0.id == pid }) {
                    areasById[pid] = p.areaHectares
                }
            }
            return TripCostService.estimate(
                trip: trip,
                operatorCategory: category,
                tractor: tractor,
                fuelPurchases: fuelPurchases,
                sprayRecord: recordCopy,
                savedChemicals: store.savedChemicals,
                paddockAreasById: areasById,
                historicalYieldRecords: store.historicalYieldRecords
            )
        }()

        Task {
            var snapshot: UIImage? = nil
            if let trip, trip.pathPoints.count > 1 {
                snapshot = await SprayRecordPDFService.captureMapSnapshot(trip: trip)
            }
            let data = SprayRecordPDFService.generatePDF(
                record: recordCopy,
                trip: trip,
                vineyardName: vineyardName,
                paddockName: paddockName,
                personName: personName,
                paddocks: paddocks,
                mapSnapshot: snapshot,
                logoData: logoData,
                fuelCost: fuelCost,
                operatorCost: operatorCost,
                operatorCategoryName: operatorCatName,
                includeCostings: includeCostings,
                timeZone: exportTimeZone,
                formatter: store.settings.regionFormatter,
                resolvedTractorName: resolvedTractorName,
                resolvedEquipmentName: resolvedEquipmentName,
                tripCostResult: costResult
            )
            let fileName = "SprayRecord_\(recordCopy.sprayReference.isEmpty ? "Record" : recordCopy.sprayReference)_\(recordCopy.date.formatted(.iso8601.year().month().day()))"
            let url = SprayRecordPDFService.savePDFToTemp(data: data, fileName: fileName)
            await MainActor.run {
                sharePDFURL = ShareURL(url: url)
                isGeneratingPDF = false
            }
        }
    }
}

struct SprayRecordBanner: View {
    let record: SprayRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "spray.and.fill")
                .font(.subheadline)
                .foregroundStyle(VineyardTheme.leafGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text("Spray Record")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    Text("\(record.tanks.count) tank\(record.tanks.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let totalChemicals = record.tanks.flatMap { $0.chemicals }.count
                    if totalChemicals > 0 {
                        Text("• \(totalChemicals) chemical\(totalChemicals == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
