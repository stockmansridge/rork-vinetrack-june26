import SwiftUI

struct SprayTripSetupSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let onSelectProgram: (SprayRecord) -> Void
    let onCreateNew: () -> Void

    @State private var showSprayProgramList: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    Image(systemName: "spray.and.fill")
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
                        icon: "list.clipboard",
                        title: "Use a Spray Program",
                        subtitle: "Select from an existing spray configured in the Spray Program",
                        color: .blue,
                        disabled: store.sprayRecords.isEmpty
                    ) {
                        showSprayProgramList = true
                    }

                    SprayTripSetupCard(
                        icon: "plus.rectangle.on.rectangle",
                        title: "Create a New Spray Job",
                        subtitle: "Open the Spray Calculator to configure a new spray from scratch",
                        color: VineyardTheme.leafGreen,
                        disabled: false
                    ) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onCreateNew()
                        }
                    }
                }
                .padding(.horizontal)

                if store.sprayRecords.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                        Text("No spray programs yet. Create one using the Spray Calculator.")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 16)
                }

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
            .sheet(isPresented: $showSprayProgramList) {
                SprayTripProgramPickerSheet { record in
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onSelectProgram(record)
                    }
                }
            }
        }
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
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let onSelect: (SprayRecord) -> Void

    private func tripForRecord(_ record: SprayRecord) -> Trip? {
        store.trips.first(where: { $0.id == record.tripId })
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
                        Text("Create spray jobs in the Spray Calculator first, then select them here.")
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
    let store: DataStore

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

                HStack(spacing: 6) {
                    Label(record.date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
