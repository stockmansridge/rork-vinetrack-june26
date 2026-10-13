import Foundation

/// Lossless semantic JSON for unrecognized registered-use evidence, never rate authority.
nonisolated enum ChemicalStoredJSON: Codable, Sendable, Hashable {
    case null, bool(Bool), number(Decimal), string(String)
    case array([ChemicalStoredJSON]), object([String: ChemicalStoredJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ChemicalStoredJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ChemicalStoredJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Dynamic keys preserve forward-compatible nested fields alongside typed projections.
nonisolated struct ChemicalStoredKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
