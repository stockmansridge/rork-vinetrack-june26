import SwiftUI

extension Color {
    struct NamedColor {
        let name: String
        let color: Color
    }

    static let availableColors: [NamedColor] = [
        .init(name: "red", color: .red),
        .init(name: "orange", color: .orange),
        .init(name: "yellow", color: .yellow),
        .init(name: "green", color: .green),
        .init(name: "darkgreen", color: Color(red: 0.10, green: 0.45, blue: 0.20)),
        .init(name: "mint", color: .mint),
        .init(name: "teal", color: .teal),
        .init(name: "cyan", color: .cyan),
        .init(name: "blue", color: .blue),
        .init(name: "indigo", color: .indigo),
        .init(name: "purple", color: .purple),
        .init(name: "pink", color: .pink),
        .init(name: "brown", color: .brown),
        .init(name: "gray", color: .gray),
        .init(name: "black", color: .black),
    ]
}

struct EditButtonTemplateSheet: View {
    let mode: PinMode
    let template: ButtonTemplate?
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var entryNames: [String] = ["", "", "", ""]
    @State private var entryColors: [String] = ["blue", "brown", "green", "red"]
    @State private var entryIsGrowthStage: [Bool] = [false, false, false, false]
    @State private var expandedColorIndex: Int? = nil

    private var isEditing: Bool { template != nil }

    private var hasDuplicateColors: Bool {
        let colors = entryColors.map { $0.lowercased() }
        return Set(colors).count != colors.count
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasDuplicateColors
            && entryNames.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Template Name", text: $name)
                }

                Section {
                    ForEach(0..<4, id: \.self) { index in
                        templateEntryRow(index: index)
                    }
                } header: {
                    Text("Buttons (4 rows, paired Left & Right)")
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
            }
            .navigationTitle(isEditing ? "Edit Template" : "New Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTemplate() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if let template {
                    name = template.name
                    for (i, entry) in template.entries.prefix(4).enumerated() {
                        entryNames[i] = entry.name
                        entryColors[i] = entry.color
                        entryIsGrowthStage[i] = entry.isGrowthStageButton
                    }
                } else {
                    let defaults = defaultEntries()
                    for (i, entry) in defaults.enumerated() {
                        entryNames[i] = entry.name
                        entryColors[i] = entry.color
                        entryIsGrowthStage[i] = entry.isGrowthStageButton
                    }
                }
            }
        }
    }

    private func templateEntryRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
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

                TextField("Button Name", text: $entryNames[index])
                    .font(.headline)

                Text("Row \(index + 1)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(.capsule)

                if mode == .growth {
                    Button {
                        entryIsGrowthStage[index].toggle()
                    } label: {
                        GrapeLeafIcon(size: 14)
                            .foregroundStyle(entryIsGrowthStage[index] ? .green : .secondary)
                    }
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

    private func defaultEntries() -> [ButtonTemplateEntry] {
        if mode == .repairs {
            return [
                ButtonTemplateEntry(name: "", color: "blue"),
                ButtonTemplateEntry(name: "", color: "brown"),
                ButtonTemplateEntry(name: "", color: "green"),
                ButtonTemplateEntry(name: "", color: "red"),
            ]
        } else {
            return [
                ButtonTemplateEntry(name: "Growth Stage", color: "darkgreen", isGrowthStageButton: true),
                ButtonTemplateEntry(name: "", color: "gray"),
                ButtonTemplateEntry(name: "", color: "yellow"),
                ButtonTemplateEntry(name: "", color: "red"),
            ]
        }
    }

    private func saveTemplate() {
        guard canSave else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newEntries = (0..<4).map { i in
            ButtonTemplateEntry(
                name: entryNames[i].trimmingCharacters(in: .whitespacesAndNewlines),
                color: entryColors[i],
                isGrowthStageButton: entryIsGrowthStage[i]
            )
        }

        if var existing = template {
            existing.name = trimmedName
            existing.entries = newEntries
            store.updateButtonTemplate(existing)
        } else {
            let newTemplate = ButtonTemplate(
                vineyardId: store.selectedVineyardId ?? UUID(),
                name: trimmedName,
                mode: mode,
                entries: newEntries
            )
            store.addButtonTemplate(newTemplate)
        }
        dismiss()
    }
}
