import Foundation

/// Frozen automatic placement awaiting an explicit mapped aisle/row confirmation.
/// The save closure captures the original observation and resolved attachment;
/// later GPS or heading updates are never consulted.
struct PendingMappedAisleConfirmation: Identifiable {
    struct Choice: Identifiable {
        let id: UUID = UUID()
        let aisleNumber: Double
        let rowNumber: Int
        let side: PinSide
        let confirm: @MainActor () -> Void

        var label: String {
            let sideLabel = side == .left ? "Left" : "Right"
            return "Aisle \(aisleNumber.formatted()) · Row \(rowNumber) · \(sideLabel)"
        }
    }

    let id: UUID = UUID()
    let paddockName: String
    let choices: [Choice]
}
