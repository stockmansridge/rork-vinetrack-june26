import SwiftUI

struct EditButtonsSheet: View {
    let mode: PinMode
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(\.dismiss) private var dismiss

    @State private var entryNames: [String] = ["", "", "", ""]
    @State private var entryColors: [String] = ["blue", "brown", "green", "red"]
    @State private var entryIsGrowthStage: [Bool] = [false, false, false, false]
    @State private var expandedColorIndex: Int? = nil
    @State private var showTemplates: Bool = false
    @State private var showResetConfirm: Bool = false

    private var canEdit: Bool { accessControl.canChangeSettings }

    private var hasDuplicateColors: Bool {
        let colors = entryColors.map { $0.lowercased() }
        return Set(colors).count != colors.count
    }

    private var canSave: Bool {
        canEdit
            && !hasDuplicateColors
            && entryNames.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !canEdit {
                    Section {
                        Label("Read-only — only owners and managers can edit buttons.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(0..<4, id: \.self) { index in
                        entryRow(index: index)
                    }
                } header: {
                    Text("\(mode.rawValue) Buttons (4 rows, paired Left & Right)")
                } footer: {
                    if hasDuplicateColors {
                        Label("Each button must have a unique colour.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    } else {
                        Text("Each row uses the same button on both the left and right side.")
                    }
                }

                Section("Preview") { previewGrid }

                if canEdit {
                    Section {
                        Button {
                            showTemplates = true
                        } label: {
                            Label("Apply Template…", systemImage: "square.grid.2x2")
                        }
                        Button(role: .destructive) {
                            showResetConfirm = true
                        } label: {
                            Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
            .navigationTitle("Edit \(mode.rawValue) Buttons")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveButtons() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: loadCurrent)
            .sheet(isPresented: $showTemplates) {
                ButtonTemplateListView(mode: mode)
                    .onDisappear { loadCurrent() }
            }
            .confirmationDialog("Reset to defaults?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    if mode == .repairs {
                        store.resetRepairButtonsToDefault()
                    } else {
                        store.resetGrowthButtonsToDefault()
                    }
                    loadCurrent()
                }
            }
        }
    }

    private func entryRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    guard canEdit else { return }
                    withAnimation(.snappy(duration: 0.2)) {
                        expandedColorIndex = expandedColorIndex == index ? nil : index
                    }
                } label: {
                    Circle()
                        .fill(Color.fromString(entryColors[index]).gradient)
                        .frame(width: 32, height: 32)
                        .overlay {
                            Circle().stroke(.primary.opacity(0.15), lineWidth: 1)
                        }
                }
                .disabled(!canEdit)

                TextField("Button Name", text: $entryNames[index])
                    .font(.headline)
                    .disabled(!canEdit)

                Text("Row \(index + 1)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(.capsule)

                if mode == .growth {
                    Button {
                        guard canEdit else { return }
                        entryIsGrowthStage[index].toggle()
                    } label: {
                        GrapeLeafIcon(size: 14, color: entryIsGrowthStage[index] ? .green : Color.secondary)
                    }
                    .disabled(!canEdit)
                }
            }

            if expandedColorIndex == index {
                colorPicker(for: index)
            }
        }
        .padding(.vertical, 4)
    }

    private func colorPicker(for index: Int) -> some View {
        let usedColors = Set(entryColors.enumerated().compactMap { i, c in i != index ? c.lowercased() : nil })

        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Color.availableColors, id: \.name) { item in
                    let isUsed = usedColors.contains(item.name.lowercased())
                    Button {
                        entryColors[index] = item.name
                        withAnimation(.snappy(duration: 0.2)) {
                            expandedColorIndex = nil
                        }
                    } label: {
                        Circle()
                            .fill(item.color.gradient)
                            .frame(width: 28, height: 28)
                            .overlay {
                                if entryColors[index] == item.name {
                                    Circle().stroke(.primary, lineWidth: 2)
                                }
                            }
                            .opacity(isUsed ? 0.3 : 1.0)
                    }
                    .disabled(isUsed)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var previewGrid: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("LEFT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach(0..<4, id: \.self) { i in
                    previewButton(name: entryNames[i], color: entryColors[i])
                }
            }
            VStack(spacing: 4) {
                Text("RIGHT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                ForEach(0..<4, id: \.self) { i in
                    previewButton(name: entryNames[i], color: entryColors[i])
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func previewButton(name: String, color: String) -> some View {
        let isLight = ["yellow", "white", "cyan"].contains(color.lowercased())
        return Text(name.isEmpty ? "Untitled" : name)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(isLight ? .black : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.fromString(color).gradient, in: .rect(cornerRadius: 8))
    }

    private func loadCurrent() {
        let active = mode == .repairs ? store.repairButtons : store.growthButtons
        // Take the first 4 (left side) — the model pairs L/R.
        let firstFour = Array(active.sorted { $0.index < $1.index }.prefix(4))
        for i in 0..<4 {
            if i < firstFour.count {
                entryNames[i] = firstFour[i].name
                entryColors[i] = firstFour[i].color
                entryIsGrowthStage[i] = firstFour[i].isGrowthStageButton
            } else {
                entryNames[i] = ""
                entryColors[i] = ["blue", "brown", "green", "red"][i]
                entryIsGrowthStage[i] = false
            }
        }
    }

    private func saveButtons() {
        guard canSave, let vineyardId = store.selectedVineyardId else { return }
        var configs: [ButtonConfig] = []
        for i in 0..<4 {
            let name = entryNames[i].trimmingCharacters(in: .whitespacesAndNewlines)
            configs.append(ButtonConfig(
                vineyardId: vineyardId,
                name: name,
                color: entryColors[i],
                index: i,
                mode: mode,
                isGrowthStageButton: entryIsGrowthStage[i]
            ))
            configs.append(ButtonConfig(
                vineyardId: vineyardId,
                name: name,
                color: entryColors[i],
                index: i + 4,
                mode: mode,
                isGrowthStageButton: entryIsGrowthStage[i]
            ))
        }
        if mode == .repairs {
            store.updateRepairButtons(configs)
        } else {
            store.updateGrowthButtons(configs)
        }
        dismiss()
    }
}
