import Foundation

/// Independently owned encoder on a worker queue; prepares bytes but never commits them.
nonisolated enum PersistenceEncodePreparation {
    struct Prepared: Sendable {
        let bytes: Data
        let encodeMilliseconds: Double
        let offMain: Bool
    }

    static func encode<T: Encodable & Sendable>(_ value: T) async throws -> Prepared {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let start = ProcessInfo.processInfo.systemUptime
                    let bytes = try encoder.encode(value)
                    continuation.resume(returning: Prepared(bytes: bytes,
                        encodeMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                        offMain: !Thread.isMainThread))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
