import SwiftUI

/// Identifies the row currently open in the per-row vine-count editor.
struct RowVineCountTarget: Identifiable {
    /// Real-world row number — the stable key the editor works in.
    let number: Int
    /// The automatic calculation for this row, including WHY there is no
    /// number when the block can't produce one yet.
    let calculation: PaddockRowVineCount.Calculation

    var id: Int { number }

    /// The calculated estimate, or nil when it can't be calculated.
    var calculated: Int? { calculation.value }
}

/// The single-row vine-count editor (sql/188).
///
/// Deliberately minimal — this is not a row-management workflow. It shows the
/// three numbers a grower needs and nothing else:
///
/// ```text
/// Row 12
///
/// Calculated vines: 187
/// Manual override: [182]
///
/// Using: 182 vines
/// ```
///
/// The calculated value is ALWAYS derived automatically from this row's own
/// length and the block's vine spacing — the grower never has to type anything
/// to get a vine count. Clearing the field immediately returns to it.
struct RowVineCountEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let rowNumber: Int
    /// The automatic calculation, carrying its reason when unavailable.
    let calculation: PaddockRowVineCount.Calculation
    let currentOverride: Int?
    /// Called with the new manual count, or nil to clear it.
    let onSave: (Int?) -> Void

    @State private var text: String = ""
    @FocusState private var isFieldFocused: Bool

    private var calculated: Int? { calculation.value }

    private var parsed: PaddockRowVineCount.OverrideInput {
        PaddockRowVineCount.parseOverride(text)
    }

    /// The count that will actually be used once saved. Nil only when there is
    /// neither an override nor a calculable estimate.
    private var effective: Int? {
        parsed.value ?? calculated
    }

    private var canSave: Bool { !parsed.isInvalid }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Calculated vines") {
                        Text(calculated.map { "\($0)" } ?? "—")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    if let message = calculation.message {
                        Label(message, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Manual override")
                        Spacer()
                        TextField(calculated.map { "\($0)" } ?? "—", text: $text)
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
                        Text(effective.map { "\($0) vines" } ?? "—")
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .foregroundStyle(VineyardTheme.earthBrown)
                    }
                    if parsed.value != nil {
                        Button(calculated.map { "Use calculated (\($0) vines)" } ?? "Clear manual count") {
                            text = ""
                        }
                        .font(.footnote)
                    }
                } footer: {
                    Text(usingFooter)
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
                // The calculated value is already on screen; this only
                // restores any manual count the row already carries.
                if let currentOverride { text = "\(currentOverride)" }
                isFieldFocused = true
            }
        }
        .presentationDetents([.medium])
    }

    private var usingFooter: String {
        if parsed.value != nil {
            return "This manual count replaces the calculated estimate everywhere this row's vines are counted, including piece-rate pruning costing."
        }
        if let message = calculation.message {
            return message
        }
        return "This row is using its calculated estimate."
    }
}
