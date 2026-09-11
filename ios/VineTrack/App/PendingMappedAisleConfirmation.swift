import Foundation

/// Frozen automatic placement awaiting an explicit mapped aisle/row confirmation.
/// The save closure captures the original observation and resolved attachment;
/// later GPS or heading updates are never consulted.
struct PendingMappedAisleConfirmation: Identifiable {
    let id: UUID = UUID()
    let paddockName: String
    let aisleNumber: Double
    let rowNumber: Int
    let confirm: @MainActor () -> Void

    var choiceLabel: String {
        "Aisle \(aisleNumber.formatted()) · Row \(rowNumber)"
    }
}
