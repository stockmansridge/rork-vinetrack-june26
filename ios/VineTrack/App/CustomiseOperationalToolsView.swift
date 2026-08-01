import SwiftUI

/// Customise Operational Tools — reorder, hide and restore the Home grid
/// tiles. Changes save automatically (locally first, then to Supabase), so
/// there is no way to lose an edit by leaving the screen.
///
/// Only tools the caller is entitled to see appear here; hiding is purely a
/// display choice and never changes permissions, records or notifications.
struct CustomiseOperationalToolsView: View {
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(OperationalToolLayoutStore.self) private var layout

    @State private var showResetConfirmation = false
    @State private var minimumVisibleAlert = false

    private var authorised: [OperationalTool] {
        OperationalToolCatalog.authorised(canViewCosting: accessControl.canViewCosting)
    }

    private var visible: [OperationalTool] { layout.visibleTools(authorised: authorised) }
    private var hidden: [OperationalTool] { layout.hiddenTools(authorised: authorised) }

    var body: some View {
        List {
            if layout.hasPendingSync {
                Section {
                    Label(OperationalToolLayoutStore.offlineSaveMessage, systemImage: "icloud.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Layout saved on this device and will sync later")
                }
            }

            Section {
                ForEach(visible) { tool in
                    row(for: tool, isHiddenRow: false)
                }
                .onMove { offsets, destination in
                    layout.move(from: offsets, to: destination, authorised: authorised)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } header: {
                Text("Visible Tools")
            } footer: {
                Text("Drag to reorder. At least one tool must remain visible.")
            }

            if !hidden.isEmpty {
                Section {
                    ForEach(hidden) { tool in
                        row(for: tool, isHiddenRow: true)
                    }
                } header: {
                    Text("Hidden Tools")
                } footer: {
                    Text("Restored tools are added to the end of Visible Tools — drag them where you want them.")
                }
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset to default layout", systemImage: "arrow.counterclockwise")
                }
                .accessibilityLabel("Reset layout")
                .accessibilityHint("Shows all available tools in the default VineTrack order")
            } footer: {
                Text("Hiding a tool only removes its tile from the Operational Tools grid. Records, notifications, reports and permissions are unaffected, and no other user's layout changes.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Customise Tools")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await layout.refreshFromServer()
        }
        .alert("At least one operational tool must remain visible.", isPresented: $minimumVisibleAlert) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog(
            "Reset Operational Tools?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                layout.resetToDefault()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will show all available tools and return them to the default VineTrack order.")
        }
    }

    @ViewBuilder
    private func row(for tool: OperationalTool, isHiddenRow: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tool.tint.opacity(isHiddenRow ? 0.10 : 0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: tool.icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tool.tint.opacity(isHiddenRow ? 0.6 : 1))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isHiddenRow ? .secondary : .primary)
                if !tool.subtitle.isEmpty {
                    Text(tool.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isHiddenRow {
                Button {
                    layout.show(toolId: tool.id, authorised: authorised)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label("Show", systemImage: "eye")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Show tool, \(tool.title)")
            } else {
                Button {
                    if !layout.hide(toolId: tool.id, authorised: authorised) {
                        minimumVisibleAlert = true
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    } else {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Hide tool, \(tool.title)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityHint(isHiddenRow ? "Hidden" : "Move tool by dragging the handle")
        .moveDisabled(isHiddenRow)
        .deleteDisabled(true)
    }
}
