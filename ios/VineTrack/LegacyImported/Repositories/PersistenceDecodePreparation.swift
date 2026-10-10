import Foundation

/// Independently owned decoder on a worker queue. It never reads or writes application state.
nonisolated enum PersistenceDecodePreparation {
    struct Prepared<T: Sendable>: Sendable {
        let bytes: Data
        let value: T
        let readMilliseconds: Double
        let decodeMilliseconds: Double
        let offMain: Bool
    }

    static func read<T: Decodable & Sendable>(_ type: T.Type, url: URL) async throws -> Prepared<T> {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let readStart = ProcessInfo.processInfo.systemUptime
                    let bytes = try Data(contentsOf: url)
                    let readMilliseconds = (ProcessInfo.processInfo.systemUptime - readStart) * 1000
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let decodeStart = ProcessInfo.processInfo.systemUptime
                    let value = try decoder.decode(T.self, from: bytes)
                    continuation.resume(returning: Prepared(bytes: bytes, value: value,
                        readMilliseconds: readMilliseconds,
                        decodeMilliseconds: (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000,
                        offMain: !Thread.isMainThread))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
