import SwiftUI

/// Explicit whole-pass checklist. Returning to Review preserves the original selected evidence.
struct SprayWorkAreaSelectionView: View {
    let choices: [SprayWorkAreaSelection.Choice]
    let configuration: SprayPassConfiguration
    @Binding var selected: [SprayWorkAreaSelection.Selected]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select complete machine travel passes. Selection never marks a pass as sprayed.")
                    if configuration == .overRow {
                        Text("Over-Row: one travel pass, two controller row equivalents. Treatment context is retained; no second coverage occurrence is completed.")
                    }
                }
                if choices.isEmpty {
                    Section { Text("No physical passes are available. Check the selected blocks and stored row geometry.") }
                }
                Section("Whole physical passes") {
                    ForEach(choices) { choice in
                        let current = selected.first { $0.choiceId == choice.id }
                        Button {
                            if let current { selected.removeAll { $0.id == current.id } }
                            else { selected.append(SprayWorkAreaSelection.select(choice, configuration: configuration)) }
                        } label: {
                            HStack {
                                Image(systemName: current == nil ? "circle" : "checkmark.circle.fill")
                                VStack(alignment: .leading) {
                                    Text(choice.title)
                                    Text(choice.hasGeometry ? "Frozen row geometry • treatment area not certified" : "Missing or uncertain geometry")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let current, !SprayWorkAreaSelection.retained(current, choices: choices, configuration: configuration) {
                                        Text("Selection changed: remove and explicitly select again.").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }.frame(minHeight: 44)
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("spray.work.\(choice.id)")
                            .accessibilityValue(current == nil ? "Not selected" : "Selected")
                    }
                }
                let unavailable = selected.filter { s in !choices.contains { $0.id == s.choiceId } }
                if !unavailable.isEmpty {
                    Section("Retained unavailable selections") {
                        ForEach(unavailable) { item in
                            Button("Remove \(item.title)") { selected.removeAll { $0.id == item.id } }
                        }
                    }
                }
                Section { Text(SprayWorkAreaSelection.routeAdmissionMessage).font(.footnote) }
            }
            .navigationTitle("Select Work Area")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
