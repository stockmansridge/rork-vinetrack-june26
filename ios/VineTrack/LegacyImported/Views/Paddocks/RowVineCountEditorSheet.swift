import SwiftUI

/// Identifies the row currently open in the per-row vine-count editor.
struct RowVineCountTarget: Identifiable {
    /// Real-world row number — the stable key the editor works in.
    let number: Int
    /// The automatically calculated estimate for this row.
    let calculated: Int

    var id: Int { number }
}

/// The single-row vine-count editor (sql/188).
///
/// Deliberately minimal — this is not a row-management workflow. It shows the
/// three numbers a grower needs and nothing else:
///
/// ```text
/// Row 12
///
/// Calculated: 187 vines
/// Manual override: [182]
///
/// Using: 182 vines
/// ```
///
/// Clearing the field immediately returns to the calculated value.
struct RowVineCountEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let rowNumber: Int
    let calculated: Int
    let currentOverride: Int?
    /// Called with the new manual count, or nil to clear it.
    let onSave: (Int?) -> Void

    @State private var text: String = ""
    @FocusState private var isFieldFocused: Bool

    private var parsed: PaddockRowVineCount.OverrideInput {
        PaddockRowVineCount.parseOverride(text)
    }

    /// The count that will actually be used once saved.
    private var effective: Int {
        parsed.value ?? calculated
    }

    private var canSave: Bool { !parsed.isInvalid }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Calculated") {
                        Text("\(calculated) vines")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Manual override")
                        Spacer()
                        TextField("\(calculated)", text: $text)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .focused($isFieldFocused)
                    }

                    if let message = parsed.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Vines in this row")
                } footer: {
                    Text("Leave blank to use the calculated estimate from this row's length and the block's vine spacing. Whole vines only.")
                }

                Section {
                    HStack {
                        Text("Using")
                            .font(.headline)
                        Spacer()
                        Text("\(effective) vines")
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .foregroundStyle(VineyardTheme.earthBrown)
                    }
                    if parsed.value != nil {
                        Button("Use calculated (\(calculated) vines)") {
                            text = ""
                        }
                        .font(.footnote)
                    }
                } footer: {
                    Text(parsed.value == nil
                        ? "This row is using its calculated estimate."
                        : "This manual count replaces the calculated estimate everywhere this row's vines are counted, including piece-rate pruning costing.")
                }
            }
            .navigationTitle("Row \(rowNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(parsed.value)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if let currentOverride { text = "\(currentOverride)" }
                isFieldFocused = true
            }
        }
        .presentationDetents([.medium])
    }
}
