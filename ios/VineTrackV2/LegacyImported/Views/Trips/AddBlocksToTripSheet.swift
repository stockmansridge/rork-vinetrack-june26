import SwiftUI

/// Sheet shown while a trip is paused so the operator can add additional
/// paddocks/blocks to the in-progress trip without losing existing coverage.
struct AddBlocksToTripSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(TripTrackingService.self) private var tracking
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIds: Set<UUID> = []
    @State private var searchText: String = ""

    private var existingIds: Set<UUID> {
        guard let trip = tracking.activeTrip else { return [] }
        var ids = Set<UUID>(trip.paddockIds)
        if let id = trip.paddockId { ids.insert(id) }
        return ids
    }

    private var availablePaddocks: [Paddock] {
        let all = store.paddocks
            .filter { !existingIds.contains($0.id) }
            .sorted(by: StartTripSheet.rowOrderSort)
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if availablePaddocks.isEmpty {
                    ContentUnavailableView {
                        Label("No Other Blocks", systemImage: "square.grid.2x2")
                    } description: {
                        Text("All available blocks are already part of this trip.")
                    }
                } else {
                    List {
                        Section {
                            Text("Select additional blocks to include in this trip. Existing coverage is preserved; new blocks are appended to the planned sequence.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Section {
                            ForEach(availablePaddocks) { paddock in
                                let isSelected = selectedIds.contains(paddock.id)
                                Button {
                                    if isSelected {
                                        selectedIds.remove(paddock.id)
                                    } else {
                                        selectedIds.insert(paddock.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected ? AnyShapeStyle(.blue) : AnyShapeStyle(.tertiary))
                                        GrapeLeafIcon(size: 20, color: VineyardTheme.leafGreen)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(paddock.name)
                                                .font(.subheadline.weight(.semibold))
                                            Text("\(StartTripSheet.rowRangeLabel(for: paddock)) · \(String(format: "%.2f", paddock.areaHectares)) ha")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $searchText, prompt: "Search blocks")
                }
            }
            .navigationTitle("Add Blocks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        tracking.addPaddocksToActiveTrip(Array(selectedIds))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedIds.isEmpty)
                }
            }
        }
    }
}
