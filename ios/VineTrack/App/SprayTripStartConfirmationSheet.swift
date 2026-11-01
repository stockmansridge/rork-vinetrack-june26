import SwiftUI

/// Final operational confirmation shown only when live spray tracking is about to begin.
struct SprayTripStartConfirmationSheet: View {
    let machineName: String
    let latestEngineHours: Double?
    let tanks: [SprayTank]
    let formatter: RegionFormatter
    let onStart: (Double?, SprayInitialTankAmounts, @escaping (String?) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startEngineHoursText: String = ""
    @State private var actualInput: SprayInitialTankInput
    @State private var retainedActuals: SprayInitialTankAmounts?
    @State private var isStarting = false
    @State private var startError: String?

    init(machineName: String, latestEngineHours: Double?, tanks: [SprayTank],
         formatter: RegionFormatter, retainedActuals: SprayInitialTankAmounts? = nil,
         onStart: @escaping (Double?, SprayInitialTankAmounts, @escaping (String?) -> Void) -> Void) {
        self.machineName = machineName
        self.latestEngineHours = latestEngineHours
        self.tanks = tanks
        self.formatter = formatter
        self.onStart = onStart
        _retainedActuals = State(initialValue: retainedActuals)
        _actualInput = State(initialValue: retainedActuals.flatMap { amounts in
            SprayInitialTankAmounts.firstTank(in: tanks).map { SprayInitialTankInput(amounts: amounts, tank: $0, formatter: formatter) }
        } ?? SprayInitialTankInput())
    }

    private var enteredActuals: SprayInitialTankAmounts? {
        guard let tank = SprayInitialTankAmounts.firstTank(in: tanks) else { return nil }
        if let retainedActuals { return retainedActuals.isValid(for: tank) ? retainedActuals : nil }
        return actualInput.resolved(tank: tank, formatter: formatter)
    }

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
                } header: {
                    HStack {
                        Text("Engine hours")
                        FieldInfoButton(title: "Engine hours", message: "Enter the meter reading now. Leave blank to calculate fuel from pause-aware trip duration.")
                    }
                }
                if let tank = SprayInitialTankAmounts.firstTank(in: tanks) {
                    Section {
                        SprayInitialTankActualsEditor(tank: tank, tankCount: tanks.count,
                            formatter: formatter, input: $actualInput)
                            .disabled(isStarting || retainedActuals != nil)
                    }
                }
                if let startError {
                    Section { Text(startError).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Start Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isStarting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStarting ? "Starting…" : "Start Trip") {
                        guard let amounts = enteredActuals else { return }
                        retainedActuals = amounts
                        isStarting = true
                        startError = nil
                        onStart(parsedStartEngineHours, amounts) { message in
                            isStarting = false
                            startError = message
                        }
                    }
                        .fontWeight(.semibold)
                        .disabled(isStarting || enteredActuals == nil || !SprayStartRateReview.isReviewable(tanks) ||
                            (!startEngineHoursText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsedStartEngineHours == nil))
                }
            }
            .interactiveDismissDisabled(isStarting)
        }
    }
}
