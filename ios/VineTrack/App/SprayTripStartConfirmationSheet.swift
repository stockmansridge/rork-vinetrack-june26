import SwiftUI

/// Final operational confirmation shown only when live spray tracking is about to begin.
struct SprayTripStartConfirmationSheet: View {
    let machineName: String
    let latestEngineHours: Double?
    let onStart: (Double?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startEngineHoursText: String = ""

    private var parsedStartEngineHours: Double? {
        let normalized = startEngineHoursText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value >= 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Machine") {
                    Label(machineName.isEmpty ? "Not selected" : machineName, systemImage: "tractor.fill")
                }
                Section {
                    TextField("Start engine hours (optional)", text: $startEngineHoursText)
                        .keyboardType(.decimalPad)
                    if let latestEngineHours {
                        Text("Last recorded: \(latestEngineHours.formatted(.number.precision(.fractionLength(0...1)))) hrs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Enter the meter reading now. Leave blank to calculate fuel from pause-aware trip duration.")
                }
            }
            .navigationTitle("Start Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Trip") { onStart(parsedStartEngineHours) }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
