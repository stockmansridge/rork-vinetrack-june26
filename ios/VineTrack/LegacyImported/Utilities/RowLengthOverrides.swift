import Foundation

/// Calculation-only metre overrides keyed by real-world (including decimal) row number.
nonisolated struct RowLengthOverrides: Codable, Sendable, Hashable {
    let values: [String: Double]

    init(_ values: [String: Double]) {
        self.values = values.filter { Double($0.key)?.isFinite == true && $0.value.isFinite && $0.value > 0 }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: Key.self) else {
            values = [:]
            return
        }
        var valid: [String: Double] = [:]
        for key in container.allKeys {
            if let number = Double(key.stringValue), number.isFinite,
               let value = try? container.decode(Double.self, forKey: key), value.isFinite, value > 0 {
                valid[key.stringValue] = value
            }
        }
        values = valid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    func length(for number: Double) -> Double? {
        guard number.isFinite else { return nil }
        return values.sorted { $0.key < $1.key }.first { Double($0.key) == number }?.value
    }
}
