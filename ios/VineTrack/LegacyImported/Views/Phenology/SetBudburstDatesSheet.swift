import SwiftUI

/// Focused sheet opened from the Optimal Ripeness setup checklist (or
/// from a per-block swipe action) when the GDD calculation depends on
/// each block having its own Budburst date. Lists every block with a
/// `.budburst` reset mode, shows the currently stored date, and lets
/// the user set/clear it inline. Saves write back through the same
/// `MigratedDataStore.updatePaddock` path Block Settings uses.
///
/// Where possible the sheet also surfaces the most recent
/// growth-stage observation matching `GrowthStage.budburstCode`
/// (EL4) for the block as a one-tap suggestion.
struct SetBudburstDatesSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Optional paddock to scroll to / highlight when the sheet opens.
    var focusPaddockId: UUID?

    private var resetDefault: GDDResetMode { store.settings.resetMode }

    private var budburstBlocks: [Paddock] {
        store.orderedPaddocks.filter {
            $0.effectiveResetMode(defaultMode: resetDefault) == .budburst
        }
    }

    private var otherBlocks: [Paddock] {
        store.orderedPaddocks.filter {
            $0.effectiveResetMode(defaultMode: resetDefault) != .budburst
        }
    }

    var body: some View {
        List {
            if budburstBlocks.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No blocks use Budburst as reset point")
                            .font(.subheadline.weight(.semibold))
                        Text("Switch the GDD reset mode to Budburst under Operation Preferences (or per-block override) to require a Budburst date.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(budburstBlocks) { paddock in
                        BudburstRow(paddockId: paddock.id)
                    }
                } header: {
                    Text("Budburst Blocks")
                } footer: {
                    Text("These blocks use Budburst as the GDD reset point. Setting a Budburst date here updates the same value used by Block Settings and Optimal Ripeness.")
                        .font(.caption)
                }
            }

            if !otherBlocks.isEmpty {
                Section("Other Blocks") {
                    ForEach(otherBlocks) { paddock in
                        BudburstRow(paddockId: paddock.id, dimmed: true)
                    }
                }
            }
        }
        .navigationTitle("Set Budburst Dates")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Per-block row

private struct BudburstRow: View {
    @Environment(MigratedDataStore.self) private var store

    let paddockId: UUID
    var dimmed: Bool = false

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    @State private var date: Date = Date()
    @State private var hasDate: Bool = false
    @State private var loaded: Bool = false

    private var paddock: Paddock? {
        store.paddocks.first(where: { $0.id == paddockId })
    }

    /// Most recent EL4 (Budburst) growth-stage pin for this paddock,
    /// used as a one-tap suggestion when no manual date is set.
    private var suggestedDate: Date? {
        let bb = GrowthStage.budburstCode
        return store.pins
            .filter { $0.paddockId == paddockId && $0.growthStageCode == bb && $0.mode == .growth }
            .max(by: { $0.timestamp < $1.timestamp })?
            .timestamp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(paddock?.name ?? "Block")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: $hasDate)
                    .labelsHidden()
                    .onChange(of: hasDate) { _, _ in persist() }
            }

            if hasDate {
                DatePicker("Budburst", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .onChange(of: date) { _, _ in persist() }
            } else {
                Text("Using season start date as fallback")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let suggestion = suggestedDate, !hasDate || abs(suggestion.timeIntervalSince(date)) > 60 {
                Button {
                    date = suggestion
                    hasDate = true
                    persist()
                } label: {
                    Label {
                        Text("Use observation: \(fmt.formatDate(suggestion))")
                            .font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: "leaf.arrow.triangle.circlepath")
                            .font(.caption)
                    }
                    .foregroundStyle(VineyardTheme.info)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .opacity(dimmed ? 0.55 : 1.0)
        .onAppear {
            guard !loaded, let p = paddock else { return }
            if let bd = p.budburstDate {
                date = bd
                hasDate = true
            } else {
                date = suggestedDate ?? Date()
                hasDate = false
            }
            loaded = true
        }
    }

    private func persist() {
        guard var current = paddock else { return }
        let newValue: Date? = hasDate ? date : nil
        if current.budburstDate == newValue { return }
        current.budburstDate = newValue
        store.updatePaddock(current)
    }
}
