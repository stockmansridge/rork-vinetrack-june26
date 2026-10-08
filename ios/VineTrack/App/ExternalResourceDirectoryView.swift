import SwiftUI

struct ExternalResourceDirectoryView: View {
    let vineyardId: UUID
    @Environment(NewBackendAuthService.self) private var auth
    @State private var resources: [VineyardExternalResource] = []
    @State private var canManage: Bool = false
    @State private var error: String?
    @State private var editing: VineyardExternalResource?
    @State private var creating: Bool = false

    var body: some View {
        List {
            Section {
                Text("Crews and external contractors are resources, not login accounts. Assignments do not create labour charges; Worker Types govern labour rates.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.orange) }
            ForEach(resources.filter { $0.deletedAt == nil }) { resource in
                Button { if canManage { editing = resource } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(resource.name).foregroundStyle(.primary)
                        Text("\(resource.kind == "crew" ? "Crew" : "External contractor")\(resource.isActive ? "" : " · Inactive")").font(.caption).foregroundStyle(.secondary)
                        if let contact = resource.contactName { Text(contact).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("Crew / Contractors")
        .toolbar { if canManage { Button("Add", systemImage: "plus") { creating = true } } }
        .sheet(isPresented: $creating) {
            ExternalResourceEditorView(vineyardId: vineyardId) { _ in Task { await reload() } }
        }
        .sheet(item: $editing) { resource in
            ExternalResourceEditorView(vineyardId: vineyardId, existing: resource) { _ in Task { await reload() } }
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            let team = try await SupabaseTeamRepository().listMembers(vineyardId: vineyardId)
            canManage = team.contains { $0.vineyardId == vineyardId && $0.userId == auth.userId && ($0.role == .owner || $0.role == .manager) }
            resources = try await SupabaseExternalResourceRepository().list(vineyardId: vineyardId)
            error = nil
        } catch { self.error = "Directory unavailable. Reconnect to load resources." }
    }
}

/// Online guarded editing; this sheet does not dismiss or replace its parent's unfinished draft.
struct ExternalResourceEditorView: View {
    let vineyardId: UUID
    var existing: VineyardExternalResource? = nil
    let onSaved: (VineyardExternalResource) -> Void
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var id: UUID = UUID()
    @State private var name: String = ""
    @State private var kind: String = "crew"
    @State private var contact: String = ""
    @State private var phone: String = ""
    @State private var email: String = ""
    @State private var notes: String = ""
    @State private var active: Bool = true
    @State private var saving: Bool = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Resource") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) { Text("Crew").tag("crew"); Text("External contractor").tag("contractor") }
                    Toggle("Active", isOn: $active)
                }
                Section("Contact") {
                    TextField("Contact name", text: $contact)
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                    TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                Section {
                    Text("Online confirmation is required. Your unfinished task or pruning activity stays open underneath this form.").font(.footnote).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.orange) }
                }
            }
            .navigationTitle(existing == nil ? "Add Resource" : "Edit Resource")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { Task { await save() } }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .interactiveDismissDisabled(saving)
            .onAppear {
                if let existing { id = existing.id; name = existing.name; kind = existing.kind; contact = existing.contactName ?? ""; phone = existing.phone ?? ""; email = existing.email ?? ""; notes = existing.notes ?? ""; active = existing.isActive }
            }
        }
    }

    private func optional(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    private func save() async {
        guard !saving, let author = auth.userId else { return }
        saving = true
        defer { saving = false }
        do {
            let members = try await SupabaseTeamRepository().listMembers(vineyardId: vineyardId)
            guard members.contains(where: { $0.vineyardId == vineyardId && $0.userId == author && ($0.role == .owner || $0.role == .manager) }), auth.userId == author else { throw DirectoryWriteError.invalid }
            let resource = VineyardExternalResource(id: id, vineyardId: vineyardId, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, contactName: optional(contact), phone: optional(phone), email: optional(email), notes: optional(notes), isActive: active, deletedAt: nil)
            let repo = SupabaseExternalResourceRepository()
            let saved: VineyardExternalResource
            if let existing { saved = try await repo.update(resource, expected: existing) } else { saved = try await repo.create(resource) }
            guard auth.userId == author else { return }
            onSaved(saved)
            dismiss()
        } catch { self.error = (error as? DirectoryWriteError)?.errorDescription ?? "Save could not be confirmed. Your form is retained. Reconnect and retry; newer directory edits will not be overwritten." }
    }
}
