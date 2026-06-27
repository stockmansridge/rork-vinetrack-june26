import SwiftUI
import MapKit

struct SprayRecordDetailView: View {
    let record: SprayRecord
    @Environment(DataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @State private var showEditSheet: Bool = false
    @State private var isGeneratingPDF: Bool = false
    @State private var isMapExpanded: Bool = true
    @State private var isRowsExpanded: Bool = false
    @State private var mapPosition: MapCameraPosition = .automatic

    private var tripForRecord: Trip? {
        store.trips.first(where: { $0.id == record.tripId })
    }

    var body: some View {
        List {
            if !record.sprayReference.isEmpty {
                Section {
                    Text(record.sprayReference)
                        .font(.title3.bold())
                        .listRowBackground(Color.clear)
                }
            }

            if let trip = tripForRecord, trip.pathPoints.count > 1 {
                tripMapSection(trip)
            }

            summarySection
            timingSection
            weatherSection

            if let trip = tripForRecord, !trip.rowSequence.isEmpty {
                rowsSprayedSection(trip)
            }

            ForEach(record.tanks) { tank in
                tankSection(tank)
            }

            chemicalTotalsSection
            if accessControl?.canViewFinancials ?? false {
                sprayCostSection
            }

            if !record.notes.isEmpty {
                Section("Notes") {
                    Text(record.notes)
                        .font(.subheadline)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Spray Record")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    if accessControl?.canExportFinancialPDF ?? false {
                        Button {
                            sharePDF()
                        } label: {
                            Label("Share PDF", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }

        .sheet(isPresented: $showEditSheet) {
            SprayRecordFormView(
                tripId: record.tripId,
                paddockIds: paddockIdsForTrip,
                existingRecord: record
            )
        }
    }

    private func sharePDF() {
        guard !isGeneratingPDF else { return }
        isGeneratingPDF = true
        let trip = store.trips.first(where: { $0.id == record.tripId })
        let vineyard = store.selectedVineyard
        let tripPaddocks: [Paddock] = {
            guard let t = trip else { return [] }
            if !t.paddockIds.isEmpty {
                return store.paddocks.filter { t.paddockIds.contains($0.id) }
            }
            if let pid = t.paddockId {
                return store.paddocks.filter { $0.id == pid }
            }
            return []
        }()

        Task {
            var mapSnapshot: UIImage? = nil
            if let trip = trip {
                mapSnapshot = await SprayRecordPDFService.captureMapSnapshot(trip: trip)
            }

            let pdfData = SprayRecordPDFService.generatePDF(
                record: record,
                trip: trip,
                vineyardName: vineyard?.name ?? "",
                paddockName: trip?.paddockName ?? "",
                personName: trip?.personName ?? "",
                paddocks: tripPaddocks,
                mapSnapshot: mapSnapshot,
                logoData: vineyard?.logoData,
                fuelCost: fuelCostForTrip,
                operatorCost: operatorCostForTrip,
                operatorCategoryName: operatorCategoryNameForTrip
            )
            let dateStr = record.date.formatted(.dateTime.year().month().day())
            let fileName = "SprayRecord_\(dateStr)"
            let url = SprayRecordPDFService.savePDFToTemp(data: pdfData, fileName: fileName)
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

    private var paddockIdsForTrip: [UUID] {
        if let trip = store.trips.first(where: { $0.id == record.tripId }) {
            return trip.paddockIds
        }
        return []
    }

    private func tripMapSection(_ trip: Trip) -> some View {
        Section {
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
                .frame(height: 250)
                .clipShape(.rect(cornerRadius: 10))
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } label: {
                Label("Trip Map", systemImage: "map.fill")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private func rowsSprayedSection(_ trip: Trip) -> some View {
        let completed = trip.rowSequence.filter { trip.completedPaths.contains($0) }.count
        let skipped = trip.rowSequence.filter { trip.skippedPaths.contains($0) }.count

        return Section {
            DisclosureGroup(isExpanded: $isRowsExpanded) {
                HStack(spacing: 16) {
                    rowStatLabel(count: completed, label: "Done", color: VineyardTheme.leafGreen)
                    rowStatLabel(count: skipped, label: "Skipped", color: .red)
                    rowStatLabel(count: trip.rowSequence.count, label: "Total", color: .secondary)
                }
                .padding(.vertical, 4)

                ForEach(Array(trip.rowSequence.enumerated()), id: \.offset) { index, path in
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
            } label: {
                Label("Rows Sprayed", systemImage: "arrow.left.and.right")
                    .font(.subheadline.weight(.medium))
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

    private var summarySection: some View {
        Section {
            LabeledContent("Date", value: record.date.formatted(date: .abbreviated, time: .omitted))
            if let trip = tripForRecord, !trip.paddockName.isEmpty {
                LabeledContent("Paddock / Block", value: trip.paddockName)
            }
            if !record.tractor.isEmpty {
                LabeledContent {
                    Text(record.tractor)
                } label: {
                    Label("Tractor", systemImage: "steeringwheel")
                }
            }
            if !record.equipmentType.isEmpty {
                LabeledContent("Equipment", value: record.equipmentType)
            }
            if let trip = tripForRecord, !trip.personName.isEmpty {
                LabeledContent("Operator", value: trip.personName)
            }
            if !record.tractorGear.isEmpty {
                LabeledContent("Tractor Gear", value: record.tractorGear)
            }
            if !record.numberOfFansJets.isEmpty {
                LabeledContent("No. Fans/Jets", value: record.numberOfFansJets)
            }

        }
    }

    private var timingSection: some View {
        let effectiveEnd = record.endTime ?? tripForRecord?.endTime
        return Section("Timing") {
            LabeledContent("Started", value: record.startTime.formatted(date: .abbreviated, time: .shortened))
            if let endTime = record.endTime {
                LabeledContent("Finished", value: endTime.formatted(date: .abbreviated, time: .shortened))
            } else if let trip = tripForRecord, let tripEnd = trip.endTime {
                LabeledContent("Finished", value: tripEnd.formatted(date: .abbreviated, time: .shortened))
            }
            if let trip = tripForRecord {
                let duration = trip.activeDuration
                let hours = Int(duration) / 3600
                let minutes = (Int(duration) % 3600) / 60
                LabeledContent("Duration", value: hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")

                let fillSessions = trip.tankSessions.filter { $0.fillDuration != nil }
                if !fillSessions.isEmpty {
                    ForEach(fillSessions) { session in
                        if let fillDur = session.fillDuration {
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
                }
            } else if let endTime = effectiveEnd {
                let duration = endTime.timeIntervalSince(record.startTime)
                let hours = Int(duration) / 3600
                let minutes = (Int(duration) % 3600) / 60
                LabeledContent("Duration", value: hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")
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

    private var weatherSection: some View {
        Section("Conditions") {
            if let temp = record.temperature {
                LabeledContent("Temperature", value: String(format: "%.1f°C", temp))
            }
            if let wind = record.windSpeed {
                LabeledContent("Wind Speed (10 min avg)", value: String(format: "%.1f km/h", wind))
            }
            if !record.windDirection.isEmpty {
                LabeledContent("Wind Direction", value: record.windDirection)
            }
            if let humidity = record.humidity {
                LabeledContent("Humidity", value: String(format: "%.0f%%", humidity))
            }
            if let avgSpeed = record.averageSpeed {
                LabeledContent("Average Speed", value: String(format: "%.1f km/h", avgSpeed))
            }
        }
    }

    private var chemicalTotalsSection: some View {
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
                Section("Chemical Totals (All Tanks)") {
                    ForEach(totals, id: \.0) { name, totalBase, unit in
                        let displayTotal = unit.fromBase(totalBase)
                        let unitAbbrev = unit == .litres ? "L" : unit == .kilograms ? "Kg" : unit.rawValue
                        HStack {
                            Text(name)
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "%.2f%@", displayTotal, unitAbbrev))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
    }

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

    private var sprayCostSection: some View {
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
                Section("Costs") {
                    ForEach(chemCosts, id: \.0) { name, cost in
                        HStack {
                            Text(name)
                                .font(.subheadline)
                            Spacer()
                            Text(String(format: "$%.2f", cost))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !chemCosts.isEmpty {
                        HStack {
                            Label("Chemical", systemImage: "flask.fill")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(String(format: "$%.2f", totalChemCost))
                                .font(.subheadline.weight(.semibold))
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
                            Label(operatorCatName ?? "Operator", systemImage: "person.badge.clock")
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

    private func tankSection(_ tank: SprayTank) -> some View {
        Section {
            LabeledContent("Water Volume", value: String(format: "%.1f L", tank.waterVolume))
            LabeledContent("Spray Rate", value: String(format: "%.1f L/Ha", tank.sprayRatePerHa))
            LabeledContent("Concentration Factor", value: String(format: "%.2f", tank.concentrationFactor))

            if tank.areaPerTank > 0 {
                HStack {
                    Text("Area per Tank")
                    Spacer()
                    Text(String(format: "%.2f Ha", tank.areaPerTank))
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }

            if !tank.rowApplications.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Row Applications")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(tank.rowApplications) { application in
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.left.and.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(application.rowRange)
                                .font(.subheadline)
                        }
                    }
                }
            }

            if !tank.chemicals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Chemicals")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(tank.chemicals) { chemical in
                        HStack {
                            Text(chemical.name.isEmpty ? "Unnamed" : chemical.name)
                                .font(.subheadline)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.2f %@/tank", chemical.displayVolume, chemical.unitLabel))
                                    .font(.caption)
                                Text(String(format: "%.2f %@/Ha", chemical.displayRate, chemical.unitLabel))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Label("Tank \(tank.tankNumber)", systemImage: "drop.fill")
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
