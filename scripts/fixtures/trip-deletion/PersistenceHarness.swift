import Foundation
// Harness boundary only. Native tests use the real PersistenceStore.
@MainActor final class PersistenceStore {
    static let shared = PersistenceStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    enum LoadOutcome<T> { case missing, decoded(T), failed(Error) }
    var durableSaveFailureForTesting: ((String) -> Error?)?
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    func loadOutcome<T: Decodable>(key: String) -> LoadOutcome<T> {
        let file = directory.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        do { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return .decoded(try decoder.decode(T.self, from: Data(contentsOf: file)))
        } catch { return .failed(error) }
    }
    func saveOrThrow<T: Encodable>(_ value: T, key: String) throws {
        if let error = durableSaveFailureForTesting?(key) { throw error }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(value).write(to: directory.appendingPathComponent(key + ".json"), options: .atomic)
    }
}
