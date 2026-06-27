import SwiftUI

struct ButtonTemplateListView: View {
    let mode: PinMode
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessControl) private var accessControl
    @State private var editingTemplate: ButtonTemplate?
    @State private var showAddTemplate: Bool = false

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    private var templates: [ButtonTemplate] {
        store.buttonTemplates(for: mode)
    }

    var body: some View {
        NavigationStack {
            List {
                if templates.isEmpty {
                    ContentUnavailableView {
                        Label("No Templates", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Create button templates to quickly apply different button sets.")
                    }
                } else {
                    ForEach(templates) { template in
                        Group {
                            if canManageSetup {
                                Button { editingTemplate = template } label: { templateRow(template) }
                            } else {
                                templateRow(template)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canManageSetup {
                                Button(role: .destructive) {
                                    store.deleteButtonTemplate(template)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    store.applyButtonTemplate(template)
                                    dismiss()
                                } label: {
                                    Label("Apply", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                            }
                        }
                    }
                    if !canManageSetup {
                        Section {
                            Label("Setup data is managed by vineyard owners and managers.", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("\(mode.rawValue) Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if canManageSetup {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showAddTemplate = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showAddTemplate) {
                EditButtonTemplateSheet(mode: mode, template: nil)
            }
            .sheet(item: $editingTemplate) { template in
                EditButtonTemplateSheet(mode: mode, template: template)
            }
        }
    }

    private func templateRow(_ template: ButtonTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(template.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                ForEach(Array(template.entries.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.fromString(entry.color).gradient)
                            .frame(width: 14, height: 14)
                        Text(entry.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Text("\(template.entries.count) buttons \u{2022} Rows paired L/R")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
