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
    #if DEBUG
    var durableSaveFailureForTesting: ((String) -> Error?)?
    #endif

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "com.rork.vinetrack", category: "PersistenceStore")
    private struct DecodedSnapshot {
        let bytes: Data
        let value: Any
    }
    // Only audited, Sendable value-type collections are memoized. Every load
    // still reads the actual file, including durable read-back gates.
    private var decodedSnapshots: [String: DecodedSnapshot] = [:]
    private let snapshotByteLimit: Int = 24 * 1024 * 1024
    private var pinEncodingMemo: PinEncodingMemo?
    #if DEBUG
    var onPersistenceMeasurementForTesting: ((PersistenceMeasurement) -> Void)?
    #endif

    private func canMemoize<T>(_ type: T.Type, key: String) -> Bool {
        (key == "vinetrack_pins" && type == [VinePin].self)
            || (key == "vinetrack_paddocks" && type == [Paddock].self)
            || (key == "vinetrack_saved_chemicals" && type == [SavedChemical].self)
    }

    private func retainSnapshot<T>(_ value: T, bytes: Data, key: String) {
        guard canMemoize(T.self, key: key), bytes.count <= snapshotByteLimit,
              PersistenceDecodeEligibility.permits(.classify(key), bytes: bytes) else { return }
        decodedSnapshots.removeValue(forKey: key)
        if decodedSnapshots.values.reduce(bytes.count + (pinEncodingMemo?.bytes.count ?? 0), { $0 + $1.bytes.count }) > snapshotByteLimit {
            decodedSnapshots.removeAll()
        }
        if bytes.count + (pinEncodingMemo?.bytes.count ?? 0) <= snapshotByteLimit {
            decodedSnapshots[key] = DecodedSnapshot(bytes: bytes, value: value)
        }
    }

    private func retainPinEncoding(_ memo: PinEncodingMemo) {
        guard memo.bytes.count <= snapshotByteLimit else { pinEncodingMemo = nil; return }
        if decodedSnapshots.values.reduce(memo.bytes.count, { $0 + $1.bytes.count }) > snapshotByteLimit {
            decodedSnapshots.removeAll()
        }
        pinEncodingMemo = memo
    }

    /// Pure preparation, not an async write. A synchronous save only reuses
    /// these bytes if its complete pin value matches bit-for-bit/string-for-string.
    func preparePinEncoding() async {
        guard pinEncodingMemo == nil,
              let pins = decodedSnapshots["vinetrack_pins"]?.value as? [VinePin] else { return }
        var measurement = PersistenceMeasurement(dataset: .pins, operation: .prepare)
        measurement.records = pins.count
        defer { report(measurement) }
        do {
            let prepared = try await PersistenceEncodePreparation.encode(pins)
            // A newer synchronous encoder has precedence over speculative work.
            guard pinEncodingMemo == nil else { return }
            retainPinEncoding(PinEncodingMemo(pins: pins, bytes: prepared.bytes))
            measurement.codecMilliseconds = prepared.encodeMilliseconds
            measurement.bytes = prepared.bytes.count
            measurement.offMain = prepared.offMain
            measurement.succeeded = true
        } catch {
            // Actual saves still use the original encoder/failure contract.
        }
    }

    private func recordCount<T>(_ value: T) -> Int? {
        (value as? any Collection)?.count
    }

    private func report(_ measurement: PersistenceMeasurement) {
        PerformanceCapture.shared.persistence(measurement)
        #if DEBUG
        onPersistenceMeasurementForTesting?(measurement)
        #endif
    }

    /// Speculative read-only preparation. A stale result is harmless: the next
    /// synchronous load validates exact file bytes before using it. No state,
    /// failure callback, sync cursor or acknowledgement changes here.
    func prepareDecode<T: Decodable & Sendable>(_ type: T.Type, key: String) async {
        guard canMemoize(type, key: key), decodedSnapshots[key] == nil else { return }
        var measurement = PersistenceMeasurement(dataset: .classify(key), operation: .prepare)
        defer { report(measurement) }
        do {
            let prepared = try await PersistenceDecodePreparation.read(type, url: fileURL(for: key))
            // Never replace a snapshot installed by a newer synchronous load.
            guard decodedSnapshots[key] == nil else { return }
            retainSnapshot(prepared.value, bytes: prepared.bytes, key: key)
            measurement.readMilliseconds = prepared.readMilliseconds
            measurement.codecMilliseconds = prepared.decodeMilliseconds
            measurement.bytes = prepared.bytes.count
            measurement.records = recordCount(prepared.value)
            measurement.offMain = prepared.offMain
            measurement.succeeded = true
        } catch {
            // The authoritative load retains the established missing/corrupt
            // handling, including callbacks and quarantine, exactly as before.
        }
    }

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
        let performanceSpan = PerformanceCapture.shared.begin("persistence read and JSON decode")
        defer { PerformanceCapture.shared.end(performanceSpan) }
        var measurement = PersistenceMeasurement(dataset: .classify(key), operation: .read)
        defer { report(measurement) }
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            decodedSnapshots.removeValue(forKey: key)
            measurement.succeeded = true
            return .missing
        }
        do {
            let readStart = ProcessInfo.processInfo.systemUptime
            let data = try Data(contentsOf: url)
            measurement.readMilliseconds = (ProcessInfo.processInfo.systemUptime - readStart) * 1000
            measurement.bytes = data.count
            if canMemoize(T.self, key: key), let snapshot = decodedSnapshots[key],
               snapshot.bytes == data, let value = snapshot.value as? T {
                measurement.reusedDecode = true
                measurement.changed = false
                measurement.records = recordCount(value)
                measurement.succeeded = true
                return .decoded(value)
            }
            decodedSnapshots.removeValue(forKey: key)
            let decodeStart = ProcessInfo.processInfo.systemUptime
            defer { measurement.codecMilliseconds = (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000 }
            let value = try decoder.decode(T.self, from: data)
            retainSnapshot(value, bytes: data, key: key)
            measurement.records = recordCount(value)
            measurement.succeeded = true
            return .decoded(value)
        } catch {
            decodedSnapshots.removeValue(forKey: key)
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
        let performanceSpan = PerformanceCapture.shared.begin("persistence JSON encode and atomic save")
        defer { PerformanceCapture.shared.end(performanceSpan) }
        try? encodeAndSave(value, key: key, durable: false)
    }

    /// Durable variant of `save`: encoding and disk-write failures THROW
    /// instead of being silently ignored. Used for payloads (like the block
    /// cache) whose sync must not report success — or advance a watermark —
    /// until the data is verifiably on disk.
    func saveOrThrow<T: Encodable>(_ value: T, key: String) throws {
        let performanceSpan = PerformanceCapture.shared.begin("persistence durable JSON encode and atomic save")
        defer { PerformanceCapture.shared.end(performanceSpan) }
        #if DEBUG
        if let error = durableSaveFailureForTesting?(key) { throw error }
        #endif
        try encodeAndSave(value, key: key, durable: true)
    }

    private func encodeAndSave<T: Encodable>(_ value: T, key: String, durable: Bool) throws {
        var measurement = PersistenceMeasurement(dataset: .classify(key), operation: durable ? .durableSave : .save)
        measurement.records = recordCount(value)
        defer { report(measurement) }
        let encodeStart = ProcessInfo.processInfo.systemUptime
        let data: Data
        do {
            if key == "vinetrack_pins", let pins = value as? [VinePin],
               let memo = pinEncodingMemo, memo.matches(pins) {
                data = memo.bytes
                measurement.reusedEncode = true
            } else {
                data = try encoder.encode(value)
                if key == "vinetrack_pins", let pins = value as? [VinePin] {
                    // Single bounded immutable result; failed writes never turn
                    // this into evidence that anything was persisted.
                    retainPinEncoding(PinEncodingMemo(pins: pins, bytes: data))
                }
            }
        }
        catch {
            measurement.codecMilliseconds = (ProcessInfo.processInfo.systemUptime - encodeStart) * 1000
            throw error
        }
        measurement.codecMilliseconds = (ProcessInfo.processInfo.systemUptime - encodeStart) * 1000
        measurement.bytes = data.count
        let url = fileURL(for: key)
        // Only non-durable collection saves compare disk bytes to avoid a
        // redundant rewrite. Durable saves must write regardless; reading a
        // photo-heavy cache solely for diagnostics would add main-thread work.
        // Their changed flag remains unknown, not inferred from an encode memo.
        if !durable && canMemoize(T.self, key: key) {
            let readStart = ProcessInfo.processInfo.systemUptime
            if let persisted = try? Data(contentsOf: url) {
                measurement.changed = persisted != data
            }
            measurement.readMilliseconds = (ProcessInfo.processInfo.systemUptime - readStart) * 1000
        }
        if !durable && measurement.changed == false {
            measurement.succeeded = true
            return
        }
        // Durable callers ALWAYS perform and wait for the atomic write,
        // including identical bytes. No new suspension or reordering exists.
        let writeStart = ProcessInfo.processInfo.systemUptime
        defer { measurement.writeMilliseconds = (ProcessInfo.processInfo.systemUptime - writeStart) * 1000 }
        try data.write(to: url, options: [.atomic])
        if decodedSnapshots[key]?.bytes != data { decodedSnapshots.removeValue(forKey: key) }
        measurement.succeeded = true
    }

    func remove(key: String) {
        try? removeOrThrow(key: key)
    }

    func removeOrThrow(key: String) throws {
        decodedSnapshots.removeValue(forKey: key)
        if key == "vinetrack_pins" { pinEncodingMemo = nil }
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Move a corrupt payload aside so the next save starts from a clean file
    /// WITHOUT overwriting the evidence (or a still-recoverable cache).
    /// Returns the quarantine location, or nil when there was nothing to move.
    @discardableResult
    func quarantine(key: String) -> URL? {
        decodedSnapshots.removeValue(forKey: key)
        if key == "vinetrack_pins" { pinEncodingMemo = nil }
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
