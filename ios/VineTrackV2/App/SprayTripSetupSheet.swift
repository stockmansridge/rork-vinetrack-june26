import SwiftUI

/// Backend-safe Spray Trip Setup sheet.
/// Restores the original two-option flow:
///   1. Use an existing spray program (template or record)
///   2. Create a new spray job (opens SprayRecordFormView)
///
/// Uses MigratedDataStore + TripTrackingService only. No old DataStore /
/// SprayCalculatorView dependencies.
struct SprayTripSetupSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(TripTrackingService.self) private var tracking
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var showProgramPicker: Bool = false
    @State private var showCalculator: Bool = false
    @State private var showTemplatePicker: Bool = false
    @State private var prefillTemplate: SprayRecord?

    private var activeTemplates: [SprayRecord] {
        store.sprayRecords.filter { $0.isTemplate }
    }

    private var nonTemplateRecords: [SprayRecord] {
        store.sprayRecords.filter { !$0.isTemplate }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    Image(systemName: "sprinkler.and.droplets.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(VineyardTheme.leafGreen.gradient)
                        .padding(.top, 24)

                    VStack(spacing: 6) {
                        Text("Spray Trip Setup")
                            .font(.title2.bold())
                        Text("How would you like to set up this spray?")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.bottom, 24)

                VStack(spacing: 12) {
                    SprayTripSetupCard(
                        icon: "doc.on.doc.fill",
                        title: "Start from Template",
                        subtitle: activeTemplates.isEmpty
                            ? "No templates available — create one in the admin portal"
                            : "Use a saved spray template to pre-fill a new job (\(activeTemplates.count) available)",
                        color: .purple,
                        disabled: activeTemplates.isEmpty
                    ) {
                        showTemplatePicker = true
                    }

                    SprayTripSetupCard(
                        icon: "plus.rectangle.on.rectangle",
                        title: "Custom Spray Job",
                        subtitle: "Open the spray calculator and configure a new job from scratch",
                        color: VineyardTheme.leafGreen,
                        disabled: false
                    ) {
                        showCalculator = true
                    }

                    if !nonTemplateRecords.isEmpty {
                        SprayTripSetupCard(
                            icon: "list.clipboard",
                            title: "Resume a Spray Program",
                            subtitle: "Continue an in-progress or saved spray record",
                            color: .blue,
                            disabled: false
                        ) {
                            showProgramPicker = true
                        }
                    }
                }
                .padding(.horizontal)

                Spacer()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Spray Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showProgramPicker) {
                SprayTripProgramPickerSheet { record in
                    startTripFromRecord(record)
                }
            }
            .sheet(isPresented: $showTemplatePicker) {
                SprayTemplatePickerSheet { template in
                    prefillTemplate = template
                    showTemplatePicker = false
                    DispatchQueue.main.async {
                        showCalculator = true
                    }
                }
            }
            .sheet(isPresented: $showCalculator, onDismiss: {
                prefillTemplate = nil
                dismiss()
            }) {
                SprayCalculatorView(prefillRecord: prefillTemplate)
            }
        }
    }

    private func startTripFromRecord(_ record: SprayRecord) {
        let trip = store.trips.first(where: { $0.id == record.tripId })
        let paddockId: UUID? = trip?.paddockId ?? trip?.paddockIds.first
        let paddockName: String = trip?.paddockName
            ?? (paddockId.flatMap { id in store.paddocks.first(where: { $0.id == id })?.name } ?? "")

        tracking.startTrip(
            type: .spray,
            paddockId: paddockId,
            paddockName: paddockName,
            trackingPattern: trip?.trackingPattern ?? .sequential,
            personName: auth.userName ?? ""
        )

        if let activeTrip = tracking.activeTrip, record.tripId != activeTrip.id {
            var updated = record
            updated.tripId = activeTrip.id
            store.updateSprayRecord(updated)
        }

        dismiss()
    }
}

private struct SprayTripSetupCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(disabled ? .secondary : color)
                    .frame(width: 44, height: 44)
                    .background((disabled ? Color.secondary : color).opacity(0.12))
                    .clipShape(.rect(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(disabled ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
        }
        .disabled(disabled)
    }
}

struct SprayTripProgramPickerSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let onSelect: (SprayRecord) -> Void

    private func tripForRecord(_ record: SprayRecord) -> Trip? {
        store.trips.first(where: { $0.id == record.tripId })
    }

    private func recordStatus(_ record: SprayRecord) -> SprayStatusFilter {
        if record.endTime != nil { return .completed }
        if let trip = tripForRecord(record), trip.isActive { return .inProgress }
        return .notStarted
    }

    private var linkedRecords: [SprayRecord] {
        store.sprayRecords
            .filter { tripForRecord($0) != nil && !$0.isTemplate }
            .sorted { $0.date > $1.date }
    }

    private var templateRecords: [SprayRecord] {
        store.sprayRecords
            .filter { $0.isTemplate }
            .sorted { $0.sprayReference.lowercased() < $1.sprayReference.lowercased() }
    }

    private var inProgressRecords: [SprayRecord] {
        linkedRecords.filter { recordStatus($0) == .inProgress }
    }

    private var notStartedRecords: [SprayRecord] {
        linkedRecords.filter { recordStatus($0) == .notStarted }
    }

    private var completedRecords: [SprayRecord] {
        linkedRecords.filter { recordStatus($0) == .completed }
    }

    private var hasAnyRecords: Bool {
        !templateRecords.isEmpty || !linkedRecords.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasAnyRecords {
                    ContentUnavailableView {
                        Label("No Spray Programs", systemImage: "list.bullet.clipboard")
                    } description: {
                        Text("Create spray records first, then select them here.")
                    }
                } else {
                    List {
                        if !templateRecords.isEmpty {
                            Section {
                                ForEach(templateRecords) { record in
                                    pickerRow(record)
                                }
                            } header: {
                                Label("Templates", systemImage: "doc.on.doc")
                            }
                        }

                        if !inProgressRecords.isEmpty {
                            Section {
                                ForEach(inProgressRecords) { record in
                                    pickerRow(record)
                                }
                            } header: {
                                Label("In Progress", systemImage: "record.circle")
                            }
                        }

                        if !notStartedRecords.isEmpty {
                            Section {
                                ForEach(notStartedRecords) { record in
                                    pickerRow(record)
                                }
                            } header: {
                                Label("Not Started", systemImage: "clock")
                            }
                        }

                        if !completedRecords.isEmpty {
                            Section {
                                ForEach(completedRecords) { record in
                                    pickerRow(record)
                                }
                            } header: {
                                Label("Completed", systemImage: "checkmark.circle")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Spray Program")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func pickerRow(_ record: SprayRecord) -> some View {
        Button {
            onSelect(record)
            dismiss()
        } label: {
            SprayTripProgramRow(record: record, store: store)
        }
    }
}

private struct SprayTripProgramRow: View {
    let record: SprayRecord
    let store: MigratedDataStore

    private var trip: Trip? {
        store.trips.first(where: { $0.id == record.tripId })
    }

    var body: some View {
        HStack {
            if record.isTemplate {
                Image(systemName: "doc.on.doc.fill")
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .frame(width: 28)
            }

            VStack(alignment: .leading, spacing: 5) {
                if !record.sprayReference.isEmpty {
                    Text(record.sprayReference)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                Label(record.date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(record.tanks.count) tank\(record.tanks.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if !record.equipmentType.isEmpty {
                    Text(record.equipmentType)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Template Picker (read-only, active templates only)

/// Lists active spray templates (is_template = true, deleted_at IS NULL).
/// Templates are deep-copied into a new spray job by `SprayCalculatorView`'s
/// prefill flow — the source template is never mutated.
struct SprayTemplatePickerSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let onSelect: (SprayRecord) -> Void

    private var activeTemplates: [SprayRecord] {
        // Soft-deleted templates are removed locally during sync, so filtering
        // by `isTemplate` is equivalent to `is_template = true AND deleted_at IS NULL`.
        store.sprayRecords
            .filter { $0.isTemplate }
            .sorted { $0.sprayReference.lowercased() < $1.sprayReference.lowercased() }
    }

    private var groupedTemplates: [(OperationType, [SprayRecord])] {
        let grouped = Dictionary(grouping: activeTemplates, by: { $0.operationType })
        return OperationType.allCases.compactMap { type in
            guard let items = grouped[type], !items.isEmpty else { return nil }
            return (type, items)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if activeTemplates.isEmpty {
                    ContentUnavailableView {
                        Label("No Templates Available", systemImage: "doc.on.doc")
                    } description: {
                        Text("Spray templates are managed in the admin portal. Once created, they will appear here.")
                    }
                } else {
                    List {
                        ForEach(groupedTemplates, id: \.0) { type, templates in
                            Section {
                                ForEach(templates) { template in
                                    Button {
                                        onSelect(template)
                                    } label: {
                                        SprayTemplateRow(template: template)
                                    }
                                }
                            } header: {
                                Label(type.rawValue, systemImage: type.iconName)
                            }
                        }

                        Section {
                            Label {
                                Text("Selecting a template will pre-fill a new spray job. The original template is not changed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Choose a Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct SprayTemplateRow: View {
    let template: SprayRecord

    private var chemicalSummary: String {
        let names = template.tanks.flatMap { $0.chemicals }
            .map { $0.name }
            .filter { !$0.isEmpty }
        return names.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc.fill")
                .font(.title3)
                .foregroundStyle(.purple)
                .frame(width: 32, height: 32)
                .background(Color.purple.opacity(0.12))
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(template.sprayReference.isEmpty ? "Untitled Template" : template.sprayReference)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                if !chemicalSummary.isEmpty {
                    Text(chemicalSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text("\(template.tanks.count) tank\(template.tanks.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if !template.equipmentType.isEmpty {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(template.equipmentType)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
