import SwiftUI

/// Scoped selection only; choosing a resource never creates labour lines or changes frozen rates.
struct PruningResourcePickerView: View {
    let vineyardId: UUID
    let selectedName: String
    let onSelect: (UUID?, UUID?, String) -> Void
    var allowsManualName: Bool = true
    @Environment(NewBackendAuthService.self) private var auth
    @State private var showQuickAdd: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""
    @State private var members: [BackendVineyardMember] = []
    @State private var resources: [VineyardExternalResource] = []
    @State private var error: String?

    private func matches(_ name: String) -> Bool {
        search.isEmpty || name.localizedStandardContains(search)
    }
    private func choose(_ external: UUID?, _ internalId: UUID?, _ name: String) {
        onSelect(external, internalId, name)
        dismiss()
    }
    var body: some View {
        NavigationStack {
            List {
                if !selectedName.isEmpty {
                    Section("Current selection") { Text(selectedName) }
                }
                Section {
                    Button("Unassigned") { choose(nil, nil, "") }
                    if allowsManualName { Button("Other / manual name") { choose(nil, nil, selectedName) } }
                }
                Section("Internal resources") {
                    ForEach(members.filter { $0.vineyardId == vineyardId && matches($0.fullName ?? $0.displayName ?? $0.email ?? "Vineyard member") }, id: \.userId) { member in
                        let name = member.fullName ?? member.displayName ?? member.email ?? "Vineyard member"
                        Button(name) { choose(nil, member.userId, name) }
                    }
                }
                Section("Crew / External contractors") {
                    ForEach(resources.filter { WorkTaskPlanning.canSelect($0, vineyard: vineyardId) && matches($0.name) }) { resource in
                        Button { choose(resource.id, nil, resource.name) } label: {
                            VStack(alignment: .leading) {
                                Text(resource.name)
                                Text(resource.kind == "crew" ? "Crew" : "External contractor").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Text("Assignments do not create labour charges. Worker Types control labour classifications and frozen rates.").font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.orange) }
                }
            }
            .searchable(text: $search, prompt: "Search people, crews and contractors")
            .navigationTitle("Assigned to")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if members.contains(where: { $0.vineyardId == vineyardId && $0.userId == auth.userId && ($0.role == .owner || $0.role == .manager) }) {
                    ToolbarItem(placement: .primaryAction) { Button("Add resource", systemImage: "plus") { showQuickAdd = true } }
                }
            }
            .sheet(isPresented: $showQuickAdd) {
                ExternalResourceEditorView(vineyardId: vineyardId) { resource in
                    if resource.isActive { choose(resource.id, nil, resource.name) }
                }
            }
            .task {
                do {
                    async let team = SupabaseTeamRepository().listMembers(vineyardId: vineyardId)
                    async let directory = SupabaseExternalResourceRepository().list(vineyardId: vineyardId)
                    members = try await team
                    resources = try await directory
                } catch {
                    self.error = "Directory unavailable. Your current selection is retained; reconnect to choose another resource."
                }
            }
        }
    }
}
