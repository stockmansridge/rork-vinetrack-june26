import Foundation
import os

enum LegacyStorage {
    static let storageDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("VineTrackData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

@MainActor
final class PersistenceStore {
    static let shared = PersistenceStore()

    /// Outcome of loading a persisted JSON payload. Distinguishes "no file"
    /// (fresh install / never saved) from "file exists but cannot be read or
    /// decoded", so callers never mistake a corrupt cache for an empty one.
    enum LoadOutcome<T> {
        case missing
        case decoded(T)
        case failed(Error)
    }

    /// Diagnostics hook fired whenever a stored payload exists but fails to
    /// read or decode: (persistence key, underlying error).
    var onDecodeFailure: ((String, Error) -> Void)?

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.rork.vinetrack", category: "PersistenceStore")

    init(directory: URL = LegacyStorage.storageDirectory) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    /// Load with an explicit outcome. A decode failure is logged with the
    /// persistence key and underlying error (never silently swallowed) and
    /// reported through `onDecodeFailure`.
    func loadOutcome<T: Decodable>(key: String) -> LoadOutcome<T> {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: url)
            return .decoded(try decoder.decode(T.self, from: data))
        } catch {
            logger.error("Load FAILED for persistence key '\(key, privacy: .public)': \(String(describing: error), privacy: .public)")
            #if DEBUG
            print("[PersistenceStore] load FAILED for key '\(key)': \(error)")
            #endif
            onDecodeFailure?(key, error)
            return .failed(error)
        }
    }

    func load<T: Decodable>(key: String) -> T? {
        let outcome: LoadOutcome<T> = loadOutcome(key: key)
        switch outcome {
        case .decoded(let value):
            return value
        case .missing, .failed:
            return nil
        }
    }

    func save<T: Encodable>(_ value: T, key: String) {
        let url = fileURL(for: key)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    /// Durable variant of `save`: encoding and disk-write failures THROW
    /// instead of being silently ignored. Used for payloads (like the block
    /// cache) whose sync must not report success — or advance a watermark —
    /// until the data is verifiably on disk.
    func saveOrThrow<T: Encodable>(_ value: T, key: String) throws {
        let data = try encoder.encode(value)
        try data.write(to: fileURL(for: key), options: [.atomic])
    }

    func remove(key: String) {
        let url = fileURL(for: key)
        try? FileManager.default.removeItem(at: url)
    }

    /// Move a corrupt payload aside so the next save starts from a clean file
    /// WITHOUT overwriting the evidence (or a still-recoverable cache).
    /// Returns the quarantine location, or nil when there was nothing to move.
    @discardableResult
    func quarantine(key: String) -> URL? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let unique = UUID().uuidString.prefix(8)
        let destination = directory.appendingPathComponent("\(key).corrupt-\(stamp)-\(unique).json")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            logger.error("Quarantined corrupt payload for key '\(key, privacy: .public)' at \(destination.lastPathComponent, privacy: .public)")
            return destination
        } catch {
            // Moving failed. NEVER delete the original — it may hold the only
            // copy of still-recoverable data. Try to at least copy the
            // evidence aside; if that also fails, leave the file in place.
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                logger.error("Quarantine move failed for key '\(key, privacy: .public)'; copied evidence to \(destination.lastPathComponent, privacy: .public) and retained the original")
                return destination
            } catch {
                logger.error("Quarantine FAILED for key '\(key, privacy: .public)': \(String(describing: error), privacy: .public). Corrupt file retained in place for possible recovery.")
                return nil
            }
        }
    }
}
