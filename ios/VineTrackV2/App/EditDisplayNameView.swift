import SwiftUI

struct EditDisplayNameView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        !trimmed.isEmpty && trimmed != (auth.userName ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
            } header: {
                Text("Display Name")
            } footer: {
                Text("This name appears on records you create, such as pins, trips, and spray jobs.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(!hasChanges || isSaving)
            }
        }
        .onAppear {
            name = auth.userName ?? ""
            isFocused = true
        }
    }

    private func save() async {
        guard hasChanges, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let success = await auth.updateDisplayName(trimmed)
        if success {
            dismiss()
        } else {
            errorMessage = auth.errorMessage ?? "Could not update name. Please try again."
        }
    }
}
