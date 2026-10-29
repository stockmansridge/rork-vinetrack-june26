import Foundation

/// Separate diagnostic evidence only. Never changes a source file, queue or receipt.
/// No response bodies, credentials, decoded values or free-form error descriptions.
nonisolated enum RecoveryDecodeEvidence {
    struct Entry: Codable, Sendable {
        let capturedAt: Date
        let source: String
        let operation: String
        let failure: String
        let codingPath: [String]
        let missingKey: String?
        let expectedType: String?
    }

    static func entry(_ error: Error, source: String, operation: String) -> Entry? {
        let context: DecodingError.Context
        let failure: String
        var missingKey: String?
        var expectedType: String?
        switch error {
        case let DecodingError.keyNotFound(key, c):
            context = c; failure = "keyNotFound"; missingKey = key.stringValue
        case let DecodingError.typeMismatch(type, c):
            context = c; failure = "typeMismatch"; expectedType = String(describing: type)
        case let DecodingError.valueNotFound(type, c):
            context = c; failure = "valueNotFound"; expectedType = String(describing: type)
        case let DecodingError.dataCorrupted(c):
            context = c; failure = "dataCorrupted"
        default: return nil
        }
        return Entry(capturedAt: Date(), source: source, operation: operation,
                     failure: failure, codingPath: context.codingPath.map {
                         $0.intValue.map { "[\($0)]" } ?? $0.stringValue
                     }, missingKey: missingKey, expectedType: expectedType)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, source: String, operation: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            record(error, source: source, operation: operation)
            throw error
        }
    }

    static func record(_ error: Error, source: String, operation: String) {
        guard let evidence = entry(error, source: source, operation: operation),
              let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let directory = root.appendingPathComponent("RecoveryDecodeDiagnostics-v1", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Append-only unique file; failure must never mask the original error.
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(evidence).write(to: directory.appendingPathComponent(UUID().uuidString + ".json"), options: [.atomic, .completeFileProtection])
        } catch {
            // The original caller still throws/returns its unchanged failure.
        }
    }
}
