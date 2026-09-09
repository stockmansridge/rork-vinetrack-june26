import SwiftUI

struct SprayTripCorrectionEditor: View {
    let tripId: UUID
    let report: SprayReportPayloadV1
    let machines: [VineyardMachine]
    let tractors: [Tractor]
    let sprayEquipment: [SprayEquipmentItem]
    let onSaved: (SprayReportPayloadV1) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var machineId: UUID?
    @State private var tractorId: UUID?
    @State private var sprayEquipmentId: UUID?
    @State private var fuelRateText: String
    @State private var startHoursText: String
    @State private var endHoursText: String
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    init(
        tripId: UUID,
        report: SprayReportPayloadV1,
        machines: [VineyardMachine],
        tractors: [Tractor],
        sprayEquipment: [SprayEquipmentItem],
        onSaved: @escaping (SprayReportPayloadV1) -> Void
    ) {
        self.tripId = tripId
        self.report = report
        self.machines = machines
        self.tractors = tractors
        self.sprayEquipment = sprayEquipment
        self.onSaved = onSaved
        _machineId = State(initialValue: report.equipment.machineId)
        _tractorId = State(initialValue: report.equipment.tractorId)
        _sprayEquipmentId = State(initialValue: report.equipment.sprayEquipmentId)
        _fuelRateText = State(initialValue: Self.text(report.equipment.fuelConsumptionLPerHour))
        _startHoursText = State(initialValue: Self.text(report.equipment.startEngineHours))
        _endHoursText = State(initialValue: Self.text(report.equipment.endEngineHours))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Equipment") {
                    Picker("Machine", selection: $machineId) {
                        Text("Not recorded").tag(UUID?.none)
                        ForEach(machines) { machine in Text(machine.displayName).tag(Optional(machine.id)) }
                    }
                    Picker("Legacy tractor", selection: $tractorId) {
                        Text("Not recorded").tag(UUID?.none)
                        ForEach(tractors) { tractor in Text(tractor.displayName).tag(Optional(tractor.id)) }
                    }
                    Picker("Spray unit", selection: $sprayEquipmentId) {
                        Text("Not recorded").tag(UUID?.none)
                        ForEach(sprayEquipment) { unit in Text(unit.name).tag(Optional(unit.id)) }
                    }
                }
                Section {
                    numericField("Fuel use (L/hr)", text: $fuelRateText)
                    numericField("Start engine hours", text: $startHoursText)
                    numericField("End engine hours", text: $endHoursText)
                } header: {
                    Text("Fuel and engine hours")
                } footer: {
                    Text("Saving creates an audited correction. Leave a field blank only when it is genuinely not recorded.")
                }
            }
            .navigationTitle("Correct equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(isSaving || validationError != nil)
                }
            }
            .alert("Correction not saved", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func numericField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).keyboardType(.decimalPad)
    }

    private var validationError: String? {
        let fuel = number(fuelRateText)
        let start = number(startHoursText)
        let end = number(endHoursText)
        if !fuelRateText.trimmingCharacters(in: .whitespaces).isEmpty && (fuel == nil || fuel! <= 0 || fuel! >= 1000) { return "Enter a fuel rate greater than 0 and below 1000 L/hr." }
        if !startHoursText.trimmingCharacters(in: .whitespaces).isEmpty && (start == nil || start! < 0) { return "Enter valid start engine hours." }
        if !endHoursText.trimmingCharacters(in: .whitespaces).isEmpty && (end == nil || end! < 0) { return "Enter valid end engine hours." }
        if let start, let end, end < start { return "End engine hours cannot be lower than start engine hours." }
        return nil
    }

    @MainActor
    private func save() async {
        if let validationError { errorMessage = validationError; return }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await SprayReportRepository.shared.correctMetadata(
                tripId: tripId,
                expectedVersion: report.metadataCorrectionVersion ?? 0,
                machineId: machineId,
                tractorId: tractorId,
                sprayEquipmentId: sprayEquipmentId,
                operatorUserId: report.trip.operatorId,
                fuelConsumptionLPerHour: number(fuelRateText),
                startEngineHours: number(startHoursText),
                endEngineHours: number(endHoursText)
            )
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = "The correction could not be saved. Refresh the report and try again."
        }
    }

    private func number(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let parsed = Double(trimmed), parsed.isFinite else { return nil }
        return parsed
    }

    private static func text(_ value: Double?) -> String { value.map { String(format: "%g", $0) } ?? "" }
}
