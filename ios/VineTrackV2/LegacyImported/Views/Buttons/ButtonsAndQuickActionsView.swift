import SwiftUI

struct ButtonsAndQuickActionsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl

    @State private var showEditRepair: Bool = false
    @State private var showEditGrowth: Bool = false
    @State private var showRepairTemplates: Bool = false
    @State private var showGrowthTemplates: Bool = false
    @State private var showQuickPin: Bool = false

    private var canEdit: Bool { accessControl.canChangeSettings }
    private var canCreate: Bool { accessControl.canCreateOperationalRecords }

    var body: some View {
        Form {
            Section {
                buttonPreviewRow(title: "Repair Buttons", buttons: store.repairButtons) {
                    showEditRepair = true
                }
                Button {
                    showRepairTemplates = true
                } label: {
                    Label("Repair Templates", systemImage: "square.grid.2x2")
                }
            } header: {
                Text("Repairs")
            } footer: {
                if !canEdit {
                    Text("Read-only — only owners and managers can edit buttons.")
                }
            }

            Section {
                buttonPreviewRow(title: "Growth Buttons", buttons: store.growthButtons) {
                    showEditGrowth = true
                }
                Button {
                    showGrowthTemplates = true
                } label: {
                    Label("Growth Templates", systemImage: "square.grid.2x2.fill")
                }
            } header: {
                Text("Growth & Phenology")
            }

            if canCreate {
                Section {
                    Button {
                        showQuickPin = true
                    } label: {
                        Label("Drop Quick Pin", systemImage: "mappin.and.ellipse")
                    }
                } header: {
                    Text("Quick Actions")
                } footer: {
                    Text("Drop a pin at your current location using a configured button.")
                }
            }
        }
        .navigationTitle("Buttons & Quick Actions")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditRepair) {
            EditButtonsSheet(mode: .repairs)
        }
        .sheet(isPresented: $showEditGrowth) {
            EditButtonsSheet(mode: .growth)
        }
        .sheet(isPresented: $showRepairTemplates) {
            ButtonTemplateListView(mode: .repairs)
        }
        .sheet(isPresented: $showGrowthTemplates) {
            ButtonTemplateListView(mode: .growth)
        }
        .sheet(isPresented: $showQuickPin) {
            QuickPinSheet()
        }
    }

    private func buttonPreviewRow(title: String, buttons: [ButtonConfig], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    if canEdit {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                let firstFour = Array(buttons.sorted { $0.index < $1.index }.prefix(4))
                if firstFour.isEmpty {
                    Text("No buttons configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(firstFour) { btn in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.fromString(btn.color).gradient)
                                    .frame(width: 12, height: 12)
                                Text(btn.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
