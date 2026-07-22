import SwiftUI

/// Focused correction sheet opened from the Optimal Ripeness setup
/// checklist when one or more blocks have a missing or unrecognised
/// variety. Supports the same percentage allocation model as the
/// Block Settings editor — each block can hold one or more variety
/// allocations whose percentages should total 100%. Saves write
/// back to the same `MigratedDataStore.updatePaddock` path that
/// Block Settings uses, so changes are reflected in both places.
struct FixBlockVarietiesSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id: UUID
        let paddock: Paddock
        let resolution: RipenessVarietyResolution
    }

    private var allRows: [Row] {
        store.orderedPaddocks.map { p in
            Row(id: p.id, paddock: p, resolution: RipenessVarietyResolver.resolve(p, store: store))
        }
    }

    private var problemRows: [Row] { allRows.filter { !$0.resolution.isReady } }
    private var resolvedRows: [Row] { allRows.filter { $0.resolution.isReady } }

    private var managedVarieties: [GrapeVariety] {
        let vineyardId = store.selectedVineyardId
        var seen = Set<String>()
        return store.grapeVarieties
            .filter { v in
                if let vid = vineyardId, v.vineyardId != vid { return false }
                let key = RipenessVarietyResolver.canonicalName(v.name)
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if !problemRows.isEmpty {
                Section {
                    ForEach(problemRows) { row in
                        BlockAllocationEditor(paddockId: row.paddock.id, managedVarieties: managedVarieties)
                    }
                } header: {
                    Text("Needs Attention")
                } footer: {
                    Text("Allocate the planted varieties and percentages — totals should add to 100%. Saves immediately to the same data used by Block Settings.")
                        .font(.caption)
                }
            } else {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(VineyardTheme.leafGreen)
                        Text("All blocks have a recognised variety.")
                            .font(.subheadline)
                    }
                }
            }

            if !resolvedRows.isEmpty {
                Section("Already Configured") {
                    ForEach(resolvedRows) { row in
                        BlockAllocationEditor(paddockId: row.paddock.id, managedVarieties: managedVarieties)
                    }
                }
            }
        }
        .navigationTitle("Fix Block Varieties")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Per-block allocation editor

private struct BlockAllocationEditor: View {
    @Environment(MigratedDataStore.self) private var store

    let paddockId: UUID
    let managedVarieties: [GrapeVariety]

    @State private var allocations: [PaddockVarietyAllocation] = []
    @State private var loaded: Bool = false

    private var paddock: Paddock? {
        store.paddocks.first(where: { $0.id == paddockId })
    }

    private var total: Double { allocations.reduce(0) { $0 + $1.percent } }
    private var isBalanced: Bool { abs(total - 100) < 0.5 }

    private var available: [GrapeVariety] {
        let used = Set(allocations.map { $0.varietyId })
        return managedVarieties.filter { !used.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(paddock?.name ?? "Block")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !allocations.isEmpty {
                    Text("Total: \(Int(total))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(isBalanced ? VineyardTheme.leafGreen : .orange)
                }
            }

            if allocations.isEmpty {
                Text("No variety allocations yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(allocations) { alloc in
                allocationRow(alloc)
            }

            HStack(spacing: 10) {
                if !available.isEmpty {
                    Button {
                        addAllocation()
                    } label: {
                        Label("Add Variety", systemImage: "plus.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(VineyardTheme.info)
                    }
                    .buttonStyle(.plain)
                } else if !managedVarieties.isEmpty {
                    Text("All varieties already allocated.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isBalanced, !allocations.isEmpty {
                    Label("Doesn't total 100%", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if !loaded, let p = paddock {
                allocations = p.varietyAllocations
                loaded = true
            }
        }
    }

    @ViewBuilder
    private func allocationRow(_ alloc: PaddockVarietyAllocation) -> some View {
        let current = store.grapeVariety(for: alloc.varietyId)
        HStack(spacing: 8) {
            Menu {
                ForEach(managedVarieties) { v in
                    Button {
                        replaceVariety(alloc.id, with: v.id)
                    } label: {
                        if v.optimalGDD > 0 {
                            Text("\(v.name) • \(Int(v.optimalGDD)) GDD")
                        } else {
                            Text("\(v.name) • no target")
                        }
                    }
                }
                if managedVarieties.isEmpty {
                    Text("No varieties available")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(current?.name ?? "Choose Variety")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(current == nil ? .orange : .primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            TextField("0", value: percentBinding(for: alloc.id), format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
            Text("%")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                allocations.removeAll { $0.id == alloc.id }
                persist()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    private func percentBinding(for id: UUID) -> Binding<Double> {
        Binding(
            get: { allocations.first(where: { $0.id == id })?.percent ?? 0 },
            set: { newValue in
                if let i = allocations.firstIndex(where: { $0.id == id }) {
                    allocations[i].percent = newValue
                    persist()
                }
            }
        )
    }

    private func addAllocation() {
        let remaining = max(0, 100 - total)
        let suggested = allocations.isEmpty ? 100.0 : remaining
        guard let v = available.first else { return }
        allocations.append(PaddockVarietyAllocation(varietyId: v.id, percent: suggested))
        persist()
    }

    private func replaceVariety(_ allocId: UUID, with varietyId: UUID) {
        guard let i = allocations.firstIndex(where: { $0.id == allocId }) else { return }
        allocations[i] = PaddockVarietyAllocation(
            id: allocations[i].id,
            varietyId: varietyId,
            percent: allocations[i].percent
        )
        persist()
    }

    private func persist() {
        guard var current = paddock else { return }
        current.varietyAllocations = allocations
        store.updatePaddock(current)
    }
}
