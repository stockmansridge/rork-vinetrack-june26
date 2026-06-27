import SwiftUI
import MapKit
import UniformTypeIdentifiers

nonisolated enum SprayProgramSortOption: String, CaseIterable, Sendable {
    case date = "Date"
    case name = "Name"
    case elStage = "E-L Stage"
}

nonisolated enum SprayStatusFilter: String, CaseIterable, Sendable {
    case all = "All"
    case inProgress = "In Progress"
    case notStarted = "Not Started"
    case completed = "Completed"
    case templates = "Templates"
}

struct SprayProgramView: View {
    @Environment(DataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @State private var selectedRecord: SprayRecord?
    @State private var searchText: String = ""
    @State private var sortOption: SprayProgramSortOption = .date
    @State private var statusFilter: SprayStatusFilter = .all
    @State private var isEditing: Bool = false
    @State private var showCalculator: Bool = false
    @State private var showImportPicker: Bool = false
    @State private var showImportPreview: Bool = false
    @State private var importedRows: [SprayProgramCSVService.ImportedSprayRow] = []
    @State private var importWarnings: [SprayProgramCSVService.ImportWarning] = []
    @State private var importError: String?
    @State private var recordToDelete: SprayRecord?
    @State private var includeCostings: Bool = true

    private func tripForRecord(_ record: SprayRecord) -> Trip? {
        store.trips.first(where: { $0.id == record.tripId })
    }

    private func elStageForRecord(_ record: SprayRecord) -> String? {
        guard let trip = tripForRecord(record) else { return nil }
        let paddockIds = !trip.paddockIds.isEmpty ? trip.paddockIds : (trip.paddockId.map { [$0] } ?? [])
        guard !paddockIds.isEmpty else { return nil }
        let stagePins = store.pins
            .filter { $0.mode == .growth && $0.growthStageCode != nil && paddockIds.contains($0.paddockId ?? UUID()) }
            .sorted { $0.timestamp > $1.timestamp }
        return stagePins.first?.growthStageCode
    }

    private func elStageNumeric(_ code: String?) -> Int {
        guard let code = code else { return Int.max }
        let digits = code.filter { $0.isNumber }
        return Int(digits) ?? Int.max
    }

    private var filteredAndSortedRecords: [SprayRecord] {
        var records = store.sprayRecords.filter { tripForRecord($0) != nil && !$0.isTemplate }

        if !searchText.isEmpty {
            records = records.filter { record in
                let trip = tripForRecord(record)
                let paddockName = trip?.paddockName ?? ""
                let chemicalNames = record.tanks.flatMap { $0.chemicals }.map { $0.name }.joined(separator: " ")
                let combined = "\(record.sprayReference) \(paddockName) \(chemicalNames) \(record.notes) \(record.equipmentType)"
                return combined.localizedStandardContains(searchText)
            }
        }

        switch sortOption {
        case .date:
            records.sort { $0.date > $1.date }
        case .name:
            records.sort { $0.sprayReference.lowercased() < $1.sprayReference.lowercased() }
        case .elStage:
            records.sort { elStageNumeric(elStageForRecord($0)) < elStageNumeric(elStageForRecord($1)) }
        }

        return records
    }

    private func recordStatus(_ record: SprayRecord) -> SprayStatusFilter {
        if record.endTime != nil {
            return .completed
        }
        let trip = tripForRecord(record)
        if let trip = trip, trip.isActive {
            return .inProgress
        }
        return .notStarted
    }

    private var statusFilteredRecords: [SprayRecord] {
        switch statusFilter {
        case .all:
            return filteredAndSortedRecords
        case .completed:
            return filteredAndSortedRecords.filter { recordStatus($0) == .completed }
        case .inProgress:
            return filteredAndSortedRecords.filter { recordStatus($0) == .inProgress }
        case .notStarted:
            return filteredAndSortedRecords.filter { recordStatus($0) == .notStarted }
        case .templates:
            return []
        }
    }

    private var inProgressRecords: [SprayRecord] {
        statusFilteredRecords.filter { recordStatus($0) == .inProgress }
    }

    private var notStartedRecords: [SprayRecord] {
        statusFilteredRecords.filter { recordStatus($0) == .notStarted }
    }

    private var completedRecords: [SprayRecord] {
        statusFilteredRecords.filter { recordStatus($0) == .completed }
    }

    private var templateRecords: [SprayRecord] {
        var records = store.sprayRecords.filter { $0.isTemplate }
        if !searchText.isEmpty {
            records = records.filter { record in
                let trip = tripForRecord(record)
                let paddockName = trip?.paddockName ?? ""
                let chemicalNames = record.tanks.flatMap { $0.chemicals }.map { $0.name }.joined(separator: " ")
                let combined = "\(record.sprayReference) \(paddockName) \(chemicalNames) \(record.notes) \(record.equipmentType)"
                return combined.localizedStandardContains(searchText)
            }
        }
        return records.sorted { $0.sprayReference.lowercased() < $1.sprayReference.lowercased() }
    }

    private var canReorder: Bool {
        searchText.isEmpty && isEditing
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SprayStatusFilter.allCases, id: \.self) { filter in
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    statusFilter = filter
                                }
                            } label: {
                                Text(filter.rawValue)
                                    .font(.subheadline.weight(statusFilter == filter ? .semibold : .regular))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(statusFilter == filter ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                                    .foregroundStyle(statusFilter == filter ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                .contentMargins(.horizontal, 16)
                .padding(.vertical, 8)

            List {
                if canReorder {
                    ForEach(statusFilteredRecords) { record in
                        recordRow(record)
                    }
                } else if statusFilter == .templates {
                    if !templateRecords.isEmpty {
                        ForEach(templateRecords) { record in
                            recordRow(record)
                        }
                    }
                } else {
                    if statusFilter == .all && !templateRecords.isEmpty {
                        Section {
                            ForEach(templateRecords) { record in
                                recordRow(record)
                            }
                        } header: {
                            Label("Templates", systemImage: "doc.on.doc")
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    if !inProgressRecords.isEmpty {
                        Section {
                            ForEach(inProgressRecords) { record in
                                recordRow(record)
                            }
                        } header: {
                            Label("In Progress", systemImage: "record.circle")
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    if !notStartedRecords.isEmpty {
                        Section {
                            ForEach(notStartedRecords) { record in
                                recordRow(record)
                            }
                        } header: {
                            Label("Not Started", systemImage: "clock")
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    if !completedRecords.isEmpty {
                        Section {
                            ForEach(completedRecords) { record in
                                recordRow(record)
                            }
                        } header: {
                            Label("Completed", systemImage: "checkmark.circle")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            }
            .navigationTitle("Spray Program")
            .searchable(text: $searchText, prompt: "Search spray records")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if accessControl?.canExport ?? false {
                        Menu {
                            if !statusFilteredRecords.isEmpty {
                                ShareLink(
                                    item: SprayProgramExportService.generateProgramPDF(
                                        records: statusFilteredRecords,
                                        trips: store.trips,
                                        paddocks: store.paddocks,
                                        vineyardName: store.selectedVineyard?.name ?? "",
                                        logoData: store.selectedVineyard?.logoData,
                                        tractors: store.tractors,
                                        seasonFuelCostPerLitre: store.seasonFuelCostPerLitre,
                                        operatorCategories: store.operatorCategories,
                                        vineyardUsers: store.selectedVineyard?.users ?? [],
                                        includeCostings: includeCostings && (accessControl?.canExportFinancialPDF ?? false)
                                    ),
                                    preview: SharePreview("Spray Program PDF", image: Image(systemName: "doc.fill"))
                                ) {
                                    Label("Export as PDF", systemImage: "doc.richtext")
                                }

                                ShareLink(
                                    item: SprayProgramCSVService.exportRecords(
                                        records: statusFilteredRecords,
                                        trips: store.trips,
                                        vineyardName: store.selectedVineyard?.name ?? "",
                                        growthStageLookup: { record in
                                            elStageForRecord(record)
                                        }
                                    ),
                                    preview: SharePreview("Spray Program CSV", image: Image(systemName: "tablecells"))
                                ) {
                                    Label("Export as Excel (CSV)", systemImage: "tablecells")
                                }

                                Divider()

                                if accessControl?.canExportFinancialPDF ?? false {
                                    Toggle(isOn: $includeCostings) {
                                        Label("Include Costings", systemImage: "dollarsign.circle")
                                    }
                                }

                                Divider()
                            }

                            ShareLink(
                                item: SprayProgramCSVService.generateTemplate(),
                                preview: SharePreview("Spray Program Template", image: Image(systemName: "doc.badge.arrow.up"))
                            ) {
                                Label("Download Template", systemImage: "doc.badge.arrow.up")
                            }

                            Button {
                                showImportPicker = true
                            } label: {
                                Label("Import from CSV", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showCalculator = true
                        } label: {
                            Image(systemName: "plus")
                        }

                    if !statusFilteredRecords.isEmpty {
                        Menu {
                            Picker("Sort By", selection: $sortOption) {
                                ForEach(SprayProgramSortOption.allCases, id: \.self) { option in
                                    Label(option.rawValue, systemImage: sortIconName(for: option))
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
            .sheet(isPresented: $showCalculator) {
                SprayCalculatorView()
            }
            .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText, UTType.data]) { result in
                switch result {
                case .success(let url):
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let data = try Data(contentsOf: url)
                        let result = try SprayProgramCSVService.parseCSV(data: data)
                        importedRows = result.rows
                        importWarnings = result.warnings
                        showImportPreview = true
                    } catch {
                        importError = error.localizedDescription
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .sheet(isPresented: $showImportPreview) {
                if !importedRows.isEmpty {
                    SprayProgramImportView(importedRows: importedRows, warnings: importWarnings)
                }
            }
            .alert("Import Error", isPresented: .init(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .overlay {
                if statusFilter == .templates && templateRecords.isEmpty {
                    ContentUnavailableView {
                        Label("No Templates", systemImage: "doc.on.doc")
                    } description: {
                        Text("Mark a spray record as a template to reuse it for future trips.")
                    }
                } else if statusFilter != .templates && statusFilteredRecords.isEmpty && templateRecords.isEmpty {
                    ContentUnavailableView {
                        Label("No Spray Records", systemImage: "list.bullet.clipboard")
                    } description: {
                        if statusFilter != .all && !filteredAndSortedRecords.isEmpty {
                            Text("No \(statusFilter.rawValue.lowercased()) spray records found.")
                        } else {
                            Text("Spray records will appear here once created from a trip.")
                        }
                    }
                } else if statusFilter != .templates && statusFilter != .all && statusFilteredRecords.isEmpty {
                    ContentUnavailableView {
                        Label("No \(statusFilter.rawValue) Records", systemImage: "list.bullet.clipboard")
                    } description: {
                        Text("No \(statusFilter.rawValue.lowercased()) spray records found.")
                    }
                }
            }
            .alert("Delete Spray Record", isPresented: .init(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } })) {
                Button("Delete", role: .destructive) {
                    if let record = recordToDelete {
                        store.deleteSprayRecord(record)
                    }
                    recordToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    recordToDelete = nil
                }
            } message: {
                Text("Are you sure you want to delete this spray record? This action cannot be undone.")
            }
            .sheet(item: $selectedRecord) { record in
                SprayProgramDetailSheet(record: record)
            }
        }
    }

    @ViewBuilder
    private func recordRow(_ record: SprayRecord) -> some View {
        let trip = tripForRecord(record)
        let status = recordStatus(record)

        Button {
            selectedRecord = record
        } label: {
            HStack {
                if record.isTemplate {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.title3)
                        .foregroundStyle(.purple)
                        .frame(width: 28)
                } else if status == .inProgress {
                    Image(systemName: "record.circle")
                        .font(.title3)
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: true)
                        .frame(width: 28)
                } else if status == .notStarted {
                    Image(systemName: "clock")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .frame(width: 28)
                }

                VStack(alignment: .leading, spacing: 5) {
                    if !record.sprayReference.isEmpty {
                        Text(record.sprayReference)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }

                    HStack(spacing: 6) {
                        Label(record.date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let temp = record.temperature {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                            Label("\(String(format: "%.0f", temp))°C", systemImage: "thermometer.medium")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let paddockName = trip?.paddockName, !paddockName.isEmpty {
                        Label { Text(paddockName) } icon: { GrapeLeafIcon(size: 12) }
                            .font(.caption)
                            .foregroundStyle(VineyardTheme.olive)
                    }

                    let chemicalNames = record.tanks.flatMap { $0.chemicals }
                        .map { $0.name }
                        .filter { !$0.isEmpty }
                    if !chemicalNames.isEmpty {
                        Text(chemicalNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if status == .inProgress, let trip = trip, trip.isActive {
                        SprayElapsedTimeLabel(startDate: trip.startTime)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(record.tanks.count) tank\(record.tanks.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let wind = record.windSpeed {
                        HStack(spacing: 2) {
                            Image(systemName: "wind")
                                .font(.caption2)
                            Text("\(String(format: "%.0f", wind)) km/h")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if accessControl?.canDelete ?? false {
                Button(role: .destructive) {
                    recordToDelete = record
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func sortIconName(for option: SprayProgramSortOption) -> String {
        switch option {
        case .date: return "calendar"
        case .name: return "textformat"
        case .elStage: return "leaf"
        }
    }

}

struct SprayElapsedTimeLabel: View {
    let startDate: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let hours = Int(elapsed) / 3600
            let minutes = (Int(elapsed) % 3600) / 60
            let seconds = Int(elapsed) % 60
            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.caption2)
                Text(String(format: "%02d:%02d:%02d", hours, minutes, seconds))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
            }
            .foregroundStyle(.red)
        }
    }
}

struct SprayProgramDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    let record: SprayRecord
    @State private var isMapExpanded: Bool = true
    @State private var isRowsExpanded: Bool = false
    @State private var isRowsSectionExpanded: Bool = false
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var isGeneratingPDF: Bool = false
    @State private var includeCostingsInExport: Bool = true

    private var trip: Trip? {
        store.trips.first(where: { $0.id == record.tripId })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    templateToggleSection
                    if let trip = trip, trip.pathPoints.count > 1 {
                        tripMapCard(trip)
                    }
                    conditionsSection
                    tanksSection
                    chemicalTotalsSection
                    if accessControl?.canViewFinancials ?? false {
                        sprayCostSection
                    }
                    if !record.notes.isEmpty {
                        notesSection
                    }
                    if accessControl?.canExport ?? false {
                        exportSection
                    }
                    if let trip = trip, !trip.rowSequence.isEmpty {
                        rowsSprayedCard(trip)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Spray Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var templateToggleSection: some View {
        HStack(spacing: 12) {
            Image(systemName: record.isTemplate ? "doc.on.doc.fill" : "doc.on.doc")
                .font(.subheadline)
                .foregroundStyle(record.isTemplate ? .purple : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Template")
                    .font(.subheadline.weight(.medium))
                Text(record.isTemplate ? "This spray is reusable from Start Trip" : "Mark as template to reuse for future trips")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { record.isTemplate },
                set: { newValue in
                    var updated = record
                    updated.isTemplate = newValue
                    store.updateSprayRecord(updated)
                }
            ))
            .labelsHidden()
            .tint(.purple)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !record.sprayReference.isEmpty {
                Text(record.sprayReference)
                    .font(.title3.bold())
            }
            Text(record.date.formatted(.dateTime.weekday(.wide).day().month().year()))
                .font(record.sprayReference.isEmpty ? .title3.bold() : .subheadline)
                .foregroundStyle(record.sprayReference.isEmpty ? .primary : .secondary)

            if let trip = trip, !trip.paddockName.isEmpty {
                Label { Text(trip.paddockName) } icon: { GrapeLeafIcon(size: 14) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !record.tractor.isEmpty {
                Label(record.tractor, systemImage: "steeringwheel")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !record.equipmentType.isEmpty {
                Label(record.equipmentType, systemImage: "wrench.and.screwdriver")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let trip = trip, !trip.personName.isEmpty {
                Label(trip.personName, systemImage: "person")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !record.tractorGear.isEmpty {
                Label("Gear: \(record.tractorGear)", systemImage: "gearshape")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !record.numberOfFansJets.isEmpty {
                Label("Fans/Jets: \(record.numberOfFansJets)", systemImage: "fan")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack(spacing: 12) {
                Image(systemName: "timer")
                    .font(.subheadline)
                    .foregroundStyle(VineyardTheme.olive)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Started")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(record.startTime.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                if let endTime = record.endTime {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Finished")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(endTime.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.weight(.medium))
                    }
                } else if let tripEnd = trip?.endTime {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Finished")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(tripEnd.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.weight(.medium))
                    }
                } else if let trip = trip, trip.isActive {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("In Progress")
                            .font(.caption)
                            .foregroundStyle(.red)
                        SprayElapsedTimeLabel(startDate: record.startTime)
                    }
                }
            }
            if let effectiveEnd = record.endTime ?? trip?.endTime {
                let duration = effectiveEnd.timeIntervalSince(record.startTime)
                let hours = Int(duration) / 3600
                let minutes = (Int(duration) % 3600) / 60
                HStack {
                    Text("Duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VineyardTheme.olive)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var conditionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cloud.sun.fill")
                    .font(.subheadline)
                    .symbolRenderingMode(.multicolor)
                Text("Weather Conditions")
                    .font(.subheadline.weight(.semibold))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let temp = record.temperature {
                    weatherCell(icon: "thermometer.medium", label: "Temperature", value: "\(String(format: "%.1f", temp))°C")
                }
                if let humidity = record.humidity {
                    weatherCell(icon: "humidity.fill", label: "Humidity", value: "\(String(format: "%.0f", humidity))%")
                }
                if !record.windDirection.isEmpty {
                    weatherCell(icon: "location.north.fill", label: "Wind From", value: record.windDirection)
                }
                if let wind = record.windSpeed {
                    weatherCell(icon: "wind", label: "Wind Speed", value: "\(String(format: "%.1f", wind)) km/h")
                }
                if let avgSpeed = record.averageSpeed {
                    weatherCell(icon: "speedometer", label: "Avg Speed", value: "\(String(format: "%.1f", avgSpeed)) km/h")
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func weatherCell(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(VineyardTheme.olive)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
            }
            Spacer()
        }
        .padding(8)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 8))
    }

    private var tanksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "drop.fill")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                Text("Tanks")
                    .font(.subheadline.weight(.semibold))
            }

            ForEach(record.tanks) { tank in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Tank \(tank.tankNumber)")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if tank.areaPerTank > 0 {
                            Text(String(format: "%.2f Ha/tank", tank.areaPerTank))
                                .font(.caption)
                                .foregroundStyle(VineyardTheme.olive)
                        }
                    }

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Water")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f L", tank.waterVolume))
                                .font(.caption.weight(.semibold))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rate")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f L/Ha", tank.sprayRatePerHa))
                                .font(.caption.weight(.semibold))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CF")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.2f", tank.concentrationFactor))
                                .font(.caption.weight(.semibold))
                        }
                    }

                    if !tank.rowApplications.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Row Applications")
                                .font(.caption2)
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
                        ForEach(tank.chemicals) { chemical in
                            HStack {
                                Label(chemical.name.isEmpty ? "Unnamed" : chemical.name, systemImage: "flask.fill")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(String(format: "%.2f %@/tank", chemical.displayVolume, chemical.unitLabel))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(String(format: "%.2f %@/Ha", chemical.displayRate, chemical.unitLabel))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    @ViewBuilder
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

        if !totals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "flask.fill")
                        .font(.subheadline)
                        .foregroundStyle(VineyardTheme.leafGreen)
                    Text("Chemical Totals")
                        .font(.subheadline.weight(.semibold))
                }

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
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
        }
    }

    private var fuelCostForTrip: Double {
        guard let trip else { return 0 }
        let tractor = store.tractors.first(where: { $0.displayName == record.tractor || $0.name == record.tractor })
        guard let tractor, tractor.fuelUsageLPerHour > 0 else { return 0 }
        let fuelPrice = store.seasonFuelCostPerLitre
        guard fuelPrice > 0 else { return 0 }
        let end = trip.endTime ?? Date()
        let durationHours = end.timeIntervalSince(trip.startTime) / 3600.0
        return fuelPrice * tractor.fuelUsageLPerHour * durationHours
    }

    private var operatorCostForTrip: Double {
        guard let trip, !trip.personName.isEmpty else { return 0 }
        guard let category = store.operatorCategoryForName(trip.personName) else { return 0 }
        guard category.costPerHour > 0 else { return 0 }
        let end = trip.endTime ?? Date()
        let durationHours = end.timeIntervalSince(trip.startTime) / 3600.0
        return category.costPerHour * durationHours
    }

    private var operatorCategoryName: String? {
        guard let trip, !trip.personName.isEmpty else { return nil }
        return store.operatorCategoryForName(trip.personName)?.name
    }

    @ViewBuilder
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
        let operatorCatName = operatorCategoryName
        let grandTotal = totalChemCost + fuelCost + operatorCost
        let hasCosts = !chemCosts.isEmpty || fuelCost > 0 || operatorCost > 0

        if hasCosts && (accessControl?.canViewFinancials ?? false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "dollarsign.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Text("Costs")
                        .font(.subheadline.weight(.semibold))
                }

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
                        Text("Chemical Subtotal")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(String(format: "$%.2f", totalChemCost))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if fuelCost > 0 {
                    HStack {
                        Label("Fuel Cost", systemImage: "fuelpump.fill")
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

                Divider()

                HStack {
                    Text("Total Cost")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(format: "$%.2f", grandTotal))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
        }
    }

    private func tripMapCard(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "map.fill")
                    .font(.subheadline)
                    .foregroundStyle(VineyardTheme.olive)
                Text("Trip Map")
                    .font(.subheadline.weight(.semibold))
            }

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
            .frame(height: 200)
            .clipShape(.rect(cornerRadius: 10))

            NavigationLink(destination: TripDetailView(trip: trip)) {
                HStack {
                    Label("View Full Trip Map", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(VineyardTheme.olive)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func rowsSprayedCard(_ trip: Trip) -> some View {
        let completed = trip.rowSequence.filter { trip.completedPaths.contains($0) }.count
        let skipped = trip.rowSequence.filter { trip.skippedPaths.contains($0) }.count

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isRowsSectionExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.subheadline)
                        .foregroundStyle(VineyardTheme.leafGreen)
                    Text("Rows Sprayed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(completed)/\(trip.rowSequence.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isRowsSectionExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isRowsSectionExpanded {
                HStack(spacing: 16) {
                    rowStatCell(count: completed, label: "Done", color: VineyardTheme.leafGreen)
                    rowStatCell(count: skipped, label: "Skipped", color: .red)
                    rowStatCell(count: trip.rowSequence.count, label: "Total", color: .secondary)
                }

                ForEach(Array(trip.rowSequence.enumerated()), id: \.offset) { index, path in
                    let status = rowStatusForPath(path, in: trip)
                    HStack(spacing: 8) {
                        Image(systemName: status.icon)
                            .font(.caption)
                            .foregroundStyle(status.color)
                            .frame(width: 20)
                        Text("Path \(formatPathValue(path))")
                            .font(.caption)
                        Spacer()
                        Text(status.label)
                            .font(.caption2)
                            .foregroundStyle(status.color)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func rowStatCell(count: Int, label: String, color: Color) -> some View {
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

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Notes")
                    .font(.subheadline.weight(.semibold))
            }
            Text(record.notes)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var exportSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline)
                    .foregroundStyle(VineyardTheme.olive)
                Text("Export This Record")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if accessControl?.canExportFinancialPDF ?? false {
                Toggle(isOn: $includeCostingsInExport) {
                    Label("Include Costings", systemImage: "dollarsign.circle")
                        .font(.subheadline)
                }
                .tint(VineyardTheme.olive)
            }

            Button {
                sharePDF()
            } label: {
                if isGeneratingPDF {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    Label("Export as PDF", systemImage: "doc.richtext")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isGeneratingPDF)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func sharePDF() {
        guard !isGeneratingPDF else { return }
        isGeneratingPDF = true
        let currentTrip = trip
        let vineyard = store.selectedVineyard
        let tripPaddocks: [Paddock] = {
            guard let t = currentTrip else { return [] }
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
            if let currentTrip {
                mapSnapshot = await SprayRecordPDFService.captureMapSnapshot(trip: currentTrip)
            }

            let pdfData = SprayRecordPDFService.generatePDF(
                record: record,
                trip: currentTrip,
                vineyardName: vineyard?.name ?? "",
                paddockName: currentTrip?.paddockName ?? "",
                personName: currentTrip?.personName ?? "",
                paddocks: tripPaddocks,
                mapSnapshot: mapSnapshot,
                logoData: vineyard?.logoData,
                fuelCost: fuelCostForTrip,
                operatorCost: operatorCostForTrip,
                operatorCategoryName: operatorCategoryName,
                includeCostings: includeCostingsInExport && (accessControl?.canExportFinancialPDF ?? false)
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
}
