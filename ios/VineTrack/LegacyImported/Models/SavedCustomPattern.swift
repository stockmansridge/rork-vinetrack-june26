import Foundation

nonisolated struct SavedCustomPattern: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var name: String
    var sequence: [Double]
    var startRow: Int
    var totalRows: Int

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        name: String = "",
        sequence: [Double] = [],
        startRow: Int = 1,
        totalRows: Int = 20
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.name = name
        self.sequence = sequence
        self.startRow = startRow
        self.totalRows = totalRows
    }

    var formattedSequence: String {
        sequence.map { formatPath($0) }.joined(separator: ", ")
    }

    private func formatPath(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.1f", value)
        }
        return String(format: "%.1f", value)
    }
}
